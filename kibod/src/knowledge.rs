use crate::journal::bound_description_text;
use crate::model::{epoch, make_id, valid_id};
use crate::store::{Store, hex_sha256};
use crate::workflow::{AttemptState, ConversationWorkflow};
use anyhow::{Context, Result, anyhow, bail};
use reqwest::header::{AUTHORIZATION, HeaderValue};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File};
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

pub const RECIPE_VERSION: u64 = 1;
const MAX_READER_BYTES: usize = 5 * 1024 * 1024;
const DEFAULT_INSTRUCTIONS: &str = r#"# Kibo knowledge instructions

Turn each source into a concise, durable Markdown note.

- Preserve concrete facts, decisions, questions, and useful context.
- Distinguish what the source says from any inference.
- Prefer short sections and descriptive headings.
- Do not invent facts or repeat the transcript verbatim.
- Keep the note useful when read without the original conversation.
"#;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DocumentKind {
    Conversation,
    Web,
}

impl DocumentKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Conversation => "conversation",
            Self::Web => "web",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Document {
    pub key: String,
    pub id: String,
    pub kind: DocumentKind,
    pub title: String,
    pub body: String,
    pub content_sha256: String,
    pub origin: Option<String>,
    /// Every image the canonical body references, in body order. The
    /// committed note's `## Images` appendix is a mechanical derivative of
    /// this list; because each entry's id and description also appear in the
    /// body text, `content_sha256` covers everything the appendix renders.
    pub images: Vec<NoteImage>,
}

/// One image reference in the canonical body: the id plus the first-success
/// description value, `None` when the description failed terminally.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteImage {
    pub id: String,
    pub description: Option<String>,
}

impl Document {
    fn new(
        key: String,
        id: String,
        kind: DocumentKind,
        title: String,
        body: String,
        origin: Option<String>,
        images: Vec<NoteImage>,
    ) -> Self {
        let content_sha256 = hex_sha256(body.as_bytes());
        Self {
            key,
            id,
            kind,
            title,
            body,
            content_sha256,
            origin,
            images,
        }
    }

    pub fn wiki_file(&self) -> String {
        format!("sources/{}--{}.md", self.kind.as_str(), self.id)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebSource {
    pub id: String,
    pub url: String,
    pub title: String,
    pub created_at: u64,
    pub updated_at: u64,
    pub content_sha256: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct KnowledgeCheckpoint {
    #[serde(default = "checkpoint_format")]
    pub format: u64,
    #[serde(default)]
    pub documents: BTreeMap<String, IngestReceipt>,
}

fn checkpoint_format() -> u64 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IngestReceipt {
    pub content_sha256: String,
    pub instructions_sha256: String,
    pub recipe_version: u64,
    pub generation: u64,
    pub ingested_at: u64,
    pub title: String,
    pub kind: String,
    pub wiki_file: String,
}

#[derive(Debug, Clone)]
pub struct SourceStatus {
    pub key: String,
    pub id: String,
    pub kind: DocumentKind,
    pub title: String,
    pub origin: Option<String>,
    pub has_content: bool,
    pub dirty: bool,
    pub generation: u64,
    pub wiki_file: Option<String>,
}

#[derive(Debug, Clone)]
pub struct MarkdownFile {
    pub path: String,
    pub label: String,
}

#[derive(Clone)]
pub struct JinaReader {
    client: reqwest::Client,
    api_key: Option<String>,
}

impl JinaReader {
    pub fn from_env() -> Self {
        let api_key = std::env::var("JINA_API_KEY")
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(90))
            .build()
            .expect("build Jina Reader HTTP client");
        Self { client, api_key }
    }

    pub fn has_api_key(&self) -> bool {
        self.api_key.is_some()
    }

    pub async fn read(&self, target: &str) -> Result<ReaderDocument> {
        let parsed = reqwest::Url::parse(target).context("URL is not valid")?;
        if !matches!(parsed.scheme(), "http" | "https") {
            bail!("URL must start with http:// or https://");
        }
        let target = parsed.as_str();
        let reader_url = format!("https://r.jina.ai/{target}");
        let mut request = self.client.get(reader_url).header("x-no-cache", "true");
        if let Some(key) = &self.api_key {
            let value = HeaderValue::from_str(&format!("Bearer {key}"))
                .context("JINA_API_KEY is not a valid HTTP header value")?;
            request = request.header(AUTHORIZATION, value);
        }
        let response = request.send().await.context("fetch URL with Jina Reader")?;
        let status = response.status();
        let bytes = response
            .bytes()
            .await
            .context("read Jina Reader response")?;
        if !status.is_success() {
            bail!(
                "Jina Reader returned {status}: {}",
                String::from_utf8_lossy(&bytes)
                    .chars()
                    .take(500)
                    .collect::<String>()
            );
        }
        if bytes.len() > MAX_READER_BYTES {
            bail!("Jina Reader response exceeded 5 MiB");
        }
        let content =
            String::from_utf8(bytes.to_vec()).context("Jina Reader returned non-UTF-8")?;
        if content.trim().is_empty() {
            bail!("Jina Reader returned an empty document");
        }
        Ok(parse_reader_document(target, content))
    }
}

#[derive(Debug, Clone)]
pub struct ReaderDocument {
    pub url: String,
    pub title: String,
    pub content: String,
}

fn parse_reader_document(url: &str, content: String) -> ReaderDocument {
    let title = content
        .lines()
        .find_map(|line| line.strip_prefix("Title: "))
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .unwrap_or(url)
        .chars()
        .take(160)
        .collect();
    ReaderDocument {
        url: url.to_string(),
        title,
        content,
    }
}

pub fn ensure_project(store: &Store, project_id: &str) -> Result<()> {
    store.project(project_id)?;
    let root = knowledge_root(store, project_id);
    fs::create_dir_all(root.join("web"))?;
    fs::create_dir_all(root.join("wiki/sources"))?;
    if !root.join("instructions.md").exists() {
        write_text_atomic(&root.join("instructions.md"), DEFAULT_INSTRUCTIONS)?;
    }
    if !root.join("ingested.json").exists() {
        write_json_atomic(
            &root.join("ingested.json"),
            &KnowledgeCheckpoint {
                format: 1,
                documents: BTreeMap::new(),
            },
        )?;
    }
    if !root.join("wiki/index.md").exists() {
        write_text_atomic(
            &root.join("wiki/index.md"),
            "# Knowledge index\n\n_No sources have been ingested yet._\n",
        )?;
    }
    Ok(())
}

pub fn instructions(store: &Store, project_id: &str) -> Result<(String, String)> {
    ensure_project(store, project_id)?;
    let text = fs::read_to_string(knowledge_root(store, project_id).join("instructions.md"))?;
    let hash = hex_sha256(text.as_bytes());
    Ok((text, hash))
}

pub fn conversation_document(
    store: &Store,
    project_id: &str,
    conversation_id: &str,
) -> Result<Document> {
    let conversation = store.conversation(project_id, conversation_id)?;
    let records = store.records(project_id, conversation_id)?;
    // Claimed media renders through the workflow's single ordered projection:
    // TurnContent order for transcripts and captions, first-success precedence
    // for descriptions — the same view every other consumer renders.
    let workflow = ConversationWorkflow::from_records(&records);
    let mut claimed = HashSet::new();
    let mut sections = Vec::new();
    let mut images = Vec::new();

    for turn in workflow.turns() {
        claimed.extend(turn.clips.iter().cloned());
        claimed.extend(turn.images.iter().cloned());
        let content = workflow.turn_content(&turn.id).unwrap_or_default();
        let mut lines = Vec::new();
        let user = content.user_text();
        let user = user.trim();
        if meaningful(user) {
            lines.push(user.to_string());
        }
        for image in content.images() {
            // Caption uniformity: captions already sit in `user_text` at
            // their media position, so the reference line never repeats them.
            if let Some(line) = image_reference(&workflow, &image.id, &mut images) {
                lines.push(line);
            }
        }
        if !lines.is_empty() {
            sections.push(format!("## You\n\n{}", lines.join("\n")));
        }
        if let AttemptState::Succeeded(reply) = &turn.reply
            && meaningful(&reply.text)
        {
            sections.push(format!("## Kibo\n\n{}", reply.text.trim()));
        }
    }

    // Unclaimed transcripts keep reading the raw event so legacy journals
    // (and fixtures) without clip commitments still render; unclaimed images
    // always have an image event, so both trail in journal order.
    let mut seen_unclaimed = HashSet::new();
    for event in &records {
        match event["kind"].as_str() {
            Some("transcript") => {
                let Some(clip_id) = event["clip"].as_str() else {
                    continue;
                };
                if claimed.contains(clip_id) || !seen_unclaimed.insert(clip_id.to_string()) {
                    continue;
                }
                if let Some(text) = event["text"].as_str().filter(|text| meaningful(text)) {
                    sections.push(format!("## You\n\n{}", text.trim()));
                }
            }
            Some("image") => {
                let Some(image_id) = event["id"].as_str() else {
                    continue;
                };
                if claimed.contains(image_id) || !seen_unclaimed.insert(image_id.to_string()) {
                    continue;
                }
                // Only successfully described unclaimed images contribute,
                // exactly like unclaimed successful transcripts; an empty
                // description is as meaningless as an empty transcript.
                if matches!(
                    workflow.image(image_id).map(|work| &work.description),
                    Some(AttemptState::Succeeded(record))
                        if !bound_description_text(&record.text).is_empty()
                ) && let Some(line) = image_reference(&workflow, image_id, &mut images)
                {
                    sections.push(format!("## You\n\n{line}"));
                }
            }
            _ => {}
        }
    }

    let body = sections.join("\n\n");
    Ok(Document::new(
        format!("conversation:{conversation_id}"),
        conversation_id.to_string(),
        DocumentKind::Conversation,
        conversation.name,
        body,
        None,
        images,
    ))
}

/// Render one image reference line for the canonical body and record the
/// appendix entry it implies. Successful descriptions render
/// `[Image {id}: {text}]`, terminal failures render the bare `[Image {id}]`,
/// and pending descriptions contribute nothing yet — the note recompiles when
/// the description value lands.
fn image_reference(
    workflow: &ConversationWorkflow,
    image_id: &str,
    images: &mut Vec<NoteImage>,
) -> Option<String> {
    match &workflow.image(image_id)?.description {
        AttemptState::Succeeded(record) => {
            let text = bound_description_text(&record.text);
            let (line, description) = if text.is_empty() {
                (format!("[Image {image_id}]"), None)
            } else {
                (format!("[Image {image_id}: {text}]"), Some(text))
            };
            images.push(NoteImage {
                id: image_id.to_string(),
                description,
            });
            Some(line)
        }
        AttemptState::TerminalFailure(_) => {
            images.push(NoteImage {
                id: image_id.to_string(),
                description: None,
            });
            Some(format!("[Image {image_id}]"))
        }
        _ => None,
    }
}

fn meaningful(text: &str) -> bool {
    crate::workflow::meaningful_user_text(text) && text.trim() != "[nothing to answer]"
}

pub fn import_reader_document(
    store: &Store,
    project_id: &str,
    reader: ReaderDocument,
) -> Result<WebSource> {
    ensure_project(store, project_id)?;
    let existing = list_web_sources(store, project_id)?
        .into_iter()
        .find(|source| source.url == reader.url);
    let now = epoch();
    let hash = hex_sha256(reader.content.as_bytes());
    let mut source = existing.unwrap_or_else(|| WebSource {
        id: make_id(&reader.title),
        url: reader.url.clone(),
        title: reader.title.clone(),
        created_at: now,
        updated_at: now,
        content_sha256: hash.clone(),
    });
    source.title = reader.title;
    source.updated_at = now;
    source.content_sha256 = hash.clone();
    let directory = knowledge_root(store, project_id)
        .join("web")
        .join(&source.id);
    let version = directory.join("versions").join(&hash);
    fs::create_dir_all(&version)?;
    let content_path = version.join("content.md");
    if !content_path.exists() {
        write_text_atomic(&content_path, &reader.content)?;
    }
    write_json_atomic(&directory.join("source.json"), &source)?;
    Ok(source)
}

pub fn web_document(store: &Store, project_id: &str, source_id: &str) -> Result<Document> {
    if !valid_id(source_id) {
        bail!("invalid web source ID");
    }
    let source = read_web_source(store, project_id, source_id)?;
    let path = knowledge_root(store, project_id)
        .join("web")
        .join(source_id)
        .join("versions")
        .join(&source.content_sha256)
        .join("content.md");
    let body = fs::read_to_string(&path)
        .with_context(|| format!("read imported source {}", path.display()))?;
    let actual = hex_sha256(body.as_bytes());
    if actual != source.content_sha256 {
        bail!("imported source content hash does not match source.json");
    }
    Ok(Document::new(
        format!("web:{source_id}"),
        source_id.to_string(),
        DocumentKind::Web,
        source.title,
        body,
        Some(source.url),
        Vec::new(),
    ))
}

pub fn list_web_sources(store: &Store, project_id: &str) -> Result<Vec<WebSource>> {
    ensure_project(store, project_id)?;
    let mut sources = Vec::new();
    for entry in fs::read_dir(knowledge_root(store, project_id).join("web"))? {
        let path = entry?.path().join("source.json");
        if path.exists() {
            sources.push(read_json(&path)?);
        }
    }
    sources.sort_by(|left: &WebSource, right: &WebSource| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.id.cmp(&right.id))
    });
    Ok(sources)
}

pub fn read_web_source(store: &Store, project_id: &str, source_id: &str) -> Result<WebSource> {
    ensure_project(store, project_id)?;
    read_json(
        &knowledge_root(store, project_id)
            .join("web")
            .join(source_id)
            .join("source.json"),
    )
    .with_context(|| format!("web source {source_id} does not exist"))
}

pub fn checkpoint(store: &Store, project_id: &str) -> Result<KnowledgeCheckpoint> {
    ensure_project(store, project_id)?;
    read_json(&knowledge_root(store, project_id).join("ingested.json"))
}

pub fn needs_ingest(
    receipt: Option<&IngestReceipt>,
    document: &Document,
    instructions_sha256: &str,
) -> bool {
    receipt.is_none_or(|receipt| {
        receipt.content_sha256 != document.content_sha256
            || receipt.instructions_sha256 != instructions_sha256
            || receipt.recipe_version != RECIPE_VERSION
    })
}

pub fn commit_ingestion(
    store: &Store,
    project_id: &str,
    document: &Document,
    instructions_sha256: &str,
    generated_markdown: &str,
) -> Result<IngestReceipt> {
    ensure_project(store, project_id)?;
    let root = knowledge_root(store, project_id);
    let mut checkpoint = checkpoint(store, project_id)?;
    let generation = checkpoint
        .documents
        .get(&document.key)
        .map_or(1, |receipt| receipt.generation + 1);
    let receipt = IngestReceipt {
        content_sha256: document.content_sha256.clone(),
        instructions_sha256: instructions_sha256.to_string(),
        recipe_version: RECIPE_VERSION,
        generation,
        ingested_at: epoch(),
        title: document.title.clone(),
        kind: document.kind.as_str().to_string(),
        wiki_file: document.wiki_file(),
    };
    let mut note = provenance_frontmatter(document, generation, generated_markdown);
    note.push_str(&images_appendix(project_id, document));
    write_text_atomic(&root.join("wiki").join(&receipt.wiki_file), &note)?;
    checkpoint
        .documents
        .insert(document.key.clone(), receipt.clone());
    write_index(&root.join("wiki/index.md"), &checkpoint)?;
    // This is deliberately last: an interrupted run remains dirty and retries
    // against the same stable wiki filename.
    write_json_atomic(&root.join("ingested.json"), &checkpoint)?;
    Ok(receipt)
}

fn provenance_frontmatter(document: &Document, generation: u64, markdown: &str) -> String {
    let origin = document
        .origin
        .as_deref()
        .map(|origin| format!("origin: \"{}\"\n", yaml_string(origin)))
        .unwrap_or_default();
    format!(
        "---\nsource_id: \"{}\"\nsource_kind: {}\ncontent_sha256: {}\ngeneration: {}\n{}---\n\n{}\n",
        yaml_string(&document.key),
        document.kind.as_str(),
        document.content_sha256,
        generation,
        origin,
        markdown.trim()
    )
}

fn yaml_string(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', " ")
}

/// The `## Images` appendix is machine-written like frontmatter: every image
/// the canonical body references reappears under a stable `#img-{id}` anchor
/// with an `<img>` at the immutable content route and its description text in
/// an escaped blockquote. Emitted only when the body references images, so
/// image-free notes stay byte-identical to the appendix-free format.
fn images_appendix(project_id: &str, document: &Document) -> String {
    let mut seen = HashSet::new();
    let mut entries = String::new();
    for image in &document.images {
        // Upload enforces `valid_id`; a handcrafted journal id that fails it
        // must never reach an HTML attribute or URL.
        if !valid_id(&image.id) || !seen.insert(image.id.as_str()) {
            continue;
        }
        entries.push_str(&format!(
            "\n### Image {id} <a id=\"img-{id}\"></a>\n\n![Image {id}](/v1/projects/{project_id}/conversations/{conversation_id}/images/{id}/content)\n",
            id = image.id,
            conversation_id = document.id,
        ));
        if let Some(text) = &image.description {
            entries.push_str(&format!("\n{}\n", escaped_blockquote(text)));
        }
    }
    if entries.is_empty() {
        String::new()
    } else {
        // The separator is the note's trust boundary: the renderer gives only
        // the region after the LAST occurrence the anchor-bearing policy, and
        // commit_ingestion always writes the appendix last, so body content
        // that reproduces the separator only donates itself to the untrusted
        // body region.
        format!("\n{}\n## Images\n{entries}", IMAGES_APPENDIX_SEPARATOR)
    }
}

/// Exact separator line committed between a note's body and its
/// machine-written images appendix. The renderer splits on the last
/// occurrence; see `images_appendix`.
pub(crate) const IMAGES_APPENDIX_SEPARATOR: &str = "<!-- kibod:images -->";

/// Mechanically neutralize untrusted description text for the committed note:
/// HTML is entity-escaped, Markdown structure characters are
/// backslash-escaped, and every line is folded into a blockquote, so a
/// hostile description cannot form headings, anchors, links, or raw HTML.
fn escaped_blockquote(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '\\' | '`' | '*' | '_' | '[' | ']' | '#' => {
                escaped.push('\\');
                escaped.push(character);
            }
            _ => escaped.push(character),
        }
    }
    escaped
        .lines()
        .map(|line| {
            if line.is_empty() {
                ">".to_string()
            } else {
                format!("> {line}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn write_index(path: &Path, checkpoint: &KnowledgeCheckpoint) -> Result<()> {
    let mut markdown = String::from(
        "# Knowledge index\n\nA generated catalog of the sources Kibo has ingested.\n\n",
    );
    if checkpoint.documents.is_empty() {
        markdown.push_str("_No sources have been ingested yet._\n");
    } else {
        for (key, receipt) in &checkpoint.documents {
            markdown.push_str(&format!(
                "- [{}]({}) — `{}` · generation {}\n",
                receipt.title.replace('[', "\\[").replace(']', "\\]"),
                receipt.wiki_file,
                key,
                receipt.generation
            ));
        }
    }
    write_text_atomic(path, &markdown)
}

pub fn source_statuses(store: &Store, project_id: &str) -> Result<Vec<SourceStatus>> {
    let (_, instructions_hash) = instructions(store, project_id)?;
    let checkpoint = checkpoint(store, project_id)?;
    let mut statuses = Vec::new();
    for conversation in store.list_conversations(project_id)? {
        let document = conversation_document(store, project_id, &conversation.id)?;
        let receipt = checkpoint.documents.get(&document.key);
        let has_content = !document.body.trim().is_empty();
        let dirty = has_content && needs_ingest(receipt, &document, &instructions_hash);
        statuses.push(SourceStatus {
            key: document.key,
            id: document.id,
            kind: DocumentKind::Conversation,
            title: document.title,
            origin: None,
            has_content,
            dirty,
            generation: receipt.map_or(0, |receipt| receipt.generation),
            wiki_file: receipt.map(|receipt| receipt.wiki_file.clone()),
        });
    }
    for source in list_web_sources(store, project_id)? {
        let document = web_document(store, project_id, &source.id)?;
        let receipt = checkpoint.documents.get(&document.key);
        let dirty = needs_ingest(receipt, &document, &instructions_hash);
        statuses.push(SourceStatus {
            key: document.key,
            id: document.id,
            kind: DocumentKind::Web,
            title: document.title,
            origin: document.origin,
            has_content: true,
            dirty,
            generation: receipt.map_or(0, |receipt| receipt.generation),
            wiki_file: receipt.map(|receipt| receipt.wiki_file.clone()),
        });
    }
    Ok(statuses)
}

pub fn markdown_files(store: &Store, project_id: &str) -> Result<Vec<MarkdownFile>> {
    ensure_project(store, project_id)?;
    let root = knowledge_root(store, project_id);
    let mut files = vec![MarkdownFile {
        path: "instructions.md".into(),
        label: "Instructions".into(),
    }];
    let index = root.join("wiki/index.md");
    if index.exists() {
        files.push(MarkdownFile {
            path: "wiki/index.md".into(),
            label: "Knowledge index".into(),
        });
    }
    let sources = root.join("wiki/sources");
    if sources.exists() {
        for entry in fs::read_dir(sources)? {
            let path = entry?.path();
            if path.extension().and_then(|value| value.to_str()) != Some("md") {
                continue;
            }
            let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
                continue;
            };
            files.push(MarkdownFile {
                path: format!("wiki/sources/{name}"),
                label: name.trim_end_matches(".md").replace("--", " · "),
            });
        }
    }
    files[2..].sort_by(|left, right| left.label.cmp(&right.label));
    Ok(files)
}

pub fn read_markdown(store: &Store, project_id: &str, relative: &str) -> Result<String> {
    ensure_project(store, project_id)?;
    let path = Path::new(relative);
    if path.is_absolute()
        || path.extension().and_then(|value| value.to_str()) != Some("md")
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        bail!("invalid Markdown path");
    }
    let full = knowledge_root(store, project_id).join(path);
    fs::read_to_string(&full).with_context(|| format!("read {}", full.display()))
}

fn knowledge_root(store: &Store, project_id: &str) -> PathBuf {
    store
        .root()
        .join("projects")
        .join(project_id)
        .join("knowledge")
}

/// Return the canonical, generated wiki directory that a read-only query
/// agent may inspect. Project validation and initialization happen before the
/// path is returned so route input can never select an arbitrary directory.
pub fn wiki_root(store: &Store, project_id: &str) -> Result<PathBuf> {
    if !valid_id(project_id) {
        bail!("invalid project id");
    }
    let root = fs::canonicalize(store.root())?;
    let projects = canonical_direct_child(&root, &root.join("projects"), "projects directory")?;
    let project =
        canonical_direct_child(&projects, &projects.join(project_id), "project directory")?;
    let project_metadata = store.project(project_id)?;
    if project_metadata.id != project_id {
        bail!("project metadata does not match its directory");
    }
    let knowledge_path = project.join("knowledge");
    if knowledge_path.exists() {
        let knowledge = canonical_direct_child(&project, &knowledge_path, "knowledge directory")?;
        let wiki_path = knowledge.join("wiki");
        if wiki_path.exists() {
            canonical_direct_child(&knowledge, &wiki_path, "wiki directory")?;
        }
    }

    ensure_project(store, project_id)?;
    let knowledge = canonical_direct_child(&project, &knowledge_path, "knowledge directory")?;
    canonical_direct_child(&knowledge, &knowledge.join("wiki"), "wiki directory")
}

fn canonical_direct_child(parent: &Path, path: &Path, label: &str) -> Result<PathBuf> {
    let metadata =
        fs::symlink_metadata(path).with_context(|| format!("inspect {}", path.display()))?;
    if metadata.file_type().is_symlink() {
        bail!("{label} must not be a symbolic link");
    }
    let canonical =
        fs::canonicalize(path).with_context(|| format!("resolve {}", path.display()))?;
    if canonical.parent() != Some(parent) || canonical.file_name() != path.file_name() {
        bail!("{label} resolves outside its expected parent");
    }
    Ok(canonical)
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let bytes = fs::read(path).with_context(|| format!("read {}", path.display()))?;
    serde_json::from_slice(&bytes).with_context(|| format!("decode {}", path.display()))
}

fn write_json_atomic(path: &Path, value: &impl Serialize) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(value)?;
    write_bytes_atomic(path, &bytes)
}

fn write_text_atomic(path: &Path, value: &str) -> Result<()> {
    write_bytes_atomic(path, value.as_bytes())
}

fn write_bytes_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("{} has no parent", path.display()))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("knowledge"),
        uuid::Uuid::new_v4().simple()
    ));
    let result = (|| -> Result<()> {
        let mut file = File::create(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn seeded(events: &[Value]) -> (tempfile::TempDir, Store, String) {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", Some("Ideas")).unwrap();
        for event in events {
            store
                .append_fixture("kibo", &conversation.id, event.clone())
                .unwrap();
        }
        (temporary, store, conversation.id)
    }

    #[test]
    fn image_turns_render_reference_lines_in_turn_content_order() {
        let (_dir, store, conversation_id) = seeded(&[
            json!({"kind":"clip", "id":"clip-1", "recorded_at":1000}),
            json!({"kind":"transcript", "clip":"clip-1", "text":"look at the whiteboard"}),
            json!({"kind":"image", "id":"img-1", "recorded_at":2000, "caption":"standup board"}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"], "images":["img-1"]}),
            json!({"kind":"description", "image":"img-1", "text":"A whiteboard covered in sticky notes"}),
            json!({"kind":"reply", "turn":"turn-1", "text":"Nice board!"}),
        ]);

        let document = conversation_document(&store, "kibo", &conversation_id).unwrap();

        assert_eq!(
            document.body,
            "## You\n\nlook at the whiteboard\nstandup board\n[Image img-1: A whiteboard covered in sticky notes]\n\n## Kibo\n\nNice board!"
        );
        assert_eq!(
            document.images,
            vec![NoteImage {
                id: "img-1".into(),
                description: Some("A whiteboard covered in sticky notes".into()),
            }]
        );
        let again = conversation_document(&store, "kibo", &conversation_id).unwrap();
        assert_eq!(document.body, again.body);
        assert_eq!(document.content_sha256, again.content_sha256);
    }

    #[test]
    fn image_identity_is_part_of_the_canonical_hash() {
        let description = "the exact same description";
        let events = |id: &str| {
            [
                json!({"kind":"image", "id":id, "recorded_at":1000}),
                json!({"kind":"turn", "id":"turn-1", "images":[id]}),
                json!({"kind":"description", "image":id, "text":description}),
            ]
        };
        let (_dir_a, store_a, conversation_a) = seeded(&events("img-a"));
        let (_dir_b, store_b, conversation_b) = seeded(&events("img-b"));

        let first = conversation_document(&store_a, "kibo", &conversation_a).unwrap();
        let second = conversation_document(&store_b, "kibo", &conversation_b).unwrap();

        assert_ne!(first.body, second.body);
        assert_ne!(first.content_sha256, second.content_sha256);
    }

    #[test]
    fn pending_descriptions_are_omitted_until_the_value_lands() {
        let (_dir, store, conversation_id) = seeded(&[
            json!({"kind":"image", "id":"img-1", "recorded_at":1000, "caption":"from my desk"}),
            json!({"kind":"turn", "id":"turn-1", "images":["img-1"]}),
            json!({"kind":"reply", "turn":"turn-1", "text":"On it."}),
        ]);

        let pending = conversation_document(&store, "kibo", &conversation_id).unwrap();
        assert_eq!(pending.body, "## You\n\nfrom my desk\n\n## Kibo\n\nOn it.");
        assert!(pending.images.is_empty());

        store
            .append_fixture(
                "kibo",
                &conversation_id,
                json!({"kind":"description", "image":"img-1", "text":"a tidy desk"}),
            )
            .unwrap();
        let described = conversation_document(&store, "kibo", &conversation_id).unwrap();

        assert_eq!(
            described.body,
            "## You\n\nfrom my desk\n[Image img-1: a tidy desk]\n\n## Kibo\n\nOn it."
        );
        assert_ne!(pending.content_sha256, described.content_sha256);
    }

    #[test]
    fn terminal_description_failures_render_a_bare_reference_without_the_caption() {
        let (_dir, store, conversation_id) = seeded(&[
            json!({"kind":"image", "id":"img-1", "recorded_at":1000, "caption":"standup board"}),
            json!({"kind":"turn", "id":"turn-1", "images":["img-1"]}),
            json!({"kind":"description_error", "image":"img-1", "attempt":3, "terminal":true, "error":"blocked"}),
        ]);

        let document = conversation_document(&store, "kibo", &conversation_id).unwrap();

        assert_eq!(document.body, "## You\n\nstandup board\n[Image img-1]");
        // Caption uniformity: the caption appears once as user text and never
        // inside the image reference line.
        assert_eq!(document.body.matches("standup board").count(), 1);
        assert_eq!(
            document.images,
            vec![NoteImage {
                id: "img-1".into(),
                description: None,
            }]
        );
    }

    #[test]
    fn description_authority_is_first_success() {
        let (_dir, store, conversation_id) = seeded(&[
            json!({"kind":"image", "id":"img-1", "recorded_at":1000}),
            json!({"kind":"turn", "id":"turn-1", "images":["img-1"]}),
            json!({"kind":"description", "image":"img-1", "text":"first description"}),
            json!({"kind":"description", "image":"img-1", "text":"second description"}),
        ]);

        let document = conversation_document(&store, "kibo", &conversation_id).unwrap();

        assert_eq!(document.body, "## You\n\n[Image img-1: first description]");
    }

    #[test]
    fn unclaimed_described_images_render_trailing_sections() {
        let (_dir, store, conversation_id) = seeded(&[
            json!({"kind":"image", "id":"img-9", "recorded_at":1000}),
            json!({"kind":"image", "id":"img-10", "recorded_at":2000}),
            json!({"kind":"image", "id":"img-11", "recorded_at":3000}),
            json!({"kind":"description", "image":"img-9", "text":"a stray photo"}),
            json!({"kind":"description_error", "image":"img-11", "attempt":3, "terminal":true, "error":"blocked"}),
        ]);

        let document = conversation_document(&store, "kibo", &conversation_id).unwrap();

        assert_eq!(document.body, "## You\n\n[Image img-9: a stray photo]");
        assert_eq!(
            document.images,
            vec![NoteImage {
                id: "img-9".into(),
                description: Some("a stray photo".into()),
            }]
        );
    }

    #[test]
    fn images_appendix_survives_hostile_descriptions() {
        let hostile = format!(
            "### Fake heading\n<a id=\"img-fake\"></a><script>alert(1)</script>[claim](sources/evil.md) {}",
            "x".repeat(5000)
        );
        let (_dir, store, conversation_id) = seeded(&[
            json!({"kind":"image", "id":"img-1", "recorded_at":1000}),
            json!({"kind":"turn", "id":"turn-1", "images":["img-1"]}),
            json!({"kind":"description", "image":"img-1", "text":hostile}),
        ]);
        let document = conversation_document(&store, "kibo", &conversation_id).unwrap();
        let (_, instructions_hash) = instructions(&store, "kibo").unwrap();

        let receipt =
            commit_ingestion(&store, "kibo", &document, &instructions_hash, "# Note").unwrap();
        let note = read_markdown(&store, "kibo", &format!("wiki/{}", receipt.wiki_file)).unwrap();

        assert!(note.contains("\n## Images\n"));
        assert!(note.contains("### Image img-1 <a id=\"img-img-1\"></a>"));
        assert!(note.contains(&format!(
            "![Image img-1](/v1/projects/kibo/conversations/{conversation_id}/images/img-1/content)"
        )));
        // The description renders as one escaped blockquote line: no raw
        // HTML, no fake anchor, no heading, and the oversize tail is bounded.
        let blockquote = note
            .lines()
            .find(|line| line.starts_with("> "))
            .expect("appendix blockquote");
        assert!(blockquote.starts_with("> \\#\\#\\# Fake heading"));
        assert!(blockquote.contains("&lt;a id="));
        assert!(!note.contains("<script"));
        assert!(!note.contains("<a id=\"img-fake\""));
        assert!(!note.contains("[claim]"));
        assert!(blockquote.len() < 3 * 4096 + 16);
    }

    #[test]
    fn image_free_notes_are_byte_identical_to_the_legacy_format() {
        let (_dir, store, conversation_id) = seeded(&[
            json!({"kind":"clip", "id":"clip-1", "recorded_at":1000}),
            json!({"kind":"transcript", "clip":"clip-1", "text":"Keep it simple."}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            json!({"kind":"reply", "turn":"turn-1", "text":"Use values."}),
            json!({"kind":"transcript", "clip":"clip-9", "text":"stray thought"}),
        ]);
        let document = conversation_document(&store, "kibo", &conversation_id).unwrap();
        assert_eq!(
            document.body,
            "## You\n\nKeep it simple.\n\n## Kibo\n\nUse values.\n\n## You\n\nstray thought"
        );

        let receipt =
            commit_ingestion(&store, "kibo", &document, "instructions-hash", "# Note\n\nBody.")
                .unwrap();
        let note = read_markdown(&store, "kibo", &format!("wiki/{}", receipt.wiki_file)).unwrap();

        assert_eq!(
            note,
            format!(
                "---\nsource_id: \"conversation:{conversation_id}\"\nsource_kind: conversation\ncontent_sha256: {}\ngeneration: 1\n---\n\n# Note\n\nBody.\n",
                document.content_sha256
            )
        );
    }

    #[test]
    fn conversation_hash_ignores_processing_events() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", Some("Ideas")).unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"transcript", "clip":"c1", "text":"A useful idea"}),
            )
            .unwrap();
        let before = conversation_document(&store, "kibo", &conversation.id).unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"speech_ready", "turn":"t1", "samples":10, "rate":24000}),
            )
            .unwrap();
        let after = conversation_document(&store, "kibo", &conversation.id).unwrap();
        assert_eq!(before.body, after.body);
        assert_eq!(before.content_sha256, after.content_sha256);
    }

    #[cfg(unix)]
    #[test]
    fn query_wiki_root_rejects_a_symlink_escape() {
        use std::os::unix::fs::symlink;

        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let wiki = wiki_root(&store, "kibo").unwrap();
        fs::remove_dir_all(&wiki).unwrap();
        let outside = temporary.path().join("outside-wiki");
        fs::create_dir(&outside).unwrap();
        symlink(&outside, &wiki).unwrap();

        let error = wiki_root(&store, "kibo").unwrap_err();

        assert!(
            error
                .to_string()
                .contains("wiki directory must not be a symbolic link")
        );
        assert_eq!(fs::read_dir(outside).unwrap().count(), 0);
    }

    #[cfg(unix)]
    #[test]
    fn query_wiki_root_rejects_a_same_parent_project_symlink() {
        use std::os::unix::fs::symlink;

        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let other = store.create_project("Other").unwrap();
        let other_wiki = wiki_root(&store, &other.id).unwrap();
        fs::write(other_wiki.join("secret.md"), "sibling secret").unwrap();

        let projects = temporary.path().join("projects");
        let alias = projects.join("alias");
        symlink(projects.join(&other.id), &alias).unwrap();

        let error = wiki_root(&store, "alias").unwrap_err();

        assert!(
            error
                .to_string()
                .contains("project directory must not be a symbolic link")
        );
    }

    #[cfg(unix)]
    #[test]
    fn query_wiki_root_rejects_a_same_parent_wiki_symlink() {
        use std::os::unix::fs::symlink;

        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let wiki = wiki_root(&store, "kibo").unwrap();
        let knowledge = wiki.parent().unwrap();
        let sibling = knowledge.join("web");
        fs::remove_dir_all(&wiki).unwrap();
        symlink(&sibling, &wiki).unwrap();

        let error = wiki_root(&store, "kibo").unwrap_err();

        assert!(
            error
                .to_string()
                .contains("wiki directory must not be a symbolic link")
        );
    }

    #[test]
    fn imported_url_keeps_content_addressed_versions() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let first = import_reader_document(
            &store,
            "kibo",
            ReaderDocument {
                url: "https://example.com".into(),
                title: "Example".into(),
                content: "first".into(),
            },
        )
        .unwrap();
        let second = import_reader_document(
            &store,
            "kibo",
            ReaderDocument {
                url: "https://example.com".into(),
                title: "Example".into(),
                content: "second".into(),
            },
        )
        .unwrap();
        assert_eq!(first.id, second.id);
        let root = knowledge_root(&store, "kibo")
            .join("web")
            .join(first.id)
            .join("versions");
        assert!(root.join(hex_sha256(b"first")).join("content.md").exists());
        assert!(root.join(hex_sha256(b"second")).join("content.md").exists());
    }

    #[test]
    fn reader_title_is_extracted_without_changing_content() {
        let parsed = parse_reader_document(
            "https://example.com",
            "Title: An example\nURL Source: https://example.com\n\nMarkdown Content:\nHello".into(),
        );
        assert_eq!(parsed.title, "An example");
        assert!(parsed.content.contains("Markdown Content:"));
    }
}

use crate::model::{epoch, make_id, valid_id};
use crate::store::{Store, hex_sha256};
use anyhow::{Context, Result, anyhow, bail};
use reqwest::header::{AUTHORIZATION, HeaderValue};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
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
}

impl Document {
    fn new(
        key: String,
        id: String,
        kind: DocumentKind,
        title: String,
        body: String,
        origin: Option<String>,
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
    let transcripts: HashMap<&str, &str> = records
        .iter()
        .filter(|event| event["kind"] == "transcript")
        .filter_map(|event| Some((event["clip"].as_str()?, event["text"].as_str()?)))
        .collect();
    let replies: HashMap<&str, &str> = records
        .iter()
        .filter(|event| event["kind"] == "reply")
        .filter_map(|event| Some((event["turn"].as_str()?, event["text"].as_str()?)))
        .collect();
    let mut claimed = HashSet::new();
    let mut sections = Vec::new();

    for turn in records.iter().filter(|event| event["kind"] == "turn") {
        let clip_ids: Vec<&str> = turn["clips"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        claimed.extend(clip_ids.iter().copied());
        let user = clip_ids
            .iter()
            .filter_map(|clip_id| transcripts.get(clip_id).copied())
            .filter(|text| meaningful(text))
            .collect::<Vec<_>>()
            .join("\n");
        if !user.is_empty() {
            sections.push(format!("## You\n\n{}", user.trim()));
        }
        if let Some(reply) = turn["id"]
            .as_str()
            .and_then(|turn_id| replies.get(turn_id).copied())
            .filter(|text| meaningful(text))
        {
            sections.push(format!("## Kibo\n\n{}", reply.trim()));
        }
    }

    let mut seen_unclaimed = HashSet::new();
    for event in records.iter().filter(|event| event["kind"] == "transcript") {
        let Some(clip_id) = event["clip"].as_str() else {
            continue;
        };
        if claimed.contains(clip_id) || !seen_unclaimed.insert(clip_id) {
            continue;
        }
        if let Some(text) = event["text"].as_str().filter(|text| meaningful(text)) {
            sections.push(format!("## You\n\n{}", text.trim()));
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
    ))
}

fn meaningful(text: &str) -> bool {
    !matches!(
        text.trim(),
        "" | "[silent]" | "[no speech]" | "[nothing to answer]"
    )
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
    let note = provenance_frontmatter(document, generation, generated_markdown);
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
    use serde_json::json;

    #[test]
    fn conversation_hash_ignores_processing_events() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", Some("Ideas")).unwrap();
        store
            .append(
                "kibo",
                &conversation.id,
                json!({"kind":"transcript", "clip":"c1", "text":"A useful idea"}),
            )
            .unwrap();
        let before = conversation_document(&store, "kibo", &conversation.id).unwrap();
        store
            .append(
                "kibo",
                &conversation.id,
                json!({"kind":"speech_ready", "turn":"t1", "samples":10, "rate":24000}),
            )
            .unwrap();
        let after = conversation_document(&store, "kibo", &conversation.id).unwrap();
        assert_eq!(before.body, after.body);
        assert_eq!(before.content_sha256, after.content_sha256);
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

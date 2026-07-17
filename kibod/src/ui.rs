use crate::knowledge::{self, DocumentKind, SourceStatus};
use crate::model::CreateNamed;
use crate::state::{AppState, IngestOutcome};
use crate::workflow::{AttemptState, ConversationWorkflow, SpeechState, TurnWork};
use axum::Router;
use axum::extract::{Form, Path, Query, State};
use axum::http::{StatusCode, header};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use pulldown_cmark::{Options, Parser, html};
use serde::Deserialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

const CSS: &str = include_str!("../assets/app.css");
const JS: &str = include_str!("../assets/app.js");
const KNOWLEDGE_QUERY_JS: &str = include_str!("../assets/knowledge-query.js");
const HTMX: &str = include_str!("../assets/htmx.min.js");

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(index))
        .route("/app/{project_id}", get(project_page))
        .route(
            "/app/{project_id}/{conversation_id}",
            get(conversation_page),
        )
        .route(
            "/app/{project_id}/{conversation_id}/timeline",
            get(timeline_fragment),
        )
        .route("/app/{project_id}/knowledge", get(knowledge_page))
        .route(
            "/app/{project_id}/knowledge/query",
            get(knowledge_query_page),
        )
        .route(
            "/app/{project_id}/knowledge/files/{*path}",
            get(knowledge_file_page),
        )
        .route("/ui/projects", post(create_project))
        .route(
            "/ui/projects/{project_id}/conversations",
            post(create_conversation),
        )
        .route(
            "/ui/projects/{project_id}/knowledge/ingest",
            post(ingest_changed),
        )
        .route(
            "/ui/projects/{project_id}/knowledge/conversations/{conversation_id}/ingest",
            post(ingest_conversation),
        )
        .route(
            "/ui/projects/{project_id}/knowledge/import",
            post(import_url),
        )
        .route(
            "/ui/projects/{project_id}/knowledge/sources/{source_id}/ingest",
            post(ingest_web_source),
        )
        .route(
            "/ui/projects/{project_id}/knowledge/sources/{source_id}/refresh",
            post(refresh_web_source),
        )
        .route("/assets/app.css", get(asset_css))
        .route("/assets/app.js", get(asset_js))
        .route("/assets/knowledge-query.js", get(asset_knowledge_query_js))
        .route("/assets/htmx.min.js", get(asset_htmx))
}

#[derive(Debug, Default, Deserialize)]
struct KnowledgeQuery {
    #[serde(default)]
    notice: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ImportUrl {
    url: String,
}

async fn index(State(state): State<AppState>) -> Response {
    match state.store().list_projects() {
        Ok(projects) => match projects.into_iter().next() {
            Some(project) => Redirect::temporary(&format!("/app/{}", project.id)).into_response(),
            None => (StatusCode::INTERNAL_SERVER_ERROR, "No projects available").into_response(),
        },
        Err(error) => (StatusCode::INTERNAL_SERVER_ERROR, error.to_string()).into_response(),
    }
}

async fn project_page(State(state): State<AppState>, Path(project_id): Path<String>) -> Response {
    match render_project_page(&state, &project_id) {
        Ok(html) => Html(html).into_response(),
        Err(error) => (StatusCode::NOT_FOUND, error.to_string()).into_response(),
    }
}

async fn conversation_page(
    State(state): State<AppState>,
    Path((project_id, conversation_id)): Path<(String, String)>,
) -> Response {
    match render_page(&state, &project_id, &conversation_id) {
        Ok(html) => Html(html).into_response(),
        Err(error) => (StatusCode::NOT_FOUND, error.to_string()).into_response(),
    }
}

async fn timeline_fragment(
    State(state): State<AppState>,
    Path((project_id, conversation_id)): Path<(String, String)>,
) -> Response {
    match state.store().records(&project_id, &conversation_id) {
        Ok(records) => {
            Html(render_timeline(&project_id, &conversation_id, &records)).into_response()
        }
        Err(error) => (StatusCode::NOT_FOUND, error.to_string()).into_response(),
    }
}

async fn knowledge_page(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
    Query(query): Query<KnowledgeQuery>,
) -> Response {
    match render_knowledge_page(&state, &project_id, query.notice.as_deref()) {
        Ok(html) => Html(html).into_response(),
        Err(error) => (StatusCode::NOT_FOUND, error.to_string()).into_response(),
    }
}

async fn knowledge_query_page(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
) -> Response {
    match render_knowledge_query_page(&state, &project_id) {
        Ok(html) => Html(html).into_response(),
        Err(error) => (StatusCode::NOT_FOUND, error.to_string()).into_response(),
    }
}

async fn knowledge_file_page(
    State(state): State<AppState>,
    Path((project_id, path)): Path<(String, String)>,
) -> Response {
    match render_knowledge_file_page(&state, &project_id, &path) {
        Ok(html) => Html(html).into_response(),
        Err(error) => (StatusCode::NOT_FOUND, error.to_string()).into_response(),
    }
}

async fn create_project(
    State(state): State<AppState>,
    Form(request): Form<CreateNamed>,
) -> Response {
    match state.store().create_project(&request.name) {
        Ok(project) => Redirect::to(&format!("/app/{}", project.id)).into_response(),
        Err(error) => (StatusCode::BAD_REQUEST, error.to_string()).into_response(),
    }
}

async fn create_conversation(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
) -> Response {
    match state.store().create_conversation(&project_id, None) {
        Ok(conversation) => Redirect::to(&format!(
            "/app/{}/{}",
            conversation.project_id, conversation.id
        ))
        .into_response(),
        Err(error) => (StatusCode::BAD_REQUEST, error.to_string()).into_response(),
    }
}

async fn ingest_changed(State(state): State<AppState>, Path(project_id): Path<String>) -> Response {
    match state.ingest_changed(&project_id).await {
        Ok(summary) => Redirect::to(&format!(
            "/app/{}/knowledge?notice=ingested-{}-{}",
            url_component(&project_id),
            summary.ingested,
            summary.skipped
        ))
        .into_response(),
        Err(error) => knowledge_action_error(&project_id, error),
    }
}

async fn ingest_conversation(
    State(state): State<AppState>,
    Path((project_id, conversation_id)): Path<(String, String)>,
) -> Response {
    match state
        .ingest_conversation(&project_id, &conversation_id, true)
        .await
    {
        Ok(_) => knowledge_redirect(&project_id, "conversation-ingested"),
        Err(error) => knowledge_action_error(&project_id, error),
    }
}

async fn import_url(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
    Form(request): Form<ImportUrl>,
) -> Response {
    match state.import_url(&project_id, request.url.trim()).await {
        Ok((_, IngestOutcome::Ingested(_))) => knowledge_redirect(&project_id, "url-ingested"),
        Ok((_, IngestOutcome::Skipped)) => knowledge_redirect(&project_id, "url-unchanged"),
        Err(error) => knowledge_action_error(&project_id, error),
    }
}

async fn ingest_web_source(
    State(state): State<AppState>,
    Path((project_id, source_id)): Path<(String, String)>,
) -> Response {
    match state.ingest_web_source(&project_id, &source_id, true).await {
        Ok(_) => knowledge_redirect(&project_id, "source-reingested"),
        Err(error) => knowledge_action_error(&project_id, error),
    }
}

async fn refresh_web_source(
    State(state): State<AppState>,
    Path((project_id, source_id)): Path<(String, String)>,
) -> Response {
    match state.refresh_web_source(&project_id, &source_id).await {
        Ok((_, IngestOutcome::Ingested(_))) => knowledge_redirect(&project_id, "source-refreshed"),
        Ok((_, IngestOutcome::Skipped)) => knowledge_redirect(&project_id, "url-unchanged"),
        Err(error) => knowledge_action_error(&project_id, error),
    }
}

fn knowledge_redirect(project_id: &str, notice: &str) -> Response {
    Redirect::to(&format!(
        "/app/{}/knowledge?notice={}",
        url_component(project_id),
        notice
    ))
    .into_response()
}

fn knowledge_action_error(project_id: &str, error: anyhow::Error) -> Response {
    let body = format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"stylesheet\" href=\"/assets/app.css?v=4\"><title>Knowledge error · Kibo</title></head><body><main class=\"action-error\"><p class=\"eyebrow\">Knowledge ingestion</p><h1>That didn’t work.</h1><p>{}</p><a class=\"primary-link\" href=\"/app/{}/knowledge\">Back to knowledge</a></main></body></html>",
        escape(&error.to_string()),
        url_component(project_id)
    );
    (StatusCode::BAD_REQUEST, Html(body)).into_response()
}

async fn asset_css() -> impl IntoResponse {
    ([(header::CONTENT_TYPE, "text/css; charset=utf-8")], CSS)
}

async fn asset_js() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
        JS,
    )
}

async fn asset_knowledge_query_js() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
        KNOWLEDGE_QUERY_JS,
    )
}

async fn asset_htmx() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
        HTMX,
    )
}

fn render_page(
    state: &AppState,
    project_id: &str,
    conversation_id: &str,
) -> anyhow::Result<String> {
    let project = state.store().project(project_id)?;
    let conversation = state.store().conversation(project_id, conversation_id)?;
    let records = state.store().records(project_id, conversation_id)?;
    let last_seq = records
        .last()
        .and_then(|event| event["seq"].as_u64())
        .unwrap_or(0);

    let navigation = render_navigation(state, project_id, Some(conversation_id), false)?;

    let base = format!(
        "/v1/projects/{}/conversations/{}",
        url_component(project_id),
        url_component(conversation_id)
    );
    let page_url = format!(
        "/app/{}/{}",
        url_component(project_id),
        url_component(conversation_id)
    );
    let mock_notice = if state.ai().is_mock() {
        "<span class=\"mode-badge\">Mock AI</span>"
    } else {
        ""
    };
    Ok(format!(
        "<!doctype html>
<html lang=\"en\"><head>
<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">
<title>{conversation} · Kibo</title><meta name=\"description\" content=\"A durable voice conversation with Kibo\">
	<link rel=\"stylesheet\" href=\"/assets/app.css?v=4\"><script src=\"/assets/htmx.min.js\" defer></script><script src=\"/assets/app.js?v=4\" defer></script>
	</head><body data-project-id=\"{project_id}\" data-conversation-id=\"{conversation_id}\" data-last-seq=\"{last_seq}\" data-conversation-url=\"{base}\" data-timeline-url=\"{page_url}/timeline\" data-events-url=\"{base}/events\">
	<div class=\"app-shell\"><aside class=\"sidebar\"><div class=\"brand\"><span class=\"brand-mark\">k</span>Kibo</div>{navigation}
	<details class=\"new-item\"><summary>New project</summary><form method=\"post\" action=\"/ui/projects\"><label>Name<input name=\"name\" maxlength=\"100\" required></label><button> create </button></form></details>
</aside><main class=\"main\"><header class=\"conversation-header\"><div><p class=\"eyebrow\">{project} {mock_notice}</p><h1>{conversation}</h1></div><span id=\"connection-status\">Connecting…</span></header>
<section id=\"timeline\" class=\"timeline\" aria-live=\"polite\">{timeline}</section>
<section class=\"composer\" aria-label=\"Voice controls\"><div class=\"record-group\"><button id=\"record-button\" type=\"button\" aria-pressed=\"false\" aria-label=\"Hold to record\"><span aria-hidden=\"true\">●</span></button><div><strong>Hold to talk <kbd>space</kbd></strong><div id=\"recording-status\">Hold the spacebar (or the button) to record.</div><button id=\"discard-failed-button\" class=\"discard-button\" type=\"button\" hidden>Discard failed recording</button></div></div><button id=\"turn-button\" type=\"button\">Ask Kibo</button></section>
</main></div></body></html>",
        conversation = escape(&conversation.name),
        project = escape(&project.name),
        project_id = escape_attr(project_id),
        conversation_id = escape_attr(conversation_id),
        timeline = render_timeline(project_id, conversation_id, &records),
    ))
}

fn render_project_page(state: &AppState, project_id: &str) -> anyhow::Result<String> {
    let project = state.store().project(project_id)?;
    let conversations = state.store().list_conversations(project_id)?;
    let navigation = render_navigation(state, project_id, None, false)?;
    let mock_notice = if state.ai().is_mock() {
        "<span class=\"mode-badge\">Mock AI</span>"
    } else {
        ""
    };
    let content = if conversations.is_empty() {
        format!(
            "<section class=\"project-home empty-project\"><p class=\"eyebrow\">Project</p><h1>{}</h1><p>This project has no chats yet. Start one whenever you have something to explore.</p>{}</section>",
            escape(&project.name),
            new_chat_form(project_id, "Start a new chat", "primary-button")
        )
    } else {
        let mut cards = String::new();
        for conversation in &conversations {
            cards.push_str(&format!(
                "<li><a href=\"/app/{}/{}\"><strong>{}</strong><span>Open chat</span></a></li>",
                url_component(project_id),
                url_component(&conversation.id),
                escape(&conversation.name)
            ));
        }
        format!(
            "<section class=\"project-home\"><p class=\"eyebrow\">Project {}</p><div class=\"project-home-heading\"><h1>{}</h1>{}</div><p class=\"project-intro\">Pick up a recent chat or start a fresh one.</p><ul class=\"chat-grid\">{}</ul></section>",
            mock_notice,
            escape(&project.name),
            new_chat_form(project_id, "New chat", "primary-button"),
            cards
        )
    };
    Ok(format!(
        "<!doctype html>
<html lang=\"en\"><head>
<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">
<title>{project} · Kibo</title><meta name=\"description\" content=\"Voice chats organized in Kibo projects\">
<link rel=\"stylesheet\" href=\"/assets/app.css?v=4\"><script src=\"/assets/htmx.min.js\" defer></script><script src=\"/assets/app.js?v=4\" defer></script>
</head><body data-project-id=\"{project_id}\">
<div class=\"app-shell\"><aside class=\"sidebar\"><div class=\"brand\"><span class=\"brand-mark\">k</span>Kibo</div>{navigation}
<details class=\"new-item\"><summary>New project</summary><form method=\"post\" action=\"/ui/projects\"><label>Name<input name=\"name\" maxlength=\"100\" required></label><button> create </button></form></details>
</aside><main class=\"main project-main\">{content}</main></div></body></html>",
        project = escape(&project.name),
        project_id = escape_attr(project_id),
    ))
}

fn render_knowledge_page(
    state: &AppState,
    project_id: &str,
    notice: Option<&str>,
) -> anyhow::Result<String> {
    let project = state.store().project(project_id)?;
    let statuses = knowledge::source_statuses(state.store(), project_id)?;
    let files = knowledge::markdown_files(state.store(), project_id)?;
    let navigation = render_navigation(state, project_id, None, true)?;
    let dirty = statuses.iter().filter(|source| source.dirty).count();
    let ingested = statuses
        .iter()
        .filter(|source| source.generation > 0)
        .count();
    let conversations: Vec<&SourceStatus> = statuses
        .iter()
        .filter(|source| source.kind == DocumentKind::Conversation)
        .collect();
    let web_sources: Vec<&SourceStatus> = statuses
        .iter()
        .filter(|source| source.kind == DocumentKind::Web)
        .collect();
    let conversation_cards = if conversations.is_empty() {
        "<p class=\"knowledge-empty\">No conversations yet.</p>".to_string()
    } else {
        conversations
            .into_iter()
            .map(|source| render_knowledge_source(project_id, source))
            .collect()
    };
    let web_cards = if web_sources.is_empty() {
        "<p class=\"knowledge-empty\">No URLs imported yet.</p>".to_string()
    } else {
        web_sources
            .into_iter()
            .map(|source| render_knowledge_source(project_id, source))
            .collect()
    };
    let file_links = files
        .iter()
        .map(|file| {
            format!(
                "<li><a href=\"/app/{}/knowledge/files/{}\"><span>{}</span><small>{}</small></a></li>",
                url_component(project_id),
                escape_attr(&file.path),
                escape(&file.label),
                escape(&file.path)
            )
        })
        .collect::<String>();
    let jina_badge = if state.jina_has_api_key() {
        "<span class=\"mode-badge ready-badge\">Jina key loaded</span>"
    } else {
        "<span class=\"mode-badge\">Jina anonymous mode</span>"
    };
    Ok(format!(
        "<!doctype html>
<html lang=\"en\"><head>
<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>Knowledge · {project}</title><meta name=\"description\" content=\"Ingest conversations and web sources into project Markdown\">
<link rel=\"stylesheet\" href=\"/assets/app.css?v=4\"><script src=\"/assets/app.js?v=4\" defer></script>
</head><body data-project-id=\"{project_id}\"><div class=\"app-shell\"><aside class=\"sidebar\"><div class=\"brand\"><span class=\"brand-mark\">k</span>Kibo</div>{navigation}
<details class=\"new-item\"><summary>New project</summary><form method=\"post\" action=\"/ui/projects\"><label>Name<input name=\"name\" maxlength=\"100\" required></label><button> create </button></form></details>
</aside><main class=\"main knowledge-main\"><div class=\"knowledge-wrap\">
<header class=\"knowledge-header\"><div><p class=\"eyebrow\">{project} {jina_badge}</p><h1>Knowledge</h1><p>Compile conversations and pages into durable, readable Markdown.</p></div><div class=\"knowledge-header-actions\"><a class=\"primary-link ask-knowledge-link\" href=\"/app/{project_id}/knowledge/query\">Ask knowledge</a><form method=\"post\" action=\"/ui/projects/{project_id}/knowledge/ingest\" data-knowledge-action data-progress-title=\"Ingesting changed sources\" data-progress-detail=\"Kibo is checking each source and generating notes for anything new.\" data-progress-long=\"Gemini is still building the changed notes. This can take a little while.\"><button class=\"primary-button\" type=\"submit\">Ingest changed <span>{dirty}</span></button></form></div></header>
{notice}
<div id=\"knowledge-progress\" class=\"knowledge-progress\" role=\"status\" aria-live=\"polite\" hidden><span class=\"knowledge-spinner\" aria-hidden=\"true\"></span><div><strong id=\"knowledge-progress-title\">Updating knowledge</strong><p id=\"knowledge-progress-detail\">This may take a moment.</p><span class=\"knowledge-progress-track\" aria-hidden=\"true\"><i></i></span></div></div>
<section class=\"knowledge-stats\" aria-label=\"Knowledge status\"><div><strong>{sources}</strong><span>available sources</span></div><div><strong>{ingested}</strong><span>ingested</span></div><div><strong>{dirty}</strong><span>changed</span></div><div><strong>{files_count}</strong><span>Markdown files</span></div></section>
<div class=\"knowledge-grid\"><div class=\"knowledge-sources\">
<section class=\"knowledge-section\"><div class=\"section-heading\"><div><p class=\"eyebrow\">Raw transcripts</p><h2>Conversations</h2></div></div><div class=\"source-list\">{conversation_cards}</div></section>
<section class=\"knowledge-section\"><div class=\"section-heading\"><div><p class=\"eyebrow\">Jina Reader</p><h2>Import a URL</h2></div></div><form class=\"url-import\" method=\"post\" action=\"/ui/projects/{project_id}/knowledge/import\" data-knowledge-action data-progress-title=\"Importing with Jina Reader\" data-progress-detail=\"Jina is fetching the source; then Gemini will turn it into a knowledge note.\" data-progress-long=\"Still importing. Complex pages and PDFs can take a little longer.\"><label><span>Public webpage or PDF URL</span><input type=\"url\" name=\"url\" placeholder=\"https://example.com/article\" required></label><button class=\"primary-button\" type=\"submit\">Import &amp; ingest</button></form><div class=\"source-list web-source-list\">{web_cards}</div></section>
</div><aside class=\"markdown-library\"><div class=\"section-heading\"><div><p class=\"eyebrow\">Generated files</p><h2>Markdown</h2></div></div><ul>{file_links}</ul></aside></div>
</div></main></div></body></html>",
        project = escape(&project.name),
        project_id = escape_attr(project_id),
        notice = render_knowledge_notice(notice),
        sources = statuses.len(),
        files_count = files.len(),
    ))
}

fn render_knowledge_query_page(state: &AppState, project_id: &str) -> anyhow::Result<String> {
    let project = state.store().project(project_id)?;
    let navigation = render_navigation(state, project_id, None, true)?;
    Ok(format!(
        "<!doctype html>
<html lang=\"en\"><head>
<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">
<base href=\"/app/{project_id}/knowledge/files/wiki/\">
<title>Ask knowledge · {project}</title><meta name=\"description\" content=\"Ask an agent to investigate this project's knowledge base\">
<link rel=\"stylesheet\" href=\"/assets/app.css?v=4\"><script src=\"/assets/knowledge-query.js?v=1\" defer></script>
</head><body data-project-id=\"{project_id}\" data-query-url=\"/v1/projects/{project_id}/knowledge/query\"><div class=\"app-shell\"><aside class=\"sidebar\"><div class=\"brand\"><span class=\"brand-mark\">k</span>Kibo</div>{navigation}
<details class=\"new-item\"><summary>New project</summary><form method=\"post\" action=\"/ui/projects\"><label>Name<input name=\"name\" maxlength=\"100\" required></label><button> create </button></form></details>
</aside><main class=\"main knowledge-query-main\"><div class=\"knowledge-query-shell\">
<header class=\"knowledge-query-header\"><div><p class=\"eyebrow\">{project} · Knowledge</p><h1>Ask your knowledge</h1><p>Let an agent follow connections across the notes and cite the files it used.</p></div><div class=\"knowledge-query-header-actions\"><button id=\"knowledge-query-new\" class=\"quiet-button query-new-button\" type=\"button\" aria-controls=\"knowledge-query-timeline\" hidden>New conversation</button><a class=\"quiet-link\" href=\"/app/{project_id}/knowledge\">Manage sources</a></div></header>
<section id=\"knowledge-query-timeline\" class=\"knowledge-query-timeline\" role=\"log\" aria-label=\"Knowledge query conversation\" aria-live=\"polite\" aria-relevant=\"additions text\">
<div id=\"knowledge-query-empty\" class=\"knowledge-query-empty\"><div class=\"query-orbit\" aria-hidden=\"true\"><span></span></div><p class=\"eyebrow\">Read-only research</p><h2>What would you like to understand?</h2><p>The agent can inspect this project's generated Markdown, connect ideas across sources, and link you back to the relevant notes.</p><div class=\"query-suggestions\" role=\"group\" aria-label=\"Example questions\"><button type=\"button\" data-query-suggestion=\"What themes recur across my knowledge base?\">Find recurring themes</button><button type=\"button\" data-query-suggestion=\"Which sources disagree, and what are the key differences?\">Compare disagreements</button><button type=\"button\" data-query-suggestion=\"What important questions are still unanswered in these notes?\">Find open questions</button></div></div>
</section>
<form id=\"knowledge-query-form\" class=\"knowledge-query-composer\" aria-label=\"Ask the knowledge base\"><label class=\"visually-hidden\" for=\"knowledge-query-input\">Question</label><textarea id=\"knowledge-query-input\" name=\"question\" rows=\"2\" placeholder=\"Ask a question about your knowledge…\" autocomplete=\"off\" aria-describedby=\"knowledge-query-hint knowledge-query-status\" required></textarea><div class=\"query-composer-row\"><p id=\"knowledge-query-hint\">Enter to ask · Shift+Enter for a new line</p><div class=\"query-composer-actions\"><button id=\"knowledge-query-cancel\" class=\"quiet-button query-cancel-button\" type=\"button\" aria-controls=\"knowledge-query-timeline\" hidden>Stop</button><button id=\"knowledge-query-submit\" class=\"primary-button\" type=\"submit\">Ask knowledge</button></div></div></form>
<p id=\"knowledge-query-status\" class=\"knowledge-query-status\" role=\"status\" aria-live=\"polite\">Ready for a question.</p>
</div></main></div></body></html>",
        project = escape(&project.name),
        project_id = escape_attr(project_id),
    ))
}

fn render_knowledge_source(project_id: &str, source: &SourceStatus) -> String {
    let (status, class) = if !source.has_content {
        ("Waiting for transcript", "waiting")
    } else if source.dirty && source.generation == 0 {
        ("Ready to ingest", "dirty")
    } else if source.dirty {
        ("Changed", "dirty")
    } else {
        ("Up to date", "clean")
    };
    let view = source
        .wiki_file
        .as_deref()
        .map_or_else(String::new, |path| {
            format!(
                "<a class=\"quiet-link\" href=\"/app/{}/knowledge/files/wiki/{}\">View note</a>",
                url_component(project_id),
                escape_attr(path)
            )
        });
    let generation = if source.generation == 0 {
        String::new()
    } else {
        format!("<span>Generation {}</span>", source.generation)
    };
    let origin = source.origin.as_deref().map_or_else(String::new, |url| {
        format!(
            "<a class=\"source-origin\" href=\"{}\" target=\"_blank\" rel=\"noopener noreferrer\">{}</a>",
            escape_attr(url),
            escape(url)
        )
    });
    let controls = match source.kind {
        DocumentKind::Conversation => format!(
            "<form method=\"post\" action=\"/ui/projects/{}/knowledge/conversations/{}/ingest\" data-knowledge-action data-progress-title=\"Generating conversation note\" data-progress-detail=\"Gemini is compiling this transcript into Markdown.\"><button type=\"submit\" {}>{}</button></form>",
            url_component(project_id),
            url_component(&source.id),
            if source.has_content { "" } else { "disabled" },
            if source.generation > 0 {
                "Re-ingest"
            } else {
                "Ingest"
            }
        ),
        DocumentKind::Web => format!(
            "<form method=\"post\" action=\"/ui/projects/{}/knowledge/sources/{}/refresh\" data-knowledge-action data-progress-title=\"Refreshing imported source\" data-progress-detail=\"Jina is checking the URL; Gemini will update its note only if the content changed.\"><button type=\"submit\">Refresh &amp; ingest</button></form><form method=\"post\" action=\"/ui/projects/{}/knowledge/sources/{}/ingest\" data-knowledge-action data-progress-title=\"Regenerating source note\" data-progress-detail=\"Gemini is rebuilding the note from the saved source.\"><button class=\"quiet-button\" type=\"submit\">Re-ingest</button></form>",
            url_component(project_id),
            url_component(&source.id),
            url_component(project_id),
            url_component(&source.id)
        ),
    };
    format!(
        "<article class=\"source-card\"><div class=\"source-card-top\"><span class=\"source-status {class}\">{status}</span>{generation}</div><h3>{title}</h3>{origin}<div class=\"source-actions\">{controls}{view}</div></article>",
        title = escape(&source.title)
    )
}

fn render_knowledge_notice(notice: Option<&str>) -> String {
    let message = match notice {
        Some(value) if value.starts_with("ingested-") => {
            let parts: Vec<&str> = value.split('-').collect();
            format!(
                "Knowledge is current: {} ingested, {} already unchanged.",
                parts.get(1).copied().unwrap_or("0"),
                parts.get(2).copied().unwrap_or("0")
            )
        }
        Some("conversation-ingested") => "Conversation note regenerated.".into(),
        Some("url-ingested") => "URL imported and its note generated.".into(),
        Some("url-unchanged") => {
            "The imported content is unchanged; the existing note is current.".into()
        }
        Some("source-reingested") => "Source note regenerated from the saved content.".into(),
        Some("source-refreshed") => {
            "The URL changed, so its saved source and note were updated.".into()
        }
        _ => return String::new(),
    };
    format!(
        "<div class=\"knowledge-notice\" role=\"status\">{}</div>",
        escape(&message)
    )
}

fn render_knowledge_file_page(
    state: &AppState,
    project_id: &str,
    path: &str,
) -> anyhow::Result<String> {
    let project = state.store().project(project_id)?;
    let markdown = knowledge::read_markdown(state.store(), project_id, path)?;
    let files = knowledge::markdown_files(state.store(), project_id)?;
    let navigation = render_navigation(state, project_id, None, true)?;
    let rendered = render_markdown(markdown_without_frontmatter(&markdown));
    let file_links = files
        .iter()
        .map(|file| {
            let current = if file.path == path {
                " aria-current=\"page\""
            } else {
                ""
            };
            format!(
                "<li><a href=\"/app/{}/knowledge/files/{}\"{}>{}</a></li>",
                url_component(project_id),
                escape_attr(&file.path),
                current,
                escape(&file.label)
            )
        })
        .collect::<String>();
    Ok(format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><base href=\"/app/{project_id}/knowledge/files/wiki/\"><title>{path} · {project}</title><link rel=\"stylesheet\" href=\"/assets/app.css?v=4\"></head><body data-project-id=\"{project_id}\"><div class=\"app-shell\"><aside class=\"sidebar\"><div class=\"brand\"><span class=\"brand-mark\">k</span>Kibo</div>{navigation}</aside><main class=\"main markdown-main\"><div class=\"markdown-shell\"><aside class=\"file-rail\"><a class=\"back-link\" href=\"/app/{project_id}/knowledge\">← Knowledge</a><p class=\"eyebrow\">Markdown files</p><ul>{file_links}</ul></aside><article class=\"markdown-document\"><header><p class=\"eyebrow\">{path}</p></header><div class=\"markdown-body\">{rendered}</div><details class=\"raw-markdown\"><summary>View raw Markdown</summary><pre>{raw}</pre></details></article></div></main></div></body></html>",
        project = escape(&project.name),
        project_id = escape_attr(project_id),
        path = escape(path),
        raw = escape(&markdown),
    ))
}

pub(crate) fn render_markdown(markdown: &str) -> String {
    ammonia::clean(&markdown_html(markdown))
}

pub(crate) fn render_query_markdown(markdown: &str) -> String {
    let mut sanitizer = ammonia::Builder::default();
    sanitizer
        .rm_tags(["img", "map", "area"])
        .url_schemes(HashSet::new())
        .attribute_filter(|element, attribute, value| match (element, attribute) {
            ("a", "href") if safe_query_citation(value) => Some(value.into()),
            ("a", "href") | (_, "src") | (_, "cite") => None,
            _ => Some(value.into()),
        });
    sanitizer.clean(&markdown_html(markdown)).to_string()
}

fn markdown_html(markdown: &str) -> String {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TASKLISTS);
    options.insert(Options::ENABLE_FOOTNOTES);
    let mut rendered = String::new();
    html::push_html(&mut rendered, Parser::new_ext(markdown, options));
    rendered
}

fn safe_query_citation(value: &str) -> bool {
    if value.starts_with('#') {
        return true;
    }
    let path = value.split(['?', '#']).next().unwrap_or_default();
    if path == "index.md" {
        return true;
    }
    path.strip_prefix("sources/").is_some_and(|relative| {
        !relative.is_empty()
            && !relative.contains('%')
            && !relative.contains('\\')
            && relative
                .split('/')
                .all(|segment| !segment.is_empty() && segment != "." && segment != "..")
    })
}

fn markdown_without_frontmatter(markdown: &str) -> &str {
    let Some(rest) = markdown.strip_prefix("---\n") else {
        return markdown;
    };
    rest.find("\n---\n")
        .map_or(markdown, |end| &rest[end + 5..])
}

fn render_navigation(
    state: &AppState,
    current_project_id: &str,
    current_conversation_id: Option<&str>,
    knowledge_current: bool,
) -> anyhow::Result<String> {
    let mut navigation = String::new();
    for project in state.store().list_projects()? {
        let current_project = project.id == current_project_id;
        let project_current =
            if current_project && current_conversation_id.is_none() && !knowledge_current {
                " aria-current=\"page\""
            } else {
                ""
            };
        navigation.push_str(&format!(
            "<section class=\"project-nav\"><a class=\"project-link\" href=\"/app/{}\"{}>{}</a>{}<a class=\"knowledge-link\" href=\"/app/{}/knowledge\"{}>◇ Knowledge</a><ul class=\"nav-list\">",
            url_component(&project.id),
            project_current,
            escape(&project.name),
            new_chat_form(&project.id, "+ New chat", "new-chat-button"),
            url_component(&project.id),
            if current_project && knowledge_current {
                " aria-current=\"page\""
            } else {
                ""
            }
        ));
        for conversation in state.store().list_conversations(&project.id)? {
            let current =
                if current_project && current_conversation_id == Some(conversation.id.as_str()) {
                    " aria-current=\"page\""
                } else {
                    ""
                };
            navigation.push_str(&format!(
                "<li><a href=\"/app/{}/{}\" data-project-id=\"{}\" data-conversation-id=\"{}\"{}>{}</a></li>",
                url_component(&project.id),
                url_component(&conversation.id),
                escape_attr(&project.id),
                escape_attr(&conversation.id),
                current,
                escape(&conversation.name)
            ));
        }
        navigation.push_str("</ul></section>");
    }
    Ok(navigation)
}

fn new_chat_form(project_id: &str, label: &str, class: &str) -> String {
    format!(
        "<form class=\"new-chat-form\" method=\"post\" action=\"/ui/projects/{}/conversations\"><button class=\"{}\" type=\"submit\">{}</button></form>",
        url_component(project_id),
        escape_attr(class),
        escape(label)
    )
}

fn render_timeline(project_id: &str, conversation_id: &str, records: &[Value]) -> String {
    if records.is_empty() {
        return "<div class=\"empty-state\"><p><strong>No conversation yet.</strong></p><p>Hold the coral button to record a thought, then ask Kibo.</p></div>".into();
    }
    let workflow = ConversationWorkflow::from_records(records);
    let claimed: HashSet<&str> = workflow
        .turns()
        .iter()
        .flat_map(|turn| turn.clips.iter().map(String::as_str))
        .collect();
    let clips: HashMap<&str, &Value> = records
        .iter()
        .filter(|event| event["kind"] == "clip")
        .filter_map(|event| Some((event["id"].as_str()?, event)))
        .collect();

    let mut html = String::new();
    for turn in workflow.turns() {
        let clip_ids: Vec<&str> = turn.clips.iter().map(String::as_str).collect();
        html.push_str(&render_user_message(
            project_id,
            conversation_id,
            &clip_ids,
            &clips,
            &workflow,
        ));
        match &turn.reply {
            AttemptState::Succeeded(reply) => html.push_str(&render_reply(turn, reply)),
            AttemptState::TerminalFailure(failure) => html.push_str(&format!(
                "<article class=\"message assistant\"><p class=\"error-text\">{}</p></article>",
                escape(failure.error())
            )),
            AttemptState::RetryScheduled { .. } => html.push_str(
                "<article class=\"message assistant\"><p class=\"thinking\">Retrying…</p></article>",
            ),
            AttemptState::Due { .. } | AttemptState::Attempting { .. } => html.push_str(
                "<article class=\"message assistant\"><p class=\"thinking\">Thinking…</p></article>",
            ),
        }
    }

    for clip_id in records
        .iter()
        .filter(|event| event["kind"] == "clip")
        .filter_map(|event| event["id"].as_str())
        .filter(|clip_id| !claimed.contains(*clip_id))
    {
        html.push_str(&render_user_message(
            project_id,
            conversation_id,
            &[clip_id],
            &clips,
            &workflow,
        ));
    }
    html
}

fn render_user_message(
    project_id: &str,
    conversation_id: &str,
    clip_ids: &[&str],
    clips: &HashMap<&str, &Value>,
    workflow: &ConversationWorkflow,
) -> String {
    let mut html = String::new();
    for clip_id in clip_ids {
        let text = match workflow.clip(clip_id).map(|clip| &clip.transcript) {
            Some(AttemptState::Succeeded(transcript)) => escape(transcript),
            Some(AttemptState::TerminalFailure(failure)) => format!(
                "<span class=\"error-text\">Transcription failed: {}</span>",
                escape(&failure.error)
            ),
            Some(AttemptState::RetryScheduled { .. }) => {
                "<span class=\"thinking\">Retrying transcription…</span>".into()
            }
            Some(AttemptState::Due { .. } | AttemptState::Attempting { .. }) | None => {
                "<span class=\"thinking\">Transcribing…</span>".into()
            }
        };
        if clips.contains_key(clip_id) {
            html.push_str(&format!(
                "<article class=\"message user clip\" data-clip data-state=\"paused\" role=\"button\" tabindex=\"0\" aria-label=\"Play recording\"><p>{}</p><audio preload=\"none\" src=\"/v1/projects/{}/conversations/{}/clips/{}/audio\"></audio></article>",
                text,
                url_component(project_id), url_component(conversation_id), url_component(clip_id)
            ));
        } else {
            html.push_str(&format!(
                "<article class=\"message user\"><p>{}</p></article>",
                text
            ));
        }
    }
    html
}

fn render_reply(turn: &TurnWork, reply: &crate::workflow::ReplyRecord) -> String {
    let text = escape(&reply.text);
    match &turn.speech {
        Some(SpeechState::TerminalFailure(failure)) => {
            return format!(
                "<article class=\"message assistant\"><p>{}</p><span class=\"error-text\">Speech unavailable: {}</span></article>",
                text,
                escape(&failure.error)
            );
        }
        Some(SpeechState::RetryScheduled { .. }) => {
            return format!(
                "<article class=\"message assistant\"><p>{}</p><span class=\"thinking\">Retrying speech…</span></article>",
                text
            );
        }
        Some(
            SpeechState::Due { .. } | SpeechState::Attempting { .. } | SpeechState::Succeeded(()),
        )
        | None => {}
    }
    if reply.audio.is_none() || turn.speech.is_none() {
        return format!(
            "<article class=\"message assistant\"><p>{}</p></article>",
            text
        );
    }
    format!(
        "<article class=\"message assistant\" data-speech-player data-turn-id=\"{}\" role=\"button\" tabindex=\"0\" aria-label=\"Play reply\"><p>{}</p></article>",
        escape_attr(&turn.id),
        text
    )
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn escape_attr(value: &str) -> String {
    escape(value)
}

fn url_component(value: &str) -> String {
    // IDs are constrained to this alphabet by the store. Keeping this helper
    // makes that boundary explicit at render sites.
    value.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::Ai;
    use crate::model::ConversationNameSource;
    use crate::store::Store;

    #[tokio::test]
    async fn root_opens_the_starter_project_not_a_magic_conversation() {
        let temporary = tempfile::tempdir().unwrap();
        let state = AppState::new(Store::open(temporary.path()).unwrap(), Ai::mock());

        let response = index(State(state)).await;

        assert_eq!(response.status(), StatusCode::TEMPORARY_REDIRECT);
        assert_eq!(response.headers()[header::LOCATION], "/app/kibo");
    }

    #[test]
    fn empty_project_page_offers_an_unnamed_chat_flow() {
        let temporary = tempfile::tempdir().unwrap();
        let state = AppState::new(Store::open(temporary.path()).unwrap(), Ai::mock());

        let html = render_project_page(&state, "kibo").unwrap();

        assert!(html.contains("This project has no chats yet"));
        assert!(html.contains("Start a new chat"));
        assert!(html.contains("action=\"/ui/projects/kibo/conversations\""));
        assert!(!html.contains("data-conversation-url"));
    }

    #[test]
    fn knowledge_page_exposes_ingestion_and_markdown_controls() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", Some("Research")).unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                serde_json::json!({"kind":"transcript", "clip":"clip-1", "text":"A testable source"}),
            )
            .unwrap();
        let state = AppState::new(store, Ai::mock());

        let html = render_knowledge_page(&state, "kibo", None).unwrap();

        assert!(html.contains("Import &amp; ingest"));
        assert!(html.contains("Ingest changed"));
        assert!(html.contains("Ready to ingest"));
        assert!(html.contains("wiki/index.md"));
        assert!(html.contains("id=\"knowledge-progress\""));
        assert!(html.contains("data-progress-title=\"Importing with Jina Reader\""));
        assert!(html.contains("href=\"/app/kibo/knowledge/query\""));
        assert!(html.contains("Ask knowledge"));
    }

    #[test]
    fn knowledge_query_page_exposes_an_accessible_streaming_conversation() {
        let temporary = tempfile::tempdir().unwrap();
        let state = AppState::new(Store::open(temporary.path()).unwrap(), Ai::mock());

        let html = render_knowledge_query_page(&state, "kibo").unwrap();

        assert!(html.contains("<base href=\"/app/kibo/knowledge/files/wiki/\">"));
        assert!(html.contains("data-query-url=\"/v1/projects/kibo/knowledge/query\""));
        assert!(html.contains("src=\"/assets/knowledge-query.js?v=1\""));
        assert!(html.contains("id=\"knowledge-query-timeline\""));
        assert!(html.contains("aria-live=\"polite\""));
        assert!(html.contains("id=\"knowledge-query-input\""));
        assert!(html.contains("id=\"knowledge-query-cancel\""));
        assert!(html.contains("id=\"knowledge-query-new\""));
        assert!(html.contains("New conversation"));
        assert!(html.contains("Read-only research"));
        assert!(!html.contains("app-server"));
        assert!(!html.contains("sandboxPolicy"));
        assert!(!html.contains("thread/start"));
    }

    #[test]
    fn knowledge_query_script_preserves_threads_and_renders_streams_safely() {
        assert!(KNOWLEDGE_QUERY_JS.contains("const payload = { question: normalized };"));
        assert!(KNOWLEDGE_QUERY_JS.contains("if (threadId) payload.thread_id = threadId;"));
        assert!(KNOWLEDGE_QUERY_JS.contains("threadId = event.query_id;"));
        assert!(KNOWLEDGE_QUERY_JS.contains("threadId = \"\";"));
        assert!(KNOWLEDGE_QUERY_JS.matches("threadId = \"\";").count() >= 4);
        assert!(KNOWLEDGE_QUERY_JS.contains("turn.answerText.appendData(event.text);"));
        assert!(KNOWLEDGE_QUERY_JS.contains("turn.answerBody.innerHTML = event.html;"));
        assert!(KNOWLEDGE_QUERY_JS.contains("link.target = \"_blank\";"));
        assert!(KNOWLEDGE_QUERY_JS.contains("link.rel = \"noopener noreferrer\";"));
        assert!(KNOWLEDGE_QUERY_JS.contains("\"Accept\": \"application/x-ndjson\""));
    }

    #[test]
    fn query_markdown_is_sanitized_and_keeps_relative_citations() {
        let rendered = render_query_markdown(
            "# Answer\n\n[Source](sources/conversation--research.md)\n\n[Bad](javascript:alert(1))\n\n[Remote](https://attacker.invalid/leak)\n\n[Network path](//attacker.invalid/leak)\n\n[Traversal](sources/../../secret)\n\n![Tracking pixel](https://attacker.invalid/pixel)\n\n<script>alert('no')</script>",
        );

        assert!(rendered.contains("<h1>Answer</h1>"));
        assert!(rendered.contains("href=\"sources/conversation--research.md\""));
        assert!(!rendered.contains("<script>"));
        assert!(!rendered.contains("href=\"javascript:"));
        assert!(!rendered.contains("attacker.invalid"));
        assert!(!rendered.contains("../../secret"));
        assert!(!rendered.contains("<img"));
    }

    #[test]
    fn markdown_view_sanitizes_generated_html() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", Some("Safety")).unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                serde_json::json!({"kind":"transcript", "clip":"clip-1", "text":"safe input"}),
            )
            .unwrap();
        let document = knowledge::conversation_document(&store, "kibo", &conversation.id).unwrap();
        let (_, instructions_hash) = knowledge::instructions(&store, "kibo").unwrap();
        let receipt = knowledge::commit_ingestion(
            &store,
            "kibo",
            &document,
            &instructions_hash,
            "# Safe note\n\n<script>alert('no')</script>\n\n[bad](javascript:alert(1))",
        )
        .unwrap();
        let state = AppState::new(store, Ai::mock());

        let html =
            render_knowledge_file_page(&state, "kibo", &format!("wiki/{}", receipt.wiki_file))
                .unwrap();

        assert!(html.contains("<h1>Safe note</h1>"));
        assert!(!html.contains("<script>"));
        assert!(!html.contains("href=\"javascript:"));
    }

    #[tokio::test]
    async fn web_new_chat_always_creates_a_placeholder_title() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let state = AppState::new(store.clone(), Ai::mock());

        let response = create_conversation(State(state), Path("kibo".into())).await;

        assert_eq!(response.status(), StatusCode::SEE_OTHER);
        let conversations = store.list_conversations("kibo").unwrap();
        assert_eq!(conversations.len(), 1);
        assert_eq!(conversations[0].name, "New conversation");
        assert_eq!(
            conversations[0].name_source,
            ConversationNameSource::Placeholder
        );
        assert_eq!(
            response.headers()[header::LOCATION],
            format!("/app/kibo/{}", conversations[0].id)
        );
    }

    #[test]
    fn timeline_presents_nonterminal_failures_as_retrying() {
        let records = vec![
            serde_json::json!({"kind":"clip", "id":"clip-1"}),
            serde_json::json!({"kind":"transcript_error", "clip":"clip-1", "error":"temporary", "terminal":false}),
            serde_json::json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            serde_json::json!({"kind":"reply_error", "turn":"turn-1", "error":"temporary", "terminal":false}),
        ];

        let html = render_timeline("kibo", "conversation", &records);

        assert!(html.contains("Retrying transcription…"));
        assert!(html.contains(">Retrying…<"));
        assert!(!html.contains("Transcription failed"));
        assert!(!html.contains(">temporary<"));
    }

    #[test]
    fn timeline_allows_durable_retry_events_to_supersede_terminal_errors() {
        let records = vec![
            serde_json::json!({"kind":"clip", "id":"clip-1"}),
            serde_json::json!({"kind":"transcript_error", "clip":"clip-1", "error":"broken", "terminal":true}),
            serde_json::json!({"kind":"transcript_retry_requested", "clip":"clip-1"}),
            serde_json::json!({"kind":"transcript", "clip":"clip-1", "text":"recovered"}),
            serde_json::json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            serde_json::json!({"kind":"reply_error", "turn":"turn-1", "error":"broken", "terminal":true}),
            serde_json::json!({"kind":"reply_retry_requested", "turn":"turn-1"}),
        ];

        let html = render_timeline("kibo", "conversation", &records);

        assert!(html.contains("recovered"));
        assert!(html.contains(">Thinking…<"));
        assert!(!html.contains("broken"));
    }

    #[test]
    fn timeline_keeps_reply_text_while_speech_retries() {
        let records = vec![
            serde_json::json!({"kind":"turn", "id":"turn-1", "clips":[]}),
            serde_json::json!({"kind":"reply", "turn":"turn-1", "text":"Durable text", "audio":"tts/turn-1.wav"}),
            serde_json::json!({"kind":"tts_error", "turn":"turn-1", "error":"temporary", "terminal":false}),
        ];

        let html = render_timeline("kibo", "conversation", &records);

        assert!(html.contains("Durable text"));
        assert!(html.contains("Retrying speech…"));
        assert!(!html.contains("Speech unavailable"));
        assert!(!html.contains("data-speech-player"));
    }
}

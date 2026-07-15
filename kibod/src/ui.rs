use crate::model::{CreateConversation, CreateNamed};
use crate::state::AppState;
use axum::Router;
use axum::extract::{Form, Path, State};
use axum::http::{StatusCode, header};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

const CSS: &str = include_str!("../assets/app.css");
const JS: &str = include_str!("../assets/app.js");
const HTMX: &str = include_str!("../assets/htmx.min.js");

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(index))
        .route(
            "/app/{project_id}/{conversation_id}",
            get(conversation_page),
        )
        .route(
            "/app/{project_id}/{conversation_id}/timeline",
            get(timeline_fragment),
        )
        .route("/ui/projects", post(create_project))
        .route(
            "/ui/projects/{project_id}/conversations",
            post(create_conversation),
        )
        .route("/assets/app.css", get(asset_css))
        .route("/assets/app.js", get(asset_js))
        .route("/assets/htmx.min.js", get(asset_htmx))
}

async fn index(State(state): State<AppState>) -> Response {
    let destination = state
        .store()
        .list_projects()
        .ok()
        .and_then(|projects| projects.into_iter().next())
        .and_then(|project| {
            state
                .store()
                .list_conversations(&project.id)
                .ok()
                .and_then(|conversations| conversations.into_iter().next())
                .map(|conversation| format!("/app/{}/{}", project.id, conversation.id))
        })
        .unwrap_or_else(|| "/".into());
    Redirect::temporary(&destination).into_response()
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

async fn create_project(
    State(state): State<AppState>,
    Form(request): Form<CreateNamed>,
) -> Response {
    match state.store().create_project(&request.name) {
        Ok(project) => Redirect::to(&format!("/app/{}/general", project.id)).into_response(),
        Err(error) => (StatusCode::BAD_REQUEST, error.to_string()).into_response(),
    }
}

async fn create_conversation(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
    Form(request): Form<CreateConversation>,
) -> Response {
    match state
        .store()
        .create_conversation(&project_id, request.name.as_deref())
    {
        Ok(conversation) => Redirect::to(&format!(
            "/app/{}/{}",
            conversation.project_id, conversation.id
        ))
        .into_response(),
        Err(error) => (StatusCode::BAD_REQUEST, error.to_string()).into_response(),
    }
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
    let projects = state.store().list_projects()?;
    let records = state.store().records(project_id, conversation_id)?;
    let last_seq = records
        .last()
        .and_then(|event| event["seq"].as_u64())
        .unwrap_or(0);

    let mut navigation = String::new();
    for candidate in projects {
        let conversations = state.store().list_conversations(&candidate.id)?;
        navigation.push_str(&format!(
            "<p class=\"nav-label\">{}</p><ul class=\"nav-list\">",
            escape(&candidate.name)
        ));
        for item in conversations {
            let current = if item.id == conversation_id && candidate.id == project_id {
                " aria-current=\"page\""
            } else {
                ""
            };
            navigation.push_str(&format!(
                "<li><a href=\"/app/{}/{}\" data-project-id=\"{}\" data-conversation-id=\"{}\"{}>{}</a></li>",
                url_component(&candidate.id),
                url_component(&item.id),
                escape_attr(&candidate.id),
                escape_attr(&item.id),
                current,
                escape(&item.name)
            ));
        }
        navigation.push_str("</ul>");
    }

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
<link rel=\"stylesheet\" href=\"/assets/app.css\"><script src=\"/assets/htmx.min.js\" defer></script><script src=\"/assets/app.js\" defer></script>
</head><body data-project-id=\"{project_id}\" data-conversation-id=\"{conversation_id}\" data-last-seq=\"{last_seq}\" data-conversation-url=\"{base}\" data-timeline-url=\"{page_url}/timeline\" data-events-url=\"{base}/events\">
<div class=\"app-shell\"><aside class=\"sidebar\"><div class=\"brand\"><span class=\"brand-mark\">k</span>Kibo</div>{navigation}
<details class=\"new-item\"><summary>New conversation</summary><form method=\"post\" action=\"/ui/projects/{project_id}/conversations\"><button>Create conversation</button></form></details>
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

fn render_timeline(project_id: &str, conversation_id: &str, records: &[Value]) -> String {
    if records.is_empty() {
        return "<div class=\"empty-state\"><p><strong>No conversation yet.</strong></p><p>Hold the coral button to record a thought, then ask Kibo.</p></div>".into();
    }
    let transcripts: HashMap<&str, &Value> = records
        .iter()
        .filter(|event| event["kind"] == "transcript")
        .filter_map(|event| Some((event["clip"].as_str()?, event)))
        .collect();
    let transcript_errors: HashMap<&str, &Value> = records
        .iter()
        .filter(|event| event["kind"] == "transcript_error")
        .filter_map(|event| Some((event["clip"].as_str()?, event)))
        .collect();
    let replies: HashMap<&str, &Value> = records
        .iter()
        .filter(|event| event["kind"] == "reply")
        .filter_map(|event| Some((event["turn"].as_str()?, event)))
        .collect();
    let reply_errors: HashMap<&str, &Value> = records
        .iter()
        .filter(|event| event["kind"] == "reply_error")
        .filter_map(|event| Some((event["turn"].as_str()?, event)))
        .collect();
    let mut speech_failed: HashMap<&str, bool> = HashMap::new();
    for event in records {
        if let Some(turn_id) = event["turn"].as_str() {
            match event["kind"].as_str() {
                Some("tts_error") => {
                    speech_failed.insert(turn_id, true);
                }
                Some("speech_ready") => {
                    speech_failed.insert(turn_id, false);
                }
                _ => {}
            }
        }
    }
    let claimed: HashSet<&str> = records
        .iter()
        .filter(|event| event["kind"] == "turn")
        .flat_map(|event| event["clips"].as_array().into_iter().flatten())
        .filter_map(Value::as_str)
        .collect();
    let clips: HashMap<&str, &Value> = records
        .iter()
        .filter(|event| event["kind"] == "clip")
        .filter_map(|event| Some((event["id"].as_str()?, event)))
        .collect();

    let mut html = String::new();
    for turn in records.iter().filter(|event| event["kind"] == "turn") {
        let Some(turn_id) = turn["id"].as_str() else {
            continue;
        };
        let clip_ids: Vec<&str> = turn["clips"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        html.push_str(&render_user_message(
            project_id,
            conversation_id,
            &clip_ids,
            &clips,
            &transcripts,
            &transcript_errors,
        ));
        if let Some(reply) = replies.get(turn_id) {
            html.push_str(&render_reply(
                turn_id,
                reply,
                speech_failed.get(turn_id) == Some(&true),
            ));
        } else if let Some(error) = reply_errors.get(turn_id) {
            html.push_str(&format!(
                "<article class=\"message error\"><div class=\"message-meta\">Kibo · reply failed</div><p>{}</p></article>",
                escape(error["error"].as_str().unwrap_or("Unknown error"))
            ));
        } else {
            html.push_str("<article class=\"message\"><div class=\"message-meta\">Kibo</div><p class=\"thinking\">Thinking…</p></article>");
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
            &transcripts,
            &transcript_errors,
        ));
    }
    html
}

fn render_user_message(
    project_id: &str,
    conversation_id: &str,
    clip_ids: &[&str],
    clips: &HashMap<&str, &Value>,
    transcripts: &HashMap<&str, &Value>,
    transcript_errors: &HashMap<&str, &Value>,
) -> String {
    let mut parts = Vec::new();
    let mut audio = String::new();
    for clip_id in clip_ids {
        if let Some(transcript) = transcripts.get(clip_id) {
            parts.push(escape(transcript["text"].as_str().unwrap_or("")));
        } else if let Some(error) = transcript_errors.get(clip_id) {
            parts.push(format!(
                "<span class=\"error-text\">Transcription failed: {}</span>",
                escape(error["error"].as_str().unwrap_or("unknown error"))
            ));
        } else {
            parts.push("<span class=\"thinking\">Transcribing…</span>".into());
        }
        if clips.contains_key(clip_id) {
            audio.push_str(&format!(
                "<audio controls preload=\"none\" src=\"/v1/projects/{}/conversations/{}/clips/{}/audio\"></audio>",
                url_component(project_id), url_component(conversation_id), url_component(clip_id)
            ));
        }
    }
    format!(
        "<article class=\"message user\"><div class=\"message-meta\">You · {} recording{}</div><p>{}</p><div class=\"clip-audio\">{}</div></article>",
        clip_ids.len(),
        if clip_ids.len() == 1 { "" } else { "s" },
        parts.join("<br>"),
        audio
    )
}

fn render_reply(turn_id: &str, reply: &Value, tts_failed: bool) -> String {
    let audio = if tts_failed || reply["audio"].is_null() {
        "<span class=\"error-text\">Speech unavailable</span>".into()
    } else {
        format!(
            "<div class=\"audio-controls\" data-speech-player data-turn-id=\"{}\"><button type=\"button\" data-audio-action=\"toggle\">Play</button><button type=\"button\" data-audio-action=\"rewind\" data-seconds=\"10\">−10s</button><button type=\"button\" data-audio-action=\"restart\">Restart</button><span class=\"audio-position\" data-audio-position>0:00</span></div>",
            escape_attr(turn_id)
        )
    };
    format!(
        "<article class=\"message assistant\"><div class=\"message-meta\">Kibo</div><p>{}</p>{}</article>",
        escape(reply["text"].as_str().unwrap_or("")),
        audio
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

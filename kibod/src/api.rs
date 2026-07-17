use crate::agentic::{QueryBusy, QueryEvent, QueryTimeout, RestrictedAccessUnavailable};
use crate::model::{
    ConversationsEnvelope, CreateConversation, CreateNamed, CreateTurn, EventsEnvelope,
    EventsQuery, KiboConversation, KiboEvent, KiboProject, ProjectsEnvelope, PutClipResponse,
    SpeechQuery, TurnResponse, epoch, valid_id,
};
use crate::state::{AppState, QueryThreadBusy, UnknownQueryThread};
use crate::store::{ClipConflict, ClipUpload, CreateTurnOutcome, NoPendingClips, PutClip};
use async_stream::stream;
use axum::body::{Body, Bytes};
use axum::extract::ws::rejection::WebSocketUpgradeRejection;
use axum::extract::ws::{Message, WebSocket};
use axum::extract::{DefaultBodyLimit, Path, Query, State, WebSocketUpgrade};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{Value, json};
use std::convert::Infallible;

const MAX_KNOWLEDGE_QUESTION_BYTES: usize = 16 * 1024;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/v1/projects", get(list_projects).post(create_project))
        .route(
            "/v1/projects/{project_id}/conversations",
            get(list_conversations).post(create_conversation),
        )
        .route(
            "/v1/projects/{project_id}/conversations/{conversation_id}/clips/{clip_id}",
            put(put_clip),
        )
        .route(
            "/v1/projects/{project_id}/conversations/{conversation_id}/clips/{clip_id}/audio",
            get(clip_audio),
        )
        .route(
            "/v1/projects/{project_id}/conversations/{conversation_id}/turns",
            post(create_turn),
        )
        .route(
            "/v1/projects/{project_id}/conversations/{conversation_id}/turns/{turn_id}/speech",
            get(speech),
        )
        .route(
            "/v1/projects/{project_id}/conversations/{conversation_id}/events",
            get(events),
        )
        .route(
            "/v1/projects/{project_id}/knowledge/query",
            post(knowledge_query).layer(DefaultBodyLimit::max(20 * 1024)),
        )
        .layer(DefaultBodyLimit::max(20 * 1024 * 1024))
}

#[derive(Debug, Deserialize)]
struct KnowledgeQueryRequest {
    question: String,
    #[serde(default)]
    thread_id: Option<String>,
}

async fn knowledge_query(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
    Json(request): Json<KnowledgeQueryRequest>,
) -> Result<Response, ApiError> {
    state
        .store()
        .project(&project_id)
        .map_err(ApiError::not_found)?;
    let question = request.question.trim();
    if question.is_empty() {
        return Err(ApiError::bad_request("question must not be empty"));
    }
    if question.len() > MAX_KNOWLEDGE_QUESTION_BYTES {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "question must be 16 KiB or smaller",
        ));
    }
    if request
        .thread_id
        .as_deref()
        .is_some_and(|thread_id| !valid_id(thread_id))
    {
        return Err(ApiError::bad_request("invalid thread_id"));
    }

    let mut query = state
        .start_knowledge_query(&project_id, question, request.thread_id.as_deref())
        .await
        .map_err(query_start_error)?;
    let query_id = query.query_id().to_string();
    let body = Body::from_stream(stream! {
        yield Ok::<Bytes, Infallible>(ndjson(json!({
            "type": "started",
            "query_id": query_id
        })));
        loop {
            match query.next_event().await {
                Ok(Some(QueryEvent::Activity { id, status, label })) => {
                    yield Ok(ndjson(json!({
                        "type": "activity",
                        "id": id,
                        "status": status,
                        "label": label
                    })));
                }
                Ok(Some(QueryEvent::Delta(text))) => {
                    yield Ok(ndjson(json!({ "type": "delta", "text": text })));
                }
                Ok(Some(QueryEvent::Completed(markdown))) => {
                    let html = crate::ui::render_query_markdown(&markdown);
                    yield Ok(ndjson(json!({
                        "type": "completed",
                        "markdown": markdown,
                        "html": html
                    })));
                    break;
                }
                Ok(None) => {
                    yield Ok(ndjson(json!({
                        "type": "error",
                        "message": "Codex ended the query without a completion event"
                    })));
                    break;
                }
                Err(error) => {
                    tracing::error!(%project_id, %query_id, "knowledge query failed: {error:#}");
                    yield Ok(ndjson(json!({
                        "type": "error",
                        "message": query_public_error(&error)
                    })));
                    break;
                }
            }
        }
    });
    Ok(Response::builder()
        .header(header::CONTENT_TYPE, "application/x-ndjson; charset=utf-8")
        .header(header::CACHE_CONTROL, "no-store")
        .header(header::X_CONTENT_TYPE_OPTIONS, "nosniff")
        .body(body)
        .unwrap())
}

fn ndjson(value: Value) -> Bytes {
    let mut bytes = serde_json::to_vec(&value).expect("serialize normalized query event");
    bytes.push(b'\n');
    Bytes::from(bytes)
}

fn query_start_error(error: anyhow::Error) -> ApiError {
    if error.downcast_ref::<QueryBusy>().is_some() {
        return ApiError::new(StatusCode::TOO_MANY_REQUESTS, error);
    }
    if error.downcast_ref::<QueryThreadBusy>().is_some() {
        return ApiError::new(StatusCode::CONFLICT, error);
    }
    if error.downcast_ref::<UnknownQueryThread>().is_some() {
        return ApiError::new(StatusCode::NOT_FOUND, error);
    }
    tracing::error!("could not start knowledge query: {error:#}");
    ApiError::new(StatusCode::SERVICE_UNAVAILABLE, query_public_error(&error))
}

fn query_public_error(error: &anyhow::Error) -> String {
    if error.chain().any(|cause| {
        cause
            .downcast_ref::<RestrictedAccessUnavailable>()
            .is_some()
    }) {
        "Codex could not enforce the isolated read-only knowledge sandbox.".into()
    } else if error
        .chain()
        .any(|cause| cause.downcast_ref::<QueryTimeout>().is_some())
    {
        "The Codex knowledge query timed out.".into()
    } else {
        "The Codex knowledge query failed. Check kibod logs and Codex authentication.".into()
    }
}

async fn list_projects(State(state): State<AppState>) -> Result<Json<ProjectsEnvelope>, ApiError> {
    let projects = state.store().list_projects()?;
    Ok(Json(ProjectsEnvelope { projects }))
}

async fn create_project(
    State(state): State<AppState>,
    Json(request): Json<CreateNamed>,
) -> Result<(StatusCode, Json<KiboProject>), ApiError> {
    let project = state
        .store()
        .create_project(&request.name)
        .map_err(ApiError::bad_request)?;
    Ok((StatusCode::CREATED, Json(project)))
}

async fn list_conversations(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
) -> Result<Json<ConversationsEnvelope>, ApiError> {
    let conversations = state
        .store()
        .list_conversations(&project_id)
        .map_err(ApiError::not_found)?;
    Ok(Json(ConversationsEnvelope { conversations }))
}

async fn create_conversation(
    State(state): State<AppState>,
    Path(project_id): Path<String>,
    Json(request): Json<CreateConversation>,
) -> Result<(StatusCode, Json<KiboConversation>), ApiError> {
    let conversation = state
        .store()
        .create_conversation(&project_id, request.name.as_deref())
        .map_err(ApiError::bad_request)?;
    Ok((StatusCode::CREATED, Json(conversation)))
}

async fn put_clip(
    State(state): State<AppState>,
    Path((project_id, conversation_id, clip_id)): Path<(String, String, String)>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<(StatusCode, Json<PutClipResponse>), ApiError> {
    if body.len() < 44 || &body[..4] != b"RIFF" || &body[8..12] != b"WAVE" {
        return Err(ApiError::bad_request("body must be a WAV file"));
    }
    let expected_sha256 = required_header(&headers, "x-content-sha256")?;
    let duration_ms = numeric_header(&headers, "x-duration-ms")?;
    let peak_pct = numeric_header::<u32>(&headers, "x-peak-pct")?.min(100);
    let recorded_at = numeric_header(&headers, "x-recorded-at").unwrap_or_else(|_| epoch());
    let (outcome, event) = state
        .store()
        .put_clip(ClipUpload {
            project_id: &project_id,
            conversation_id: &conversation_id,
            clip_id: &clip_id,
            bytes: &body,
            expected_sha256: &expected_sha256,
            duration_ms,
            peak_pct,
            recorded_at,
        })
        .map_err(|error| {
            if error.downcast_ref::<ClipConflict>().is_some() {
                ApiError::new(StatusCode::CONFLICT, error)
            } else {
                ApiError::bad_request(error)
            }
        })?;
    if let Some(event) = event {
        state.publish(&project_id, &conversation_id, event);
    }
    state.start_transcription(project_id, conversation_id, clip_id.clone());
    let status = if outcome == PutClip::Created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((
        status,
        Json(PutClipResponse {
            clip_id,
            created: outcome == PutClip::Created,
        }),
    ))
}

async fn create_turn(
    State(state): State<AppState>,
    Path((project_id, conversation_id)): Path<(String, String)>,
    Json(request): Json<CreateTurn>,
) -> Result<(StatusCode, Json<TurnResponse>), ApiError> {
    if !valid_id(&request.turn_id) {
        return Err(ApiError::bad_request("invalid turn_id"));
    }
    let outcome = state
        .store()
        .create_turn(&project_id, &conversation_id, &request.turn_id)
        .map_err(|error| {
            if error.downcast_ref::<NoPendingClips>().is_some() {
                ApiError::new(StatusCode::CONFLICT, "nothing new to answer")
            } else {
                ApiError::bad_request(error)
            }
        })?;
    let (status, clips, created) = match outcome {
        CreateTurnOutcome::Created { record, clips } => {
            state.publish(&project_id, &conversation_id, record);
            (StatusCode::ACCEPTED, clips, true)
        }
        CreateTurnOutcome::Existing { clips, .. } => (StatusCode::OK, clips, false),
    };
    state.start_turn(project_id, conversation_id, request.turn_id.clone());
    Ok((
        status,
        Json(TurnResponse {
            turn_id: request.turn_id,
            clips,
            created,
        }),
    ))
}

async fn clip_audio(
    State(state): State<AppState>,
    Path((project_id, conversation_id, clip_id)): Path<(String, String, String)>,
) -> Result<Response, ApiError> {
    let path = state
        .store()
        .clip_path(&project_id, &conversation_id, &clip_id)
        .map_err(ApiError::bad_request)?;
    let bytes = tokio::fs::read(path).await.map_err(ApiError::not_found)?;
    Ok(([(header::CONTENT_TYPE, "audio/wav")], bytes).into_response())
}

async fn speech(
    State(state): State<AppState>,
    Path((project_id, conversation_id, turn_id)): Path<(String, String, String)>,
    Query(query): Query<SpeechQuery>,
) -> Result<Response, ApiError> {
    if let Some(speech) = state.speech(&project_id, &conversation_id, &turn_id) {
        let mut position = query.from_sample;
        let mut changes = speech.changes();
        let body = Body::from_stream(stream! {
            loop {
                let (samples, done, error) = speech.snapshot(position);
                if !samples.is_empty() {
                    position += samples.len();
                    let mut bytes = Vec::with_capacity(samples.len() * 2);
                    bytes.extend(samples.iter().flat_map(|sample| sample.to_le_bytes()));
                    yield Ok::<Bytes, std::io::Error>(Bytes::from(bytes));
                    continue;
                }
                if let Some(error) = error {
                    yield Err(std::io::Error::other(error));
                    break;
                }
                if done {
                    break;
                }
                if changes.changed().await.is_err() {
                    break;
                }
            }
        });
        return Ok(pcm_response(body));
    }

    let path = state
        .store()
        .speech_path(&project_id, &conversation_id, &turn_id)
        .map_err(ApiError::bad_request)?;
    if path.exists() {
        let mut reader = hound::WavReader::open(path).map_err(ApiError::internal)?;
        let samples = reader
            .samples::<i16>()
            .skip(query.from_sample)
            .collect::<Result<Vec<_>, _>>()
            .map_err(ApiError::internal)?;
        let bytes: Vec<u8> = samples
            .iter()
            .flat_map(|sample| sample.to_le_bytes())
            .collect();
        return Ok(pcm_response(Body::from(bytes)));
    }
    let records = state
        .store()
        .records(&project_id, &conversation_id)
        .map_err(ApiError::not_found)?;
    if let Some(error) = records
        .iter()
        .rev()
        .find(|event| event["kind"] == "tts_error" && event["turn"] == turn_id)
    {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            error["error"].as_str().unwrap_or("speech synthesis failed"),
        ));
    }
    if records
        .iter()
        .any(|event| event["kind"] == "turn" && event["id"] == turn_id)
    {
        return Err(ApiError::new(
            StatusCode::TOO_EARLY,
            "speech is not ready yet",
        ));
    }
    Err(ApiError::new(StatusCode::NOT_FOUND, "turn not found"))
}

fn pcm_response(body: Body) -> Response {
    Response::builder()
        .header(
            header::CONTENT_TYPE,
            "application/vnd.kibo.pcm; format=s16le",
        )
        .header("X-Audio-Sample-Rate", crate::ai::TTS_RATE.to_string())
        .header("X-Audio-Channels", "1")
        .header("Cache-Control", "no-store")
        .body(body)
        .unwrap()
}

async fn events(
    websocket: Result<WebSocketUpgrade, WebSocketUpgradeRejection>,
    State(state): State<AppState>,
    Path((project_id, conversation_id)): Path<(String, String)>,
    Query(query): Query<EventsQuery>,
) -> Result<Response, ApiError> {
    state
        .store()
        .conversation(&project_id, &conversation_id)
        .map_err(ApiError::not_found)?;
    if let Ok(websocket) = websocket {
        return Ok(websocket
            .on_upgrade(move |socket| {
                event_socket(socket, state, project_id, conversation_id, query.after)
            })
            .into_response());
    }
    let events: Vec<KiboEvent> = state
        .store()
        .records(&project_id, &conversation_id)?
        .into_iter()
        .filter(|event| event["seq"].as_u64().unwrap_or(0) > query.after)
        .map(decode_event)
        .collect::<Result<_, _>>()?;
    let latest_seq = events.last().map(|event| event.seq).unwrap_or(query.after);
    Ok(Json(EventsEnvelope { events, latest_seq }).into_response())
}

async fn event_socket(
    mut socket: WebSocket,
    state: AppState,
    project_id: String,
    conversation_id: String,
    after: u64,
) {
    // Subscribe before reading the durable catch-up so an append between the
    // read and subscription cannot disappear. Sequence de-duplication makes
    // the possible overlap harmless.
    let mut receiver = state.subscribe(&project_id, &conversation_id);
    let mut cursor = after;
    let catchup = state
        .store()
        .records(&project_id, &conversation_id)
        .unwrap_or_default();
    for event in catchup {
        if event["seq"].as_u64().unwrap_or(0) <= cursor {
            continue;
        }
        cursor = event["seq"].as_u64().unwrap_or(cursor);
        if send_event(&mut socket, event).await.is_err() {
            return;
        }
    }
    loop {
        match receiver.recv().await {
            Ok(event) => {
                if send_event(&mut socket, event).await.is_err() {
                    return;
                }
            }
            Err(broadcast_error) => {
                tracing::debug!("event socket ended: {broadcast_error}");
                return;
            }
        }
    }
}

fn decode_event(event: Value) -> Result<KiboEvent, ApiError> {
    serde_json::from_value(event).map_err(ApiError::internal)
}

async fn send_event(socket: &mut WebSocket, event: Value) -> Result<(), ApiError> {
    let event = decode_event(event)?;
    let text = serde_json::to_string(&event).map_err(ApiError::internal)?;
    socket
        .send(Message::Text(text.into()))
        .await
        .map_err(ApiError::internal)
}

fn required_header(headers: &HeaderMap, name: &'static str) -> Result<String, ApiError> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| ApiError::bad_request(format!("missing {name} header")))
}

fn numeric_header<T>(headers: &HeaderMap, name: &'static str) -> Result<T, ApiError>
where
    T: std::str::FromStr,
{
    required_header(headers, name)?
        .parse()
        .map_err(|_| ApiError::bad_request(format!("invalid {name} header")))
}

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn new(status: StatusCode, error: impl std::fmt::Display) -> Self {
        Self {
            status,
            message: error.to_string(),
        }
    }

    fn bad_request(error: impl std::fmt::Display) -> Self {
        Self::new(StatusCode::BAD_REQUEST, error)
    }

    fn not_found(error: impl std::fmt::Display) -> Self {
        Self::new(StatusCode::NOT_FOUND, error)
    }

    fn internal(error: impl std::fmt::Display) -> Self {
        tracing::error!("internal server error: {error}");
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, "internal server error")
    }
}

impl<E> From<E> for ApiError
where
    E: Into<anyhow::Error>,
{
    fn from(error: E) -> Self {
        Self::internal(error.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, self.message).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agentic::CodexKnowledgeAgent;
    use crate::ai::Ai;
    use crate::knowledge;
    use crate::store::Store;
    use axum::body::to_bytes;
    use axum::extract::Request;
    use futures_util::StreamExt;
    use std::fs;
    use tower::ServiceExt;

    fn test_service(store: Store) -> Router {
        router().with_state(AppState::new(store, Ai::mock()))
    }

    fn query_request(project_id: &str, body: String) -> Request {
        Request::builder()
            .method("POST")
            .uri(format!("/v1/projects/{project_id}/knowledge/query"))
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body))
            .unwrap()
    }

    #[tokio::test]
    async fn knowledge_query_validates_project_and_question_before_spawning_codex() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();

        let response = test_service(store.clone())
            .oneshot(query_request("missing", r#"{"question":"hello"}"#.into()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);

        let response = test_service(store)
            .oneshot(query_request("kibo", r#"{"question":"   "}"#.into()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn knowledge_query_rejects_oversized_questions() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let body = serde_json::to_string(&json!({
            "question": "x".repeat(MAX_KNOWLEDGE_QUESTION_BYTES + 1)
        }))
        .unwrap();

        let response = test_service(store)
            .oneshot(query_request("kibo", body))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn knowledge_query_streams_normalized_events_and_sanitized_markdown() {
        use std::os::unix::fs::PermissionsExt;

        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let wiki = knowledge::wiki_root(&store, "kibo").unwrap();
        let wiki_json = serde_json::to_string(&wiki.to_string_lossy()).unwrap();
        let script = temporary.path().join("fake-codex");
        let body = format!(
            r##"#!/bin/sh
read initialize
printf '%s\n' '{{"id":0,"result":{{"userAgent":"fake"}}}}'
read initialized
read thread_start
permission_id=$(printf '%s\n' "$thread_start" | sed -n 's/.*"permissions":"\([^"]*\)".*/\1/p')
printf '%s\n' '{{"id":1,"result":{{"thread":{{"id":"thread-1"}},"cwd":{wiki_json},"runtimeWorkspaceRoots":[{wiki_json}],"approvalPolicy":"never","sandbox":{{"type":"readOnly","networkAccess":false}},"activePermissionProfile":{{"id":"PROFILE_ID"}},"instructionSources":[]}}}}' | sed "s/PROFILE_ID/$permission_id/"
read mcp_status
printf '%s\n' '{{"id":2,"result":{{"data":[],"nextCursor":null}}}}'
read turn_start
printf '%s\n' '{{"id":3,"result":{{"turn":{{"id":"turn-1"}}}}}}'
printf '%s\n' '{{"method":"item/agentMessage/delta","params":{{"threadId":"thread-1","turnId":"turn-1","itemId":"answer-1","delta":"# Answer"}}}}'
printf '%s\n' '{{"method":"item/completed","params":{{"threadId":"thread-1","turnId":"turn-1","item":{{"type":"agentMessage","id":"answer-1","text":"# Answer\n\n<script>bad()</script>\n\n[Note](sources/test.md)"}}}}}}'
printf '%s\n' '{{"method":"turn/completed","params":{{"threadId":"thread-1","turn":{{"id":"turn-1","status":"completed","items":[],"error":null}}}}}}'
while read ignored; do :; done
"##
        );
        fs::write(&script, body).unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let state = AppState::with_test_knowledge_agent(
            store,
            Ai::mock(),
            CodexKnowledgeAgent::for_test(script.into_os_string()),
        );

        let response = router()
            .with_state(state)
            .oneshot(query_request(
                "kibo",
                r#"{"question":"What is here?"}"#.into(),
            ))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers()[header::CONTENT_TYPE],
            "application/x-ndjson; charset=utf-8"
        );
        let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
        let events: Vec<Value> = std::str::from_utf8(&bytes)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(events[0]["type"], "started");
        assert!(events[0]["query_id"].as_str().is_some_and(valid_id));
        assert_eq!(events[1], json!({ "type": "delta", "text": "# Answer" }));
        assert_eq!(events[2]["type"], "completed");
        assert!(
            events[2]["html"]
                .as_str()
                .unwrap()
                .contains("<h1>Answer</h1>")
        );
        assert!(!events[2]["html"].as_str().unwrap().contains("<script>"));
        assert!(
            events[2]["html"]
                .as_str()
                .unwrap()
                .contains("href=\"sources/test.md\"")
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn dropped_knowledge_query_stream_revokes_its_continuation_token() {
        use std::os::unix::fs::PermissionsExt;

        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let wiki = knowledge::wiki_root(&store, "kibo").unwrap();
        let wiki_json = serde_json::to_string(&wiki.to_string_lossy()).unwrap();
        let script = temporary.path().join("fake-codex");
        let body = format!(
            r##"#!/bin/sh
read initialize
printf '%s\n' '{{"id":0,"result":{{"userAgent":"fake"}}}}'
read initialized
read thread_start
permission_id=$(printf '%s\n' "$thread_start" | sed -n 's/.*"permissions":"\([^"]*\)".*/\1/p')
printf '%s\n' '{{"id":1,"result":{{"thread":{{"id":"thread-incomplete"}},"cwd":{wiki_json},"runtimeWorkspaceRoots":[{wiki_json}],"approvalPolicy":"never","sandbox":{{"type":"readOnly","networkAccess":false}},"activePermissionProfile":{{"id":"PROFILE_ID"}},"instructionSources":[]}}}}' | sed "s/PROFILE_ID/$permission_id/"
read mcp_status
printf '%s\n' '{{"id":2,"result":{{"data":[],"nextCursor":null}}}}'
read turn_start
printf '%s\n' '{{"id":3,"result":{{"turn":{{"id":"turn-incomplete"}}}}}}'
case "$turn_start" in
  *fail*) printf '%s\n' '{{"method":"turn/completed","params":{{"threadId":"thread-incomplete","turn":{{"id":"turn-incomplete","status":"failed","items":[],"error":{{"message":"forced failure"}}}}}}}}' ;;
esac
while read ignored; do :; done
"##
        );
        fs::write(&script, body).unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let state = AppState::with_test_knowledge_agent(
            store,
            Ai::mock(),
            CodexKnowledgeAgent::for_test(script.into_os_string()),
        );
        let service = router().with_state(state);

        let response = service
            .clone()
            .oneshot(query_request(
                "kibo",
                r#"{"question":"What is here?"}"#.into(),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let mut events = response.into_body().into_data_stream();
        let started = events.next().await.unwrap().unwrap();
        let started: Value = serde_json::from_slice(&started).unwrap();
        let query_id = started["query_id"].as_str().unwrap().to_string();

        // This is the HTTP client-disconnect path: dropping the response body
        // drops KnowledgeQuery before Codex has emitted a Completed event.
        drop(events);

        let response = service
            .clone()
            .oneshot(query_request(
                "kibo",
                serde_json::to_string(&json!({
                    "question": "continue",
                    "thread_id": query_id
                }))
                .unwrap(),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);

        let response = service
            .clone()
            .oneshot(query_request(
                "kibo",
                r#"{"question":"fail this turn"}"#.into(),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
        let failed_events: Vec<Value> = std::str::from_utf8(&bytes)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let failed_query_id = failed_events[0]["query_id"].as_str().unwrap();
        assert_eq!(failed_events.last().unwrap()["type"], "error");

        let response = service
            .oneshot(query_request(
                "kibo",
                serde_json::to_string(&json!({
                    "question": "continue after failure",
                    "thread_id": failed_query_id
                }))
                .unwrap(),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[test]
    fn arbitrary_process_errors_are_not_exposed_to_api_clients() {
        let error = anyhow::anyhow!("spawn /private/secret/tool: permission denied");
        assert_eq!(
            query_public_error(&error),
            "The Codex knowledge query failed. Check kibod logs and Codex authentication."
        );

        let restricted = anyhow::Error::new(RestrictedAccessUnavailable)
            .context("loaded /private/secret/AGENTS.md");
        assert_eq!(
            query_public_error(&restricted),
            "Codex could not enforce the isolated read-only knowledge sandbox."
        );
        assert!(!query_public_error(&restricted).contains("/private/secret"));

        let timed_out = anyhow::Error::new(QueryTimeout).context("reading /private/secret/path");
        assert_eq!(
            query_public_error(&timed_out),
            "The Codex knowledge query timed out."
        );
    }
}

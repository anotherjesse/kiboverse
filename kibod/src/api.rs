use crate::model::{
    CompleteRecording, CompleteRecordingResponse, ConversationsEnvelope, CreateConversation,
    CreateNamed, CreateTurn, EventsEnvelope, EventsQuery, KiboConversation, KiboEvent, KiboProject,
    ProjectsEnvelope, PutClipResponse, PutRecordingPartResponse, SpeechQuery, TurnResponse, epoch,
    valid_id,
};
use crate::state::AppState;
use crate::store::{
    ClipConflict, ClipUpload, CompleteRecordingOutcome, CreateTurnOutcome, NoPendingClips, PutClip,
    PutRecordingPart, RecordingCompletion, RecordingConflict, RecordingPartUpload, hex_sha256,
};
use crate::workflow::AttemptState;
use async_stream::stream;
use axum::body::{Body, Bytes};
use axum::extract::ws::rejection::WebSocketUpgradeRejection;
use axum::extract::ws::{Message, WebSocket};
use axum::extract::{DefaultBodyLimit, Path, Query, State, WebSocketUpgrade};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::{Json, Router};
use serde_json::Value;
use std::io::Cursor;

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
            "/v1/projects/{project_id}/conversations/{conversation_id}/recordings/{recording_id}/parts/{sequence}",
            put(put_recording_part),
        )
        .route(
            "/v1/projects/{project_id}/conversations/{conversation_id}/recordings/{recording_id}/complete",
            post(complete_recording),
        )
        .route(
            "/v1/projects/{project_id}/conversations/{conversation_id}/clips/{clip_id}/audio",
            get(clip_audio),
        )
        .route(
            "/v1/projects/{project_id}/conversations/{conversation_id}/clips/{clip_id}/retry",
            post(retry_clip),
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
            "/v1/projects/{project_id}/conversations/{conversation_id}/turns/{turn_id}/retry",
            post(retry_turn),
        )
        .route(
            "/v1/projects/{project_id}/conversations/{conversation_id}/events",
            get(events),
        )
        .layer(DefaultBodyLimit::max(20 * 1024 * 1024))
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
        state.publish_persisted(&project_id, &conversation_id, event);
    }
    state
        .reconcile_transcriptions(&project_id, &conversation_id)
        .map_err(ApiError::internal)?;
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

async fn put_recording_part(
    State(state): State<AppState>,
    Path((project_id, conversation_id, recording_id, sequence)): Path<(
        String,
        String,
        String,
        u32,
    )>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<(StatusCode, Json<PutRecordingPartResponse>), ApiError> {
    let expected_sha256 = required_header(&headers, "x-content-sha256")?;
    let sample_count = numeric_header(&headers, "x-sample-count")?;
    let outcome = state
        .store()
        .put_recording_part(RecordingPartUpload {
            project_id: &project_id,
            conversation_id: &conversation_id,
            recording_id: &recording_id,
            sequence,
            bytes: &body,
            expected_sha256: &expected_sha256,
            sample_count,
        })
        .map_err(recording_api_error)?;
    let created = outcome == PutRecordingPart::Created;
    Ok((
        if created {
            StatusCode::CREATED
        } else {
            StatusCode::OK
        },
        Json(PutRecordingPartResponse {
            recording_id,
            sequence,
            created,
        }),
    ))
}

async fn complete_recording(
    State(state): State<AppState>,
    Path((project_id, conversation_id, recording_id)): Path<(String, String, String)>,
    Json(request): Json<CompleteRecording>,
) -> Result<(StatusCode, Json<CompleteRecordingResponse>), ApiError> {
    let (outcome, event) = state
        .store()
        .complete_recording(RecordingCompletion {
            project_id: &project_id,
            conversation_id: &conversation_id,
            recording_id: &recording_id,
            part_count: request.part_count,
            total_samples: request.total_samples,
        })
        .map_err(recording_api_error)?;
    if let Some(event) = event {
        state.publish_persisted(&project_id, &conversation_id, event);
    }
    state
        .reconcile_transcriptions(&project_id, &conversation_id)
        .map_err(ApiError::internal)?;
    let created = outcome == CompleteRecordingOutcome::Created;
    Ok((
        if created {
            StatusCode::CREATED
        } else {
            StatusCode::OK
        },
        Json(CompleteRecordingResponse {
            clip_id: recording_id,
            created,
        }),
    ))
}

fn recording_api_error(error: anyhow::Error) -> ApiError {
    if error.downcast_ref::<RecordingConflict>().is_some() {
        ApiError::new(StatusCode::CONFLICT, error)
    } else {
        ApiError::bad_request(error)
    }
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
            state.publish_persisted(&project_id, &conversation_id, record);
            (StatusCode::ACCEPTED, clips, true)
        }
        CreateTurnOutcome::Existing { clips, .. } => (StatusCode::OK, clips, false),
    };
    // Scheduling an existing command is safe after a lost HTTP response, but
    // replaying the idempotent POST must never reopen terminal provider work.
    state.wake_conversation(project_id, conversation_id);
    Ok((
        status,
        Json(TurnResponse {
            turn_id: request.turn_id,
            clips,
            created,
        }),
    ))
}

async fn retry_clip(
    State(state): State<AppState>,
    Path((project_id, conversation_id, clip_id)): Path<(String, String, String)>,
) -> Result<StatusCode, ApiError> {
    let found = state
        .retry_transcription(&project_id, &conversation_id, &clip_id, "explicit_retry")
        .map_err(ApiError::retry_lookup)?;
    if found {
        Ok(StatusCode::ACCEPTED)
    } else {
        Err(ApiError::not_found("clip not found"))
    }
}

async fn retry_turn(
    State(state): State<AppState>,
    Path((project_id, conversation_id, turn_id)): Path<(String, String, String)>,
) -> Result<StatusCode, ApiError> {
    let found = state
        .retry_turn(&project_id, &conversation_id, &turn_id)
        .map_err(ApiError::retry_lookup)?;
    if found {
        Ok(StatusCode::ACCEPTED)
    } else {
        Err(ApiError::not_found("turn not found"))
    }
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
    headers: HeaderMap,
    Query(query): Query<SpeechQuery>,
) -> Result<Response, ApiError> {
    let expected_generation = optional_header(&headers, "x-speech-generation")?;
    if let Some(speech) = state.speech(&project_id, &conversation_id, &turn_id) {
        let generation = speech.generation().to_string();
        validate_speech_resume(
            query.from_sample,
            expected_generation.as_deref(),
            &generation,
            speech.generation_index(),
        )?;
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
        return Ok(pcm_response(body, &generation));
    }

    let path = state
        .store()
        .speech_path(&project_id, &conversation_id, &turn_id)
        .map_err(ApiError::bad_request)?;
    if path.exists() {
        let records = state
            .store()
            .records(&project_id, &conversation_id)
            .map_err(ApiError::retry_lookup)?;
        let workflow = crate::workflow::ConversationWorkflow::from_records(&records);
        let turn = workflow.turn(&turn_id);
        let wav = std::fs::read(&path).map_err(ApiError::internal)?;
        let explicit_generation = turn
            .and_then(|turn| turn.speech_generation.as_deref())
            .filter(|generation| *generation != "legacy");
        let adopted_generation;
        let generation = if let Some(generation) = explicit_generation {
            generation
        } else {
            adopted_generation = adopted_speech_generation(&wav);
            &adopted_generation
        };
        let generation_index = turn
            .map(|turn| turn.speech_generation_index)
            .unwrap_or(0)
            .max(if explicit_generation.is_some() { 1 } else { 2 });
        validate_speech_resume(
            query.from_sample,
            expected_generation.as_deref(),
            generation,
            generation_index,
        )?;
        let mut reader = hound::WavReader::new(Cursor::new(wav)).map_err(ApiError::internal)?;
        let samples = reader
            .samples::<i16>()
            .skip(query.from_sample)
            .collect::<Result<Vec<_>, _>>()
            .map_err(ApiError::internal)?;
        let bytes: Vec<u8> = samples
            .iter()
            .flat_map(|sample| sample.to_le_bytes())
            .collect();
        return Ok(pcm_response(Body::from(bytes), generation));
    }
    let records = state
        .store()
        .records(&project_id, &conversation_id)
        .map_err(ApiError::retry_lookup)?;
    let workflow = crate::workflow::ConversationWorkflow::from_records(&records);
    if let Some(AttemptState::TerminalFailure(failure)) = workflow
        .turn(&turn_id)
        .and_then(|turn| turn.speech.as_ref())
    {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            failure.error.clone(),
        ));
    }
    if workflow.turn(&turn_id).is_some() {
        return Err(ApiError::new(
            StatusCode::TOO_EARLY,
            "speech is not ready yet",
        ));
    }
    Err(ApiError::new(StatusCode::NOT_FOUND, "turn not found"))
}

fn pcm_response(body: Body, generation: &str) -> Response {
    Response::builder()
        .header(
            header::CONTENT_TYPE,
            "application/vnd.kibo.pcm; format=s16le",
        )
        .header("X-Audio-Sample-Rate", crate::ai::TTS_RATE.to_string())
        .header("X-Audio-Channels", "1")
        .header("X-Speech-Generation", generation)
        .header("Cache-Control", "no-store")
        .body(body)
        .unwrap()
}

fn adopted_speech_generation(wav: &[u8]) -> String {
    format!("adopted-{}", hex_sha256(wav))
}

fn validate_speech_resume(
    from_sample: usize,
    expected_generation: Option<&str>,
    current_generation: &str,
    generation_index: u32,
) -> Result<(), ApiError> {
    if expected_generation.is_some_and(|expected| expected != current_generation)
        || (from_sample > 0 && expected_generation.is_none() && generation_index > 1)
    {
        return Err(ApiError::new(
            StatusCode::PRECONDITION_FAILED,
            "speech generation changed; restart from sample zero",
        ));
    }
    Ok(())
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
    // read and subscription cannot disappear. The cursor removes queued
    // overlap; a forward gap closes the socket so reconnect can reread the
    // authoritative journal in order.
    let mut receiver = state.subscribe(&project_id, &conversation_id);
    let mut cursor = after;
    let catchup = match durable_event_catchup(&state, &project_id, &conversation_id, after) {
        Ok(events) => events,
        Err(error) => {
            tracing::warn!(%project_id, %conversation_id, "event socket catch-up failed: {error:#}");
            return;
        }
    };
    for event in catchup {
        match advance_event_cursor(&mut cursor, &event) {
            EventCursorAction::Send => {}
            EventCursorAction::Duplicate => continue,
            EventCursorAction::Reconnect => {
                tracing::debug!(%project_id, %conversation_id, "event socket catch-up sequence gap");
                return;
            }
        }
        if send_event(&mut socket, event).await.is_err() {
            return;
        }
    }
    loop {
        match receiver.recv().await {
            Ok(event) => {
                match advance_event_cursor(&mut cursor, &event) {
                    EventCursorAction::Send => {}
                    EventCursorAction::Duplicate => continue,
                    EventCursorAction::Reconnect => {
                        tracing::debug!(%project_id, %conversation_id, "event socket broadcast sequence gap");
                        return;
                    }
                }
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

#[derive(Debug, PartialEq, Eq)]
enum EventCursorAction {
    Send,
    Duplicate,
    Reconnect,
}

fn advance_event_cursor(cursor: &mut u64, event: &Value) -> EventCursorAction {
    let Some(sequence) = event["seq"].as_u64() else {
        return EventCursorAction::Reconnect;
    };
    if sequence <= *cursor {
        return EventCursorAction::Duplicate;
    }
    if sequence != cursor.saturating_add(1) {
        return EventCursorAction::Reconnect;
    }
    *cursor = sequence;
    EventCursorAction::Send
}

fn durable_event_catchup(
    state: &AppState,
    project_id: &str,
    conversation_id: &str,
    after: u64,
) -> anyhow::Result<Vec<Value>> {
    Ok(state
        .store()
        .records(project_id, conversation_id)?
        .into_iter()
        .filter(|event| event["seq"].as_u64().unwrap_or(0) > after)
        .collect())
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

fn optional_header(headers: &HeaderMap, name: &'static str) -> Result<Option<String>, ApiError> {
    headers
        .get(name)
        .map(|value| {
            value
                .to_str()
                .map(str::to_string)
                .map_err(|_| ApiError::bad_request(format!("invalid {name} header")))
        })
        .transpose()
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

    fn retry_lookup(error: anyhow::Error) -> Self {
        let missing_parent = error.chain().any(|cause| {
            cause
                .downcast_ref::<std::io::Error>()
                .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound)
        });
        if missing_parent {
            Self::not_found("project or conversation not found")
        } else {
            Self::internal(error)
        }
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
    use crate::{ai::Ai, store::Store};
    use axum::body::to_bytes;
    use axum::extract::Request;
    use axum::http::HeaderValue;
    use serde_json::json;
    use tower::ServiceExt;

    #[test]
    fn speech_resume_is_scoped_to_one_generation() {
        assert!(validate_speech_resume(0, None, "generation-2", 2).is_ok());
        assert!(validate_speech_resume(12, Some("generation-2"), "generation-2", 2).is_ok());
        assert!(
            validate_speech_resume(12, None, "generation-1", 1).is_ok(),
            "an older client may resume the first synthesis"
        );

        let stale =
            validate_speech_resume(12, Some("generation-1"), "generation-2", 2).unwrap_err();
        assert_eq!(stale.status, StatusCode::PRECONDITION_FAILED);
        let unversioned = validate_speech_resume(12, None, "generation-2", 2).unwrap_err();
        assert_eq!(unversioned.status, StatusCode::PRECONDITION_FAILED);
    }

    #[tokio::test]
    async fn legacy_wav_is_adopted_before_any_nonzero_resume() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        for event in [
            serde_json::json!({"kind":"turn", "id":"turn-1", "clips":[]}),
            serde_json::json!({
                "kind":"reply", "turn":"turn-1", "text":"legacy",
                "audio":"tts/turn-1.wav"
            }),
            serde_json::json!({
                "kind":"speech_ready", "turn":"turn-1", "samples":2, "rate":24000
            }),
        ] {
            store
                .append_fixture("kibo", &conversation.id, event)
                .unwrap();
        }
        let path = store
            .speech_path("kibo", &conversation.id, "turn-1")
            .unwrap();
        let mut writer = hound::WavWriter::create(
            path,
            hound::WavSpec {
                channels: 1,
                sample_rate: 24_000,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
        )
        .unwrap();
        writer.write_sample(10_i16).unwrap();
        writer.write_sample(20_i16).unwrap();
        writer.finalize().unwrap();

        let state = AppState::new(store, Ai::mock());
        let path = Path(("kibo".into(), conversation.id.clone(), "turn-1".into()));
        let response = speech(
            State(state.clone()),
            path,
            HeaderMap::new(),
            Query(SpeechQuery { from_sample: 0 }),
        )
        .await
        .unwrap();
        let adopted = response
            .headers()
            .get("X-Speech-Generation")
            .unwrap()
            .to_str()
            .unwrap()
            .to_string();
        assert!(adopted.starts_with("adopted-"));
        assert_ne!(adopted, "legacy");

        let repeated = speech(
            State(state.clone()),
            Path(("kibo".into(), conversation.id.clone(), "turn-1".into())),
            HeaderMap::new(),
            Query(SpeechQuery { from_sample: 0 }),
        )
        .await
        .unwrap();
        assert_eq!(
            repeated.headers().get("X-Speech-Generation").unwrap(),
            adopted.as_str()
        );

        let mut legacy_header = HeaderMap::new();
        legacy_header.insert("X-Speech-Generation", HeaderValue::from_static("legacy"));
        for headers in [legacy_header, HeaderMap::new()] {
            let error = speech(
                State(state.clone()),
                Path(("kibo".into(), conversation.id.clone(), "turn-1".into())),
                headers,
                Query(SpeechQuery { from_sample: 1 }),
            )
            .await
            .unwrap_err();
            assert_eq!(error.status, StatusCode::PRECONDITION_FAILED);
        }
    }

    #[test]
    fn socket_catchup_propagates_a_durable_read_failure() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let state = AppState::new(store.clone(), Ai::mock());

        assert!(
            durable_event_catchup(&state, "kibo", &conversation.id, 0)
                .unwrap()
                .is_empty()
        );
        store.fail_next_record_reads(1);
        let error = durable_event_catchup(&state, "kibo", &conversation.id, 0).unwrap_err();
        assert!(error.to_string().contains("injected journal read failure"));
    }

    #[test]
    fn socket_cursor_discards_catchup_broadcast_overlap_and_regressions() {
        let mut cursor = 4;
        assert_eq!(
            advance_event_cursor(&mut cursor, &serde_json::json!({"seq":5})),
            EventCursorAction::Send
        );
        assert_eq!(cursor, 5);
        assert_eq!(
            advance_event_cursor(&mut cursor, &serde_json::json!({"seq":5})),
            EventCursorAction::Duplicate
        );
        assert_eq!(
            advance_event_cursor(&mut cursor, &serde_json::json!({"seq":3})),
            EventCursorAction::Duplicate
        );
        assert_eq!(
            advance_event_cursor(&mut cursor, &serde_json::json!({"kind":"missing-sequence"})),
            EventCursorAction::Reconnect
        );
        assert_eq!(
            advance_event_cursor(&mut cursor, &serde_json::json!({"seq":7})),
            EventCursorAction::Reconnect,
            "a forward gap must reconnect instead of dropping a later durable event"
        );
        assert_eq!(cursor, 5, "a gap must not advance the durable cursor");
        assert_eq!(
            advance_event_cursor(&mut cursor, &serde_json::json!({"seq":6})),
            EventCursorAction::Send
        );
        assert_eq!(cursor, 6);
    }

    #[tokio::test]
    async fn retry_endpoints_report_missing_parent_resources_as_not_found() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let state = AppState::new(store, Ai::mock());

        for (project_id, conversation_id) in [("missing", "missing"), ("kibo", "missing")] {
            let clip_error = retry_clip(
                State(state.clone()),
                Path((
                    project_id.to_string(),
                    conversation_id.to_string(),
                    "clip-1".to_string(),
                )),
            )
            .await
            .unwrap_err();
            assert_eq!(clip_error.status, StatusCode::NOT_FOUND);

            let turn_error = retry_turn(
                State(state.clone()),
                Path((
                    project_id.to_string(),
                    conversation_id.to_string(),
                    "turn-1".to_string(),
                )),
            )
            .await
            .unwrap_err();
            assert_eq!(turn_error.status, StatusCode::NOT_FOUND);
        }
    }

    #[tokio::test]
    async fn retry_endpoints_keep_internal_read_failures_internal() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let state = AppState::new(store.clone(), Ai::mock());

        store.fail_next_record_reads(1);
        let clip_error = retry_clip(
            State(state.clone()),
            Path((
                "kibo".to_string(),
                conversation.id.clone(),
                "clip-1".to_string(),
            )),
        )
        .await
        .unwrap_err();
        assert_eq!(clip_error.status, StatusCode::INTERNAL_SERVER_ERROR);

        store.fail_next_record_reads(1);
        let turn_error = retry_turn(
            State(state),
            Path(("kibo".to_string(), conversation.id, "turn-1".to_string())),
        )
        .await
        .unwrap_err();
        assert_eq!(turn_error.status, StatusCode::INTERNAL_SERVER_ERROR);
    }

    #[tokio::test]
    async fn speech_distinguishes_missing_parents_from_internal_journal_failures() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();

        let missing = speech(
            State(AppState::new(store.clone(), Ai::mock())),
            Path(("kibo".into(), "missing".into(), "turn-1".into())),
            HeaderMap::new(),
            Query(SpeechQuery { from_sample: 0 }),
        )
        .await
        .unwrap_err();
        assert_eq!(missing.status, StatusCode::NOT_FOUND);

        let state = AppState::new(store.clone(), Ai::mock());
        store.fail_next_record_reads(1);
        let without_wav = speech(
            State(state.clone()),
            Path(("kibo".into(), conversation.id.clone(), "turn-1".into())),
            HeaderMap::new(),
            Query(SpeechQuery { from_sample: 0 }),
        )
        .await
        .unwrap_err();
        assert_eq!(without_wav.status, StatusCode::INTERNAL_SERVER_ERROR);

        let speech_path = store
            .speech_path("kibo", &conversation.id, "turn-1")
            .unwrap();
        let mut writer = hound::WavWriter::create(
            speech_path,
            hound::WavSpec {
                channels: 1,
                sample_rate: 24_000,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
        )
        .unwrap();
        writer.write_sample(10_i16).unwrap();
        writer.finalize().unwrap();

        store.fail_next_record_reads(1);
        let with_wav = speech(
            State(state),
            Path(("kibo".into(), conversation.id, "turn-1".into())),
            HeaderMap::new(),
            Query(SpeechQuery { from_sample: 0 }),
        )
        .await
        .unwrap_err();
        assert_eq!(with_wav.status, StatusCode::INTERNAL_SERVER_ERROR);
    }

    fn test_wav(samples: &[i16]) -> Vec<u8> {
        let data_len = u32::try_from(samples.len() * 2).unwrap();
        let mut bytes = Vec::with_capacity(44 + data_len as usize);
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&16_000_u32.to_le_bytes());
        bytes.extend_from_slice(&32_000_u32.to_le_bytes());
        bytes.extend_from_slice(&2_u16.to_le_bytes());
        bytes.extend_from_slice(&16_u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&data_len.to_le_bytes());
        bytes.extend(samples.iter().flat_map(|sample| sample.to_le_bytes()));
        bytes
    }

    fn part_request(uri: &str, samples: &[i16]) -> Request {
        let bytes = test_wav(samples);
        Request::builder()
            .method("PUT")
            .uri(uri)
            .header("X-Content-Sha256", hex_sha256(&bytes))
            .header("X-Sample-Count", samples.len())
            .header("X-Peak-Pct", "99")
            .body(Body::from(bytes))
            .unwrap()
    }

    fn completion_request(uri: &str, part_count: u32, total_samples: u64) -> Request {
        Request::builder()
            .method("POST")
            .uri(uri)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "part_count": part_count,
                    "total_samples": total_samples,
                    "peak_pct": 99
                })
                .to_string(),
            ))
            .unwrap()
    }

    #[tokio::test]
    async fn recording_routes_retry_conflict_and_commit_one_continuous_clip() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store
            .create_conversation("kibo", Some("Recording API test"))
            .unwrap();
        let service = router().with_state(AppState::new(store.clone(), Ai::mock()));
        let base = format!(
            "/v1/projects/kibo/conversations/{}/recordings/api-long",
            conversation.id
        );

        let part_one = format!("{base}/parts/1");
        assert_eq!(
            service
                .clone()
                .oneshot(part_request(&part_one, &[3, 4]))
                .await
                .unwrap()
                .status(),
            StatusCode::CREATED
        );
        assert_eq!(
            service
                .clone()
                .oneshot(part_request(&part_one, &[3, 4]))
                .await
                .unwrap()
                .status(),
            StatusCode::OK
        );
        assert_eq!(
            service
                .clone()
                .oneshot(part_request(&part_one, &[4, 3]))
                .await
                .unwrap()
                .status(),
            StatusCode::CONFLICT
        );

        let complete = format!("{base}/complete");
        let missing = service
            .clone()
            .oneshot(completion_request(&complete, 2, 4))
            .await
            .unwrap();
        assert_eq!(missing.status(), StatusCode::CONFLICT);
        let message = to_bytes(missing.into_body(), 1024).await.unwrap();
        assert!(String::from_utf8_lossy(&message).contains("part 0 is missing"));
        assert!(store.records("kibo", &conversation.id).unwrap().is_empty());

        let part_zero = format!("{base}/parts/0");
        assert_eq!(
            service
                .clone()
                .oneshot(part_request(&part_zero, &[1, 2]))
                .await
                .unwrap()
                .status(),
            StatusCode::CREATED
        );
        assert_eq!(
            service
                .clone()
                .oneshot(completion_request(&complete, 2, 5))
                .await
                .unwrap()
                .status(),
            StatusCode::CONFLICT
        );
        assert_eq!(
            service
                .clone()
                .oneshot(completion_request(&complete, 2, 4))
                .await
                .unwrap()
                .status(),
            StatusCode::CREATED
        );
        assert_eq!(
            service
                .clone()
                .oneshot(completion_request(&complete, 2, 4))
                .await
                .unwrap()
                .status(),
            StatusCode::OK
        );

        let records = store.records("kibo", &conversation.id).unwrap();
        assert_eq!(
            records
                .iter()
                .filter(|record| record["kind"] == "clip")
                .count(),
            1
        );
        let mut wav = hound::WavReader::open(
            store
                .clip_path("kibo", &conversation.id, "api-long")
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            wav.samples::<i16>().collect::<Result<Vec<_>, _>>().unwrap(),
            [1, 2, 3, 4]
        );
    }
}

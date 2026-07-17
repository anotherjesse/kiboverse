use crate::model::{
    CompleteRecording, CompleteRecordingResponse, ConversationsEnvelope, CreateConversation,
    CreateNamed, CreateTurn, EventsEnvelope, EventsQuery, KiboConversation, KiboEvent, KiboProject,
    ProjectsEnvelope, PutClipResponse, PutRecordingPartResponse, SpeechQuery, TurnResponse, epoch,
    valid_id,
};
use crate::state::AppState;
use crate::store::{
    ClipConflict, ClipUpload, CompleteRecordingOutcome, CreateTurnOutcome, NoPendingClips, PutClip,
    PutRecordingPart, RecordingCompletion, RecordingConflict, RecordingPartUpload,
};
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
        state.publish(&project_id, &conversation_id, event);
    }
    state.start_transcription(project_id, conversation_id, recording_id.clone());
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
    use crate::ai::Ai;
    use crate::store::{Store, hex_sha256};
    use axum::body::to_bytes;
    use axum::extract::Request;
    use serde_json::json;
    use tower::ServiceExt;

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

use crate::agentic::{QueryBusy, QueryEvent, QueryTimeout, RestrictedAccessUnavailable};
use crate::model::{
    CompleteRecording, CompleteRecordingResponse, ConversationsEnvelope, CreateConversation,
    CreateNamed, CreateTurn, EventsEnvelope, EventsQuery, KiboConversation, KiboEvent, KiboProject,
    ProjectsEnvelope, PutClipResponse, PutRecordingPartResponse, SpeechQuery, TurnResponse, epoch,
    valid_id,
};
use crate::model::PutImageResponse;
use crate::state::{AppState, QueryThreadBusy, UnknownQueryThread};
use crate::store::{
    ClipConflict, ClipUpload, CompleteRecordingOutcome, CreateTurnOutcome, ImageConflict,
    ImageUpload, NoPendingClips, PutClip, PutImage, PutRecordingPart, RecordingCompletion,
    RecordingConflict, RecordingPartUpload, hex_sha256, sniff_image_format,
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
use serde::Deserialize;
use serde_json::{Value, json};
use std::convert::Infallible;
use std::io::Cursor;

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
            "/v1/projects/{project_id}/conversations/{conversation_id}/images/{image_id}",
            put(put_image),
        )
        .route(
            "/v1/projects/{project_id}/conversations/{conversation_id}/images/{image_id}/content",
            get(image_content),
        )
        .route(
            "/v1/projects/{project_id}/conversations/{conversation_id}/images/{image_id}/retry",
            post(retry_image),
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
        state.publish_persisted(&project_id, &conversation_id, event);
    }
    state
        .reconcile_media(&project_id, &conversation_id)
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

const MAX_IMAGE_BYTES: usize = 10 * 1024 * 1024;
const MAX_IMAGE_CAPTION_BYTES: usize = 4 * 1024;

#[derive(Debug, Default, Deserialize)]
struct ImageUploadQuery {
    #[serde(default)]
    caption: Option<String>,
}

async fn put_image(
    State(state): State<AppState>,
    Path((project_id, conversation_id, image_id)): Path<(String, String, String)>,
    Query(query): Query<ImageUploadQuery>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<(StatusCode, Json<PutImageResponse>), ApiError> {
    if body.len() > MAX_IMAGE_BYTES {
        return Err(ApiError::bad_request("image exceeds the 10 MiB limit"));
    }
    // The sniff is the mime authority; a Content-Type header may only agree.
    let Some(format) = sniff_image_format(&body) else {
        return Err(ApiError::bad_request(
            "body must be a JPEG, PNG, or WebP image",
        ));
    };
    if let Some(content_type) = optional_header(&headers, "content-type")? {
        let essence = content_type
            .split(';')
            .next()
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase();
        if essence != format.mime() {
            return Err(ApiError::bad_request(
                "Content-Type does not match the image bytes",
            ));
        }
    }
    let expected_sha256 = required_header(&headers, "x-content-sha256")?;
    let recorded_at = numeric_header(&headers, "x-recorded-at").unwrap_or_else(|_| epoch());
    let width = optional_numeric_header(&headers, "x-width");
    let height = optional_numeric_header(&headers, "x-height");
    // The caption is fixed at first upload; replays never mutate it.
    let caption = query
        .caption
        .as_deref()
        .map(str::trim)
        .filter(|caption| !caption.is_empty())
        .map(str::to_string);
    if caption.as_ref().is_some_and(|caption| caption.len() > MAX_IMAGE_CAPTION_BYTES) {
        return Err(ApiError::bad_request("caption must be 4 KiB or smaller"));
    }
    // Validation happens here so a store failure below can only be
    // infrastructure: a failed repair batch or byte restore must surface as
    // 5xx, keeping client retry loops alive to re-enter the repair path.
    if !valid_id(&image_id) {
        return Err(ApiError::bad_request("invalid image_id"));
    }
    state
        .store()
        .conversation(&project_id, &conversation_id)
        .map_err(ApiError::not_found)?;
    if !hex_sha256(&body).eq_ignore_ascii_case(&expected_sha256) {
        return Err(ApiError::bad_request(
            "content SHA-256 does not match X-Content-Sha256",
        ));
    }
    let (outcome, events) = state
        .store()
        .put_image(ImageUpload {
            project_id: &project_id,
            conversation_id: &conversation_id,
            image_id: &image_id,
            bytes: &body,
            expected_sha256: &expected_sha256,
            recorded_at,
            width,
            height,
            caption,
        })
        .map_err(|error| {
            if error.downcast_ref::<ImageConflict>().is_some() {
                ApiError::new(StatusCode::CONFLICT, error)
            } else {
                ApiError::internal(error)
            }
        })?;
    // Publish every appended event in sequence order so the strict WS cursor
    // never sees a gap on the success path.
    for event in events {
        state.publish_persisted(&project_id, &conversation_id, event);
    }
    state
        .reconcile_media(&project_id, &conversation_id)
        .map_err(ApiError::internal)?;
    if outcome == PutImage::Repaired {
        // Repair may have reopened claiming turns; wake strictly after the
        // bytes were restored (put_image returned).
        state.wake_conversation(project_id.clone(), conversation_id.clone());
    }
    let status = if outcome == PutImage::Created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((
        status,
        Json(PutImageResponse {
            image_id,
            created: outcome == PutImage::Created,
        }),
    ))
}

async fn image_content(
    State(state): State<AppState>,
    Path((project_id, conversation_id, image_id)): Path<(String, String, String)>,
) -> Result<Response, ApiError> {
    let records = state
        .store()
        .records(&project_id, &conversation_id)
        .map_err(ApiError::retry_lookup)?;
    let Some(event) = records
        .iter()
        .find(|record| record["kind"] == "image" && record["id"] == image_id)
    else {
        return Err(ApiError::not_found("image not found"));
    };
    let mime = event["mime"].as_str().unwrap_or("application/octet-stream");
    let Some(expected_sha256) = event["sha256"].as_str() else {
        return Err(ApiError::internal("image event has no SHA-256"));
    };
    let path = state
        .store()
        .image_path(&project_id, &conversation_id, &image_id)
        .map_err(ApiError::bad_request)?;
    // Hash-on-read: immutable cache headers are only ever attached to bytes
    // that verifiably match the journal. Damage heals via re-PUT repair.
    let damaged = || {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "image payload is missing or damaged; re-upload to repair",
        )
    };
    let bytes = tokio::fs::read(path).await.map_err(|_| damaged())?;
    if !hex_sha256(&bytes).eq_ignore_ascii_case(expected_sha256) {
        return Err(damaged());
    }
    Ok(Response::builder()
        .header(header::CONTENT_TYPE, mime)
        .header(header::ETAG, format!("\"{expected_sha256}\""))
        .header(header::CACHE_CONTROL, "private, max-age=31536000, immutable")
        .body(Body::from(bytes))
        .unwrap())
}

async fn retry_image(
    State(state): State<AppState>,
    Path((project_id, conversation_id, image_id)): Path<(String, String, String)>,
) -> Result<StatusCode, ApiError> {
    let found = state
        .retry_description(&project_id, &conversation_id, &image_id, "explicit_retry")
        .map_err(ApiError::retry_lookup)?;
    if found {
        Ok(StatusCode::ACCEPTED)
    } else {
        Err(ApiError::not_found("image not found"))
    }
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
        .reconcile_media(&project_id, &conversation_id)
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
    let (status, clips, images, created) = match outcome {
        CreateTurnOutcome::Created {
            record,
            clips,
            images,
        } => {
            state.publish_persisted(&project_id, &conversation_id, record);
            (StatusCode::ACCEPTED, clips, images, true)
        }
        CreateTurnOutcome::Existing { clips, images, .. } => {
            (StatusCode::OK, clips, images, false)
        }
    };
    // Scheduling an existing command is safe after a lost HTTP response, but
    // replaying the idempotent POST must never reopen terminal provider work.
    state.wake_conversation(project_id, conversation_id);
    Ok((
        status,
        Json(TurnResponse {
            turn_id: request.turn_id,
            clips,
            images: Some(images),
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

/// Optional trusted client hints: absent or unparsable values simply drop.
fn optional_numeric_header<T>(headers: &HeaderMap, name: &'static str) -> Option<T>
where
    T: std::str::FromStr,
{
    headers.get(name)?.to_str().ok()?.trim().parse().ok()
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
    use crate::agentic::CodexKnowledgeAgent;
    use crate::knowledge;
    use crate::{ai::Ai, store::Store};
    use axum::body::to_bytes;
    use axum::extract::Request;
    use axum::http::HeaderValue;
    use futures_util::StreamExt;
    use serde_json::json;
    use std::fs;
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

    /// The scripted ask-citation path: the wiki holds a compiled note whose
    /// `## Images` appendix anchors a description, the (fake) Codex agent
    /// cites the `#img-…` anchor, and the sanitized answer keeps the link.
    #[cfg(unix)]
    #[tokio::test]
    async fn knowledge_query_keeps_image_anchor_citations() {
        use std::os::unix::fs::PermissionsExt;

        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", Some("Board")).unwrap();
        for event in [
            json!({"kind":"image", "id":"img-1", "recorded_at":1000}),
            json!({"kind":"turn", "id":"turn-1", "images":["img-1"]}),
            json!({"kind":"description", "image":"img-1", "text":"Sticky notes grouped into three lanes"}),
            json!({"kind":"reply", "turn":"turn-1", "text":"Looks busy."}),
        ] {
            store
                .append_fixture("kibo", &conversation.id, event)
                .unwrap();
        }
        let document = knowledge::conversation_document(&store, "kibo", &conversation.id).unwrap();
        let (_, instructions_hash) = knowledge::instructions(&store, "kibo").unwrap();
        let receipt = knowledge::commit_ingestion(
            &store,
            "kibo",
            &document,
            &instructions_hash,
            "# Board\n\nA whiteboard conversation.",
        )
        .unwrap();
        let note =
            knowledge::read_markdown(&store, "kibo", &format!("wiki/{}", receipt.wiki_file))
                .unwrap();
        assert!(note.contains("<a id=\"img-img-1\"></a>"));
        assert!(note.contains("> Sticky notes grouped into three lanes"));

        let citation = format!("sources/conversation--{}.md#img-img-1", conversation.id);
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
printf '%s\n' '{{"method":"item/completed","params":{{"threadId":"thread-1","turnId":"turn-1","item":{{"type":"agentMessage","id":"answer-1","text":"The board holds sticky notes in three lanes; see [Whiteboard photo]({citation})."}}}}}}'
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
                r#"{"question":"What is on the whiteboard?"}"#.into(),
            ))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
        let events: Vec<Value> = std::str::from_utf8(&bytes)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let completed = events
            .iter()
            .find(|event| event["type"] == "completed")
            .unwrap();
        assert!(
            completed["html"]
                .as_str()
                .unwrap()
                .contains(&format!("href=\"{citation}\""))
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

    fn test_jpeg(payload: &[u8]) -> Vec<u8> {
        let mut bytes = vec![0xFF, 0xD8, 0xFF, 0xE0];
        bytes.extend_from_slice(payload);
        bytes
    }

    fn image_put_request(uri: &str, bytes: &[u8]) -> Request {
        Request::builder()
            .method("PUT")
            .uri(uri)
            .header("X-Content-Sha256", hex_sha256(bytes))
            .body(Body::from(bytes.to_vec()))
            .unwrap()
    }

    #[tokio::test]
    async fn image_upload_roundtrip_replay_and_conflict() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let service = router().with_state(AppState::new(store.clone(), Ai::mock()));
        let base = format!("/v1/projects/kibo/conversations/{}", conversation.id);
        let uri = format!("{base}/images/img-1?caption=my%20desk");
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);

        let created = service
            .clone()
            .oneshot(image_put_request(&uri, &bytes))
            .await
            .unwrap();
        assert_eq!(created.status(), StatusCode::CREATED);
        let body = to_bytes(created.into_body(), 1024).await.unwrap();
        let response: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(response["image_id"], "img-1");
        assert_eq!(response["created"], true);

        let replayed = service
            .clone()
            .oneshot(image_put_request(&uri, &bytes))
            .await
            .unwrap();
        assert_eq!(replayed.status(), StatusCode::OK);

        let conflicting = service
            .clone()
            .oneshot(image_put_request(
                &format!("{base}/images/img-1"),
                &test_jpeg(b"different pixels"),
            ))
            .await
            .unwrap();
        assert_eq!(conflicting.status(), StatusCode::CONFLICT);

        let fetched = service
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("{base}/images/img-1/content"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(fetched.status(), StatusCode::OK);
        assert_eq!(fetched.headers()[header::CONTENT_TYPE], "image/jpeg");
        assert_eq!(
            fetched.headers()[header::ETAG],
            format!("\"{sha}\"").as_str()
        );
        assert_eq!(
            fetched.headers()[header::CACHE_CONTROL],
            "private, max-age=31536000, immutable"
        );
        let served = to_bytes(fetched.into_body(), 1024 * 1024).await.unwrap();
        assert_eq!(&served[..], &bytes[..]);

        let missing = service
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("{base}/images/img-unknown/content"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(missing.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn image_content_verifies_bytes_on_every_read() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let service = router().with_state(AppState::new(store.clone(), Ai::mock()));
        let base = format!("/v1/projects/kibo/conversations/{}", conversation.id);
        let bytes = test_jpeg(b"pixels");
        assert_eq!(
            service
                .clone()
                .oneshot(image_put_request(&format!("{base}/images/img-1"), &bytes))
                .await
                .unwrap()
                .status(),
            StatusCode::CREATED
        );
        std::fs::write(
            store
                .image_path("kibo", &conversation.id, "img-1")
                .unwrap(),
            b"tampered",
        )
        .unwrap();

        let damaged = service
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("{base}/images/img-1/content"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        // Nothing cacheable leaves the server for corrupt bytes: 503, no ETag.
        assert_eq!(damaged.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert!(damaged.headers().get(header::ETAG).is_none());
    }

    #[tokio::test]
    async fn image_upload_validates_format_headers_caption_and_size() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let service = router().with_state(AppState::new(store.clone(), Ai::mock()));
        let base = format!("/v1/projects/kibo/conversations/{}", conversation.id);
        let bytes = test_jpeg(b"pixels");

        // HEIC (and anything unsniffable) is rejected at the door.
        let heic = service
            .clone()
            .oneshot(image_put_request(
                &format!("{base}/images/img-1"),
                b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00",
            ))
            .await
            .unwrap();
        assert_eq!(heic.status(), StatusCode::BAD_REQUEST);

        // A Content-Type header must agree with the sniffed bytes.
        let mismatched = service
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri(format!("{base}/images/img-1"))
                    .header("X-Content-Sha256", hex_sha256(&bytes))
                    .header(header::CONTENT_TYPE, "image/png")
                    .body(Body::from(bytes.clone()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(mismatched.status(), StatusCode::BAD_REQUEST);
        let agreeing = service
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri(format!("{base}/images/img-1"))
                    .header("X-Content-Sha256", hex_sha256(&bytes))
                    .header(header::CONTENT_TYPE, "image/jpeg")
                    .body(Body::from(bytes.clone()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(agreeing.status(), StatusCode::CREATED);

        // The sha header is required and verified.
        let missing_sha = service
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri(format!("{base}/images/img-2"))
                    .body(Body::from(bytes.clone()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(missing_sha.status(), StatusCode::BAD_REQUEST);
        let wrong_sha = service
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri(format!("{base}/images/img-2"))
                    .header("X-Content-Sha256", hex_sha256(b"other"))
                    .body(Body::from(bytes.clone()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(wrong_sha.status(), StatusCode::BAD_REQUEST);

        let invalid_id = service
            .clone()
            .oneshot(image_put_request(
                &format!("{base}/images/img%2F..%2Fescape"),
                &bytes,
            ))
            .await
            .unwrap();
        assert_eq!(invalid_id.status(), StatusCode::BAD_REQUEST);

        // Captions are bounded at 4 KiB after trim.
        let oversized_caption = format!(
            "{base}/images/img-3?caption={}",
            "a".repeat(4 * 1024 + 1)
        );
        let too_long = service
            .clone()
            .oneshot(image_put_request(&oversized_caption, &bytes))
            .await
            .unwrap();
        assert_eq!(too_long.status(), StatusCode::BAD_REQUEST);

        // The per-image route cap is 10 MiB.
        let oversized = test_jpeg(&vec![0u8; 10 * 1024 * 1024]);
        let too_big = service
            .clone()
            .oneshot(image_put_request(
                &format!("{base}/images/img-4"),
                &oversized,
            ))
            .await
            .unwrap();
        assert_eq!(too_big.status(), StatusCode::BAD_REQUEST);
    }

    /// Regression test for the decode_event strip-on-wire trap: every field
    /// the image and description events carry must survive `KiboEvent`.
    #[tokio::test]
    async fn events_preserve_image_and_description_fields_end_to_end() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let state = AppState::new(store.clone(), Ai::mock());
        let service = router().with_state(state.clone());
        let base = format!("/v1/projects/kibo/conversations/{}", conversation.id);
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);

        let uploaded = service
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri(format!("{base}/images/img-1?caption=the%20whiteboard"))
                    .header("X-Content-Sha256", &sha)
                    .header("X-Recorded-At", "41")
                    .header("X-Width", "3024")
                    .header("X-Height", "4032")
                    .body(Body::from(bytes.clone()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(uploaded.status(), StatusCode::CREATED);

        let turn = service
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("{base}/turns"))
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(json!({"turn_id": "turn-1"}).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(turn.status(), StatusCode::ACCEPTED);
        let turn_body = to_bytes(turn.into_body(), 1024).await.unwrap();
        let turn_response: Value = serde_json::from_slice(&turn_body).unwrap();
        assert_eq!(turn_response["images"], json!(["img-1"]));
        assert_eq!(turn_response["clips"], json!([]));

        store
            .append(
                "kibo",
                &conversation.id,
                crate::journal::JournalWrite::description_succeeded(
                    "img-1",
                    "a full whiteboard",
                    1,
                    "gemini-3.5-flash",
                    1,
                ),
            )
            .unwrap();

        let events = service
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("{base}/events"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(events.status(), StatusCode::OK);
        let body = to_bytes(events.into_body(), 1024 * 1024).await.unwrap();
        let envelope: Value = serde_json::from_slice(&body).unwrap();
        let events = envelope["events"].as_array().unwrap();

        let image = events
            .iter()
            .find(|event| event["kind"] == "image")
            .unwrap();
        assert_eq!(image["id"], "img-1");
        assert_eq!(image["file"], "images/img-1.jpg");
        assert_eq!(image["mime"], "image/jpeg");
        assert_eq!(image["sha256"], sha);
        assert_eq!(image["recorded_at"], 41);
        assert_eq!(image["width"], 3024);
        assert_eq!(image["height"], 4032);
        assert_eq!(image["caption"], "the whiteboard");

        let turn = events.iter().find(|event| event["kind"] == "turn").unwrap();
        assert_eq!(turn["images"], json!(["img-1"]));

        let description = events
            .iter()
            .find(|event| event["kind"] == "description")
            .unwrap();
        assert_eq!(description["image"], "img-1");
        assert_eq!(description["text"], "a full whiteboard");
        assert_eq!(description["attempt"], 1);
        assert_eq!(description["model"], "gemini-3.5-flash");
        assert_eq!(description["prompt_version"], 1);
    }

    /// The strict WS cursor must see every repair event: the batch is
    /// published in sequence order on the same broadcast the socket consumes.
    #[tokio::test]
    async fn image_repair_publishes_every_event_in_order() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let state = AppState::new(store.clone(), Ai::mock());
        let service = router().with_state(state.clone());
        let base = format!("/v1/projects/kibo/conversations/{}", conversation.id);
        let bytes = test_jpeg(b"pixels");
        assert_eq!(
            service
                .clone()
                .oneshot(image_put_request(&format!("{base}/images/img-1"), &bytes))
                .await
                .unwrap()
                .status(),
            StatusCode::CREATED
        );
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"turn", "id":"turn-1", "clips":[], "images":["img-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "stage":"reply", "error":"corrupt input"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"description_error", "image":"img-1", "attempt":1, "terminal":true, "error":"corrupt input"}),
            )
            .unwrap();
        std::fs::write(
            store
                .image_path("kibo", &conversation.id, "img-1")
                .unwrap(),
            b"damaged",
        )
        .unwrap();

        let mut receiver = state.subscribe("kibo", &conversation.id);
        let repaired = service
            .clone()
            .oneshot(image_put_request(&format!("{base}/images/img-1"), &bytes))
            .await
            .unwrap();
        assert_eq!(repaired.status(), StatusCode::OK);

        // The repair batch arrives first, in contiguous sequence order.
        let first = receiver.try_recv().unwrap();
        let second = receiver.try_recv().unwrap();
        assert_eq!(first["kind"], "reply_retry_requested");
        assert_eq!(first["reason"], "payload_repaired");
        assert_eq!(second["kind"], "description_retry_requested");
        assert_eq!(
            second["seq"].as_u64().unwrap(),
            first["seq"].as_u64().unwrap() + 1
        );
    }

    #[tokio::test]
    async fn image_repair_infrastructure_failure_is_5xx_and_restores_nothing() {
        // A failed repair batch is infrastructure, not client error: the
        // response must keep retry loops alive so re-entry can heal.
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let service = router().with_state(AppState::new(store.clone(), Ai::mock()));
        let base = format!("/v1/projects/kibo/conversations/{}", conversation.id);
        let bytes = test_jpeg(b"pixels");
        assert_eq!(
            service
                .clone()
                .oneshot(image_put_request(&format!("{base}/images/img-1"), &bytes))
                .await
                .unwrap()
                .status(),
            StatusCode::CREATED
        );
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"turn", "id":"turn-1", "clips":[], "images":["img-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "stage":"reply", "error":"corrupt input"}),
            )
            .unwrap();
        let path = store
            .image_path("kibo", &conversation.id, "img-1")
            .unwrap();
        std::fs::write(&path, b"damaged").unwrap();

        store.fail_append_after(0);
        let failed = service
            .clone()
            .oneshot(image_put_request(&format!("{base}/images/img-1"), &bytes))
            .await
            .unwrap();
        assert_eq!(failed.status(), StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(std::fs::read(&path).unwrap(), b"damaged");

        // The client retry loop re-enters repair and converges.
        let repaired = service
            .clone()
            .oneshot(image_put_request(&format!("{base}/images/img-1"), &bytes))
            .await
            .unwrap();
        assert_eq!(repaired.status(), StatusCode::OK);
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }

    #[tokio::test]
    async fn image_retry_route_reopens_terminal_descriptions() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let service = router().with_state(AppState::new(store.clone(), Ai::mock()));
        let base = format!("/v1/projects/kibo/conversations/{}", conversation.id);

        let missing = service
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("{base}/images/img-unknown/retry"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(missing.status(), StatusCode::NOT_FOUND);

        let bytes = test_jpeg(b"pixels");
        assert_eq!(
            service
                .clone()
                .oneshot(image_put_request(&format!("{base}/images/img-1"), &bytes))
                .await
                .unwrap()
                .status(),
            StatusCode::CREATED
        );
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"description_error", "image":"img-1", "attempt":3, "terminal":true, "error":"blocked"}),
            )
            .unwrap();
        let accepted = service
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("{base}/images/img-1/retry"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(accepted.status(), StatusCode::ACCEPTED);
        assert!(
            store
                .records("kibo", &conversation.id)
                .unwrap()
                .iter()
                .any(|event| event["kind"] == "description_retry_requested"
                    && event["reason"] == "explicit_retry")
        );
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

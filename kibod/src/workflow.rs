use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureStage {
    Transcription,
    Reply,
    Speech,
}

impl FailureStage {
    fn parse(value: Option<&str>, default: Self) -> Self {
        match value {
            Some("transcription") => Self::Transcription,
            Some("speech") => Self::Speech,
            Some("reply") => Self::Reply,
            _ => default,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkFailure {
    pub attempt: u32,
    pub error: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReplyFailure {
    Transcription(WorkFailure),
    Generation(WorkFailure),
}

impl ReplyFailure {
    pub fn error(&self) -> &str {
        match self {
            Self::Transcription(failure) | Self::Generation(failure) => &failure.error,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttemptState<T, F = WorkFailure> {
    Due {
        next_attempt: u32,
    },
    Attempting {
        attempt: u32,
    },
    RetryScheduled {
        next_attempt: u32,
        retry_at_ms: u64,
        error: String,
    },
    Succeeded(T),
    TerminalFailure(F),
}

impl<T, F> AttemptState<T, F> {
    pub(crate) fn scheduled_work(&self) -> Option<(u32, u64)> {
        match self {
            Self::Due { next_attempt } => Some((*next_attempt, 0)),
            Self::RetryScheduled {
                next_attempt,
                retry_at_ms,
                ..
            } => Some((*next_attempt, *retry_at_ms)),
            Self::Attempting { .. } | Self::Succeeded(_) | Self::TerminalFailure(_) => None,
        }
    }

    fn is_attempting(&self) -> bool {
        matches!(self, Self::Attempting { .. })
    }
}

pub type TranscriptState = AttemptState<String>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplyRecord {
    pub text: String,
    pub audio: Option<String>,
    pub interaction_id: Option<String>,
    pub speech_generation: Option<String>,
    pub history_through_seq: Option<u64>,
}

pub type ReplyState = AttemptState<ReplyRecord, ReplyFailure>;
pub type SpeechState = AttemptState<()>;
pub type DescriptionState = AttemptState<DescriptionRecord>;

/// The durable text projection of an image, produced once by the AI layer.
/// First success is authoritative, exactly like transcripts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DescriptionRecord {
    pub text: String,
    pub model: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClipWork {
    pub id: String,
    pub peak: Option<u64>,
    pub sha256: Option<String>,
    pub recorded_at: u64,
    pub seq: u64,
    pub transcript: TranscriptState,
}

/// An image is a blob commitment plus values; its only attempt state is the
/// advisory description, which never gates turn readiness.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageWork {
    pub id: String,
    pub file: String,
    pub mime: String,
    pub sha256: Option<String>,
    pub recorded_at: u64,
    pub seq: u64,
    pub width: Option<u64>,
    pub height: Option<u64>,
    pub caption: Option<String>,
    pub description: DescriptionState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptionWork {
    pub clip_id: String,
    pub next_attempt: u32,
    pub retry_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DescriptionWork {
    pub image_id: String,
    pub next_attempt: u32,
    pub retry_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryImage {
    pub id: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectedHistoryTurn {
    pub user: String,
    pub assistant: String,
    pub images: Vec<HistoryImage>,
}

/// One ordered projection of a claimed turn's media for every consumer:
/// prompt construction, history fallback, knowledge, and UIs all render the
/// same `(recorded_at, seq)` merge of clips and images.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TurnContent {
    pub items: Vec<TurnMedia>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TurnMedia {
    Transcript { clip: String, text: String },
    Image(TurnImage),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnImage {
    pub id: String,
    pub file: String,
    pub mime: String,
    pub sha256: Option<String>,
    pub caption: Option<String>,
    pub description: Option<String>,
}

impl TurnContent {
    /// Caption uniformity rule: a caption is user text and appears exactly
    /// once, at its media position. Image reference lines rendered elsewhere
    /// carry the description or a bare id — never the caption.
    pub fn user_text(&self) -> String {
        self.items
            .iter()
            .filter_map(|item| match item {
                TurnMedia::Transcript { text, .. } => {
                    meaningful_user_text(text).then(|| text.clone())
                }
                TurnMedia::Image(image) => image
                    .caption
                    .as_deref()
                    .map(str::trim)
                    .filter(|caption| !caption.is_empty())
                    .map(str::to_string),
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn images(&self) -> Vec<&TurnImage> {
        self.items
            .iter()
            .filter_map(|item| match item {
                TurnMedia::Image(image) => Some(image),
                TurnMedia::Transcript { .. } => None,
            })
            .collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryContext {
    pub turns: Vec<ProjectedHistoryTurn>,
    pub previous_interaction_id: Option<String>,
    pub through_seq: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TurnInput {
    Awaiting,
    Ready(String),
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnWork {
    pub id: String,
    pub clips: Vec<String>,
    pub images: Vec<String>,
    pub input: TurnInput,
    pub reply: ReplyState,
    /// `None` means the durable reply does not advertise speech.
    pub speech: Option<SpeechState>,
    /// Opaque identity of the current synthesis. Transport clients use this
    /// to distinguish a reconnect from a brand-new provider attempt.
    pub speech_generation: Option<String>,
    /// One-based count of accepted synthesis generations for this reply.
    /// Legacy audio is conservatively reserved at generation two because its
    /// old journal cannot prove that no earlier prefix was streamed.
    pub speech_generation_index: u32,
}

/// The single authority for "does this user text carry content": trimmed, so
/// a padded sentinel cannot slip past one consumer and not another.
pub(crate) fn meaningful_user_text(text: &str) -> bool {
    !matches!(text.trim(), "" | "[silent]" | "[no speech]")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TurnAction {
    AwaitingEvent,
    WaitUntil { deadline_ms: u64 },
    RecordTranscriptFailure { error: String },
    GenerateReply { attempt: u32 },
    GenerateSpeech { attempt: u32, reply: ReplyRecord },
    Complete,
}

impl TurnWork {
    pub fn action(&self, now_ms: u64) -> TurnAction {
        match &self.reply {
            ReplyState::Succeeded(_) => return self.speech_action(now_ms),
            ReplyState::TerminalFailure(ReplyFailure::Generation(_)) => {
                return TurnAction::Complete;
            }
            _ => {}
        }
        if let TurnInput::Failed(error) = &self.input {
            return match &self.reply {
                ReplyState::TerminalFailure(ReplyFailure::Transcription(_)) => TurnAction::Complete,
                _ => TurnAction::RecordTranscriptFailure {
                    error: error.clone(),
                },
            };
        }
        match &self.input {
            TurnInput::Ready(_) => {}
            TurnInput::Awaiting => return TurnAction::AwaitingEvent,
            TurnInput::Failed(_) => unreachable!("failed input returned above"),
        }
        match &self.reply {
            ReplyState::Due { next_attempt } => TurnAction::GenerateReply {
                attempt: *next_attempt,
            },
            ReplyState::RetryScheduled {
                next_attempt,
                retry_at_ms,
                ..
            } if *retry_at_ms <= now_ms => TurnAction::GenerateReply {
                attempt: *next_attempt,
            },
            ReplyState::RetryScheduled { retry_at_ms, .. } => TurnAction::WaitUntil {
                deadline_ms: *retry_at_ms,
            },
            ReplyState::Attempting { .. } => TurnAction::AwaitingEvent,
            ReplyState::TerminalFailure(_) => TurnAction::Complete,
            ReplyState::Succeeded(_) => unreachable!("successful replies returned above"),
        }
    }

    fn speech_action(&self, now_ms: u64) -> TurnAction {
        let ReplyState::Succeeded(reply) = &self.reply else {
            return TurnAction::Complete;
        };
        match &self.speech {
            None | Some(SpeechState::Succeeded(())) | Some(SpeechState::TerminalFailure(_)) => {
                TurnAction::Complete
            }
            Some(SpeechState::Due { next_attempt }) => TurnAction::GenerateSpeech {
                attempt: *next_attempt,
                reply: reply.clone(),
            },
            Some(SpeechState::RetryScheduled {
                next_attempt,
                retry_at_ms,
                ..
            }) if *retry_at_ms <= now_ms => TurnAction::GenerateSpeech {
                attempt: *next_attempt,
                reply: reply.clone(),
            },
            Some(SpeechState::RetryScheduled { retry_at_ms, .. }) => TurnAction::WaitUntil {
                deadline_ms: *retry_at_ms,
            },
            Some(SpeechState::Attempting { .. }) => TurnAction::AwaitingEvent,
        }
    }
}

#[derive(Debug, Clone)]
enum JournalEvent {
    Clip {
        id: String,
        peak: Option<u64>,
        sha256: Option<String>,
        recorded_at: u64,
    },
    Image {
        id: String,
        file: String,
        mime: String,
        sha256: Option<String>,
        recorded_at: u64,
        width: Option<u64>,
        height: Option<u64>,
        caption: Option<String>,
    },
    DescriptionStarted {
        image: String,
        attempt: u32,
    },
    DescriptionRetryRequested {
        image: String,
    },
    DescriptionError {
        image: String,
        attempt: Option<u32>,
        retry_at_ms: u64,
        terminal: bool,
        error: String,
    },
    Description {
        image: String,
        text: String,
        model: Option<String>,
    },
    TranscriptStarted {
        clip: String,
        attempt: u32,
    },
    TranscriptRetryRequested {
        clip: String,
    },
    TranscriptError {
        clip: String,
        attempt: Option<u32>,
        retry_at_ms: u64,
        terminal: bool,
        error: String,
    },
    Transcript {
        clip: String,
        text: String,
    },
    Turn {
        id: String,
        clips: Vec<String>,
        images: Vec<String>,
    },
    ReplyStarted {
        turn: String,
        attempt: u32,
    },
    ReplyRetryRequested {
        turn: String,
    },
    ReplyError {
        turn: String,
        attempt: Option<u32>,
        retry_at_ms: u64,
        terminal: bool,
        stage: FailureStage,
        error: String,
    },
    Reply {
        turn: String,
        reply: ReplyRecord,
    },
    SpeechStarted {
        turn: String,
        attempt: u32,
        generation: Option<String>,
    },
    SpeechRetryRequested {
        turn: String,
    },
    TtsError {
        turn: String,
        attempt: Option<u32>,
        retry_at_ms: u64,
        terminal: bool,
        error: String,
    },
    SpeechReady {
        turn: String,
    },
    Unknown,
}

impl JournalEvent {
    fn parse(value: &Value) -> Self {
        let string = |field: &str| value[field].as_str().map(str::to_string);
        let attempt = || {
            value["attempt"]
                .as_u64()
                .and_then(|number| u32::try_from(number).ok())
                .filter(|number| *number > 0)
        };
        let retry_at_ms = || {
            value["retry_at_ms"].as_u64().unwrap_or_else(|| {
                value["retry_at"]
                    .as_u64()
                    .unwrap_or(0)
                    .saturating_mul(1_000)
            })
        };
        let kind = value["kind"].as_str();
        let has_retry_deadline =
            value.get("retry_at_ms").is_some() || value.get("retry_at").is_some();
        if value["terminal"].as_bool() == Some(true) && has_retry_deadline {
            return Self::Unknown;
        }
        if matches!(
            kind,
            Some("transcript_retry_scheduled" | "reply_retry_scheduled" | "speech_retry_scheduled")
        ) && value.get("terminal").is_some()
        {
            return Self::Unknown;
        }
        let string_list = |field: &str| {
            value[field]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect::<Vec<_>>()
        };
        match kind {
            Some("clip") => match string("id") {
                Some(id) => Self::Clip {
                    id,
                    peak: value["peak"].as_u64(),
                    sha256: string("sha256"),
                    recorded_at: value["recorded_at"].as_u64().unwrap_or(0),
                },
                None => Self::Unknown,
            },
            Some("image") => match string("id") {
                Some(id) => Self::Image {
                    file: string("file").unwrap_or_else(|| format!("images/{id}.jpg")),
                    mime: string("mime").unwrap_or_else(|| "image/jpeg".into()),
                    sha256: string("sha256"),
                    recorded_at: value["recorded_at"].as_u64().unwrap_or(0),
                    width: value["width"].as_u64(),
                    height: value["height"].as_u64(),
                    caption: string("caption"),
                    id,
                },
                None => Self::Unknown,
            },
            Some("description_started") => match (string("image"), attempt()) {
                (Some(image), Some(attempt)) => Self::DescriptionStarted { image, attempt },
                _ => Self::Unknown,
            },
            Some("description_retry_requested") => string("image")
                .map(|image| Self::DescriptionRetryRequested { image })
                .unwrap_or(Self::Unknown),
            Some("description_error") => match string("image") {
                Some(image) => Self::DescriptionError {
                    image,
                    attempt: attempt(),
                    retry_at_ms: retry_at_ms(),
                    terminal: value["terminal"].as_bool().unwrap_or(false),
                    error: string("error").unwrap_or_else(|| "description failed".into()),
                },
                None => Self::Unknown,
            },
            Some("description_retry_scheduled") => match string("image") {
                Some(image) => Self::DescriptionError {
                    image,
                    attempt: attempt(),
                    retry_at_ms: retry_at_ms(),
                    terminal: false,
                    error: string("error").unwrap_or_else(|| "description failed".into()),
                },
                None => Self::Unknown,
            },
            Some("description") => match (string("image"), string("text")) {
                (Some(image), Some(text)) => Self::Description {
                    image,
                    text,
                    model: string("model"),
                },
                _ => Self::Unknown,
            },
            Some("transcript_started") => match (string("clip"), attempt()) {
                (Some(clip), Some(attempt)) => Self::TranscriptStarted { clip, attempt },
                _ => Self::Unknown,
            },
            Some("transcript_retry_requested") => string("clip")
                .map(|clip| Self::TranscriptRetryRequested { clip })
                .unwrap_or(Self::Unknown),
            Some("transcript_error") => match string("clip") {
                Some(clip) => Self::TranscriptError {
                    clip,
                    attempt: attempt(),
                    retry_at_ms: retry_at_ms(),
                    // Legacy errors were retryable on restart.
                    terminal: value["terminal"].as_bool().unwrap_or(false),
                    error: string("error").unwrap_or_else(|| "transcription failed".into()),
                },
                None => Self::Unknown,
            },
            Some("transcript_retry_scheduled") => match string("clip") {
                Some(clip) => Self::TranscriptError {
                    clip,
                    attempt: attempt(),
                    retry_at_ms: retry_at_ms(),
                    terminal: false,
                    error: string("error").unwrap_or_else(|| "transcription failed".into()),
                },
                None => Self::Unknown,
            },
            Some("transcript") => match (string("clip"), string("text")) {
                (Some(clip), Some(text)) => Self::Transcript { clip, text },
                _ => Self::Unknown,
            },
            Some("turn") => match string("id") {
                Some(id) => Self::Turn {
                    id,
                    clips: string_list("clips"),
                    // Absent on every legacy turn: audio-only journals parse
                    // identically to how they always have.
                    images: string_list("images"),
                },
                None => Self::Unknown,
            },
            Some("reply_started") => match (string("turn"), attempt()) {
                (Some(turn), Some(attempt)) => Self::ReplyStarted { turn, attempt },
                _ => Self::Unknown,
            },
            Some("reply_retry_requested") => string("turn")
                .map(|turn| Self::ReplyRetryRequested { turn })
                .unwrap_or(Self::Unknown),
            Some("reply_error") => match string("turn") {
                Some(turn) => Self::ReplyError {
                    turn,
                    attempt: attempt(),
                    retry_at_ms: retry_at_ms(),
                    // Legacy reply failures were retried by the old worker.
                    terminal: value["terminal"].as_bool().unwrap_or(false),
                    stage: FailureStage::parse(value["stage"].as_str(), FailureStage::Reply),
                    error: string("error").unwrap_or_else(|| "reply failed".into()),
                },
                None => Self::Unknown,
            },
            Some("reply_retry_scheduled") => match string("turn") {
                Some(turn) => Self::ReplyError {
                    turn,
                    attempt: attempt(),
                    retry_at_ms: retry_at_ms(),
                    terminal: false,
                    stage: FailureStage::Reply,
                    error: string("error").unwrap_or_else(|| "reply failed".into()),
                },
                None => Self::Unknown,
            },
            Some("reply") => match string("turn") {
                Some(turn) => Self::Reply {
                    turn,
                    reply: ReplyRecord {
                        text: string("text").unwrap_or_default(),
                        audio: string("audio"),
                        interaction_id: string("interaction_id"),
                        speech_generation: string("speech_generation"),
                        history_through_seq: value["history_through_seq"].as_u64(),
                    },
                },
                None => Self::Unknown,
            },
            Some("speech_started") => match (string("turn"), attempt()) {
                (Some(turn), Some(attempt)) => Self::SpeechStarted {
                    turn,
                    attempt,
                    generation: string("generation"),
                },
                _ => Self::Unknown,
            },
            Some("speech_retry_requested") => string("turn")
                .map(|turn| Self::SpeechRetryRequested { turn })
                .unwrap_or(Self::Unknown),
            Some("tts_error") => match string("turn") {
                Some(turn) => Self::TtsError {
                    turn,
                    attempt: attempt(),
                    retry_at_ms: retry_at_ms(),
                    // Legacy speech failures were retried on server restart.
                    terminal: value["terminal"].as_bool().unwrap_or(false),
                    error: string("error").unwrap_or_else(|| "speech synthesis failed".into()),
                },
                None => Self::Unknown,
            },
            Some("speech_retry_scheduled") => match string("turn") {
                Some(turn) => Self::TtsError {
                    turn,
                    attempt: attempt(),
                    retry_at_ms: retry_at_ms(),
                    terminal: false,
                    error: string("error").unwrap_or_else(|| "speech synthesis failed".into()),
                },
                None => Self::Unknown,
            },
            Some("speech_ready") => string("turn")
                .map(|turn| Self::SpeechReady { turn })
                .unwrap_or(Self::Unknown),
            _ => Self::Unknown,
        }
    }
}

#[derive(Debug, Clone)]
struct MutableTurn {
    id: String,
    clips: Vec<String>,
    images: Vec<String>,
    reply: ReplyState,
    speech: Option<SpeechState>,
    speech_generation: Option<String>,
    speech_generation_index: u32,
}

/// Canonical, typed interpretation of the append-only conversation journal.
#[derive(Debug, Clone, Default)]
pub struct ConversationWorkflow {
    clip_order: Vec<String>,
    clips: HashMap<String, ClipWork>,
    image_order: Vec<String>,
    images: HashMap<String, ImageWork>,
    turns: Vec<TurnWork>,
    reply_event_sequence: HashMap<String, u64>,
}

impl ConversationWorkflow {
    pub fn from_records(records: &[Value]) -> Self {
        let mut clip_order = Vec::new();
        let mut clips = HashMap::<String, ClipWork>::new();
        let mut image_order = Vec::new();
        let mut images = HashMap::<String, ImageWork>::new();
        let mut turn_order = Vec::new();
        let mut turns = HashMap::<String, MutableTurn>::new();
        let mut reply_event_sequence = HashMap::new();

        for (event_index, record) in records.iter().enumerate() {
            let event = JournalEvent::parse(record);
            let event_sequence = record["seq"]
                .as_u64()
                .unwrap_or_else(|| (event_index as u64).saturating_add(1));
            match event {
                JournalEvent::Clip {
                    id,
                    peak,
                    sha256,
                    recorded_at,
                } => {
                    if !clips.contains_key(&id) {
                        clip_order.push(id.clone());
                        clips.insert(
                            id.clone(),
                            ClipWork {
                                id,
                                peak,
                                sha256,
                                recorded_at,
                                seq: event_sequence,
                                transcript: TranscriptState::Due { next_attempt: 1 },
                            },
                        );
                    }
                }
                JournalEvent::Image {
                    id,
                    file,
                    mime,
                    sha256,
                    recorded_at,
                    width,
                    height,
                    caption,
                } => {
                    if !images.contains_key(&id) {
                        image_order.push(id.clone());
                        images.insert(
                            id.clone(),
                            ImageWork {
                                id,
                                file,
                                mime,
                                sha256,
                                recorded_at,
                                seq: event_sequence,
                                width,
                                height,
                                caption,
                                description: DescriptionState::Due { next_attempt: 1 },
                            },
                        );
                    }
                }
                JournalEvent::DescriptionStarted { image, attempt } => {
                    if let Some(work) = images.get_mut(&image)
                        && !matches!(
                            work.description,
                            DescriptionState::Succeeded(_) | DescriptionState::TerminalFailure(_)
                        )
                    {
                        work.description = DescriptionState::Attempting { attempt };
                    }
                }
                JournalEvent::DescriptionRetryRequested { image } => {
                    // Descriptions are advisory values: reopening one never
                    // touches reply state, so there is no cascade here.
                    if let Some(work) = images.get_mut(&image)
                        && !matches!(work.description, DescriptionState::Succeeded(_))
                    {
                        work.description = DescriptionState::Due { next_attempt: 1 };
                    }
                }
                JournalEvent::DescriptionError {
                    image,
                    attempt,
                    retry_at_ms,
                    terminal,
                    error,
                } => {
                    if let Some(work) = images.get_mut(&image)
                        && !matches!(
                            work.description,
                            DescriptionState::Succeeded(_) | DescriptionState::TerminalFailure(_)
                        )
                    {
                        apply_error(
                            &mut work.description,
                            attempt,
                            retry_at_ms,
                            terminal,
                            error,
                            std::convert::identity,
                        );
                    }
                }
                JournalEvent::Description { image, text, model } => {
                    if let Some(work) = images.get_mut(&image)
                        && !matches!(
                            work.description,
                            DescriptionState::Succeeded(_) | DescriptionState::TerminalFailure(_)
                        )
                    {
                        work.description =
                            DescriptionState::Succeeded(DescriptionRecord { text, model });
                    }
                }
                JournalEvent::TranscriptStarted { clip, attempt } => {
                    if let Some(work) = clips.get_mut(&clip)
                        && !matches!(
                            work.transcript,
                            TranscriptState::Succeeded(_) | TranscriptState::TerminalFailure(_)
                        )
                    {
                        work.transcript = TranscriptState::Attempting { attempt };
                    }
                }
                JournalEvent::TranscriptRetryRequested { clip } => {
                    if let Some(work) = clips.get_mut(&clip)
                        && !matches!(work.transcript, TranscriptState::Succeeded(_))
                    {
                        work.transcript = TranscriptState::Due { next_attempt: 1 };
                        // This explicit retry also reopens any reply that was
                        // closed only because this prerequisite failed. If the
                        // new transcription attempt fails terminally, the turn
                        // worker must publish a fresh reply_error so clients
                        // that observed the retry can leave their pending state.
                        for turn in turns.values_mut() {
                            if turn.clips.contains(&clip)
                                && matches!(
                                    turn.reply,
                                    ReplyState::TerminalFailure(ReplyFailure::Transcription(_))
                                )
                            {
                                turn.reply = ReplyState::Due { next_attempt: 1 };
                            }
                        }
                    }
                }
                JournalEvent::TranscriptError {
                    clip,
                    attempt,
                    retry_at_ms,
                    terminal,
                    error,
                } => {
                    if let Some(work) = clips.get_mut(&clip)
                        && !matches!(
                            work.transcript,
                            TranscriptState::Succeeded(_) | TranscriptState::TerminalFailure(_)
                        )
                    {
                        apply_error(
                            &mut work.transcript,
                            attempt,
                            retry_at_ms,
                            terminal,
                            error,
                            std::convert::identity,
                        );
                    }
                }
                JournalEvent::Transcript { clip, text } => {
                    let accepted = if let Some(work) = clips.get_mut(&clip)
                        && !matches!(
                            work.transcript,
                            TranscriptState::Succeeded(_) | TranscriptState::TerminalFailure(_)
                        ) {
                        work.transcript = TranscriptState::Succeeded(text);
                        true
                    } else {
                        false
                    };
                    if accepted {
                        for turn in turns.values_mut() {
                            let failed_on_transcription = matches!(
                                turn.reply,
                                ReplyState::TerminalFailure(ReplyFailure::Transcription(_))
                            );
                            let all_transcripts_ready = turn.clips.iter().all(|clip_id| {
                                matches!(
                                    clips.get(clip_id).map(|clip| &clip.transcript),
                                    Some(TranscriptState::Succeeded(_))
                                )
                            });
                            if failed_on_transcription && all_transcripts_ready {
                                turn.reply = ReplyState::Due { next_attempt: 1 };
                            }
                        }
                    }
                }
                JournalEvent::Turn {
                    id,
                    clips: turn_clips,
                    images: turn_images,
                } => {
                    if !turns.contains_key(&id) {
                        turn_order.push(id.clone());
                        turns.insert(
                            id.clone(),
                            MutableTurn {
                                id,
                                clips: turn_clips,
                                images: turn_images,
                                reply: ReplyState::Due { next_attempt: 1 },
                                speech: None,
                                speech_generation: None,
                                speech_generation_index: 0,
                            },
                        );
                    }
                }
                JournalEvent::ReplyStarted { turn, attempt } => {
                    if let Some(work) = turns.get_mut(&turn)
                        && !matches!(
                            work.reply,
                            ReplyState::Succeeded(_) | ReplyState::TerminalFailure(_)
                        )
                    {
                        work.reply = ReplyState::Attempting { attempt };
                    }
                }
                JournalEvent::ReplyRetryRequested { turn } => {
                    if let Some(work) = turns.get_mut(&turn)
                        && !matches!(work.reply, ReplyState::Succeeded(_))
                    {
                        work.reply = ReplyState::Due { next_attempt: 1 };
                    }
                }
                JournalEvent::ReplyError {
                    turn,
                    attempt,
                    retry_at_ms,
                    terminal,
                    stage,
                    error,
                } => {
                    let Some(work) = turns.get_mut(&turn) else {
                        continue;
                    };
                    if stage == FailureStage::Speech {
                        if let Some(speech) = &mut work.speech
                            && !matches!(
                                speech,
                                SpeechState::Succeeded(()) | SpeechState::TerminalFailure(_)
                            )
                        {
                            apply_error(
                                speech,
                                attempt,
                                retry_at_ms,
                                terminal,
                                error,
                                std::convert::identity,
                            );
                        }
                    } else if !matches!(
                        work.reply,
                        ReplyState::Succeeded(_) | ReplyState::TerminalFailure(_)
                    ) {
                        apply_error(
                            &mut work.reply,
                            attempt,
                            retry_at_ms,
                            terminal,
                            error,
                            match stage {
                                FailureStage::Transcription => ReplyFailure::Transcription,
                                FailureStage::Reply => ReplyFailure::Generation,
                                FailureStage::Speech => unreachable!("speech handled above"),
                            },
                        );
                    }
                }
                JournalEvent::Reply { turn, reply } => {
                    if let Some(work) = turns.get_mut(&turn)
                        && !matches!(
                            work.reply,
                            ReplyState::Succeeded(_) | ReplyState::TerminalFailure(_)
                        )
                    {
                        // The durable audio field is the sole wire-level
                        // authority for whether clients should expect speech.
                        // Sentinel replies intentionally omit it at the writer.
                        let needs_speech = reply.audio.is_some();
                        let initial_generation = reply.speech_generation.clone();
                        let generation_index = match (needs_speech, initial_generation.is_some()) {
                            (true, true) => 1,
                            // Old servers did not record synthesis attempts. A
                            // legacy WAV may already be a post-crash retry, so
                            // conservatively reserve generation two and adopt
                            // its bytes under a non-legacy token at read time.
                            (true, false) => 2,
                            (false, _) => 0,
                        };
                        work.reply = ReplyState::Succeeded(reply);
                        work.speech = needs_speech.then_some(SpeechState::Due { next_attempt: 1 });
                        work.speech_generation = initial_generation;
                        work.speech_generation_index = generation_index;
                        reply_event_sequence.insert(turn, event_sequence);
                    }
                }
                JournalEvent::SpeechStarted {
                    turn,
                    attempt,
                    generation,
                } => {
                    if let Some(work) = turns.get_mut(&turn)
                        && let Some(speech) = &mut work.speech
                        && !matches!(
                            speech,
                            SpeechState::Succeeded(()) | SpeechState::TerminalFailure(_)
                        )
                    {
                        *speech = SpeechState::Attempting { attempt };
                        if generation.is_none() || work.speech_generation != generation {
                            work.speech_generation_index =
                                work.speech_generation_index.saturating_add(1);
                            work.speech_generation = generation;
                        }
                    }
                }
                JournalEvent::SpeechRetryRequested { turn } => {
                    if let Some(work) = turns.get_mut(&turn)
                        && matches!(
                            &work.reply,
                            ReplyState::Succeeded(ReplyRecord { audio: Some(_), .. })
                        )
                        && work.speech.is_some()
                    {
                        work.speech = Some(SpeechState::Due { next_attempt: 1 });
                        work.speech_generation = None;
                    }
                }
                JournalEvent::TtsError {
                    turn,
                    attempt,
                    retry_at_ms,
                    terminal,
                    error,
                } => {
                    if let Some(Some(speech)) = turns.get_mut(&turn).map(|work| &mut work.speech)
                        && !matches!(
                            speech,
                            SpeechState::Succeeded(()) | SpeechState::TerminalFailure(_)
                        )
                    {
                        apply_error(
                            speech,
                            attempt,
                            retry_at_ms,
                            terminal,
                            error,
                            std::convert::identity,
                        );
                    }
                }
                JournalEvent::SpeechReady { turn } => {
                    if let Some(work) = turns.get_mut(&turn)
                        && work.speech.as_ref().is_some_and(|speech| {
                            !matches!(
                                speech,
                                SpeechState::Succeeded(()) | SpeechState::TerminalFailure(_)
                            )
                        })
                    {
                        work.speech = Some(SpeechState::Succeeded(()));
                    }
                }
                JournalEvent::Unknown => {}
            }
        }

        let turns = turn_order
            .into_iter()
            .filter_map(|id| turns.remove(&id))
            .map(|turn| project_turn(turn, &clips))
            .collect();
        Self {
            clip_order,
            clips,
            image_order,
            images,
            turns,
            reply_event_sequence,
        }
    }

    pub fn clip(&self, clip_id: &str) -> Option<&ClipWork> {
        self.clips.get(clip_id)
    }

    pub fn image(&self, image_id: &str) -> Option<&ImageWork> {
        self.images.get(image_id)
    }

    pub fn turn(&self, turn_id: &str) -> Option<&TurnWork> {
        self.turns.iter().find(|turn| turn.id == turn_id)
    }

    pub fn turns(&self) -> &[TurnWork] {
        &self.turns
    }

    pub fn transcription_work(&self) -> Vec<TranscriptionWork> {
        self.clip_order
            .iter()
            .filter_map(|clip_id| {
                let (next_attempt, retry_at_ms) =
                    self.clips.get(clip_id)?.transcript.scheduled_work()?;
                Some(TranscriptionWork {
                    clip_id: clip_id.clone(),
                    next_attempt,
                    retry_at_ms,
                })
            })
            .collect()
    }

    pub fn interrupted_transcriptions(&self) -> Vec<String> {
        self.clip_order
            .iter()
            .filter(|clip_id| {
                self.clips
                    .get(*clip_id)
                    .is_some_and(|clip| clip.transcript.is_attempting())
            })
            .cloned()
            .collect()
    }

    pub fn description_work(&self) -> Vec<DescriptionWork> {
        self.image_order
            .iter()
            .filter_map(|image_id| {
                let (next_attempt, retry_at_ms) =
                    self.images.get(image_id)?.description.scheduled_work()?;
                Some(DescriptionWork {
                    image_id: image_id.clone(),
                    next_attempt,
                    retry_at_ms,
                })
            })
            .collect()
    }

    pub fn interrupted_descriptions(&self) -> Vec<String> {
        self.image_order
            .iter()
            .filter(|image_id| {
                self.images
                    .get(*image_id)
                    .is_some_and(|image| image.description.is_attempting())
            })
            .cloned()
            .collect()
    }

    /// Project one turn's claimed media as a single ordered list, merged by
    /// `(recorded_at, seq)` across clips and images. Only settled values are
    /// included: successful transcripts and durable image records.
    pub fn turn_content(&self, turn_id: &str) -> Option<TurnContent> {
        let turn = self.turn(turn_id)?;
        let mut ordered: Vec<(u64, u64, TurnMedia)> = Vec::new();
        for clip_id in &turn.clips {
            let Some(clip) = self.clips.get(clip_id) else {
                continue;
            };
            if let TranscriptState::Succeeded(text) = &clip.transcript {
                ordered.push((
                    clip.recorded_at,
                    clip.seq,
                    TurnMedia::Transcript {
                        clip: clip_id.clone(),
                        text: text.clone(),
                    },
                ));
            }
        }
        for image_id in &turn.images {
            let Some(image) = self.images.get(image_id) else {
                continue;
            };
            let description = match &image.description {
                DescriptionState::Succeeded(record) => Some(record.text.clone()),
                _ => None,
            };
            ordered.push((
                image.recorded_at,
                image.seq,
                TurnMedia::Image(TurnImage {
                    id: image.id.clone(),
                    file: image.file.clone(),
                    mime: image.mime.clone(),
                    sha256: image.sha256.clone(),
                    caption: image.caption.clone(),
                    description,
                }),
            ));
        }
        ordered.sort_by_key(|(recorded_at, seq, _)| (*recorded_at, *seq));
        Some(TurnContent {
            items: ordered.into_iter().map(|(_, _, item)| item).collect(),
        })
    }

    pub fn interrupted_turn_stages(&self) -> Vec<(String, FailureStage)> {
        let mut interrupted = Vec::new();
        for turn in &self.turns {
            if turn.reply.is_attempting() {
                interrupted.push((turn.id.clone(), FailureStage::Reply));
            }
            if turn
                .speech
                .as_ref()
                .is_some_and(AttemptState::is_attempting)
            {
                interrupted.push((turn.id.clone(), FailureStage::Speech));
            }
        }
        interrupted
    }

    pub fn next_turn_action(&self, now_ms: u64) -> Option<(String, TurnAction)> {
        self.turns.iter().find_map(|turn| {
            let action = turn.action(now_ms);
            (!matches!(action, TurnAction::Complete)).then(|| (turn.id.clone(), action))
        })
    }

    pub fn has_runnable_turn(&self, now_ms: u64) -> bool {
        self.next_turn_action(now_ms).is_some_and(|(_, action)| {
            !matches!(
                action,
                TurnAction::AwaitingEvent | TurnAction::WaitUntil { .. }
            )
        })
    }

    pub fn history_before(&self, current_turn: &str) -> HistoryContext {
        let mut history = Vec::new();
        let mut previous_interaction_id = None;
        let mut latest_reply_sequence = 0;
        let mut legacy_order_inverted = false;
        for turn in &self.turns {
            if turn.id == current_turn {
                break;
            }
            let (TurnInput::Ready(_), ReplyState::Succeeded(reply)) = (&turn.input, &turn.reply)
            else {
                continue;
            };
            // The history user side is the same ordered TurnContent every other
            // consumer renders: transcripts and captions in media order, plus
            // image references the AI layer frames per the caption rule.
            let content = self.turn_content(&turn.id).unwrap_or_default();
            let user = content.user_text();
            let images: Vec<HistoryImage> = content
                .images()
                .into_iter()
                .map(|image| HistoryImage {
                    id: image.id.clone(),
                    description: image.description.clone(),
                })
                .collect();
            if (user.is_empty() && images.is_empty()) || reply.text.is_empty() {
                continue;
            }
            history.push(ProjectedHistoryTurn {
                user,
                assistant: reply.text.clone(),
                images,
            });

            let event_sequence = self
                .reply_event_sequence
                .get(&turn.id)
                .copied()
                .unwrap_or(0);
            legacy_order_inverted |= event_sequence < latest_reply_sequence;

            // New replies attest exactly which preceding durable reply sequence
            // was included in their provider context. This is the only way to
            // re-anchor after out-of-order recovery: event order alone cannot
            // prove that an older binary did not continue a stale provider ID.
            // Legacy monotonic chains remain usable until an inversion is seen.
            let covers_history = reply
                .history_through_seq
                .map_or(!legacy_order_inverted, |through_seq| {
                    through_seq == latest_reply_sequence
                });
            latest_reply_sequence = latest_reply_sequence.max(event_sequence);
            previous_interaction_id = covers_history
                .then(|| reply.interaction_id.clone().filter(|id| !id.is_empty()))
                .flatten();
        }
        HistoryContext {
            turns: history,
            previous_interaction_id,
            through_seq: latest_reply_sequence,
        }
    }
}

fn project_turn(turn: MutableTurn, clips: &HashMap<String, ClipWork>) -> TurnWork {
    let mut transcript_failure = None;
    let mut texts = Vec::new();
    let mut waiting = false;
    for clip_id in &turn.clips {
        match clips.get(clip_id).map(|clip| &clip.transcript) {
            Some(TranscriptState::Succeeded(text)) => texts.push(text.clone()),
            Some(TranscriptState::TerminalFailure(failure)) => {
                transcript_failure = Some(format!("clip {clip_id}: {}", failure.error));
                break;
            }
            Some(_) => waiting = true,
            None => {
                transcript_failure =
                    Some(format!("clip {clip_id} is missing from the conversation"));
                break;
            }
        }
    }
    let input = if let Some(error) = transcript_failure {
        TurnInput::Failed(error)
    } else if waiting {
        TurnInput::Awaiting
    } else {
        TurnInput::Ready(
            texts
                .into_iter()
                .filter(|text| meaningful_user_text(text))
                .collect::<Vec<_>>()
                .join("\n"),
        )
    };
    // A transcription-stage reply failure describes a failed prerequisite,
    // not independent reply work. Once every claimed transcript succeeds,
    // that old failure is stale by definition. Deriving the reopen here keeps
    // recovery crash-safe: no second journal append has to accompany the
    // durable transcript event.
    let reply = if matches!(input, TurnInput::Ready(_))
        && matches!(
            &turn.reply,
            ReplyState::TerminalFailure(ReplyFailure::Transcription(_))
        ) {
        ReplyState::Due { next_attempt: 1 }
    } else {
        turn.reply
    };
    TurnWork {
        id: turn.id,
        clips: turn.clips,
        images: turn.images,
        input,
        reply,
        speech: turn.speech,
        speech_generation: turn.speech_generation,
        speech_generation_index: turn.speech_generation_index,
    }
}

fn apply_error<T, F>(
    state: &mut AttemptState<T, F>,
    explicit_attempt: Option<u32>,
    retry_at_ms: u64,
    terminal: bool,
    error: String,
    make_failure: impl FnOnce(WorkFailure) -> F,
) {
    let attempt = explicit_attempt.unwrap_or(1).max(1);
    *state = if terminal {
        AttemptState::TerminalFailure(make_failure(WorkFailure { attempt, error }))
    } else {
        // Legacy errors had no attempt field and represent a failed attempt
        // whose retry budget starts under the new supervisor.
        let next_attempt = explicit_attempt
            .map(|number| number.saturating_add(1))
            .unwrap_or(1);
        AttemptState::RetryScheduled {
            next_attempt,
            retry_at_ms,
            error,
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn legacy_errors_are_retryable_and_not_complete() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-1"}),
            json!({"kind":"transcript_error", "clip":"clip-1", "error":"offline"}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            json!({"kind":"reply_error", "turn":"turn-1", "error":"also offline"}),
        ]);
        assert_eq!(workflow.transcription_work()[0].next_attempt, 1);
        assert!(matches!(
            workflow.turn("turn-1").unwrap().reply,
            ReplyState::RetryScheduled {
                next_attempt: 1,
                ..
            }
        ));
    }

    #[test]
    fn attempting_requires_an_explicit_recovery_transition() {
        let attempting = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-1"}),
            json!({"kind":"transcript_started", "clip":"clip-1", "attempt":1}),
        ]);
        assert!(attempting.transcription_work().is_empty());
        assert_eq!(attempting.interrupted_transcriptions(), ["clip-1"]);

        let recovered = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-1"}),
            json!({"kind":"transcript_started", "clip":"clip-1", "attempt":1}),
            json!({"kind":"transcript_retry_requested", "clip":"clip-1"}),
        ]);
        assert_eq!(recovered.transcription_work()[0].next_attempt, 1);
    }

    #[test]
    fn reply_and_speech_have_distinct_ordered_substates() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-1"}),
            json!({"kind":"transcript", "clip":"clip-1", "text":"hello"}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            json!({"kind":"reply", "turn":"turn-1", "text":"hi", "audio":"tts/turn-1.wav"}),
            json!({"kind":"speech_retry_scheduled", "turn":"turn-1", "attempt":1, "retry_at_ms":5000, "error":"busy"}),
        ]);
        let turn = workflow.turn("turn-1").unwrap();
        assert!(matches!(turn.reply, ReplyState::Succeeded(_)));
        assert!(matches!(
            turn.speech,
            Some(SpeechState::RetryScheduled {
                next_attempt: 2,
                retry_at_ms: 5000,
                ..
            })
        ));
        assert_eq!(
            turn.action(4_999),
            TurnAction::WaitUntil { deadline_ms: 5000 }
        );
        assert!(matches!(
            turn.action(5_000),
            TurnAction::GenerateSpeech { attempt: 2, .. }
        ));
    }

    #[test]
    fn speech_generation_index_survives_explicit_reopen() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"turn", "id":"turn-1", "clips":[]}),
            json!({
                "kind":"reply", "turn":"turn-1", "text":"hi",
                "audio":"tts/turn-1.wav", "speech_generation":"first"
            }),
            json!({"kind":"speech_started", "turn":"turn-1", "attempt":1, "generation":"first"}),
            json!({"kind":"tts_error", "turn":"turn-1", "attempt":1, "terminal":true, "error":"broken"}),
            json!({"kind":"speech_retry_requested", "turn":"turn-1"}),
            json!({"kind":"speech_started", "turn":"turn-1", "attempt":1, "generation":"second"}),
        ]);

        let turn = workflow.turn("turn-1").unwrap();
        assert_eq!(turn.speech_generation_index, 2);
        assert_eq!(turn.speech_generation.as_deref(), Some("second"));
    }

    #[test]
    fn legacy_audio_counts_as_a_generation_before_regeneration() {
        let adopted = ConversationWorkflow::from_records(&[
            json!({"kind":"turn", "id":"turn-1", "clips":[]}),
            json!({
                "kind":"reply", "turn":"turn-1", "text":"hi",
                "audio":"tts/turn-1.wav"
            }),
            json!({"kind":"speech_ready", "turn":"turn-1"}),
        ]);
        let turn = adopted.turn("turn-1").unwrap();
        assert_eq!(turn.speech_generation_index, 2);
        assert_eq!(turn.speech_generation, None);

        for legacy_outcome in [
            json!({"kind":"speech_ready", "turn":"turn-1"}),
            json!({
                "kind":"tts_error", "turn":"turn-1", "error":"legacy failure"
            }),
        ] {
            let workflow = ConversationWorkflow::from_records(&[
                json!({"kind":"turn", "id":"turn-1", "clips":[]}),
                json!({
                    "kind":"reply", "turn":"turn-1", "text":"hi",
                    "audio":"tts/turn-1.wav"
                }),
                legacy_outcome,
                json!({"kind":"speech_retry_requested", "turn":"turn-1"}),
                json!({
                    "kind":"speech_started", "turn":"turn-1", "attempt":1,
                    "generation":"post-upgrade"
                }),
            ]);

            let turn = workflow.turn("turn-1").unwrap();
            assert_eq!(turn.speech_generation_index, 3);
            assert_eq!(turn.speech_generation.as_deref(), Some("post-upgrade"));
        }
    }

    #[test]
    fn audio_field_requires_speech_even_for_bracket_leading_text() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"turn", "id":"turn-1", "clips":[]}),
            json!({
                "kind":"reply", "turn":"turn-1", "text":"[aside] still speak this",
                "audio":"tts/turn-1.wav"
            }),
        ]);

        let turn = workflow.turn("turn-1").unwrap();
        assert!(matches!(
            turn.speech,
            Some(SpeechState::Due { next_attempt: 1 })
        ));
        assert!(matches!(
            turn.action(0),
            TurnAction::GenerateSpeech { attempt: 1, .. }
        ));
    }

    #[test]
    fn speech_retry_requires_advertised_and_existing_speech() {
        let audio_less = ConversationWorkflow::from_records(&[
            json!({"kind":"turn", "id":"turn-1", "clips":[]}),
            json!({"kind":"reply", "turn":"turn-1", "text":"text only"}),
            json!({"kind":"speech_retry_requested", "turn":"turn-1"}),
        ]);
        assert!(audio_less.turn("turn-1").unwrap().speech.is_none());

        let ready_repair = ConversationWorkflow::from_records(&[
            json!({"kind":"turn", "id":"turn-1", "clips":[]}),
            json!({"kind":"reply", "turn":"turn-1", "text":"hi", "audio":"tts/turn-1.wav"}),
            json!({"kind":"speech_started", "turn":"turn-1", "attempt":1}),
            json!({"kind":"speech_ready", "turn":"turn-1"}),
            json!({"kind":"speech_retry_requested", "turn":"turn-1"}),
        ]);
        assert!(matches!(
            ready_repair.turn("turn-1").unwrap().speech,
            Some(SpeechState::Due { next_attempt: 1 })
        ));

        let explicit_retry = ConversationWorkflow::from_records(&[
            json!({"kind":"turn", "id":"turn-1", "clips":[]}),
            json!({"kind":"reply", "turn":"turn-1", "text":"hi", "audio":"tts/turn-1.wav"}),
            json!({"kind":"tts_error", "turn":"turn-1", "attempt":1, "terminal":true, "error":"broken"}),
            json!({"kind":"speech_retry_requested", "turn":"turn-1"}),
        ]);
        assert!(matches!(
            explicit_retry.turn("turn-1").unwrap().speech,
            Some(SpeechState::Due { next_attempt: 1 })
        ));
    }

    #[test]
    fn successful_transcript_and_reply_are_authoritative_for_history() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-1"}),
            json!({"kind":"transcript_error", "clip":"clip-1", "attempt":1, "terminal":false, "retry_at_ms":10, "error":"offline"}),
            json!({"kind":"transcript", "clip":"clip-1", "text":"hello"}),
            json!({"kind":"transcript", "clip":"clip-1", "text":"stale replacement"}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            json!({"kind":"reply", "turn":"turn-1", "text":"hi", "interaction_id":"provider-1"}),
            json!({"kind":"reply", "turn":"turn-1", "text":"stale replacement", "interaction_id":"provider-2"}),
            json!({"kind":"turn", "id":"turn-2", "clips":[]}),
        ]);
        let context = workflow.history_before("turn-2");
        assert_eq!(
            context.turns,
            [ProjectedHistoryTurn {
                user: "hello".into(),
                assistant: "hi".into(),
                images: vec![],
            }]
        );
        assert_eq!(
            context.previous_interaction_id.as_deref(),
            Some("provider-1")
        );
    }

    #[test]
    fn recovered_earlier_reply_invalidates_and_then_reanchors_provider_cache() {
        let records = [
            json!({"kind":"clip", "id":"clip-1"}),
            json!({"kind":"transcript", "clip":"clip-1", "text":"first"}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "error":"offline"}),
            json!({"kind":"clip", "id":"clip-2"}),
            json!({"kind":"transcript", "clip":"clip-2", "text":"second"}),
            json!({"kind":"turn", "id":"turn-2", "clips":["clip-2"]}),
            json!({"kind":"reply", "turn":"turn-2", "text":"second answer", "interaction_id":"provider-2"}),
            json!({"kind":"reply_retry_requested", "turn":"turn-1"}),
            json!({"kind":"reply", "turn":"turn-1", "text":"first answer", "interaction_id":"provider-1-recovered"}),
            json!({"kind":"clip", "id":"clip-3"}),
            json!({"kind":"transcript", "clip":"clip-3", "text":"third"}),
            json!({"kind":"turn", "id":"turn-3", "clips":["clip-3"]}),
        ];
        let recovered = ConversationWorkflow::from_records(&records);
        let context = recovered.history_before("turn-3");
        assert_eq!(context.turns.len(), 2);
        assert_eq!(context.through_seq, 10);
        assert_eq!(
            context.previous_interaction_id, None,
            "provider-2 predates the recovered turn"
        );

        let mut legacy_records = records.to_vec();
        legacy_records.push(json!({
            "kind":"reply", "turn":"turn-3", "text":"third answer",
            "interaction_id":"unproven-provider-3"
        }));
        legacy_records.push(json!({"kind":"turn", "id":"turn-4", "clips":[]}));
        assert_eq!(
            ConversationWorkflow::from_records(&legacy_records)
                .history_before("turn-4")
                .previous_interaction_id,
            None,
            "a newer legacy event cannot prove it used durable fallback"
        );

        let mut proven_records = records.to_vec();
        proven_records.push(json!({
            "kind":"reply", "turn":"turn-3", "text":"third answer",
            "interaction_id":"provider-3", "history_through_seq":10
        }));
        proven_records.push(json!({"kind":"turn", "id":"turn-4", "clips":[]}));
        let context = ConversationWorkflow::from_records(&proven_records).history_before("turn-4");
        assert_eq!(
            context.previous_interaction_id.as_deref(),
            Some("provider-3")
        );
    }

    #[test]
    fn explicit_retry_reopens_terminal_work() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-1"}),
            json!({"kind":"transcript_error", "clip":"clip-1", "attempt":3, "terminal":true, "error":"missing"}),
            json!({"kind":"transcript_retry_requested", "clip":"clip-1"}),
        ]);
        assert_eq!(workflow.transcription_work()[0].next_attempt, 1);
    }

    #[test]
    fn terminal_failures_ignore_ordinary_later_attempt_and_success_events() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-1"}),
            json!({"kind":"transcript_error", "clip":"clip-1", "attempt":1, "terminal":true, "error":"bad audio"}),
            json!({"kind":"transcript_started", "clip":"clip-1", "attempt":2}),
            json!({"kind":"transcript", "clip":"clip-1", "text":"must stay ignored"}),
            json!({"kind":"turn", "id":"turn-reply", "clips":[]}),
            json!({"kind":"reply_error", "turn":"turn-reply", "attempt":1, "terminal":true, "error":"bad prompt"}),
            json!({"kind":"reply_started", "turn":"turn-reply", "attempt":2}),
            json!({"kind":"reply", "turn":"turn-reply", "text":"must stay ignored"}),
            json!({"kind":"turn", "id":"turn-speech", "clips":[]}),
            json!({"kind":"reply", "turn":"turn-speech", "text":"answer", "audio":"tts/turn-speech.wav"}),
            json!({"kind":"tts_error", "turn":"turn-speech", "attempt":1, "terminal":true, "error":"bad voice"}),
            json!({"kind":"speech_started", "turn":"turn-speech", "attempt":2}),
            json!({"kind":"speech_ready", "turn":"turn-speech"}),
        ]);

        assert!(matches!(
            workflow.clip("clip-1").unwrap().transcript,
            TranscriptState::TerminalFailure(_)
        ));
        assert!(matches!(
            workflow.turn("turn-reply").unwrap().reply,
            ReplyState::TerminalFailure(_)
        ));
        assert!(matches!(
            workflow.turn("turn-speech").unwrap().speech,
            Some(SpeechState::TerminalFailure(_))
        ));
    }

    #[test]
    fn contradictory_terminal_retry_events_are_ignored() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-1"}),
            json!({
                "kind":"transcript_error", "clip":"clip-1", "attempt":1,
                "terminal":true, "retry_at_ms":5000, "error":"contradictory"
            }),
        ]);
        assert!(matches!(
            workflow.clip("clip-1").unwrap().transcript,
            TranscriptState::Due { next_attempt: 1 }
        ));
    }

    #[test]
    fn recovered_transcript_derives_reply_reopen_without_a_second_event() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-1"}),
            json!({"kind":"transcript_error", "clip":"clip-1", "attempt":3, "terminal":true, "error":"offline"}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "stage":"transcription", "error":"transcription failed"}),
            json!({"kind":"transcript_retry_requested", "clip":"clip-1"}),
            json!({"kind":"transcript", "clip":"clip-1", "text":"recovered"}),
        ]);

        assert!(matches!(
            workflow.turn("turn-1").unwrap().reply,
            ReplyState::Due { next_attempt: 1 }
        ));
        assert!(matches!(
            workflow.next_turn_action(0),
            Some((turn, TurnAction::GenerateReply { .. })) if turn == "turn-1"
        ));
        assert!(matches!(
            &workflow.turn("turn-1").unwrap().input,
            TurnInput::Ready(text) if text == "recovered"
        ));

        let completed = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-1"}),
            json!({"kind":"transcript_error", "clip":"clip-1", "attempt":3, "terminal":true, "error":"offline"}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "stage":"transcription", "error":"transcription failed"}),
            json!({"kind":"transcript_retry_requested", "clip":"clip-1"}),
            json!({"kind":"transcript", "clip":"clip-1", "text":"recovered"}),
            json!({"kind":"reply_started", "turn":"turn-1", "attempt":1}),
            json!({"kind":"reply", "turn":"turn-1", "text":"accepted after derived reopen"}),
        ]);
        assert!(matches!(
            completed.turn("turn-1").unwrap().reply,
            ReplyState::Succeeded(_)
        ));
    }

    #[test]
    fn repeated_terminal_transcript_failure_closes_the_reopened_reply() {
        let mut records = vec![
            json!({"kind":"clip", "id":"clip-1"}),
            json!({"kind":"transcript_error", "clip":"clip-1", "attempt":3, "terminal":true, "error":"offline"}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "stage":"transcription", "error":"offline"}),
            json!({"kind":"transcript_retry_requested", "clip":"clip-1"}),
            json!({"kind":"transcript_started", "clip":"clip-1", "attempt":1}),
            json!({"kind":"transcript_error", "clip":"clip-1", "attempt":1, "terminal":true, "error":"still offline"}),
        ];

        let failed_again = ConversationWorkflow::from_records(&records);
        assert!(matches!(
            failed_again.next_turn_action(0),
            Some((turn, TurnAction::RecordTranscriptFailure { error }))
                if turn == "turn-1" && error.contains("still offline")
        ));

        records.push(json!({
            "kind":"reply_error", "turn":"turn-1", "attempt":1,
            "terminal":true, "stage":"transcription", "error":"still offline"
        }));
        let closed = ConversationWorkflow::from_records(&records);
        assert!(closed.next_turn_action(0).is_none());
        assert!(matches!(
            closed.turn("turn-1").unwrap().reply,
            ReplyState::TerminalFailure(ReplyFailure::Transcription(_))
        ));
    }

    #[test]
    fn image_only_turn_is_ready_immediately() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"image", "id":"img-1", "file":"images/img-1.jpg", "mime":"image/jpeg", "sha256":"abc", "recorded_at":1}),
            json!({"kind":"turn", "id":"turn-1", "images":["img-1"], "clips":[]}),
        ]);
        // No transcript gate: the turn is runnable with empty user text and
        // the reply stage decides answerability from TurnContent.
        assert!(matches!(
            workflow.next_turn_action(0),
            Some((turn, TurnAction::GenerateReply { .. })) if turn == "turn-1"
        ));
        assert!(matches!(
            &workflow.turn("turn-1").unwrap().input,
            TurnInput::Ready(text) if text.is_empty()
        ));
        let content = workflow.turn_content("turn-1").unwrap();
        assert_eq!(content.images().len(), 1);
        assert_eq!(content.user_text(), "");
    }

    #[test]
    fn images_never_gate_turn_input() {
        let mut records = vec![
            json!({"kind":"clip", "id":"clip-1", "recorded_at":1}),
            json!({"kind":"image", "id":"img-1", "file":"images/img-1.jpg", "mime":"image/jpeg", "sha256":"abc", "recorded_at":2}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"], "images":["img-1"]}),
        ];
        let awaiting = ConversationWorkflow::from_records(&records);
        assert!(matches!(
            awaiting.turn("turn-1").unwrap().input,
            TurnInput::Awaiting
        ));

        records.insert(
            1,
            json!({"kind":"transcript", "clip":"clip-1", "text":"hello"}),
        );
        let ready = ConversationWorkflow::from_records(&records);
        assert!(matches!(
            &ready.turn("turn-1").unwrap().input,
            TurnInput::Ready(text) if text == "hello"
        ));
        // The pending description never blocks the turn.
        assert!(matches!(
            ready.image("img-1").unwrap().description,
            DescriptionState::Due { next_attempt: 1 }
        ));
    }

    #[test]
    fn description_first_success_is_authoritative_over_duplicates_and_stale_events() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"image", "id":"img-1", "file":"images/img-1.jpg", "mime":"image/jpeg", "sha256":"abc", "recorded_at":1}),
            json!({"kind":"description", "image":"img-1", "text":"first", "attempt":1, "model":"gemini", "prompt_version":1}),
            json!({"kind":"description", "image":"img-1", "text":"stale duplicate", "attempt":2, "model":"gemini", "prompt_version":1}),
            json!({"kind":"description_started", "image":"img-1", "attempt":3}),
            json!({"kind":"description_error", "image":"img-1", "attempt":3, "terminal":true, "error":"stale failure"}),
            json!({"kind":"description_retry_requested", "image":"img-1"}),
        ]);
        assert!(matches!(
            &workflow.image("img-1").unwrap().description,
            DescriptionState::Succeeded(record) if record.text == "first"
        ));
        assert!(workflow.description_work().is_empty());

        let terminal = ConversationWorkflow::from_records(&[
            json!({"kind":"image", "id":"img-1", "file":"images/img-1.jpg", "mime":"image/jpeg", "sha256":"abc", "recorded_at":1}),
            json!({"kind":"description_error", "image":"img-1", "attempt":1, "terminal":true, "error":"blocked"}),
            json!({"kind":"description", "image":"img-1", "text":"must stay ignored", "attempt":2, "model":"gemini", "prompt_version":1}),
        ]);
        assert!(matches!(
            terminal.image("img-1").unwrap().description,
            DescriptionState::TerminalFailure(_)
        ));
    }

    #[test]
    fn description_stage_derives_due_attempting_scheduled_and_terminal_work() {
        let image = json!({"kind":"image", "id":"img-1", "file":"images/img-1.jpg", "mime":"image/jpeg", "sha256":"abc", "recorded_at":1});

        let due = ConversationWorkflow::from_records(&[image.clone()]);
        assert_eq!(due.description_work()[0].next_attempt, 1);

        let attempting = ConversationWorkflow::from_records(&[
            image.clone(),
            json!({"kind":"description_started", "image":"img-1", "attempt":1}),
        ]);
        assert!(attempting.description_work().is_empty());
        assert_eq!(attempting.interrupted_descriptions(), ["img-1"]);

        let scheduled = ConversationWorkflow::from_records(&[
            image.clone(),
            json!({"kind":"description_retry_scheduled", "image":"img-1", "attempt":1, "error":"busy", "retry_at_ms":9000}),
        ]);
        let work = &scheduled.description_work()[0];
        assert_eq!((work.next_attempt, work.retry_at_ms), (2, 9000));

        let terminal = ConversationWorkflow::from_records(&[
            image.clone(),
            json!({"kind":"description_error", "image":"img-1", "attempt":3, "terminal":true, "error":"blocked"}),
        ]);
        assert!(terminal.description_work().is_empty());
        let reopened = ConversationWorkflow::from_records(&[
            image,
            json!({"kind":"description_error", "image":"img-1", "attempt":3, "terminal":true, "error":"blocked"}),
            json!({"kind":"description_retry_requested", "image":"img-1"}),
        ]);
        assert_eq!(reopened.description_work()[0].next_attempt, 1);
    }

    #[test]
    fn turn_content_merges_media_by_recorded_at_with_captions_in_place() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-late", "recorded_at":30}),
            json!({"kind":"transcript", "clip":"clip-late", "text":"and after"}),
            json!({"kind":"image", "id":"img-1", "file":"images/img-1.png", "mime":"image/png", "sha256":"abc", "recorded_at":20, "caption":"the whiteboard"}),
            json!({"kind":"description", "image":"img-1", "text":"a full whiteboard", "attempt":1, "model":"gemini", "prompt_version":1}),
            json!({"kind":"clip", "id":"clip-early", "recorded_at":10}),
            json!({"kind":"transcript", "clip":"clip-early", "text":"before"}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-late", "clip-early"], "images":["img-1"]}),
        ]);

        let content = workflow.turn_content("turn-1").unwrap();
        let kinds: Vec<&str> = content
            .items
            .iter()
            .map(|item| match item {
                TurnMedia::Transcript { clip, .. } => clip.as_str(),
                TurnMedia::Image(image) => image.id.as_str(),
            })
            .collect();
        assert_eq!(kinds, ["clip-early", "img-1", "clip-late"]);
        // The caption is user text exactly once, at its media position.
        assert_eq!(content.user_text(), "before\nthe whiteboard\nand after");
        let images = content.images();
        assert_eq!(images[0].description.as_deref(), Some("a full whiteboard"));
        assert_eq!(images[0].mime, "image/png");
    }

    #[test]
    fn history_includes_image_bearing_turns() {
        let workflow = ConversationWorkflow::from_records(&[
            json!({"kind":"image", "id":"img-1", "file":"images/img-1.jpg", "mime":"image/jpeg", "sha256":"abc", "recorded_at":1, "caption":"my cat"}),
            json!({"kind":"description", "image":"img-1", "text":"a tabby cat", "attempt":1, "model":"gemini", "prompt_version":1}),
            json!({"kind":"turn", "id":"turn-1", "clips":[], "images":["img-1"]}),
            json!({"kind":"reply", "turn":"turn-1", "text":"What a nice cat."}),
            json!({"kind":"image", "id":"img-2", "file":"images/img-2.jpg", "mime":"image/jpeg", "sha256":"def", "recorded_at":2}),
            json!({"kind":"turn", "id":"turn-2", "clips":[], "images":["img-2"]}),
            json!({"kind":"reply", "turn":"turn-2", "text":"Another photo."}),
            json!({"kind":"turn", "id":"turn-3", "clips":[]}),
        ]);
        let context = workflow.history_before("turn-3");
        assert_eq!(
            context.turns,
            [
                ProjectedHistoryTurn {
                    user: "my cat".into(),
                    assistant: "What a nice cat.".into(),
                    images: vec![HistoryImage {
                        id: "img-1".into(),
                        description: Some("a tabby cat".into()),
                    }],
                },
                // Captionless and undescribed: included purely for its image.
                ProjectedHistoryTurn {
                    user: String::new(),
                    assistant: "Another photo.".into(),
                    images: vec![HistoryImage {
                        id: "img-2".into(),
                        description: None,
                    }],
                },
            ]
        );
    }

    /// R14 forward-only journals: this fixture documents what an old binary
    /// does with a new journal, and how the new binary reads the result back.
    /// An old reader sees `image` as Unknown and `turn.images` as noise, so an
    /// image-only turn fails visibly ("turn has no clips") and heals through
    /// turn-retry after upgrade; a mixed turn it answered keeps its pixel-less
    /// reply — first success stays authoritative and ordinary retry does not
    /// reopen it.
    #[test]
    fn forward_only_journal_degradations_are_visible_and_recoverable() {
        // Image-only turn closed by an old binary: terminal, retry-recoverable.
        let failed = ConversationWorkflow::from_records(&[
            json!({"kind":"image", "id":"img-1", "file":"images/img-1.jpg", "mime":"image/jpeg", "sha256":"abc", "recorded_at":1}),
            json!({"kind":"turn", "id":"turn-1", "clips":[], "images":["img-1"]}),
            json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "stage":"reply", "error":"turn has no clips"}),
        ]);
        assert!(matches!(
            failed.turn("turn-1").unwrap().reply,
            ReplyState::TerminalFailure(ReplyFailure::Generation(_))
        ));
        let healed = ConversationWorkflow::from_records(&[
            json!({"kind":"image", "id":"img-1", "file":"images/img-1.jpg", "mime":"image/jpeg", "sha256":"abc", "recorded_at":1}),
            json!({"kind":"turn", "id":"turn-1", "clips":[], "images":["img-1"]}),
            json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "stage":"reply", "error":"turn has no clips"}),
            json!({"kind":"reply_retry_requested", "turn":"turn-1", "reason":"turn_retry"}),
        ]);
        assert!(matches!(
            healed.next_turn_action(0),
            Some((turn, TurnAction::GenerateReply { .. })) if turn == "turn-1"
        ));

        // Mixed turn answered pixel-less by an old binary: the durable reply
        // stays authoritative; nothing reopens it implicitly.
        let mixed = ConversationWorkflow::from_records(&[
            json!({"kind":"clip", "id":"clip-1", "recorded_at":1}),
            json!({"kind":"transcript", "clip":"clip-1", "text":"look at this"}),
            json!({"kind":"image", "id":"img-1", "file":"images/img-1.jpg", "mime":"image/jpeg", "sha256":"abc", "recorded_at":2}),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"], "images":["img-1"]}),
            json!({"kind":"reply", "turn":"turn-1", "text":"answered without pixels"}),
        ]);
        assert!(matches!(
            &mixed.turn("turn-1").unwrap().reply,
            ReplyState::Succeeded(reply) if reply.text == "answered without pixels"
        ));
        assert!(mixed.next_turn_action(0).is_none());
        assert_eq!(mixed.turn_content("turn-1").unwrap().images().len(), 1);
    }
}

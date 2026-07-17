use crate::model::ConversationNameSource;
use crate::workflow::FailureStage;
use serde::Serialize;
use serde_json::Value;

/// A new durable journal record before store-owned sequence and timestamp
/// metadata are assigned. The representation is intentionally opaque outside
/// this module: production callers choose a domain constructor rather than
/// assembling an open JSON object.
#[derive(Debug)]
pub(crate) struct JournalWrite(JournalWriteKind);

/// The three accepted image encodings. The sniffed format is the durable
/// `mime` authority and fixes the payload extension, exactly like clips fix
/// `clips/<id>.wav`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ImageFormat {
    Jpeg,
    Png,
    Webp,
}

impl ImageFormat {
    pub(crate) fn mime(self) -> &'static str {
        match self {
            Self::Jpeg => "image/jpeg",
            Self::Png => "image/png",
            Self::Webp => "image/webp",
        }
    }

    pub(crate) fn extension(self) -> &'static str {
        match self {
            Self::Jpeg => "jpg",
            Self::Png => "png",
            Self::Webp => "webp",
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum JournalWriteKind {
    Clip {
        id: String,
        file: String,
        mime: &'static str,
        #[serde(rename = "ms")]
        duration_ms: u64,
        #[serde(rename = "peak")]
        peak_pct: u32,
        recorded_at: u64,
        sha256: String,
    },
    /// A clip assembled from streamed recording parts. Readers treat it as an
    /// ordinary `clip`; the extra fields let completion retries prove they
    /// match the committed recording.
    #[serde(rename = "clip")]
    RecordingClip {
        id: String,
        file: String,
        mime: &'static str,
        #[serde(rename = "ms")]
        duration_ms: u64,
        #[serde(rename = "peak")]
        peak_pct: u32,
        recorded_at: u64,
        sha256: String,
        samples: u64,
        rate: u32,
        part_count: u32,
    },
    Image {
        id: String,
        file: String,
        mime: &'static str,
        recorded_at: u64,
        sha256: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        width: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        height: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        caption: Option<String>,
    },
    Turn {
        id: String,
        clips: Vec<String>,
        // Omitted when empty so audio-only turns keep their exact legacy shape.
        #[serde(skip_serializing_if = "Vec::is_empty")]
        images: Vec<String>,
    },
    ConversationRenamed {
        name: String,
        source: ConversationNameSource,
    },
    TranscriptStarted {
        clip: String,
        attempt: u32,
        stage: FailureStage,
    },
    TranscriptRetryRequested {
        clip: String,
        reason: String,
    },
    TranscriptRetryScheduled {
        clip: String,
        attempt: u32,
        error: String,
        retry_at_ms: u64,
        stage: FailureStage,
    },
    Transcript {
        clip: String,
        text: String,
        attempt: u32,
    },
    TranscriptError {
        clip: String,
        attempt: u32,
        error: String,
        terminal: bool,
        stage: FailureStage,
    },
    DescriptionStarted {
        image: String,
        attempt: u32,
    },
    DescriptionRetryRequested {
        image: String,
        reason: String,
    },
    DescriptionRetryScheduled {
        image: String,
        attempt: u32,
        error: String,
        retry_at_ms: u64,
    },
    Description {
        image: String,
        attempt: u32,
        text: String,
        model: String,
        prompt_version: u32,
    },
    DescriptionError {
        image: String,
        attempt: u32,
        error: String,
        terminal: bool,
    },
    ReplyStarted {
        turn: String,
        attempt: u32,
        stage: FailureStage,
    },
    ReplyRetryRequested {
        turn: String,
        reason: String,
    },
    ReplyRetryScheduled {
        turn: String,
        attempt: u32,
        error: String,
        retry_at_ms: u64,
        stage: FailureStage,
    },
    Reply {
        turn: String,
        text: String,
        answers: Vec<String>,
        #[serde(flatten)]
        delivery: ReplyDelivery,
    },
    ReplyError {
        turn: String,
        attempt: u32,
        error: String,
        terminal: bool,
        stage: FailureStage,
    },
    SpeechStarted {
        turn: String,
        attempt: u32,
        stage: FailureStage,
        generation: String,
    },
    SpeechRetryRequested {
        turn: String,
        reason: String,
    },
    SpeechRetryScheduled {
        turn: String,
        attempt: u32,
        error: String,
        retry_at_ms: u64,
        stage: FailureStage,
    },
    TtsError {
        turn: String,
        attempt: u32,
        error: String,
        terminal: bool,
        stage: FailureStage,
    },
    SpeechReady {
        turn: String,
        samples: usize,
        rate: u32,
        recovered: bool,
    },
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
enum ReplyDelivery {
    TextOnly {},
    Spoken {
        audio: String,
        interaction_id: Option<String>,
        speech_generation: String,
        history_through_seq: u64,
    },
}

impl JournalWrite {
    pub(crate) fn clip(
        id: impl Into<String>,
        duration_ms: u64,
        peak_pct: u32,
        recorded_at: u64,
        sha256: impl Into<String>,
    ) -> Self {
        let id = id.into();
        Self(JournalWriteKind::Clip {
            file: format!("clips/{id}.wav"),
            id,
            mime: "audio/wav",
            duration_ms,
            peak_pct,
            recorded_at,
            sha256: sha256.into(),
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn recording_clip(
        id: impl Into<String>,
        duration_ms: u64,
        peak_pct: u32,
        recorded_at: u64,
        sha256: impl Into<String>,
        samples: u64,
        rate: u32,
        part_count: u32,
    ) -> Self {
        let id = id.into();
        Self(JournalWriteKind::RecordingClip {
            file: format!("clips/{id}.wav"),
            id,
            mime: "audio/wav",
            duration_ms,
            peak_pct,
            recorded_at,
            sha256: sha256.into(),
            samples,
            rate,
            part_count,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn image(
        id: impl Into<String>,
        format: ImageFormat,
        sha256: impl Into<String>,
        recorded_at: u64,
        width: Option<u32>,
        height: Option<u32>,
        caption: Option<String>,
    ) -> Self {
        let id = id.into();
        Self(JournalWriteKind::Image {
            file: format!("images/{id}.{}", format.extension()),
            id,
            mime: format.mime(),
            recorded_at,
            sha256: sha256.into(),
            width,
            height,
            caption: caption.filter(|caption| !caption.is_empty()),
        })
    }

    pub(crate) fn turn(id: impl Into<String>, clips: Vec<String>, images: Vec<String>) -> Self {
        Self(JournalWriteKind::Turn {
            id: id.into(),
            clips,
            images,
        })
    }

    pub(crate) fn description_started(image: impl Into<String>, attempt: u32) -> Self {
        Self(JournalWriteKind::DescriptionStarted {
            image: image.into(),
            attempt,
        })
    }

    pub(crate) fn description_retry_requested(
        image: impl Into<String>,
        reason: impl Into<String>,
    ) -> Self {
        Self(JournalWriteKind::DescriptionRetryRequested {
            image: image.into(),
            reason: reason.into(),
        })
    }

    pub(crate) fn description_retry_scheduled(
        image: impl Into<String>,
        attempt: u32,
        error: impl Into<String>,
        retry_at_ms: u64,
    ) -> Self {
        Self(JournalWriteKind::DescriptionRetryScheduled {
            image: image.into(),
            attempt,
            error: error.into(),
            retry_at_ms,
        })
    }

    pub(crate) fn description_succeeded(
        image: impl Into<String>,
        text: &str,
        attempt: u32,
        model: impl Into<String>,
        prompt_version: u32,
    ) -> Self {
        Self(JournalWriteKind::Description {
            image: image.into(),
            attempt,
            text: bound_description_text(text),
            model: model.into(),
            prompt_version,
        })
    }

    pub(crate) fn description_failed(
        image: impl Into<String>,
        attempt: u32,
        error: impl Into<String>,
    ) -> Self {
        Self(JournalWriteKind::DescriptionError {
            image: image.into(),
            attempt,
            error: error.into(),
            terminal: true,
        })
    }

    pub(crate) fn conversation_renamed(name: impl Into<String>) -> Self {
        Self(JournalWriteKind::ConversationRenamed {
            name: name.into(),
            source: ConversationNameSource::Transcript,
        })
    }

    pub(crate) fn transcript_started(clip: impl Into<String>, attempt: u32) -> Self {
        Self(JournalWriteKind::TranscriptStarted {
            clip: clip.into(),
            attempt,
            stage: FailureStage::Transcription,
        })
    }

    pub(crate) fn transcript_retry_requested(
        clip: impl Into<String>,
        reason: impl Into<String>,
    ) -> Self {
        Self(JournalWriteKind::TranscriptRetryRequested {
            clip: clip.into(),
            reason: reason.into(),
        })
    }

    pub(crate) fn transcript_retry_scheduled(
        clip: impl Into<String>,
        attempt: u32,
        error: impl Into<String>,
        retry_at_ms: u64,
    ) -> Self {
        Self(JournalWriteKind::TranscriptRetryScheduled {
            clip: clip.into(),
            attempt,
            error: error.into(),
            retry_at_ms,
            stage: FailureStage::Transcription,
        })
    }

    pub(crate) fn transcript_succeeded(
        clip: impl Into<String>,
        text: impl Into<String>,
        attempt: u32,
    ) -> Self {
        Self(JournalWriteKind::Transcript {
            clip: clip.into(),
            text: text.into(),
            attempt,
        })
    }

    pub(crate) fn transcript_failed(
        clip: impl Into<String>,
        attempt: u32,
        error: impl Into<String>,
    ) -> Self {
        Self(JournalWriteKind::TranscriptError {
            clip: clip.into(),
            attempt,
            error: error.into(),
            terminal: true,
            stage: FailureStage::Transcription,
        })
    }

    pub(crate) fn reply_started(turn: impl Into<String>, attempt: u32) -> Self {
        Self(JournalWriteKind::ReplyStarted {
            turn: turn.into(),
            attempt,
            stage: FailureStage::Reply,
        })
    }

    pub(crate) fn reply_retry_requested(
        turn: impl Into<String>,
        reason: impl Into<String>,
    ) -> Self {
        Self(JournalWriteKind::ReplyRetryRequested {
            turn: turn.into(),
            reason: reason.into(),
        })
    }

    pub(crate) fn reply_retry_scheduled(
        turn: impl Into<String>,
        attempt: u32,
        error: impl Into<String>,
        retry_at_ms: u64,
    ) -> Self {
        Self(JournalWriteKind::ReplyRetryScheduled {
            turn: turn.into(),
            attempt,
            error: error.into(),
            retry_at_ms,
            stage: FailureStage::Reply,
        })
    }

    pub(crate) fn reply_text(
        turn: impl Into<String>,
        text: impl Into<String>,
        answers: Vec<String>,
    ) -> Self {
        Self(JournalWriteKind::Reply {
            turn: turn.into(),
            text: text.into(),
            answers,
            delivery: ReplyDelivery::TextOnly {},
        })
    }

    pub(crate) fn reply_spoken(
        turn: impl Into<String>,
        text: impl Into<String>,
        answers: Vec<String>,
        interaction_id: Option<String>,
        speech_generation: impl Into<String>,
        history_through_seq: u64,
    ) -> Self {
        let turn = turn.into();
        let audio = format!("tts/{turn}.wav");
        Self(JournalWriteKind::Reply {
            turn,
            text: text.into(),
            answers,
            delivery: ReplyDelivery::Spoken {
                audio,
                interaction_id,
                speech_generation: speech_generation.into(),
                history_through_seq,
            },
        })
    }

    pub(crate) fn reply_failed(
        turn: impl Into<String>,
        attempt: u32,
        error: impl Into<String>,
    ) -> Self {
        Self::reply_error(turn, attempt, error, FailureStage::Reply)
    }

    pub(crate) fn reply_failed_from_transcription(
        turn: impl Into<String>,
        attempt: u32,
        error: impl Into<String>,
    ) -> Self {
        Self::reply_error(turn, attempt, error, FailureStage::Transcription)
    }

    fn reply_error(
        turn: impl Into<String>,
        attempt: u32,
        error: impl Into<String>,
        stage: FailureStage,
    ) -> Self {
        Self(JournalWriteKind::ReplyError {
            turn: turn.into(),
            attempt,
            error: error.into(),
            terminal: true,
            stage,
        })
    }

    pub(crate) fn speech_started(
        turn: impl Into<String>,
        attempt: u32,
        generation: impl Into<String>,
    ) -> Self {
        Self(JournalWriteKind::SpeechStarted {
            turn: turn.into(),
            attempt,
            stage: FailureStage::Speech,
            generation: generation.into(),
        })
    }

    pub(crate) fn speech_retry_requested(
        turn: impl Into<String>,
        reason: impl Into<String>,
    ) -> Self {
        Self(JournalWriteKind::SpeechRetryRequested {
            turn: turn.into(),
            reason: reason.into(),
        })
    }

    pub(crate) fn speech_retry_scheduled(
        turn: impl Into<String>,
        attempt: u32,
        error: impl Into<String>,
        retry_at_ms: u64,
    ) -> Self {
        Self(JournalWriteKind::SpeechRetryScheduled {
            turn: turn.into(),
            attempt,
            error: error.into(),
            retry_at_ms,
            stage: FailureStage::Speech,
        })
    }

    pub(crate) fn speech_failed(
        turn: impl Into<String>,
        attempt: u32,
        error: impl Into<String>,
    ) -> Self {
        Self(JournalWriteKind::TtsError {
            turn: turn.into(),
            attempt,
            error: error.into(),
            terminal: true,
            stage: FailureStage::Speech,
        })
    }

    pub(crate) fn speech_ready(
        turn: impl Into<String>,
        samples: usize,
        rate: u32,
        recovered: bool,
    ) -> Self {
        Self(JournalWriteKind::SpeechReady {
            turn: turn.into(),
            samples,
            rate,
            recovered,
        })
    }

    pub(crate) fn into_value(self) -> serde_json::Result<Value> {
        serde_json::to_value(self.0)
    }
}

/// Descriptions are durable values reused by history fallback, knowledge, and
/// UIs, so their bounds are enforced where the value is written: trimmed,
/// control characters stripped, collapsed to a single paragraph, and capped at
/// 4 KiB on a character boundary. Knowledge reapplies the same projection on
/// read as a defense against handcrafted journal events.
pub(crate) fn bound_description_text(text: &str) -> String {
    const MAX_DESCRIPTION_BYTES: usize = 4 * 1024;
    let mut paragraph = text
        .chars()
        .filter(|character| !character.is_control() || character.is_whitespace())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if paragraph.len() > MAX_DESCRIPTION_BYTES {
        let mut end = MAX_DESCRIPTION_BYTES;
        while !paragraph.is_char_boundary(end) {
            end -= 1;
        }
        paragraph.truncate(end);
    }
    paragraph
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn value(write: JournalWrite) -> Value {
        write.into_value().unwrap()
    }

    #[test]
    fn storage_records_derive_fixed_paths_and_metadata() {
        assert_eq!(
            value(JournalWrite::clip("clip-1", 1200, 87, 42, "abc")),
            json!({
                "kind":"clip", "id":"clip-1", "file":"clips/clip-1.wav",
                "mime":"audio/wav", "ms":1200, "peak":87,
                "recorded_at":42, "sha256":"abc"
            })
        );
        assert_eq!(
            value(JournalWrite::recording_clip(
                "rec-1", 1200, 87, 42, "abc", 19_200, 16_000, 3
            )),
            json!({
                "kind":"clip", "id":"rec-1", "file":"clips/rec-1.wav",
                "mime":"audio/wav", "ms":1200, "peak":87,
                "recorded_at":42, "sha256":"abc",
                "samples":19_200, "rate":16_000, "part_count":3
            })
        );
        // Audio-only turns must keep their exact legacy byte shape: no
        // `images` key may appear when the claim set is empty.
        assert_eq!(
            value(JournalWrite::turn(
                "turn-1",
                vec!["clip-1".into(), "clip-2".into()],
                vec![]
            )),
            json!({"kind":"turn", "id":"turn-1", "clips":["clip-1", "clip-2"]})
        );
        assert_eq!(
            value(JournalWrite::turn(
                "turn-2",
                vec!["clip-1".into()],
                vec!["img-1".into(), "img-2".into()]
            )),
            json!({
                "kind":"turn", "id":"turn-2", "clips":["clip-1"],
                "images":["img-1", "img-2"]
            })
        );
        assert_eq!(
            value(JournalWrite::image(
                "img-1",
                ImageFormat::Jpeg,
                "abc",
                42,
                Some(3024),
                Some(4032),
                Some("whiteboard".into()),
            )),
            json!({
                "kind":"image", "id":"img-1", "file":"images/img-1.jpg",
                "mime":"image/jpeg", "recorded_at":42, "sha256":"abc",
                "width":3024, "height":4032, "caption":"whiteboard"
            })
        );
        assert_eq!(
            value(JournalWrite::image(
                "img-2",
                ImageFormat::Webp,
                "def",
                7,
                None,
                None,
                None,
            )),
            json!({
                "kind":"image", "id":"img-2", "file":"images/img-2.webp",
                "mime":"image/webp", "recorded_at":7, "sha256":"def"
            })
        );
        assert_eq!(
            value(JournalWrite::conversation_renamed("A useful name")),
            json!({
                "kind":"conversation_renamed", "name":"A useful name",
                "source":"transcript"
            })
        );
    }

    #[test]
    fn attempt_boundaries_have_fixed_stage_and_owner_fields() {
        assert_eq!(
            value(JournalWrite::transcript_started("clip-1", 2)),
            json!({
                "kind":"transcript_started", "clip":"clip-1",
                "attempt":2, "stage":"transcription"
            })
        );
        assert_eq!(
            value(JournalWrite::reply_started("turn-1", 3)),
            json!({
                "kind":"reply_started", "turn":"turn-1",
                "attempt":3, "stage":"reply"
            })
        );
        assert_eq!(
            value(JournalWrite::speech_started("turn-1", 4, "generation-1")),
            json!({
                "kind":"speech_started", "turn":"turn-1", "attempt":4,
                "stage":"speech", "generation":"generation-1"
            })
        );
    }

    #[test]
    fn scheduled_and_terminal_failures_cannot_share_a_shape() {
        let scheduled = value(JournalWrite::reply_retry_scheduled(
            "turn-1", 2, "busy", 9000,
        ));
        assert_eq!(
            scheduled,
            json!({
                "kind":"reply_retry_scheduled", "turn":"turn-1", "attempt":2,
                "error":"busy", "retry_at_ms":9000, "stage":"reply"
            })
        );
        assert!(scheduled.get("terminal").is_none());

        let terminal = value(JournalWrite::reply_failed_from_transcription(
            "turn-1", 1, "bad clip",
        ));
        assert_eq!(
            terminal,
            json!({
                "kind":"reply_error", "turn":"turn-1", "attempt":1,
                "error":"bad clip", "terminal":true, "stage":"transcription"
            })
        );
        assert!(terminal.get("retry_at_ms").is_none());
    }

    #[test]
    fn reply_delivery_is_flat_and_preserves_null_interaction_id() {
        assert_eq!(
            value(JournalWrite::reply_text(
                "turn-1",
                "[nothing to answer]",
                vec!["clip-1".into()]
            )),
            json!({
                "kind":"reply", "turn":"turn-1", "text":"[nothing to answer]",
                "answers":["clip-1"]
            })
        );
        assert_eq!(
            value(JournalWrite::reply_spoken(
                "turn-1",
                "hello",
                vec!["clip-1".into()],
                None,
                "generation-1",
                17,
            )),
            json!({
                "kind":"reply", "turn":"turn-1", "text":"hello",
                "answers":["clip-1"], "audio":"tts/turn-1.wav",
                "interaction_id":null, "speech_generation":"generation-1",
                "history_through_seq":17
            })
        );
    }

    #[test]
    fn description_text_is_bounded_at_the_constructor() {
        let hostile = "  a cat\u{7} on\n\na desk\t\tnext to\ra mug  ";
        assert_eq!(
            value(JournalWrite::description_succeeded(
                "img-1", hostile, 1, "mock", 1
            ))["text"],
            "a cat on a desk next to a mug"
        );

        let oversized = "é".repeat(3 * 1024);
        let bounded = value(JournalWrite::description_succeeded(
            "img-1", &oversized, 1, "mock", 1,
        ));
        let text = bounded["text"].as_str().unwrap();
        assert!(text.len() <= 4 * 1024);
        assert_eq!(text.len(), 4 * 1024); // even byte count: no split character
        assert!(text.chars().all(|character| character == 'é'));
    }

    #[test]
    fn every_retry_result_constructor_has_an_exact_wire_shape() {
        let cases = [
            (
                JournalWrite::transcript_retry_requested("clip-1", "manual"),
                json!({
                    "kind":"transcript_retry_requested", "clip":"clip-1",
                    "reason":"manual"
                }),
            ),
            (
                JournalWrite::transcript_retry_scheduled("clip-1", 2, "busy", 41),
                json!({
                    "kind":"transcript_retry_scheduled", "clip":"clip-1",
                    "attempt":2, "error":"busy", "retry_at_ms":41,
                    "stage":"transcription"
                }),
            ),
            (
                JournalWrite::transcript_succeeded("clip-1", "hello", 2),
                json!({
                    "kind":"transcript", "clip":"clip-1", "text":"hello",
                    "attempt":2
                }),
            ),
            (
                JournalWrite::transcript_failed("clip-1", 3, "invalid audio"),
                json!({
                    "kind":"transcript_error", "clip":"clip-1", "attempt":3,
                    "error":"invalid audio", "terminal":true,
                    "stage":"transcription"
                }),
            ),
            (
                JournalWrite::description_started("img-1", 2),
                json!({
                    "kind":"description_started", "image":"img-1", "attempt":2
                }),
            ),
            (
                JournalWrite::description_retry_requested("img-1", "explicit_retry"),
                json!({
                    "kind":"description_retry_requested", "image":"img-1",
                    "reason":"explicit_retry"
                }),
            ),
            (
                JournalWrite::description_retry_scheduled("img-1", 2, "busy", 41),
                json!({
                    "kind":"description_retry_scheduled", "image":"img-1",
                    "attempt":2, "error":"busy", "retry_at_ms":41
                }),
            ),
            (
                JournalWrite::description_succeeded(
                    "img-1",
                    "a tabby cat",
                    2,
                    "gemini-3.5-flash",
                    1,
                ),
                json!({
                    "kind":"description", "image":"img-1", "attempt":2,
                    "text":"a tabby cat", "model":"gemini-3.5-flash",
                    "prompt_version":1
                }),
            ),
            (
                JournalWrite::description_failed("img-1", 3, "safety block"),
                json!({
                    "kind":"description_error", "image":"img-1", "attempt":3,
                    "error":"safety block", "terminal":true
                }),
            ),
            (
                JournalWrite::reply_retry_requested("turn-1", "manual"),
                json!({
                    "kind":"reply_retry_requested", "turn":"turn-1",
                    "reason":"manual"
                }),
            ),
            (
                JournalWrite::reply_failed("turn-1", 3, "invalid prompt"),
                json!({
                    "kind":"reply_error", "turn":"turn-1", "attempt":3,
                    "error":"invalid prompt", "terminal":true, "stage":"reply"
                }),
            ),
            (
                JournalWrite::speech_retry_requested("turn-1", "repair"),
                json!({
                    "kind":"speech_retry_requested", "turn":"turn-1",
                    "reason":"repair"
                }),
            ),
            (
                JournalWrite::speech_retry_scheduled("turn-1", 2, "busy", 42),
                json!({
                    "kind":"speech_retry_scheduled", "turn":"turn-1",
                    "attempt":2, "error":"busy", "retry_at_ms":42,
                    "stage":"speech"
                }),
            ),
            (
                JournalWrite::speech_failed("turn-1", 3, "invalid voice"),
                json!({
                    "kind":"tts_error", "turn":"turn-1", "attempt":3,
                    "error":"invalid voice", "terminal":true, "stage":"speech"
                }),
            ),
            (
                JournalWrite::speech_ready("turn-1", 28800, 24000, false),
                json!({
                    "kind":"speech_ready", "turn":"turn-1", "samples":28800,
                    "rate":24000, "recovered":false
                }),
            ),
        ];

        for (write, expected) in cases {
            let actual = value(write);
            assert_eq!(actual, expected);
            if actual["kind"]
                .as_str()
                .is_some_and(|kind| kind.ends_with("_retry_scheduled"))
            {
                assert!(actual.get("terminal").is_none());
            }
            if actual["terminal"] == true {
                assert!(actual.get("retry_at_ms").is_none());
            }
        }
    }
}

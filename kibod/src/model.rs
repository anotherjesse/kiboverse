use serde::{Deserialize, Serialize};
use typeshare::typeshare;

#[typeshare(swift = "Hashable, Identifiable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KiboProject {
    pub id: String,
    pub name: String,
    #[typeshare(serialized_as = "U53")]
    pub created_at: u64,
}

#[typeshare(swift = "Hashable, Identifiable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KiboConversation {
    pub id: String,
    pub project_id: String,
    pub name: String,
    #[serde(default)]
    pub name_source: ConversationNameSource,
    #[typeshare(serialized_as = "U53")]
    pub created_at: u64,
    /// Most recent durable event in this conversation. Older metadata does not
    /// contain this field, so readers fall back to `created_at` when it is zero.
    #[serde(default)]
    #[typeshare(serialized_as = "U53")]
    pub last_activity_at: u64,
}

impl KiboConversation {
    pub fn activity_at(&self) -> u64 {
        self.last_activity_at.max(self.created_at)
    }
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConversationNameSource {
    Placeholder,
    Transcript,
    #[default]
    Manual,
    Ai,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateNamed {
    pub name: String,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateConversation {
    #[serde(default)]
    pub name: Option<String>,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateTurn {
    pub turn_id: String,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct EventsQuery {
    #[serde(default)]
    #[typeshare(serialized_as = "U53")]
    pub after: u64,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpeechQuery {
    #[serde(default)]
    #[typeshare(serialized_as = "U53")]
    pub from_sample: usize,
}

/// A durable conversation event sent both as an HTTP JSON object and as one
/// JSON object per WebSocket text frame. The log accepts new event kinds over
/// time, so `kind` remains a string and kind-specific fields are optional.
#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KiboEvent {
    #[typeshare(serialized_as = "U53")]
    pub seq: u64,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[typeshare(serialized_as = "Option<U53>")]
    pub at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub clip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub clips: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answers: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[typeshare(serialized_as = "Option<U53>")]
    pub ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub peak: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[typeshare(serialized_as = "Option<U53>")]
    pub recorded_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interaction_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[typeshare(serialized_as = "Option<U53>")]
    pub samples: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rate: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovered: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectsEnvelope {
    pub projects: Vec<KiboProject>,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConversationsEnvelope {
    pub conversations: Vec<KiboConversation>,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EventsEnvelope {
    pub events: Vec<KiboEvent>,
    #[typeshare(serialized_as = "U53")]
    pub latest_seq: u64,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PutClipResponse {
    pub clip_id: String,
    pub created: bool,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PutRecordingPartResponse {
    pub recording_id: String,
    pub sequence: u32,
    pub created: bool,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompleteRecording {
    pub part_count: u32,
    #[typeshare(serialized_as = "U53")]
    pub total_samples: u64,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompleteRecordingResponse {
    pub clip_id: String,
    pub created: bool,
}

#[typeshare(swift = "Hashable, Sendable")]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnResponse {
    pub turn_id: String,
    pub clips: Vec<String>,
    pub created: bool,
}

pub fn epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 100
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

pub fn make_id(name: &str) -> String {
    let mut slug = name
        .to_ascii_lowercase()
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character
            } else {
                '-'
            }
        })
        .collect::<String>()
        .split('-')
        .filter(|part| !part.is_empty())
        .take(5)
        .collect::<Vec<_>>()
        .join("-");
    // Leave room for the hyphen and eight-character UUID suffix. Since the
    // slug only contains ASCII, truncating by byte cannot split a character.
    slug.truncate(91);
    let slug = slug.trim_end_matches('-');
    let slug = if slug.is_empty() { "untitled" } else { slug };
    let suffix = &uuid::Uuid::new_v4().simple().to_string()[..8];
    format!("{slug}-{suffix}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_ids_always_pass_validation() {
        for name in ["", &"a".repeat(100), "---", "hello, world"] {
            assert!(valid_id(&make_id(name)));
        }
    }

    #[test]
    fn old_conversations_default_to_manual_names() {
        let conversation: KiboConversation = serde_json::from_value(serde_json::json!({
            "id": "general",
            "project_id": "kibo",
            "name": "General",
            "created_at": 1
        }))
        .unwrap();
        assert_eq!(conversation.name_source, ConversationNameSource::Manual);
        assert_eq!(conversation.last_activity_at, 0);
        assert_eq!(conversation.activity_at(), 1);
    }
}

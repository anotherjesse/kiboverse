use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub created_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Conversation {
    pub id: String,
    pub project_id: String,
    pub name: String,
    #[serde(default)]
    pub name_source: ConversationNameSource,
    pub created_at: u64,
    /// Most recent durable event in this conversation. Older metadata does not
    /// contain this field, so readers fall back to `created_at` when it is zero.
    #[serde(default)]
    pub last_activity_at: u64,
}

impl Conversation {
    pub fn activity_at(&self) -> u64 {
        self.last_activity_at.max(self.created_at)
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConversationNameSource {
    Placeholder,
    Transcript,
    #[default]
    Manual,
    Ai,
}

#[derive(Debug, Deserialize)]
pub struct CreateNamed {
    pub name: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct CreateConversation {
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CreateTurn {
    pub turn_id: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct EventsQuery {
    #[serde(default)]
    pub after: u64,
}

#[derive(Debug, Deserialize, Default)]
pub struct SpeechQuery {
    #[serde(default)]
    pub from_sample: usize,
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
        let conversation: Conversation = serde_json::from_value(serde_json::json!({
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

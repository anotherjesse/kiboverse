use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use futures_util::StreamExt;
use serde_json::{Value, json};
use std::f32::consts::TAU;
use std::fmt;
use std::time::Duration;
use tokio::sync::mpsc;

const INTERACTIONS_URL: &str = "https://generativelanguage.googleapis.com/v1beta/interactions";
const GEMINI_MODEL: &str = "gemini-3.5-flash";
const TTS_MODEL: &str = "gemini-3.1-flash-tts-preview";
const TTS_VOICE: &str = "Kore";
const PERSONA: &str = "You are kibo, a small robot voice companion. You hear \
transcribed voice notes and reply out loud through a speaker. Keep replies \
short and conversational - one to three sentences, easy to listen to.";

pub const TTS_RATE: u32 = 24_000;

/// One completed exchange reconstructed from the durable conversation log.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryTurn {
    pub user: String,
    pub assistant: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatReply {
    pub text: String,
    /// Save this with the reply. It is a latency optimization only: `chat`
    /// falls back to `HistoryTurn`s if it is absent or no longer accepted.
    pub interaction_id: Option<String>,
}

#[derive(Clone)]
pub struct Ai {
    client: reqwest::Client,
    api_key: Option<String>,
    mock: bool,
}

impl Ai {
    /// Missing credentials deliberately select mock mode, which keeps a new
    /// checkout and the browser UI useful without configuration.
    pub fn from_env() -> Self {
        let api_key = std::env::var("GEMINI_API_KEY")
            .ok()
            .map(|key| key.trim().to_owned())
            .filter(|key| !key.is_empty());
        let mock_requested =
            std::env::var("KIBO_AI_MODE").is_ok_and(|mode| mode.eq_ignore_ascii_case("mock"));
        Self {
            client: reqwest::Client::new(),
            mock: mock_requested || api_key.is_none(),
            api_key,
        }
    }

    pub fn mock() -> Self {
        Self {
            client: reqwest::Client::new(),
            api_key: None,
            mock: true,
        }
    }

    pub fn is_mock(&self) -> bool {
        self.mock
    }

    /// Transcribe an entire WAV file using the interactions API.
    pub async fn transcribe(&self, wav: &[u8]) -> Result<String> {
        if self.mock {
            return Ok("Mock voice transcript".into());
        }
        let body = json!({
            "model": GEMINI_MODEL,
            "input": [
                {
                    "type": "text",
                    "text": "Generate a transcript of the speech. Return only the transcript text. If there is no speech, return [no speech]."
                },
                {
                    "type": "audio",
                    "data": base64::engine::general_purpose::STANDARD.encode(wav),
                    "mime_type": "audio/wav"
                }
            ]
        });
        let response = self.interaction(&body).await?;
        output_text(&response, "transcript")
    }

    /// Continue with Gemini's cached interaction when possible. If that ID
    /// has expired (or otherwise fails), reconstruct the conversation from
    /// durable turns and retry without provider-side state.
    pub async fn chat(
        &self,
        user_text: &str,
        previous_interaction_id: Option<&str>,
        durable_history: &[HistoryTurn],
    ) -> Result<ChatReply> {
        if self.mock {
            return Ok(ChatReply {
                text: format!("I heard you say: {}", user_text.trim()),
                interaction_id: None,
            });
        }

        if let Some(previous) = previous_interaction_id.filter(|id| !id.is_empty()) {
            let body = json!({
                "model": GEMINI_MODEL,
                "input": user_text,
                "previous_interaction_id": previous,
            });
            match self.interaction(&body).await {
                Ok(response) => return chat_reply(&response),
                Err(error) if previous_interaction_rejected(&error) => {}
                Err(error) => return Err(error.context("continue Gemini interaction")),
            }
        }

        let input = durable_prompt(user_text, durable_history);
        let response = self
            .interaction(&json!({"model": GEMINI_MODEL, "input": input}))
            .await
            .context("Gemini chat failed, including durable-history fallback")?;
        chat_reply(&response)
    }

    /// Compile one canonical project source into a durable Markdown note.
    /// Provenance frontmatter is added by the knowledge store after this
    /// returns, so the model only owns the human-readable body.
    pub async fn knowledge_note(
        &self,
        title: &str,
        source_kind: &str,
        source_body: &str,
        instructions: &str,
    ) -> Result<String> {
        if self.mock {
            return Ok(format!(
                "# {title}\n\n## Summary\n\nMock knowledge note generated from a {source_kind} source.\n\n## Source material\n\n{}",
                source_body.trim()
            ));
        }
        let prompt = format!(
            "You maintain a personal knowledge base. Return only the Markdown body for one source note; do not include YAML frontmatter or a fenced code block.\n\nProject instructions:\n{instructions}\n\nSource kind: {source_kind}\nSource title: {title}\n\nCanonical source:\n{source_body}"
        );
        let response = self
            .interaction(&json!({"model": GEMINI_MODEL, "input": prompt}))
            .await
            .context("generate knowledge note")?;
        output_text(&response, "knowledge note")
    }

    /// Start TTS in the background. Each successful receive is the next
    /// contiguous block of 24 kHz mono signed-16 PCM samples. The sender
    /// closes at EOF; a terminal synthesis/parsing failure is sent as `Err`.
    pub fn tts_stream(&self, text: String) -> mpsc::Receiver<Result<Vec<i16>, String>> {
        let (sender, receiver) = mpsc::channel(16);
        if self.mock {
            tokio::spawn(mock_tts(sender));
        } else {
            let ai = self.clone();
            tokio::spawn(async move {
                if let Err(error) = ai.stream_tts(text, &sender).await {
                    let _ = sender.send(Err(format!("{error:#}"))).await;
                }
            });
        }
        receiver
    }

    async fn interaction(&self, body: &Value) -> Result<Value> {
        let key = self
            .api_key
            .as_deref()
            .ok_or_else(|| anyhow!("GEMINI_API_KEY not set"))?;
        let response = self
            .client
            .post(INTERACTIONS_URL)
            .header("x-goog-api-key", key)
            .json(body)
            .timeout(Duration::from_secs(120))
            .send()
            .await
            .context("send Gemini interaction")?;
        let status = response.status();
        let bytes = response.bytes().await.context("read Gemini response")?;
        if !status.is_success() {
            return Err(HttpFailure {
                status,
                body: String::from_utf8_lossy(&bytes).chars().take(500).collect(),
            }
            .into());
        }
        serde_json::from_slice(&bytes).context("invalid JSON from Gemini")
    }

    async fn stream_tts(
        &self,
        text: String,
        sender: &mpsc::Sender<Result<Vec<i16>, String>>,
    ) -> Result<()> {
        let key = self
            .api_key
            .as_deref()
            .ok_or_else(|| anyhow!("GEMINI_API_KEY not set"))?;
        let body = json!({
            "model": TTS_MODEL,
            "input": text,
            "response_format": {"type": "audio"},
            "generation_config": {"speech_config": [{"voice": TTS_VOICE}]},
            "stream": true
        });
        let response = self
            .client
            .post(INTERACTIONS_URL)
            .header("x-goog-api-key", key)
            .json(&body)
            .timeout(Duration::from_secs(300))
            .send()
            .await
            .context("start Gemini TTS")?;
        let status = response.status();
        if !status.is_success() {
            let message = response.text().await.unwrap_or_default();
            bail!(
                "Gemini TTS returned {status}: {}",
                message.chars().take(500).collect::<String>()
            );
        }

        let mut bytes = response.bytes_stream();
        let mut lines = Vec::<u8>::new();
        let mut odd_byte = None;
        let mut produced = false;
        loop {
            let next = tokio::time::timeout(Duration::from_secs(30), bytes.next())
                .await
                .context("Gemini TTS stream was idle for 30 seconds")?;
            let Some(chunk) = next else { break };
            lines.extend_from_slice(&chunk.context("read Gemini TTS stream")?);
            while let Some(newline) = lines.iter().position(|byte| *byte == b'\n') {
                let mut line = lines.drain(..=newline).collect::<Vec<_>>();
                while matches!(line.last(), Some(b'\n' | b'\r')) {
                    line.pop();
                }
                match parse_audio_event(&line, &mut odd_byte)? {
                    AudioEvent::Samples(samples) if !samples.is_empty() => {
                        produced = true;
                        if sender.send(Ok(samples)).await.is_err() {
                            return Ok(()); // HTTP client stopped listening
                        }
                    }
                    AudioEvent::Done => {
                        if !produced {
                            bail!("Gemini TTS stream produced no audio");
                        }
                        return Ok(());
                    }
                    _ => {}
                }
            }
        }

        if !lines.is_empty()
            && let AudioEvent::Samples(samples) = parse_audio_event(&lines, &mut odd_byte)?
            && !samples.is_empty()
        {
            produced = true;
            let _ = sender.send(Ok(samples)).await;
        }
        if odd_byte.is_some() {
            bail!("Gemini TTS stream ended midway through a PCM sample");
        }
        if !produced {
            bail!("Gemini TTS stream produced no audio");
        }
        Ok(())
    }
}

#[derive(Debug)]
struct HttpFailure {
    status: reqwest::StatusCode,
    body: String,
}

impl fmt::Display for HttpFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "Gemini returned {}: {}", self.status, self.body)
    }
}

impl std::error::Error for HttpFailure {}

fn previous_interaction_rejected(error: &anyhow::Error) -> bool {
    error.downcast_ref::<HttpFailure>().is_some_and(|failure| {
        failure.status == reqwest::StatusCode::BAD_REQUEST
            && failure
                .body
                .to_ascii_lowercase()
                .contains("previous_interaction")
    })
}

enum AudioEvent {
    Ignore,
    Done,
    Samples(Vec<i16>),
}

fn parse_audio_event(line: &[u8], odd_byte: &mut Option<u8>) -> Result<AudioEvent> {
    let Some(payload) = line.strip_prefix(b"data:") else {
        return Ok(AudioEvent::Ignore);
    };
    let payload = payload.strip_prefix(b" ").unwrap_or(payload);
    if payload == b"[DONE]" {
        return Ok(AudioEvent::Done);
    }
    let value: Value = match serde_json::from_slice(payload) {
        Ok(value) => value,
        // Ignore SSE keepalive/metadata lines, but malformed audio events are
        // surfaced once they identify themselves as audio below.
        Err(_) => return Ok(AudioEvent::Ignore),
    };
    let Some(encoded) = value["delta"]["data"]
        .as_str()
        .filter(|_| value["delta"]["type"] == "audio")
    else {
        return Ok(AudioEvent::Ignore);
    };
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .context("invalid base64 in Gemini TTS audio delta")?;
    let mut samples = Vec::with_capacity((decoded.len() + usize::from(odd_byte.is_some())) / 2);
    let mut data = decoded.as_slice();
    if let Some(low) = odd_byte.take() {
        if let Some((&high, rest)) = data.split_first() {
            samples.push(i16::from_le_bytes([low, high]));
            data = rest;
        } else {
            *odd_byte = Some(low);
            return Ok(AudioEvent::Ignore);
        }
    }
    samples.extend(
        data.chunks_exact(2)
            .map(|pair| i16::from_le_bytes([pair[0], pair[1]])),
    );
    if data.len() % 2 == 1 {
        *odd_byte = data.last().copied();
    }
    Ok(AudioEvent::Samples(samples))
}

fn output_text(response: &Value, purpose: &str) -> Result<String> {
    let text = response["steps"]
        .as_array()
        .and_then(|steps| steps.iter().find(|step| step["type"] == "model_output"))
        .and_then(|step| step["content"].as_array())
        .and_then(|content| content.first())
        .and_then(|content| content["text"].as_str())
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned);
    text.ok_or_else(|| {
        anyhow!(
            "no {purpose} text in Gemini response: {}",
            response.to_string().chars().take(300).collect::<String>()
        )
    })
}

fn chat_reply(response: &Value) -> Result<ChatReply> {
    Ok(ChatReply {
        text: output_text(response, "reply")?,
        interaction_id: response["id"]
            .as_str()
            .filter(|id| !id.is_empty())
            .map(str::to_owned),
    })
}

fn durable_prompt(user_text: &str, history: &[HistoryTurn]) -> String {
    let mut prompt = String::from(PERSONA);
    if !history.is_empty() {
        prompt.push_str("\n\nConversation so far:\n");
        for turn in history {
            prompt.push_str("User: ");
            prompt.push_str(turn.user.trim());
            prompt.push_str("\nKibo: ");
            prompt.push_str(turn.assistant.trim());
            prompt.push('\n');
        }
    }
    prompt.push_str("\nUser: ");
    prompt.push_str(user_text.trim());
    prompt.push_str("\nKibo:");
    prompt
}

async fn mock_tts(sender: mpsc::Sender<Result<Vec<i16>, String>>) {
    // A short two-tone acknowledgement makes the streaming/playback path
    // audibly testable without pretending mock mode can synthesize speech.
    const CHUNK: usize = 2_400; // 100 ms
    const SAMPLE_COUNT: usize = TTS_RATE as usize * 3 / 5;
    for start in (0..SAMPLE_COUNT).step_by(CHUNK) {
        let end = (start + CHUNK).min(SAMPLE_COUNT);
        let samples = (start..end)
            .map(|index| {
                let seconds = index as f32 / TTS_RATE as f32;
                let frequency = if seconds < 0.3 { 440.0 } else { 554.37 };
                let envelope = (1.0 - index as f32 / SAMPLE_COUNT as f32).min(0.25) * 4.0;
                (TAU * frequency * seconds)
                    .sin()
                    .mul_add(5_000.0 * envelope, 0.0) as i16
            })
            .collect();
        if sender.send(Ok(samples)).await.is_err() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(35)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durable_history_is_included_in_fallback_prompt() {
        let prompt = durable_prompt(
            "new question",
            &[HistoryTurn {
                user: "old question".into(),
                assistant: "old answer".into(),
            }],
        );
        assert!(prompt.starts_with(PERSONA));
        assert!(prompt.contains("User: old question\nKibo: old answer"));
        assert!(prompt.ends_with("User: new question\nKibo:"));
    }

    #[test]
    fn audio_parser_carries_split_samples_between_events() {
        let mut odd = None;
        let first = br#"data: {"delta":{"type":"audio","data":"AQ=="}}"#;
        let second = br#"data: {"delta":{"type":"audio","data":"AgME"}}"#;
        assert!(matches!(
            parse_audio_event(first, &mut odd).unwrap(),
            AudioEvent::Samples(samples) if samples.is_empty()
        ));
        assert_eq!(odd, Some(1));
        assert!(matches!(
            parse_audio_event(second, &mut odd).unwrap(),
            AudioEvent::Samples(samples) if samples == vec![513, 1027]
        ));
        assert_eq!(odd, None);
    }
}

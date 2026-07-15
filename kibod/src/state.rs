use crate::ai::{Ai, HistoryTurn, TTS_RATE};
use crate::store::{AutoNameOutcome, Store};
use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{broadcast, watch};

#[derive(Clone)]
pub struct AppState {
    inner: Arc<Inner>,
}

struct Inner {
    pub store: Store,
    pub ai: Ai,
    channels: Mutex<HashMap<String, broadcast::Sender<Value>>>,
    speech: Mutex<HashMap<String, Arc<SpeechStream>>>,
    transcribing: Mutex<HashSet<String>>,
    processing_conversations: Mutex<HashSet<String>>,
}

pub struct SpeechStream {
    samples: Mutex<Vec<i16>>,
    done: Mutex<bool>,
    error: Mutex<Option<String>>,
    changed: watch::Sender<u64>,
}

impl Default for SpeechStream {
    fn default() -> Self {
        Self {
            samples: Mutex::new(Vec::new()),
            done: Mutex::new(false),
            error: Mutex::new(None),
            changed: watch::channel(0).0,
        }
    }
}

impl SpeechStream {
    pub fn snapshot(&self, from: usize) -> (Vec<i16>, bool, Option<String>) {
        let samples = self.samples.lock().unwrap();
        let available = samples.get(from..).unwrap_or_default().to_vec();
        (
            available,
            *self.done.lock().unwrap(),
            self.error.lock().unwrap().clone(),
        )
    }

    pub fn changes(&self) -> watch::Receiver<u64> {
        self.changed.subscribe()
    }

    fn push(&self, samples: &[i16]) {
        self.samples.lock().unwrap().extend_from_slice(samples);
        self.changed
            .send_modify(|version| *version = version.wrapping_add(1));
    }

    fn finish(&self, error: Option<String>) {
        *self.error.lock().unwrap() = error;
        *self.done.lock().unwrap() = true;
        self.changed
            .send_modify(|version| *version = version.wrapping_add(1));
    }

    fn all_samples(&self) -> Vec<i16> {
        self.samples.lock().unwrap().clone()
    }
}

impl AppState {
    pub fn new(store: Store, ai: Ai) -> Self {
        Self {
            inner: Arc::new(Inner {
                store,
                ai,
                channels: Mutex::new(HashMap::new()),
                speech: Mutex::new(HashMap::new()),
                transcribing: Mutex::new(HashSet::new()),
                processing_conversations: Mutex::new(HashSet::new()),
            }),
        }
    }

    pub fn store(&self) -> &Store {
        &self.inner.store
    }

    pub fn ai(&self) -> &Ai {
        &self.inner.ai
    }

    pub fn subscribe(&self, project_id: &str, conversation_id: &str) -> broadcast::Receiver<Value> {
        self.channel(project_id, conversation_id).subscribe()
    }

    pub fn publish(&self, project_id: &str, conversation_id: &str, event: Value) {
        let _ = self.channel(project_id, conversation_id).send(event);
    }

    pub fn append(&self, project_id: &str, conversation_id: &str, event: Value) -> Result<Value> {
        let event = self
            .inner
            .store
            .append(project_id, conversation_id, event)?;
        self.publish(project_id, conversation_id, event.clone());
        Ok(event)
    }

    fn auto_name_conversation(&self, project_id: &str, conversation_id: &str) {
        match self
            .inner
            .store
            .auto_name_from_transcript(project_id, conversation_id)
        {
            Ok(AutoNameOutcome::Named(conversation)) => {
                if let Err(error) = self.append(
                    project_id,
                    conversation_id,
                    json!({
                        "kind": "conversation_renamed",
                        "name": conversation.name,
                        "source": "transcript"
                    }),
                ) {
                    tracing::error!(%project_id, %conversation_id, "record automatic conversation name: {error:#}");
                }
            }
            Ok(AutoNameOutcome::Unchanged(_)) => {}
            Err(error) => {
                tracing::error!(%project_id, %conversation_id, "name conversation from transcript: {error:#}");
            }
        }
    }

    pub fn speech(
        &self,
        project_id: &str,
        conversation_id: &str,
        turn_id: &str,
    ) -> Option<Arc<SpeechStream>> {
        self.inner
            .speech
            .lock()
            .unwrap()
            .get(&key3(project_id, conversation_id, turn_id))
            .cloned()
    }

    pub fn start_transcription(
        &self,
        project_id: String,
        conversation_id: String,
        clip_id: String,
    ) {
        let key = key3(&project_id, &conversation_id, &clip_id);
        if !self.inner.transcribing.lock().unwrap().insert(key.clone()) {
            return;
        }
        let state = self.clone();
        tokio::spawn(async move {
            let result = state
                .transcribe(&project_id, &conversation_id, &clip_id)
                .await;
            if let Err(error) = result {
                tracing::error!(%project_id, %conversation_id, %clip_id, "transcription: {error:#}");
                let _ = state.append(
                    &project_id,
                    &conversation_id,
                    json!({"kind":"transcript_error", "clip":clip_id, "error":format!("{error:#}")}),
                );
            }
            state.inner.transcribing.lock().unwrap().remove(&key);
        });
    }

    async fn transcribe(
        &self,
        project_id: &str,
        conversation_id: &str,
        clip_id: &str,
    ) -> Result<()> {
        let records = self.inner.store.records(project_id, conversation_id)?;
        if records
            .iter()
            .any(|event| event["kind"] == "transcript" && event["clip"] == clip_id)
        {
            self.auto_name_conversation(project_id, conversation_id);
            return Ok(());
        }
        let clip = records
            .iter()
            .find(|event| event["kind"] == "clip" && event["id"] == clip_id)
            .ok_or_else(|| anyhow!("clip event is missing"))?;
        if clip["peak"].as_u64() == Some(0) {
            self.append(
                project_id,
                conversation_id,
                json!({"kind":"transcript", "clip":clip_id, "text":"[silent]"}),
            )?;
            self.auto_name_conversation(project_id, conversation_id);
            return Ok(());
        }
        let wav = tokio::fs::read(self.inner.store.clip_path(
            project_id,
            conversation_id,
            clip_id,
        )?)
        .await?;
        let text = self.inner.ai.transcribe(&wav).await?;
        self.append(
            project_id,
            conversation_id,
            json!({"kind":"transcript", "clip":clip_id, "text":text}),
        )?;
        self.auto_name_conversation(project_id, conversation_id);
        Ok(())
    }

    pub fn start_turn(&self, project_id: String, conversation_id: String, _turn_id: String) {
        let key = format!("{project_id}/{conversation_id}");
        if !self
            .inner
            .processing_conversations
            .lock()
            .unwrap()
            .insert(key.clone())
        {
            return;
        }
        let state = self.clone();
        tokio::spawn(async move {
            let drained = state.drain_turns(&project_id, &conversation_id).await;
            state
                .inner
                .processing_conversations
                .lock()
                .unwrap()
                .remove(&key);
            if drained && state.conversation_has_work(&project_id, &conversation_id) {
                state.start_turn(project_id, conversation_id, String::new());
            }
        });
    }

    async fn drain_turns(&self, project_id: &str, conversation_id: &str) -> bool {
        let mut attempted = HashSet::new();
        loop {
            let records = match self.inner.store.records(project_id, conversation_id) {
                Ok(records) => records,
                Err(error) => {
                    tracing::error!(%project_id, %conversation_id, "read turns: {error:#}");
                    return false;
                }
            };
            let next = records
                .iter()
                .filter(|event| event["kind"] == "turn")
                .filter_map(|event| event["id"].as_str())
                .find(|turn_id| !attempted.contains(*turn_id))
                .map(str::to_string);
            let Some(turn_id) = next else {
                return true;
            };
            attempted.insert(turn_id.clone());
            if let Err(error) = self
                .process_turn(project_id, conversation_id, &turn_id)
                .await
            {
                tracing::error!(%project_id, %conversation_id, %turn_id, "turn: {error:#}");
                let _ = self.append(
                    project_id,
                    conversation_id,
                    json!({"kind":"reply_error", "turn":turn_id, "error":format!("{error:#}")}),
                );
                return false;
            }
        }
    }

    fn conversation_has_work(&self, project_id: &str, conversation_id: &str) -> bool {
        let Ok(records) = self.inner.store.records(project_id, conversation_id) else {
            return false;
        };
        records
            .iter()
            .filter(|event| event["kind"] == "turn")
            .filter_map(|event| event["id"].as_str())
            .any(|turn_id| {
                !records
                    .iter()
                    .any(|event| event["kind"] == "reply" && event["turn"] == turn_id)
            })
    }

    async fn process_turn(
        &self,
        project_id: &str,
        conversation_id: &str,
        turn_id: &str,
    ) -> Result<()> {
        let initial = self.inner.store.records(project_id, conversation_id)?;
        if let Some(reply) = initial
            .iter()
            .find(|event| event["kind"] == "reply" && event["turn"] == turn_id)
        {
            if let (Some(text), Some(_audio)) = (reply["text"].as_str(), reply["audio"].as_str())
                && !text.starts_with('[')
            {
                self.synthesize_reply(project_id, conversation_id, turn_id, text)
                    .await?;
            }
            return Ok(());
        }
        let clip_ids: Vec<String> = initial
            .iter()
            .find(|event| event["kind"] == "turn" && event["id"] == turn_id)
            .and_then(|event| event["clips"].as_array())
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect();
        if clip_ids.is_empty() {
            return Err(anyhow!("turn has no clips"));
        }

        let records = loop {
            let records = self.inner.store.records(project_id, conversation_id)?;
            let complete = clip_ids.iter().all(|clip_id| {
                records.iter().any(|event| {
                    matches!(
                        event["kind"].as_str(),
                        Some("transcript" | "transcript_error")
                    ) && event["clip"] == clip_id.as_str()
                })
            });
            let retry_in_flight = clip_ids.iter().any(|clip_id| {
                self.inner.transcribing.lock().unwrap().contains(&key3(
                    project_id,
                    conversation_id,
                    clip_id,
                ))
            });
            if complete && !retry_in_flight {
                break records;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        };
        if clip_ids.iter().any(|clip_id| {
            !records
                .iter()
                .any(|event| event["kind"] == "transcript" && event["clip"] == clip_id.as_str())
        }) {
            return Err(anyhow!(
                "one or more claimed clips have no successful transcript"
            ));
        }
        let user_text = clip_ids
            .iter()
            .filter_map(|clip_id| {
                records.iter().find(|event| {
                    event["kind"] == "transcript" && event["clip"] == clip_id.as_str()
                })
            })
            .filter_map(|event| event["text"].as_str())
            .filter(|text| !matches!(*text, "" | "[silent]" | "[no speech]"))
            .collect::<Vec<_>>()
            .join("\n");
        if user_text.is_empty() {
            self.append(
                project_id,
                conversation_id,
                json!({"kind":"reply", "turn":turn_id, "text":"[nothing to answer]", "answers":clip_ids}),
            )?;
            return Ok(());
        }

        let (history, previous_interaction_id) = history_before(&records, turn_id);
        let reply = self
            .inner
            .ai
            .chat(&user_text, previous_interaction_id.as_deref(), &history)
            .await?;

        let stream = Arc::new(SpeechStream::default());
        self.inner
            .speech
            .lock()
            .unwrap()
            .insert(key3(project_id, conversation_id, turn_id), stream.clone());
        if let Err(error) = self.append(
            project_id,
            conversation_id,
            json!({
                "kind":"reply", "turn":turn_id, "text":reply.text,
                "answers":clip_ids, "audio":format!("tts/{turn_id}.wav"),
                "interaction_id":reply.interaction_id
            }),
        ) {
            stream.finish(Some(error.to_string()));
            self.inner
                .speech
                .lock()
                .unwrap()
                .remove(&key3(project_id, conversation_id, turn_id));
            return Err(error);
        }

        self.synthesize_into(project_id, conversation_id, turn_id, reply.text, stream)
            .await
    }

    async fn synthesize_reply(
        &self,
        project_id: &str,
        conversation_id: &str,
        turn_id: &str,
        text: &str,
    ) -> Result<()> {
        let path = self
            .inner
            .store
            .speech_path(project_id, conversation_id, turn_id)?;
        if path.exists() {
            match hound::WavReader::open(&path) {
                Ok(reader) => {
                    let records = self.inner.store.records(project_id, conversation_id)?;
                    if !records
                        .iter()
                        .any(|event| event["kind"] == "speech_ready" && event["turn"] == turn_id)
                    {
                        self.append(
                            project_id,
                            conversation_id,
                            json!({"kind":"speech_ready", "turn":turn_id, "samples":reader.duration(), "rate":TTS_RATE, "recovered":true}),
                        )?;
                    }
                    return Ok(());
                }
                Err(error) => {
                    tracing::warn!(%project_id, %conversation_id, %turn_id, "replacing corrupt speech file: {error}");
                    std::fs::remove_file(&path)?;
                }
            }
        }
        let stream = Arc::new(SpeechStream::default());
        self.inner
            .speech
            .lock()
            .unwrap()
            .insert(key3(project_id, conversation_id, turn_id), stream.clone());
        self.synthesize_into(
            project_id,
            conversation_id,
            turn_id,
            text.to_string(),
            stream,
        )
        .await
    }

    async fn synthesize_into(
        &self,
        project_id: &str,
        conversation_id: &str,
        turn_id: &str,
        text: String,
        stream: Arc<SpeechStream>,
    ) -> Result<()> {
        let speech_key = key3(project_id, conversation_id, turn_id);
        let mut receiver = self.inner.ai.tts_stream(text);
        while let Some(chunk) = receiver.recv().await {
            match chunk {
                Ok(samples) => stream.push(&samples),
                Err(error) => {
                    stream.finish(Some(error.clone()));
                    self.inner.speech.lock().unwrap().remove(&speech_key);
                    self.append(
                        project_id,
                        conversation_id,
                        json!({"kind":"tts_error", "turn":turn_id, "error":error}),
                    )?;
                    return Ok(());
                }
            }
        }
        let samples = stream.all_samples();
        if samples.is_empty() {
            stream.finish(Some("TTS produced no audio".into()));
            self.inner.speech.lock().unwrap().remove(&speech_key);
            self.append(
                project_id,
                conversation_id,
                json!({"kind":"tts_error", "turn":turn_id, "error":"TTS produced no audio"}),
            )?;
            return Ok(());
        }
        if let Err(error) = save_wav(
            &self
                .inner
                .store
                .speech_path(project_id, conversation_id, turn_id)?,
            &samples,
        ) {
            let message = format!("failed to save synthesized speech: {error:#}");
            stream.finish(Some(message.clone()));
            self.inner.speech.lock().unwrap().remove(&speech_key);
            self.append(
                project_id,
                conversation_id,
                json!({"kind":"tts_error", "turn":turn_id, "error":message}),
            )?;
            return Ok(());
        }
        stream.finish(None);
        let result = self.append(
            project_id,
            conversation_id,
            json!({"kind":"speech_ready", "turn":turn_id, "samples":samples.len(), "rate":TTS_RATE}),
        );
        self.inner.speech.lock().unwrap().remove(&speech_key);
        result?;
        Ok(())
    }

    pub fn resume(&self) -> Result<()> {
        for (project_id, conversation_id) in self.inner.store.conversation_keys()? {
            if let Err(error) = self.resume_conversation(&project_id, &conversation_id) {
                tracing::error!(%project_id, %conversation_id, "could not resume conversation: {error:#}");
            }
        }
        Ok(())
    }

    fn resume_conversation(&self, project_id: &str, conversation_id: &str) -> Result<()> {
        for clip_id in self
            .inner
            .store
            .untranscribed(project_id, conversation_id)?
        {
            self.start_transcription(project_id.into(), conversation_id.into(), clip_id);
        }
        let records = self.inner.store.records(project_id, conversation_id)?;
        for turn_id in records
            .iter()
            .filter(|event| event["kind"] == "turn")
            .filter_map(|event| event["id"].as_str())
        {
            self.start_turn(project_id.into(), conversation_id.into(), turn_id.into());
        }
        Ok(())
    }

    fn channel(&self, project_id: &str, conversation_id: &str) -> broadcast::Sender<Value> {
        let key = format!("{project_id}/{conversation_id}");
        self.inner
            .channels
            .lock()
            .unwrap()
            .entry(key)
            .or_insert_with(|| broadcast::channel(128).0)
            .clone()
    }
}

fn history_before(records: &[Value], current_turn: &str) -> (Vec<HistoryTurn>, Option<String>) {
    let transcripts: HashMap<&str, &str> = records
        .iter()
        .filter(|event| event["kind"] == "transcript")
        .filter_map(|event| Some((event["clip"].as_str()?, event["text"].as_str()?)))
        .collect();
    let replies: HashMap<&str, &Value> = records
        .iter()
        .filter(|event| event["kind"] == "reply")
        .filter_map(|event| Some((event["turn"].as_str()?, event)))
        .collect();
    let mut history = Vec::new();
    let mut previous_interaction_id = None;
    for turn in records.iter().filter(|event| event["kind"] == "turn") {
        let Some(turn_id) = turn["id"].as_str() else {
            continue;
        };
        if turn_id == current_turn {
            break;
        }
        let Some(reply) = replies.get(turn_id) else {
            continue;
        };
        let user = turn["clips"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .filter_map(|clip_id| transcripts.get(clip_id).copied())
            .collect::<Vec<_>>()
            .join("\n");
        let assistant = reply["text"].as_str().unwrap_or_default().to_string();
        if !user.is_empty() && !assistant.is_empty() {
            history.push(HistoryTurn { user, assistant });
        }
        if let Some(id) = reply["interaction_id"].as_str().filter(|id| !id.is_empty()) {
            previous_interaction_id = Some(id.to_string());
        }
    }
    (history, previous_interaction_id)
}

fn save_wav(path: &Path, samples: &[i16]) -> Result<()> {
    let temporary = path.with_extension("wav.part");
    let specification = hound::WavSpec {
        channels: 1,
        sample_rate: TTS_RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(&temporary, specification)?;
    for sample in samples {
        writer.write_sample(*sample)?;
    }
    writer.finalize()?;
    std::fs::OpenOptions::new()
        .read(true)
        .open(&temporary)?
        .sync_all()?;
    std::fs::rename(temporary, path).with_context(|| format!("save speech {}", path.display()))?;
    if let Some(parent) = path.parent() {
        std::fs::File::open(parent)?.sync_all()?;
    }
    Ok(())
}

fn key3(project_id: &str, conversation_id: &str, item_id: &str) -> String {
    format!("{project_id}/{conversation_id}/{item_id}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{ClipUpload, CreateTurnOutcome, hex_sha256};

    #[test]
    fn history_uses_durable_turns_and_latest_provider_id() {
        let records = vec![
            json!({"kind":"clip","id":"c1"}),
            json!({"kind":"transcript","clip":"c1","text":"hello"}),
            json!({"kind":"turn","id":"t1","clips":["c1"]}),
            json!({"kind":"reply","turn":"t1","text":"hi","interaction_id":"provider-1"}),
            json!({"kind":"turn","id":"t2","clips":["c2"]}),
        ];
        let (history, previous) = history_before(&records, "t2");
        assert_eq!(
            history,
            vec![HistoryTurn {
                user: "hello".into(),
                assistant: "hi".into()
            }]
        );
        assert_eq!(previous.as_deref(), Some("provider-1"));
    }

    #[tokio::test]
    async fn mock_pipeline_reaches_durable_speech() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let wav = b"RIFF0000WAVE mock";
        let sha = hex_sha256(wav);
        store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id: "general",
                clip_id: "clip-1",
                bytes: wav,
                expected_sha256: &sha,
                duration_ms: 800,
                peak_pct: 20,
                recorded_at: 1,
            })
            .unwrap();
        let state = AppState::new(store.clone(), Ai::mock());
        state.start_transcription("kibo".into(), "general".into(), "clip-1".into());
        let outcome = store.create_turn("kibo", "general", "turn-1").unwrap();
        assert!(matches!(outcome, CreateTurnOutcome::Created { .. }));
        state.start_turn("kibo".into(), "general".into(), "turn-1".into());

        wait_for_event(&store, "speech_ready").await;
        let records = store.records("kibo", "general").unwrap();
        assert!(records.iter().any(|event| event["kind"] == "reply"));
        assert!(
            store
                .speech_path("kibo", "general", "turn-1")
                .unwrap()
                .exists()
        );
    }

    #[tokio::test]
    async fn resume_synthesizes_a_reply_left_without_speech() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        store
            .append(
                "kibo",
                "general",
                json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            )
            .unwrap();
        store
            .append(
                "kibo",
                "general",
                json!({"kind":"reply", "turn":"turn-1", "text":"Recovered reply", "audio":"tts/turn-1.wav"}),
            )
            .unwrap();
        let state = AppState::new(store.clone(), Ai::mock());
        state.resume().unwrap();

        wait_for_event(&store, "speech_ready").await;
        assert!(
            store
                .speech_path("kibo", "general", "turn-1")
                .unwrap()
                .exists()
        );
    }

    #[tokio::test]
    async fn conversation_worker_uses_durable_turn_order() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        for (clip, turn, text) in [
            ("clip-1", "turn-1", "first"),
            ("clip-2", "turn-2", "second"),
        ] {
            store
                .append("kibo", "general", json!({"kind":"clip", "id":clip}))
                .unwrap();
            store
                .append(
                    "kibo",
                    "general",
                    json!({"kind":"transcript", "clip":clip, "text":text}),
                )
                .unwrap();
            store
                .append(
                    "kibo",
                    "general",
                    json!({"kind":"turn", "id":turn, "clips":[clip]}),
                )
                .unwrap();
        }
        let state = AppState::new(store.clone(), Ai::mock());
        // Even a later turn winning the request race cannot overtake the log.
        state.start_turn("kibo".into(), "general".into(), "turn-2".into());
        state.start_turn("kibo".into(), "general".into(), "turn-1".into());
        wait_for_event_count(&store, "speech_ready", 2).await;
        let replies: Vec<_> = store
            .records("kibo", "general")
            .unwrap()
            .into_iter()
            .filter(|event| event["kind"] == "reply")
            .filter_map(|event| event["turn"].as_str().map(str::to_string))
            .collect();
        assert_eq!(replies, ["turn-1", "turn-2"]);
    }

    async fn wait_for_event(store: &Store, kind: &str) {
        wait_for_event_count(store, kind, 1).await;
    }

    async fn wait_for_event_count(store: &Store, kind: &str, count: usize) {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if store
                    .records("kibo", "general")
                    .unwrap()
                    .iter()
                    .filter(|event| event["kind"] == kind)
                    .count()
                    >= count
                {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();
    }
}

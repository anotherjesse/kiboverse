use crate::agentic::{CodexKnowledgeAgent, QueryEvent, RunningQuery};
use crate::ai::{Ai, HistoryTurn, TTS_RATE};
use crate::knowledge::{self, Document, IngestReceipt, JinaReader, ReaderDocument, WebSource};
use crate::model::{epoch, make_id};
use crate::store::{AutoNameOutcome, Store};
use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard, broadcast, watch};

const MAX_QUERY_THREADS: usize = 128;

#[derive(Clone)]
pub struct AppState {
    inner: Arc<Inner>,
}

struct Inner {
    pub store: Store,
    pub ai: Ai,
    jina: JinaReader,
    channels: Mutex<HashMap<String, broadcast::Sender<Value>>>,
    speech: Mutex<HashMap<String, Arc<SpeechStream>>>,
    transcribing: Mutex<HashSet<String>>,
    processing_conversations: Mutex<HashSet<String>>,
    knowledge_locks: Mutex<HashMap<String, Arc<AsyncMutex<()>>>>,
    knowledge_agent: CodexKnowledgeAgent,
    query_threads: Mutex<HashMap<String, QueryThread>>,
}

#[derive(Clone)]
struct QueryThread {
    project_id: String,
    app_server_id: String,
    lock: Arc<AsyncMutex<()>>,
    last_used_at: u64,
}

pub struct KnowledgeQuery {
    query_id: String,
    running: RunningQuery,
    _thread_guard: OwnedMutexGuard<()>,
    state: Weak<Inner>,
    completed: bool,
}

struct QueryStartupLease {
    query_id: String,
    state: Weak<Inner>,
    armed: bool,
}

impl QueryStartupLease {
    fn new(query_id: &str, state: &Arc<Inner>) -> Self {
        Self {
            query_id: query_id.to_string(),
            state: Arc::downgrade(state),
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for QueryStartupLease {
    fn drop(&mut self) {
        if self.armed {
            remove_query_thread(&self.state, &self.query_id);
        }
    }
}

impl KnowledgeQuery {
    pub fn query_id(&self) -> &str {
        &self.query_id
    }

    pub async fn next_event(&mut self) -> Result<Option<QueryEvent>> {
        let event = self.running.next_event().await;
        match &event {
            Ok(Some(QueryEvent::Completed(_))) => self.completed = true,
            Ok(None) | Err(_) => self.invalidate_continuation(),
            Ok(Some(QueryEvent::Activity { .. } | QueryEvent::Delta(_))) => {}
        }
        event
    }

    fn invalidate_continuation(&self) {
        remove_query_thread(&self.state, &self.query_id);
    }
}

impl Drop for KnowledgeQuery {
    fn drop(&mut self) {
        if !self.completed {
            self.invalidate_continuation();
        }
    }
}

fn remove_query_thread(state: &Weak<Inner>, query_id: &str) {
    if let Some(state) = state.upgrade() {
        // Dropping an HTTP response or startup future must not leave a
        // resumable token for a Codex turn whose final state is unknown. Avoid
        // panicking in Drop if another task poisoned the registry lock.
        match state.query_threads.lock() {
            Ok(mut threads) => {
                threads.remove(query_id);
            }
            Err(poisoned) => {
                poisoned.into_inner().remove(query_id);
            }
        }
    }
}

#[derive(Debug)]
pub struct UnknownQueryThread;

impl std::fmt::Display for UnknownQueryThread {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("query conversation was not found; start a new conversation")
    }
}

impl std::error::Error for UnknownQueryThread {}

#[derive(Debug)]
pub struct QueryThreadBusy;

impl std::fmt::Display for QueryThreadBusy {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("this query conversation already has a turn in progress")
    }
}

impl std::error::Error for QueryThreadBusy {}

pub struct SpeechStream {
    samples: Mutex<Vec<i16>>,
    done: Mutex<bool>,
    error: Mutex<Option<String>>,
    changed: watch::Sender<u64>,
}

#[derive(Debug, Clone)]
pub enum IngestOutcome {
    Ingested(IngestReceipt),
    Skipped,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct IngestSummary {
    pub ingested: usize,
    pub skipped: usize,
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
        Self::with_knowledge_agent(store, ai, CodexKnowledgeAgent::from_env())
    }

    fn with_knowledge_agent(store: Store, ai: Ai, knowledge_agent: CodexKnowledgeAgent) -> Self {
        Self {
            inner: Arc::new(Inner {
                store,
                ai,
                jina: JinaReader::from_env(),
                channels: Mutex::new(HashMap::new()),
                speech: Mutex::new(HashMap::new()),
                transcribing: Mutex::new(HashSet::new()),
                processing_conversations: Mutex::new(HashSet::new()),
                knowledge_locks: Mutex::new(HashMap::new()),
                knowledge_agent,
                query_threads: Mutex::new(HashMap::new()),
            }),
        }
    }

    #[cfg(test)]
    pub fn with_test_knowledge_agent(
        store: Store,
        ai: Ai,
        knowledge_agent: CodexKnowledgeAgent,
    ) -> Self {
        Self::with_knowledge_agent(store, ai, knowledge_agent)
    }

    pub fn store(&self) -> &Store {
        &self.inner.store
    }

    pub fn ai(&self) -> &Ai {
        &self.inner.ai
    }

    pub fn jina_has_api_key(&self) -> bool {
        self.inner.jina.has_api_key()
    }

    pub async fn start_knowledge_query(
        &self,
        project_id: &str,
        question: &str,
        query_id: Option<&str>,
    ) -> Result<KnowledgeQuery> {
        let wiki_root = knowledge::wiki_root(&self.inner.store, project_id)?;
        if let Some(query_id) = query_id {
            let thread = self
                .inner
                .query_threads
                .lock()
                .unwrap()
                .get(query_id)
                .filter(|thread| thread.project_id == project_id)
                .cloned()
                .ok_or_else(|| anyhow!(UnknownQueryThread))?;
            let guard = thread
                .lock
                .clone()
                .try_lock_owned()
                .map_err(|_| anyhow!(QueryThreadBusy))?;
            let mut startup_lease = QueryStartupLease::new(query_id, &self.inner);
            let running = self
                .inner
                .knowledge_agent
                .start(&wiki_root, question, Some(&thread.app_server_id))
                .await?;
            if let Some(thread) = self.inner.query_threads.lock().unwrap().get_mut(query_id) {
                thread.last_used_at = epoch();
            }
            let query = KnowledgeQuery {
                query_id: query_id.to_string(),
                running,
                _thread_guard: guard,
                state: Arc::downgrade(&self.inner),
                completed: false,
            };
            startup_lease.disarm();
            return Ok(query);
        }

        let query_id = make_id("query");
        let lock = Arc::new(AsyncMutex::new(()));
        let guard = lock
            .clone()
            .try_lock_owned()
            .expect("a new query lock is available");
        let running = self
            .inner
            .knowledge_agent
            .start(&wiki_root, question, None)
            .await?;
        let app_server_id = running.app_server_thread_id().to_string();
        let mut threads = self.inner.query_threads.lock().unwrap();
        if threads.len() >= MAX_QUERY_THREADS
            && let Some(oldest) = threads
                .iter()
                .min_by_key(|(_, thread)| thread.last_used_at)
                .map(|(id, _)| id.clone())
        {
            threads.remove(&oldest);
        }
        threads.insert(
            query_id.clone(),
            QueryThread {
                project_id: project_id.to_string(),
                app_server_id,
                lock,
                last_used_at: epoch(),
            },
        );
        drop(threads);
        Ok(KnowledgeQuery {
            query_id,
            running,
            _thread_guard: guard,
            state: Arc::downgrade(&self.inner),
            completed: false,
        })
    }

    pub async fn ingest_changed(&self, project_id: &str) -> Result<IngestSummary> {
        let lock = self.knowledge_lock(project_id);
        let _guard = lock.lock().await;
        let mut summary = IngestSummary::default();
        for conversation in self.inner.store.list_conversations(project_id)? {
            let document =
                knowledge::conversation_document(&self.inner.store, project_id, &conversation.id)?;
            if document.body.trim().is_empty() {
                continue;
            }
            match self.ingest_document(project_id, document, false).await? {
                IngestOutcome::Ingested(_) => summary.ingested += 1,
                IngestOutcome::Skipped => summary.skipped += 1,
            }
        }
        for source in knowledge::list_web_sources(&self.inner.store, project_id)? {
            let document = knowledge::web_document(&self.inner.store, project_id, &source.id)?;
            match self.ingest_document(project_id, document, false).await? {
                IngestOutcome::Ingested(_) => summary.ingested += 1,
                IngestOutcome::Skipped => summary.skipped += 1,
            }
        }
        Ok(summary)
    }

    pub async fn ingest_conversation(
        &self,
        project_id: &str,
        conversation_id: &str,
        force: bool,
    ) -> Result<IngestOutcome> {
        let lock = self.knowledge_lock(project_id);
        let _guard = lock.lock().await;
        let document =
            knowledge::conversation_document(&self.inner.store, project_id, conversation_id)?;
        self.ingest_document(project_id, document, force).await
    }

    pub async fn import_url(
        &self,
        project_id: &str,
        url: &str,
    ) -> Result<(WebSource, IngestOutcome)> {
        let lock = self.knowledge_lock(project_id);
        let _guard = lock.lock().await;
        self.inner.store.project(project_id)?;
        let reader = self.inner.jina.read(url).await?;
        self.import_reader_document(project_id, reader).await
    }

    async fn import_reader_document(
        &self,
        project_id: &str,
        reader: ReaderDocument,
    ) -> Result<(WebSource, IngestOutcome)> {
        let source = knowledge::import_reader_document(&self.inner.store, project_id, reader)?;
        let document = knowledge::web_document(&self.inner.store, project_id, &source.id)?;
        let outcome = self.ingest_document(project_id, document, false).await?;
        Ok((source, outcome))
    }

    pub async fn ingest_web_source(
        &self,
        project_id: &str,
        source_id: &str,
        force: bool,
    ) -> Result<IngestOutcome> {
        let lock = self.knowledge_lock(project_id);
        let _guard = lock.lock().await;
        let document = knowledge::web_document(&self.inner.store, project_id, source_id)?;
        self.ingest_document(project_id, document, force).await
    }

    pub async fn refresh_web_source(
        &self,
        project_id: &str,
        source_id: &str,
    ) -> Result<(WebSource, IngestOutcome)> {
        let lock = self.knowledge_lock(project_id);
        let _guard = lock.lock().await;
        let source = knowledge::read_web_source(&self.inner.store, project_id, source_id)?;
        let reader = self.inner.jina.read(&source.url).await?;
        self.import_reader_document(project_id, reader).await
    }

    async fn ingest_document(
        &self,
        project_id: &str,
        document: Document,
        force: bool,
    ) -> Result<IngestOutcome> {
        if document.body.trim().is_empty() {
            return Err(anyhow!(
                "source has no transcript or document content to ingest"
            ));
        }
        let (instructions, instructions_hash) =
            knowledge::instructions(&self.inner.store, project_id)?;
        let checkpoint = knowledge::checkpoint(&self.inner.store, project_id)?;
        if !force
            && !knowledge::needs_ingest(
                checkpoint.documents.get(&document.key),
                &document,
                &instructions_hash,
            )
        {
            return Ok(IngestOutcome::Skipped);
        }
        let note = self
            .inner
            .ai
            .knowledge_note(
                &document.title,
                document.kind.as_str(),
                &document.body,
                &instructions,
            )
            .await?;
        let receipt = knowledge::commit_ingestion(
            &self.inner.store,
            project_id,
            &document,
            &instructions_hash,
            &note,
        )?;
        Ok(IngestOutcome::Ingested(receipt))
    }

    fn knowledge_lock(&self, project_id: &str) -> Arc<AsyncMutex<()>> {
        self.inner
            .knowledge_locks
            .lock()
            .unwrap()
            .entry(project_id.to_string())
            .or_insert_with(|| Arc::new(AsyncMutex::new(())))
            .clone()
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
    use crate::agentic::{CodexKnowledgeAgent, QueryEvent};
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

    #[cfg(unix)]
    #[tokio::test]
    async fn knowledge_query_tokens_resume_only_within_their_project() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        store.create_project("Other").unwrap();
        let wiki = knowledge::wiki_root(&store, "kibo").unwrap();
        let wiki_json = serde_json::to_string(&wiki.to_string_lossy()).unwrap();
        let log = temporary.path().join("operations.log");
        let log_shell = log.to_string_lossy().replace('\'', "'\\''");
        let script = temporary.path().join("fake-codex");
        let body = format!(
            r##"#!/bin/sh
read initialize
printf '%s\n' '{{"id":0,"result":{{"userAgent":"fake"}}}}'
read initialized
read thread_request
printf '%s\n' "$thread_request" >> '{log_shell}'
permission_id=$(printf '%s\n' "$thread_request" | sed -n 's/.*"permissions":"\([^"]*\)".*/\1/p')
printf '%s\n' '{{"id":1,"result":{{"thread":{{"id":"app-thread-1"}},"cwd":{wiki_json},"runtimeWorkspaceRoots":[{wiki_json}],"approvalPolicy":"never","sandbox":{{"type":"readOnly","networkAccess":false}},"activePermissionProfile":{{"id":"PROFILE_ID"}},"instructionSources":[]}}}}' | sed "s/PROFILE_ID/$permission_id/"
read mcp_status
printf '%s\n' '{{"id":2,"result":{{"data":[],"nextCursor":null}}}}'
read turn_start
printf '%s\n' '{{"id":3,"result":{{"turn":{{"id":"turn-1"}}}}}}'
printf '%s\n' '{{"method":"item/completed","params":{{"threadId":"app-thread-1","turnId":"turn-1","item":{{"type":"agentMessage","id":"answer-1","text":"answer"}}}}}}'
printf '%s\n' '{{"method":"turn/completed","params":{{"threadId":"app-thread-1","turn":{{"id":"turn-1","status":"completed","items":[],"error":null}}}}}}'
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

        let mut first = state
            .start_knowledge_query("kibo", "first", None)
            .await
            .unwrap();
        let query_id = first.query_id().to_string();
        while !matches!(
            first.next_event().await.unwrap(),
            Some(QueryEvent::Completed(_))
        ) {}
        drop(first);

        let mut follow_up = state
            .start_knowledge_query("kibo", "follow up", Some(&query_id))
            .await
            .unwrap();
        while !matches!(
            follow_up.next_event().await.unwrap(),
            Some(QueryEvent::Completed(_))
        ) {}
        drop(follow_up);

        let other = state.store().list_projects().unwrap();
        let other_id = other
            .iter()
            .find(|project| project.name == "Other")
            .unwrap()
            .id
            .clone();
        let error = state
            .start_knowledge_query(&other_id, "leak", Some(&query_id))
            .await
            .err()
            .unwrap();
        assert!(error.downcast_ref::<UnknownQueryThread>().is_some());

        let operations = fs::read_to_string(log).unwrap();
        assert!(operations.lines().next().unwrap().contains("thread/start"));
        assert!(operations.lines().nth(1).unwrap().contains("thread/resume"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cancelling_during_follow_up_start_revokes_the_token() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let wiki = knowledge::wiki_root(&store, "kibo").unwrap();
        let wiki_json = serde_json::to_string(&wiki.to_string_lossy()).unwrap();
        let resume_started = temporary.path().join("resume-started");
        let resume_started_shell = resume_started.to_string_lossy().replace('\'', "'\\''");
        let script = temporary.path().join("fake-codex-stalled-resume");
        let body = format!(
            r##"#!/bin/sh
read initialize
printf '%s\n' '{{"id":0,"result":{{"userAgent":"fake"}}}}'
read initialized
read thread_request
case "$thread_request" in
  *'"method":"thread/resume"'*)
    printf '%s\n' started > '{resume_started_shell}'
    while read ignored; do :; done
    exit 0
    ;;
esac
permission_id=$(printf '%s\n' "$thread_request" | sed -n 's/.*"permissions":"\([^"]*\)".*/\1/p')
printf '%s\n' '{{"id":1,"result":{{"thread":{{"id":"app-thread-stall"}},"cwd":{wiki_json},"runtimeWorkspaceRoots":[{wiki_json}],"approvalPolicy":"never","sandbox":{{"type":"readOnly","networkAccess":false}},"activePermissionProfile":{{"id":"PROFILE_ID"}},"instructionSources":[]}}}}' | sed "s/PROFILE_ID/$permission_id/"
read mcp_status
printf '%s\n' '{{"id":2,"result":{{"data":[],"nextCursor":null}}}}'
read turn_start
printf '%s\n' '{{"id":3,"result":{{"turn":{{"id":"turn-1"}}}}}}'
printf '%s\n' '{{"method":"item/completed","params":{{"threadId":"app-thread-stall","turnId":"turn-1","item":{{"type":"agentMessage","id":"answer-1","text":"answer"}}}}}}'
printf '%s\n' '{{"method":"turn/completed","params":{{"threadId":"app-thread-stall","turn":{{"id":"turn-1","status":"completed","items":[],"error":null}}}}}}'
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

        let mut first = state
            .start_knowledge_query("kibo", "first", None)
            .await
            .unwrap();
        let query_id = first.query_id().to_string();
        while !matches!(
            first.next_event().await.unwrap(),
            Some(QueryEvent::Completed(_))
        ) {}
        drop(first);

        let follow_up_state = state.clone();
        let follow_up_id = query_id.clone();
        let follow_up = tokio::spawn(async move {
            follow_up_state
                .start_knowledge_query("kibo", "follow up", Some(&follow_up_id))
                .await
        });
        tokio::time::timeout(Duration::from_secs(2), async {
            while !resume_started.exists() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();

        follow_up.abort();
        assert!(matches!(follow_up.await, Err(error) if error.is_cancelled()));
        let error = state
            .start_knowledge_query("kibo", "try again", Some(&query_id))
            .await
            .err()
            .unwrap();
        assert!(error.downcast_ref::<UnknownQueryThread>().is_some());
    }

    #[tokio::test]
    async fn mock_pipeline_reaches_durable_speech() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        let wav = b"RIFF0000WAVE mock";
        let sha = hex_sha256(wav);
        store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id,
                clip_id: "clip-1",
                bytes: wav,
                expected_sha256: &sha,
                duration_ms: 800,
                peak_pct: 20,
                recorded_at: 1,
            })
            .unwrap();
        let state = AppState::new(store.clone(), Ai::mock());
        state.start_transcription("kibo".into(), conversation.id.clone(), "clip-1".into());
        let outcome = store
            .create_turn("kibo", conversation_id, "turn-1")
            .unwrap();
        assert!(matches!(outcome, CreateTurnOutcome::Created { .. }));
        state.start_turn("kibo".into(), conversation.id.clone(), "turn-1".into());

        wait_for_event(&store, conversation_id, "speech_ready").await;
        let records = store.records("kibo", conversation_id).unwrap();
        assert!(records.iter().any(|event| event["kind"] == "reply"));
        assert!(
            store
                .speech_path("kibo", conversation_id, "turn-1")
                .unwrap()
                .exists()
        );
    }

    #[tokio::test]
    async fn resume_synthesizes_a_reply_left_without_speech() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        store
            .append(
                "kibo",
                conversation_id,
                json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            )
            .unwrap();
        store
            .append(
                "kibo",
                conversation_id,
                json!({"kind":"reply", "turn":"turn-1", "text":"Recovered reply", "audio":"tts/turn-1.wav"}),
            )
            .unwrap();
        let state = AppState::new(store.clone(), Ai::mock());
        state.resume().unwrap();

        wait_for_event(&store, conversation_id, "speech_ready").await;
        assert!(
            store
                .speech_path("kibo", conversation_id, "turn-1")
                .unwrap()
                .exists()
        );
    }

    #[tokio::test]
    async fn conversation_worker_uses_durable_turn_order() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        for (clip, turn, text) in [
            ("clip-1", "turn-1", "first"),
            ("clip-2", "turn-2", "second"),
        ] {
            store
                .append("kibo", conversation_id, json!({"kind":"clip", "id":clip}))
                .unwrap();
            store
                .append(
                    "kibo",
                    conversation_id,
                    json!({"kind":"transcript", "clip":clip, "text":text}),
                )
                .unwrap();
            store
                .append(
                    "kibo",
                    conversation_id,
                    json!({"kind":"turn", "id":turn, "clips":[clip]}),
                )
                .unwrap();
        }
        let state = AppState::new(store.clone(), Ai::mock());
        // Even a later turn winning the request race cannot overtake the log.
        state.start_turn("kibo".into(), conversation.id.clone(), "turn-2".into());
        state.start_turn("kibo".into(), conversation.id.clone(), "turn-1".into());
        wait_for_event_count(&store, conversation_id, "speech_ready", 2).await;
        let replies: Vec<_> = store
            .records("kibo", conversation_id)
            .unwrap()
            .into_iter()
            .filter(|event| event["kind"] == "reply")
            .filter_map(|event| event["turn"].as_str().map(str::to_string))
            .collect();
        assert_eq!(replies, ["turn-1", "turn-2"]);
    }

    #[tokio::test]
    async fn knowledge_ingestion_skips_unchanged_and_force_replaces_the_note() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store
            .create_conversation("kibo", Some("Design notes"))
            .unwrap();
        store
            .append(
                "kibo",
                &conversation.id,
                json!({"kind":"transcript", "clip":"clip-1", "text":"Keep raw sources separate from generated notes."}),
            )
            .unwrap();
        let state = AppState::new(store.clone(), Ai::mock());

        let first = state
            .ingest_conversation("kibo", &conversation.id, false)
            .await
            .unwrap();
        assert!(matches!(first, IngestOutcome::Ingested(ref receipt) if receipt.generation == 1));
        assert!(matches!(
            state
                .ingest_conversation("kibo", &conversation.id, false)
                .await
                .unwrap(),
            IngestOutcome::Skipped
        ));

        store
            .append(
                "kibo",
                &conversation.id,
                json!({"kind":"speech_ready", "turn":"turn-1", "samples":10, "rate":24000}),
            )
            .unwrap();
        assert!(matches!(
            state
                .ingest_conversation("kibo", &conversation.id, false)
                .await
                .unwrap(),
            IngestOutcome::Skipped
        ));

        let forced = state
            .ingest_conversation("kibo", &conversation.id, true)
            .await
            .unwrap();
        assert!(matches!(forced, IngestOutcome::Ingested(ref receipt) if receipt.generation == 2));
        let page = knowledge::read_markdown(
            &store,
            "kibo",
            &format!("wiki/sources/conversation--{}.md", conversation.id),
        )
        .unwrap();
        assert!(page.contains("source_id: \"conversation:"));
        assert!(page.contains("Keep raw sources separate"));
    }

    #[tokio::test]
    async fn imported_reader_content_uses_the_same_checkpoint_path() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let state = AppState::new(store.clone(), Ai::mock());
        let (source, first) = state
            .import_reader_document(
                "kibo",
                ReaderDocument {
                    url: "https://example.com/article".into(),
                    title: "Useful article".into(),
                    content: "# Useful article\n\nA durable web source.".into(),
                },
            )
            .await
            .unwrap();
        assert!(matches!(first, IngestOutcome::Ingested(_)));
        assert!(matches!(
            state
                .ingest_web_source("kibo", &source.id, false)
                .await
                .unwrap(),
            IngestOutcome::Skipped
        ));
        let files = knowledge::markdown_files(&store, "kibo").unwrap();
        assert!(
            files
                .iter()
                .any(|file| file.path == format!("wiki/sources/web--{}.md", source.id))
        );
    }

    async fn wait_for_event(store: &Store, conversation_id: &str, kind: &str) {
        wait_for_event_count(store, conversation_id, kind, 1).await;
    }

    async fn wait_for_event_count(store: &Store, conversation_id: &str, kind: &str, count: usize) {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if store
                    .records("kibo", conversation_id)
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

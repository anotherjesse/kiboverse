use crate::agentic::{CodexKnowledgeAgent, QueryEvent, RunningQuery};
use crate::ai::{Ai, DESCRIPTION_PROMPT_VERSION, HistoryImage, HistoryTurn, ImagePart, TTS_RATE};
use crate::journal::JournalWrite;
use crate::knowledge::{self, Document, IngestReceipt, JinaReader, ReaderDocument, WebSource};
use crate::model::{epoch, epoch_millis, make_id};
use crate::store::{AutoNameOutcome, Store, hex_sha256};
use crate::workflow::{
    AttemptState, ConversationWorkflow, FailureStage, HistoryContext, ImageWork, ReplyRecord,
    ReplyState, SpeechState, TranscriptState, TurnAction, TurnImage, TurnMedia,
};
use anyhow::{Context, Result, anyhow};
use serde_json::Value;
#[cfg(test)]
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard, Semaphore, broadcast, watch};

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
    conversation_supervision: Mutex<ConversationSupervision>,
    knowledge_locks: Mutex<HashMap<String, Arc<AsyncMutex<()>>>>,
    provider_permits: Semaphore,
    workflow_policy: WorkflowPolicy,
    knowledge_agent: CodexKnowledgeAgent,
    query_threads: Mutex<HashMap<String, QueryThread>>,
}

/// Coalesces wakeups without making the in-memory claim authoritative state.
/// A wake that arrives during a pass records one required rerun; releasing the
/// claim and deciding whether to rerun happen under the same mutex.
#[derive(Default)]
struct ConversationSupervision {
    claims: HashMap<String, ConversationClaim>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ConversationClaim {
    Running,
    RerunRequested,
}

impl ConversationSupervision {
    /// Returns true only for the caller that must start a supervisor task.
    fn request(&mut self, key: &str) -> bool {
        match self.claims.entry(key.to_string()) {
            std::collections::hash_map::Entry::Vacant(entry) => {
                entry.insert(ConversationClaim::Running);
                true
            }
            std::collections::hash_map::Entry::Occupied(mut entry) => {
                *entry.get_mut() = ConversationClaim::RerunRequested;
                false
            }
        }
    }

    /// Returns true when the active task must make another reconciliation
    /// pass. Otherwise this atomically releases the claim.
    fn finish_pass(&mut self, key: &str) -> bool {
        if self.claims.get(key) == Some(&ConversationClaim::RerunRequested) {
            self.claims
                .insert(key.to_string(), ConversationClaim::Running);
            true
        } else {
            self.claims.remove(key);
            false
        }
    }
}

#[derive(Clone)]
struct RetryPolicy {
    retry_delays: Arc<[Duration]>,
}

impl RetryPolicy {
    fn retry_delay_after(&self, attempt: u32) -> Option<Duration> {
        let index = usize::try_from(attempt.saturating_sub(1)).ok()?;
        self.retry_delays.get(index).copied()
    }
}

#[derive(Clone)]
struct WorkflowPolicy {
    transcription: RetryPolicy,
    description: RetryPolicy,
    reply: RetryPolicy,
    speech: RetryPolicy,
    infrastructure_delay: Duration,
}

struct AttemptFailure<'a> {
    subject: AttemptSubject<'a>,
    attempt: u32,
    error: String,
    retryable: bool,
}

#[derive(Clone, Copy)]
enum AttemptSubject<'a> {
    Transcript(&'a str),
    Description(&'a str),
    Reply(&'a str),
    Speech(&'a str),
}

/// The two per-media supervised text-projection stages. They share one
/// attempt loop; only the event kinds, provider call, and retry policy vary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MediaStage {
    Transcription,
    Description,
}

impl Default for WorkflowPolicy {
    fn default() -> Self {
        let retry_delays: Arc<[Duration]> =
            Arc::from([Duration::from_secs(1), Duration::from_secs(5)]);
        Self {
            transcription: RetryPolicy {
                retry_delays: retry_delays.clone(),
            },
            description: RetryPolicy {
                retry_delays: retry_delays.clone(),
            },
            reply: RetryPolicy {
                retry_delays: retry_delays.clone(),
            },
            speech: RetryPolicy { retry_delays },
            infrastructure_delay: Duration::from_secs(1),
        }
    }
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
    generation: String,
    generation_index: u32,
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

impl SpeechStream {
    fn new(generation: String, generation_index: u32) -> Self {
        Self {
            generation,
            generation_index,
            samples: Mutex::new(Vec::new()),
            done: Mutex::new(false),
            error: Mutex::new(None),
            changed: watch::channel(0).0,
        }
    }

    pub fn generation(&self) -> &str {
        &self.generation
    }

    pub fn generation_index(&self) -> u32 {
        self.generation_index
    }

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
        Self::with_workflow_policy(store, ai, WorkflowPolicy::default())
    }

    fn with_workflow_policy(store: Store, ai: Ai, workflow_policy: WorkflowPolicy) -> Self {
        Self::build(store, ai, workflow_policy, CodexKnowledgeAgent::from_env())
    }

    fn build(
        store: Store,
        ai: Ai,
        workflow_policy: WorkflowPolicy,
        knowledge_agent: CodexKnowledgeAgent,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                store,
                ai,
                jina: JinaReader::from_env(),
                channels: Mutex::new(HashMap::new()),
                speech: Mutex::new(HashMap::new()),
                transcribing: Mutex::new(HashSet::new()),
                conversation_supervision: Mutex::new(ConversationSupervision::default()),
                knowledge_locks: Mutex::new(HashMap::new()),
                provider_permits: Semaphore::new(3),
                workflow_policy,
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
        Self::build(store, ai, WorkflowPolicy::default(), knowledge_agent)
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
        let note = {
            let _permit = self
                .inner
                .provider_permits
                .acquire()
                .await
                .map_err(|_| anyhow!("provider concurrency gate closed"))?;
            self.inner
                .ai
                .knowledge_note(
                    &document.title,
                    document.kind.as_str(),
                    &document.body,
                    &instructions,
                )
                .await?
        };
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

    pub(crate) fn publish_persisted(&self, project_id: &str, conversation_id: &str, event: Value) {
        let _ = self.channel(project_id, conversation_id).send(event);
    }

    fn append(
        &self,
        project_id: &str,
        conversation_id: &str,
        event: JournalWrite,
    ) -> Result<Value> {
        let event = self
            .inner
            .store
            .append(project_id, conversation_id, event)?;
        self.publish_persisted(project_id, conversation_id, event.clone());
        Ok(event)
    }

    fn append_if<F>(
        &self,
        project_id: &str,
        conversation_id: &str,
        event: JournalWrite,
        predicate: F,
    ) -> Result<Option<Value>>
    where
        F: FnOnce(&[Value]) -> bool,
    {
        let event = self
            .inner
            .store
            .append_if(project_id, conversation_id, event, predicate)?;
        if let Some(event) = &event {
            self.publish_persisted(project_id, conversation_id, event.clone());
        }
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
                    JournalWrite::conversation_renamed(conversation.name),
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

    /// Make the speech endpoint available before publishing a reply that
    /// advertises audio. Existing clients may issue GET immediately on the
    /// reply event; they should receive a blocking stream, never a transient
    /// 425 caused only by internal stage ordering.
    fn prepare_speech_endpoint(
        &self,
        project_id: &str,
        conversation_id: &str,
        turn_id: &str,
        generation: &str,
        generation_index: u32,
    ) -> Result<Option<(String, Arc<SpeechStream>)>> {
        let path = self
            .inner
            .store
            .speech_path(project_id, conversation_id, turn_id)?;
        if path.exists() {
            match hound::WavReader::open(&path) {
                Ok(_) => return Ok(None),
                Err(error) => {
                    tracing::warn!(%project_id, %conversation_id, %turn_id, "replacing corrupt speech file: {error}");
                    std::fs::remove_file(&path)?;
                }
            }
        }
        let key = key3(project_id, conversation_id, turn_id);
        let stream = self
            .inner
            .speech
            .lock()
            .unwrap()
            .entry(key.clone())
            .or_insert_with(|| {
                Arc::new(SpeechStream::new(generation.to_string(), generation_index))
            })
            .clone();
        Ok(Some((key, stream)))
    }

    fn discard_speech_endpoint(&self, key: &str, stream: &SpeechStream, error: &anyhow::Error) {
        stream.finish(Some(format!("{error:#}")));
        self.inner.speech.lock().unwrap().remove(key);
    }

    /// Schedule currently due work for newly available or replayed media.
    /// This never reopens terminal work: an idempotent data submission is not
    /// a workflow control command.
    pub fn reconcile_media(&self, project_id: &str, conversation_id: &str) -> Result<()> {
        self.ensure_media_work(project_id, conversation_id)
    }

    /// Explicitly reopen a terminal transcription, then schedule all due
    /// media work. Repeating this command while work is already open is inert.
    pub fn retry_transcription(
        &self,
        project_id: &str,
        conversation_id: &str,
        clip_id: &str,
        reason: &str,
    ) -> Result<bool> {
        let records = self.inner.store.records(project_id, conversation_id)?;
        let workflow = ConversationWorkflow::from_records(&records);
        let Some(clip) = workflow.clip(clip_id) else {
            return Ok(false);
        };
        let expected_clip = clip.id.clone();
        self.append_if(
            project_id,
            conversation_id,
            JournalWrite::transcript_retry_requested(clip_id, reason),
            move |records| {
                matches!(
                    ConversationWorkflow::from_records(records)
                        .clip(&expected_clip)
                        .map(|clip| &clip.transcript),
                    Some(TranscriptState::TerminalFailure(_))
                )
            },
        )?;
        // Once the retry intent is durable, its scheduling must also be
        // supervised. The conversation worker retries transient journal reads
        // instead of leaving this reopened clip dormant after returning an
        // error to the caller.
        self.wake_conversation(project_id.to_string(), conversation_id.to_string());
        Ok(true)
    }

    /// Explicitly reopen terminal or interrupted description work. Replies
    /// never wait on descriptions, so this only reschedules the value.
    pub fn retry_description(
        &self,
        project_id: &str,
        conversation_id: &str,
        image_id: &str,
        reason: &str,
    ) -> Result<bool> {
        let records = self.inner.store.records(project_id, conversation_id)?;
        let workflow = ConversationWorkflow::from_records(&records);
        if workflow.image(image_id).is_none() {
            return Ok(false);
        }
        let expected_image = image_id.to_string();
        self.append_if(
            project_id,
            conversation_id,
            JournalWrite::description_retry_requested(image_id, reason),
            move |records| {
                matches!(
                    ConversationWorkflow::from_records(records)
                        .image(&expected_image)
                        .map(|image| &image.description),
                    Some(
                        AttemptState::TerminalFailure(_) | AttemptState::Attempting { .. }
                    )
                )
            },
        )?;
        self.wake_conversation(project_id.to_string(), conversation_id.to_string());
        Ok(true)
    }

    fn schedule_media_stage(
        &self,
        project_id: String,
        conversation_id: String,
        media_id: String,
        stage: MediaStage,
    ) {
        let key = key3(&project_id, &conversation_id, &media_id);
        if !self.inner.transcribing.lock().unwrap().insert(key.clone()) {
            return;
        }
        let state = self.clone();
        tokio::spawn(async move {
            let mut recover_infrastructure = false;
            loop {
                if recover_infrastructure {
                    tokio::time::sleep(state.inner.workflow_policy.infrastructure_delay).await;
                    match state.recover_interrupted_media(
                        &project_id,
                        &conversation_id,
                        &media_id,
                        stage,
                        "supervisor_recovery",
                    ) {
                        Ok(()) => {}
                        Err(error) => {
                            tracing::error!(%project_id, %conversation_id, %media_id, "recover media supervisor: {error:#}");
                            continue;
                        }
                    }
                }
                match state
                    .drive_media_stage(&project_id, &conversation_id, &media_id, stage)
                    .await
                {
                    Ok(()) => break,
                    Err(error) => {
                        tracing::error!(%project_id, %conversation_id, %media_id, "media stage infrastructure: {error:#}");
                        recover_infrastructure = true;
                    }
                }
            }
            state.inner.transcribing.lock().unwrap().remove(&key);
            if let Err(error) = state.ensure_media_work(&project_id, &conversation_id) {
                tracing::error!(%project_id, %conversation_id, %media_id, "reschedule durable media work: {error:#}");
            }
            state.wake_conversation(project_id, conversation_id);
        });
    }

    /// One supervised attempt loop for both per-media text projections. The
    /// stage selects event kinds, the provider call, and the retry policy;
    /// the claim/compare-and-append protocol is identical.
    async fn drive_media_stage(
        &self,
        project_id: &str,
        conversation_id: &str,
        media_id: &str,
        stage: MediaStage,
    ) -> Result<()> {
        loop {
            let records = self.inner.store.records(project_id, conversation_id)?;
            let workflow = ConversationWorkflow::from_records(&records);
            let scheduled = match stage {
                MediaStage::Transcription => workflow
                    .clip(media_id)
                    .map(|clip| clip.transcript.scheduled_work()),
                MediaStage::Description => workflow
                    .image(media_id)
                    .map(|image| image.description.scheduled_work()),
            }
            .ok_or_else(|| anyhow!("media event is missing"))?;
            let Some((attempt, retry_at_ms)) = scheduled else {
                return Ok(());
            };
            sleep_until_epoch_ms(retry_at_ms).await;

            let started_event = match stage {
                MediaStage::Transcription => JournalWrite::transcript_started(media_id, attempt),
                MediaStage::Description => JournalWrite::description_started(media_id, attempt),
            };
            let expected = media_id.to_string();
            let started = self.append_if(
                project_id,
                conversation_id,
                started_event,
                move |records| stage_runnable_in(records, stage, &expected, attempt, retry_at_ms),
            )?;
            if started.is_none() {
                continue;
            }

            let result = match stage {
                MediaStage::Transcription => {
                    let clip = workflow
                        .clip(media_id)
                        .cloned()
                        .ok_or_else(|| anyhow!("clip event is missing"))?;
                    self.transcribe_once(project_id, conversation_id, &clip).await
                }
                MediaStage::Description => {
                    let image = workflow
                        .image(media_id)
                        .cloned()
                        .ok_or_else(|| anyhow!("image event is missing"))?;
                    self.describe_once(project_id, conversation_id, &image).await
                }
            };
            match result {
                Ok(text) => {
                    let success_event = match stage {
                        MediaStage::Transcription => {
                            JournalWrite::transcript_succeeded(media_id, text, attempt)
                        }
                        MediaStage::Description => JournalWrite::description_succeeded(
                            media_id,
                            &text,
                            attempt,
                            self.inner.ai.description_model(),
                            DESCRIPTION_PROMPT_VERSION,
                        ),
                    };
                    let expected = media_id.to_string();
                    let success = self.append_if(
                        project_id,
                        conversation_id,
                        success_event,
                        move |records| stage_attempting_in(records, stage, &expected, attempt),
                    )?;
                    if success.is_none() {
                        continue;
                    }
                    if stage == MediaStage::Transcription {
                        // R13: auto-naming fires only on transcript success,
                        // never on descriptions.
                        self.auto_name_conversation(project_id, conversation_id);
                    }
                    return Ok(());
                }
                Err(error) => {
                    let subject = match stage {
                        MediaStage::Transcription => AttemptSubject::Transcript(media_id),
                        MediaStage::Description => AttemptSubject::Description(media_id),
                    };
                    let policy = match stage {
                        MediaStage::Transcription => &self.inner.workflow_policy.transcription,
                        MediaStage::Description => &self.inner.workflow_policy.description,
                    };
                    let event = self.attempt_error_event(
                        AttemptFailure {
                            subject,
                            attempt,
                            error: format!("{error:#}"),
                            retryable: self.inner.ai.failure_is_retryable(&error),
                        },
                        policy,
                    );
                    let expected = media_id.to_string();
                    let failure = self.append_if(
                        project_id,
                        conversation_id,
                        event,
                        move |records| stage_attempting_in(records, stage, &expected, attempt),
                    )?;
                    if failure.is_none() {
                        continue;
                    }
                }
            }
        }
    }

    async fn transcribe_once(
        &self,
        project_id: &str,
        conversation_id: &str,
        clip: &crate::workflow::ClipWork,
    ) -> Result<String> {
        if clip.peak == Some(0) {
            return Ok("[silent]".into());
        }
        let wav = tokio::fs::read(self.inner.store.clip_path(
            project_id,
            conversation_id,
            &clip.id,
        )?)
        .await?;
        if let Some(expected_sha256) = &clip.sha256
            && !hex_sha256(&wav).eq_ignore_ascii_case(expected_sha256)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!(
                    "clip {} payload does not match its durable SHA-256",
                    clip.id
                ),
            )
            .into());
        }
        let _permit = self
            .inner
            .provider_permits
            .acquire()
            .await
            .map_err(|_| anyhow!("provider concurrency gate closed"))?;
        self.inner.ai.transcribe(&wav).await
    }

    /// The transcribe_once doctrine for pixels: bytes are re-verified against
    /// the durable SHA before the provider sees them, so a corrupt payload can
    /// never produce an authoritative description.
    async fn describe_once(
        &self,
        project_id: &str,
        conversation_id: &str,
        image: &ImageWork,
    ) -> Result<String> {
        let bytes = tokio::fs::read(self.inner.store.image_path(
            project_id,
            conversation_id,
            &image.id,
        )?)
        .await?;
        if let Some(expected_sha256) = &image.sha256
            && !hex_sha256(&bytes).eq_ignore_ascii_case(expected_sha256)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!(
                    "image {} payload does not match its durable SHA-256",
                    image.id
                ),
            )
            .into());
        }
        let _permit = self
            .inner
            .provider_permits
            .acquire()
            .await
            .map_err(|_| anyhow!("provider concurrency gate closed"))?;
        self.inner.ai.describe_image(&bytes, &image.mime).await
    }

    fn append_attempt_error(
        &self,
        project_id: &str,
        conversation_id: &str,
        failure: AttemptFailure<'_>,
        policy: &RetryPolicy,
    ) -> Result<()> {
        let event = self.attempt_error_event(failure, policy);
        self.append(project_id, conversation_id, event)?;
        Ok(())
    }

    fn attempt_error_event(
        &self,
        failure: AttemptFailure<'_>,
        policy: &RetryPolicy,
    ) -> JournalWrite {
        let owner_id = match failure.subject {
            AttemptSubject::Transcript(clip_id) => clip_id,
            AttemptSubject::Description(image_id) => image_id,
            AttemptSubject::Reply(turn_id) | AttemptSubject::Speech(turn_id) => turn_id,
        };
        let retry_delay = if failure.retryable {
            policy.retry_delay_after(failure.attempt)
        } else {
            None
        };
        if let Some(delay) = retry_delay {
            let retry_at_ms = retry_deadline_ms(delay, owner_id, failure.attempt);
            match failure.subject {
                AttemptSubject::Transcript(clip_id) => JournalWrite::transcript_retry_scheduled(
                    clip_id,
                    failure.attempt,
                    failure.error,
                    retry_at_ms,
                ),
                AttemptSubject::Description(image_id) => JournalWrite::description_retry_scheduled(
                    image_id,
                    failure.attempt,
                    failure.error,
                    retry_at_ms,
                ),
                AttemptSubject::Reply(turn_id) => JournalWrite::reply_retry_scheduled(
                    turn_id,
                    failure.attempt,
                    failure.error,
                    retry_at_ms,
                ),
                AttemptSubject::Speech(turn_id) => JournalWrite::speech_retry_scheduled(
                    turn_id,
                    failure.attempt,
                    failure.error,
                    retry_at_ms,
                ),
            }
        } else {
            match failure.subject {
                AttemptSubject::Transcript(clip_id) => {
                    JournalWrite::transcript_failed(clip_id, failure.attempt, failure.error)
                }
                AttemptSubject::Description(image_id) => {
                    JournalWrite::description_failed(image_id, failure.attempt, failure.error)
                }
                AttemptSubject::Reply(turn_id) => {
                    JournalWrite::reply_failed(turn_id, failure.attempt, failure.error)
                }
                AttemptSubject::Speech(turn_id) => {
                    JournalWrite::speech_failed(turn_id, failure.attempt, failure.error)
                }
            }
        }
    }

    fn ensure_media_work(&self, project_id: &str, conversation_id: &str) -> Result<()> {
        let records = self.inner.store.records(project_id, conversation_id)?;
        let workflow = ConversationWorkflow::from_records(&records);
        for work in workflow.transcription_work() {
            self.schedule_media_stage(
                project_id.to_string(),
                conversation_id.to_string(),
                work.clip_id,
                MediaStage::Transcription,
            );
        }
        for work in workflow.description_work() {
            self.schedule_media_stage(
                project_id.to_string(),
                conversation_id.to_string(),
                work.image_id,
                MediaStage::Description,
            );
        }
        Ok(())
    }

    fn recover_interrupted_media(
        &self,
        project_id: &str,
        conversation_id: &str,
        media_id: &str,
        stage: MediaStage,
        reason: &str,
    ) -> Result<()> {
        let event = match stage {
            MediaStage::Transcription => JournalWrite::transcript_retry_requested(media_id, reason),
            MediaStage::Description => JournalWrite::description_retry_requested(media_id, reason),
        };
        let expected = media_id.to_string();
        self.append_if(project_id, conversation_id, event, move |records| {
            let workflow = ConversationWorkflow::from_records(records);
            match stage {
                MediaStage::Transcription => matches!(
                    workflow.clip(&expected).map(|clip| &clip.transcript),
                    Some(TranscriptState::Attempting { .. })
                ),
                MediaStage::Description => matches!(
                    workflow.image(&expected).map(|image| &image.description),
                    Some(AttemptState::Attempting { .. })
                ),
            }
        })?;
        Ok(())
    }

    /// An idempotent retry of an existing turn explicitly reopens terminal
    /// reply or speech work. Newly created turns need no reset event.
    pub fn retry_turn(
        &self,
        project_id: &str,
        conversation_id: &str,
        turn_id: &str,
    ) -> Result<bool> {
        let records = self.inner.store.records(project_id, conversation_id)?;
        let workflow = ConversationWorkflow::from_records(&records);
        let Some(turn) = workflow.turn(turn_id) else {
            return Ok(false);
        };
        let terminal_clips: Vec<_> = turn
            .clips
            .iter()
            .filter(|clip_id| {
                matches!(
                    workflow.clip(clip_id).map(|clip| &clip.transcript),
                    Some(TranscriptState::TerminalFailure(_))
                )
            })
            .cloned()
            .collect();
        if !terminal_clips.is_empty() {
            for clip_id in terminal_clips {
                let expected_clip = clip_id.clone();
                let retry = self.append_if(
                    project_id,
                    conversation_id,
                    JournalWrite::transcript_retry_requested(clip_id, "turn_retry"),
                    move |records| {
                        matches!(
                            ConversationWorkflow::from_records(records)
                                .clip(&expected_clip)
                                .map(|clip| &clip.transcript),
                            Some(TranscriptState::TerminalFailure(_))
                        )
                    },
                );
                if let Err(error) = retry {
                    // Earlier clips in this batch may already be durably
                    // reopened. Start their supervisor before propagating the
                    // later append failure, without exposing a half-finished
                    // successful batch to a concurrently running worker.
                    self.wake_conversation(project_id.to_string(), conversation_id.to_string());
                    return Err(error);
                }
            }
        } else if matches!(turn.reply, ReplyState::TerminalFailure(_)) {
            let expected_turn = turn_id.to_string();
            self.append_if(
                project_id,
                conversation_id,
                JournalWrite::reply_retry_requested(turn_id, "turn_retry"),
                move |records| {
                    matches!(
                        ConversationWorkflow::from_records(records)
                            .turn(&expected_turn)
                            .map(|turn| &turn.reply),
                        Some(ReplyState::TerminalFailure(_))
                    )
                },
            )?;
        } else if matches!(turn.speech, Some(SpeechState::TerminalFailure(_))) {
            let expected_turn = turn_id.to_string();
            self.append_if(
                project_id,
                conversation_id,
                JournalWrite::speech_retry_requested(turn_id, "turn_retry"),
                move |records| {
                    matches!(
                        ConversationWorkflow::from_records(records)
                            .turn(&expected_turn)
                            .and_then(|turn| turn.speech.as_ref()),
                        Some(SpeechState::TerminalFailure(_))
                    )
                },
            )?;
        }
        self.wake_conversation(project_id.to_string(), conversation_id.to_string());
        Ok(true)
    }

    pub fn wake_conversation(&self, project_id: String, conversation_id: String) {
        let key = format!("{project_id}/{conversation_id}");
        if !self
            .inner
            .conversation_supervision
            .lock()
            .unwrap()
            .request(&key)
        {
            return;
        }
        let state = self.clone();
        tokio::spawn(async move {
            loop {
                let mut recover_infrastructure = false;
                loop {
                    if recover_infrastructure {
                        tokio::time::sleep(state.inner.workflow_policy.infrastructure_delay).await;
                        match state.recover_interrupted_turns(
                            &project_id,
                            &conversation_id,
                            "supervisor_recovery",
                        ) {
                            Ok(()) => {}
                            Err(error) => {
                                tracing::error!(%project_id, %conversation_id, "recover turn supervisor: {error:#}");
                                continue;
                            }
                        }
                    }
                    match state
                        .reconcile_and_drain(&project_id, &conversation_id)
                        .await
                    {
                        Ok(()) => break,
                        Err(error) => {
                            tracing::error!(%project_id, %conversation_id, "turn infrastructure: {error:#}");
                            recover_infrastructure = true;
                        }
                    }
                }
                if !state
                    .inner
                    .conversation_supervision
                    .lock()
                    .unwrap()
                    .finish_pass(&key)
                {
                    break;
                }
            }
            if state.conversation_has_work(&project_id, &conversation_id) {
                state.wake_conversation(project_id, conversation_id);
            }
        });
    }

    async fn reconcile_and_drain(&self, project_id: &str, conversation_id: &str) -> Result<()> {
        // Scheduling is part of the supervised operation. A transient journal
        // read failure therefore backs off and retries instead of allowing a
        // transcription-blocked turn to become dormant.
        self.ensure_media_work(project_id, conversation_id)?;
        self.drain_turns(project_id, conversation_id).await
    }

    async fn drain_turns(&self, project_id: &str, conversation_id: &str) -> Result<()> {
        loop {
            let records = self.inner.store.records(project_id, conversation_id)?;
            let workflow = ConversationWorkflow::from_records(&records);
            let Some((turn_id, action)) = workflow.next_turn_action(epoch_millis()) else {
                return Ok(());
            };
            match action {
                TurnAction::AwaitingEvent => return Ok(()),
                TurnAction::WaitUntil { deadline_ms } => {
                    sleep_until_epoch_ms(deadline_ms).await;
                }
                TurnAction::RecordTranscriptFailure { error } => {
                    let expected_turn = turn_id.clone();
                    self.append_if(
                        project_id,
                        conversation_id,
                        JournalWrite::reply_failed_from_transcription(
                            &turn_id,
                            1,
                            format!("one or more claimed clips could not be transcribed: {error}"),
                        ),
                        move |records| {
                            matches!(
                                ConversationWorkflow::from_records(records)
                                    .turn(&expected_turn)
                                    .map(|turn| turn.action(epoch_millis())),
                                Some(TurnAction::RecordTranscriptFailure { .. })
                            )
                        },
                    )?;
                }
                TurnAction::GenerateReply { attempt } => {
                    self.run_reply_attempt(project_id, conversation_id, &workflow, &turn_id, attempt)
                        .await?;
                }
                TurnAction::GenerateSpeech { attempt, reply } => {
                    let generation_index = workflow
                        .turn(&turn_id)
                        .map(|turn| turn.speech_generation_index.saturating_add(1))
                        .unwrap_or(1);
                    self.run_speech_attempt(
                        project_id,
                        conversation_id,
                        &turn_id,
                        attempt,
                        generation_index,
                        &reply,
                    )
                    .await?;
                }
                TurnAction::Complete => unreachable!("completed turns are omitted"),
            }
        }
    }

    /// Every reply transition here is conditional on this attempt still being
    /// current (the transcription compare-and-append protocol, applied to the
    /// reply stage). A payload repair that reopens the turn while a provider
    /// call is in flight therefore supersedes this attempt instead of racing
    /// its stale result into the journal.
    async fn run_reply_attempt(
        &self,
        project_id: &str,
        conversation_id: &str,
        workflow: &ConversationWorkflow,
        turn_id: &str,
        attempt: u32,
    ) -> Result<()> {
        let expected_turn = turn_id.to_string();
        let started = self.append_if(
            project_id,
            conversation_id,
            JournalWrite::reply_started(turn_id, attempt),
            move |records| reply_runnable_in(records, &expected_turn, attempt),
        )?;
        if started.is_none() {
            return Ok(());
        }
        let turn = workflow
            .turn(turn_id)
            .ok_or_else(|| anyhow!("turn event is missing"))?;
        if turn.clips.is_empty() && turn.images.is_empty() {
            self.append_reply_result_error(
                project_id,
                conversation_id,
                turn_id,
                attempt,
                "turn has no clips or images".into(),
                false,
                &RetryPolicy {
                    retry_delays: Arc::from([]),
                },
            )?;
            return Ok(());
        }
        let content = workflow
            .turn_content(turn_id)
            .ok_or_else(|| anyhow!("turn event is missing"))?;
        let user_text = content.user_text();
        let turn_images = content.images();
        // A turn is answerable when it has text OR images; the sentinel fires
        // only when both are absent.
        if user_text.is_empty() && turn_images.is_empty() {
            let expected_turn = turn_id.to_string();
            self.append_if(
                project_id,
                conversation_id,
                JournalWrite::reply_text(turn_id, "[nothing to answer]", turn.clips.clone()),
                move |records| reply_attempting_in(records, &expected_turn, attempt),
            )?;
            return Ok(());
        }
        // Verify every claimed image against its durable SHA before any byte
        // can reach the provider; corrupt payloads close the attempt locally
        // and heal through re-PUT repair.
        let mut image_bytes = HashMap::new();
        for image in &turn_images {
            match self.load_verified_image(project_id, conversation_id, image).await {
                Ok(bytes) => {
                    image_bytes.insert(image.id.clone(), bytes);
                }
                Err(error) => {
                    self.append_reply_result_error(
                        project_id,
                        conversation_id,
                        turn_id,
                        attempt,
                        format!("{error:#}"),
                        self.inner.ai.failure_is_retryable(&error),
                        &self.inner.workflow_policy.reply,
                    )?;
                    return Ok(());
                }
            }
        }
        let request = bound_current_turn(turn_request_items(&content, &image_bytes));
        let HistoryContext {
            turns: projected_history,
            previous_interaction_id,
            through_seq: history_through_seq,
        } = workflow.history_before(turn_id);
        let history: Vec<_> = projected_history
            .into_iter()
            .map(|turn| HistoryTurn {
                user: turn.user,
                assistant: turn.assistant,
                images: turn
                    .images
                    .into_iter()
                    .map(|image| HistoryImage {
                        id: image.id,
                        description: image.description,
                    })
                    .collect(),
            })
            .collect();
        let reply_result = {
            let _permit = self
                .inner
                .provider_permits
                .acquire()
                .await
                .map_err(|_| anyhow!("provider concurrency gate closed"))?;
            self.inner
                .ai
                .chat(
                    &request.text,
                    &request.parts,
                    previous_interaction_id.as_deref(),
                    &history,
                )
                .await
        };
        match reply_result {
            Ok(reply) => {
                let generation = uuid::Uuid::new_v4().simple().to_string();
                let prepared = self.prepare_speech_endpoint(
                    project_id,
                    conversation_id,
                    turn_id,
                    &generation,
                    1,
                )?;
                let expected_turn = turn_id.to_string();
                let committed = self.append_if(
                    project_id,
                    conversation_id,
                    JournalWrite::reply_spoken(
                        turn_id,
                        reply.text,
                        turn.clips.clone(),
                        reply.interaction_id,
                        generation,
                        history_through_seq,
                    ),
                    move |records| reply_attempting_in(records, &expected_turn, attempt),
                );
                match committed {
                    Ok(Some(_)) => {}
                    Ok(None) => {
                        // Superseded mid-flight (payload repair or explicit
                        // reopen): drop the pre-registered stream and let the
                        // drain loop run the now-current attempt.
                        if let Some((key, stream)) = prepared {
                            self.discard_speech_endpoint(
                                &key,
                                &stream,
                                &anyhow!("reply attempt superseded before its result was durable"),
                            );
                        }
                    }
                    Err(error) => {
                        if let Some((key, stream)) = prepared {
                            self.discard_speech_endpoint(&key, &stream, &error);
                        }
                        return Err(error);
                    }
                }
            }
            Err(error) => {
                self.append_reply_result_error(
                    project_id,
                    conversation_id,
                    turn_id,
                    attempt,
                    format!("{error:#}"),
                    self.inner.ai.failure_is_retryable(&error),
                    &self.inner.workflow_policy.reply,
                )?;
            }
        }
        Ok(())
    }

    /// Append a reply-stage failure only while this attempt is still current.
    #[allow(clippy::too_many_arguments)]
    fn append_reply_result_error(
        &self,
        project_id: &str,
        conversation_id: &str,
        turn_id: &str,
        attempt: u32,
        error: String,
        retryable: bool,
        policy: &RetryPolicy,
    ) -> Result<()> {
        let event = self.attempt_error_event(
            AttemptFailure {
                subject: AttemptSubject::Reply(turn_id),
                attempt,
                error,
                retryable,
            },
            policy,
        );
        let expected_turn = turn_id.to_string();
        self.append_if(project_id, conversation_id, event, move |records| {
            reply_attempting_in(records, &expected_turn, attempt)
        })?;
        Ok(())
    }

    async fn load_verified_image(
        &self,
        project_id: &str,
        conversation_id: &str,
        image: &TurnImage,
    ) -> Result<Vec<u8>> {
        let bytes = tokio::fs::read(self.inner.store.image_path(
            project_id,
            conversation_id,
            &image.id,
        )?)
        .await?;
        if let Some(expected_sha256) = &image.sha256
            && !hex_sha256(&bytes).eq_ignore_ascii_case(expected_sha256)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!(
                    "image {} payload does not match its durable SHA-256",
                    image.id
                ),
            )
            .into());
        }
        Ok(bytes)
    }

    async fn run_speech_attempt(
        &self,
        project_id: &str,
        conversation_id: &str,
        turn_id: &str,
        attempt: u32,
        candidate_generation_index: u32,
        reply: &ReplyRecord,
    ) -> Result<()> {
        let candidate_generation = uuid::Uuid::new_v4().simple().to_string();
        let prepared = self.prepare_speech_endpoint(
            project_id,
            conversation_id,
            turn_id,
            &candidate_generation,
            candidate_generation_index,
        )?;
        let generation = prepared
            .as_ref()
            .map(|(_, stream)| stream.generation().to_string())
            .unwrap_or(candidate_generation);
        let generation_index = prepared
            .as_ref()
            .map(|(_, stream)| stream.generation_index())
            .unwrap_or(candidate_generation_index);
        if let Err(error) = self.append(
            project_id,
            conversation_id,
            JournalWrite::speech_started(turn_id, attempt, &generation),
        ) {
            if let Some((key, stream)) = prepared {
                self.discard_speech_endpoint(&key, &stream, &error);
            }
            return Err(error);
        }
        match self
            .synthesize_once(
                project_id,
                conversation_id,
                turn_id,
                &generation,
                generation_index,
                &reply.text,
            )
            .await
        {
            Ok((samples, recovered)) => {
                self.append(
                    project_id,
                    conversation_id,
                    JournalWrite::speech_ready(turn_id, samples, TTS_RATE, recovered),
                )?;
            }
            Err(error) => {
                self.append_attempt_error(
                    project_id,
                    conversation_id,
                    AttemptFailure {
                        subject: AttemptSubject::Speech(turn_id),
                        attempt,
                        error: format!("{error:#}"),
                        retryable: self.inner.ai.failure_is_retryable(&error),
                    },
                    &self.inner.workflow_policy.speech,
                )?;
            }
        }
        Ok(())
    }

    async fn synthesize_once(
        &self,
        project_id: &str,
        conversation_id: &str,
        turn_id: &str,
        generation: &str,
        generation_index: u32,
        text: &str,
    ) -> Result<(usize, bool)> {
        let path = self
            .inner
            .store
            .speech_path(project_id, conversation_id, turn_id)?;
        if let Ok(reader) = hound::WavReader::open(&path) {
            return Ok((reader.duration() as usize, true));
        }
        let Some((speech_key, stream)) = self.prepare_speech_endpoint(
            project_id,
            conversation_id,
            turn_id,
            generation,
            generation_index,
        )?
        else {
            let reader = hound::WavReader::open(&path)?;
            return Ok((reader.duration() as usize, true));
        };
        let _permit = self
            .inner
            .provider_permits
            .acquire()
            .await
            .map_err(|_| anyhow!("provider concurrency gate closed"))?;
        let result = async {
            let mut receiver = self.inner.ai.tts_stream(text.to_string());
            while let Some(chunk) = receiver.recv().await {
                stream.push(&chunk.map_err(anyhow::Error::new)?);
            }
            let samples = stream.all_samples();
            if samples.is_empty() {
                return Err(anyhow!("TTS produced no audio"));
            }
            save_wav(&path, &samples)
                .with_context(|| format!("failed to save synthesized speech for {turn_id}"))?;
            Ok((samples.len(), false))
        }
        .await;
        stream.finish(result.as_ref().err().map(|error| format!("{error:#}")));
        self.inner.speech.lock().unwrap().remove(&speech_key);
        result
    }

    fn recover_interrupted_turns(
        &self,
        project_id: &str,
        conversation_id: &str,
        reason: &str,
    ) -> Result<()> {
        let records = self.inner.store.records(project_id, conversation_id)?;
        let workflow = ConversationWorkflow::from_records(&records);
        for (turn_id, stage) in workflow.interrupted_turn_stages() {
            let event = match stage {
                FailureStage::Reply | FailureStage::Transcription => {
                    JournalWrite::reply_retry_requested(&turn_id, reason)
                }
                FailureStage::Speech => JournalWrite::speech_retry_requested(&turn_id, reason),
            };
            let expected_turn = turn_id.clone();
            self.append_if(project_id, conversation_id, event, move |records| {
                let workflow = ConversationWorkflow::from_records(records);
                let Some(turn) = workflow.turn(&expected_turn) else {
                    return false;
                };
                match stage {
                    FailureStage::Reply | FailureStage::Transcription => {
                        matches!(turn.reply, ReplyState::Attempting { .. })
                    }
                    FailureStage::Speech => {
                        matches!(turn.speech, Some(SpeechState::Attempting { .. }))
                    }
                }
            })?;
        }
        Ok(())
    }

    fn conversation_has_work(&self, project_id: &str, conversation_id: &str) -> bool {
        let Ok(records) = self.inner.store.records(project_id, conversation_id) else {
            // A transient read failure after releasing the in-memory claim
            // must keep a supervised retry alive.
            return true;
        };
        ConversationWorkflow::from_records(&records).has_runnable_turn(epoch_millis())
    }

    pub fn resume(&self) -> Result<()> {
        for (project_id, conversation_id) in self.inner.store.conversation_keys()? {
            self.resume_conversation(&project_id, &conversation_id)
                .with_context(|| format!("resume conversation {project_id}/{conversation_id}"))?;
        }
        Ok(())
    }

    fn resume_conversation(&self, project_id: &str, conversation_id: &str) -> Result<()> {
        let records = self.inner.store.records(project_id, conversation_id)?;
        let workflow = ConversationWorkflow::from_records(&records);
        for clip_id in workflow.interrupted_transcriptions() {
            self.recover_interrupted_media(
                project_id,
                conversation_id,
                &clip_id,
                MediaStage::Transcription,
                "startup_recovery",
            )?;
        }
        // Fail-fast doctrine: an interrupted description is durable work that
        // startup must explicitly reopen, exactly like transcripts.
        for image_id in workflow.interrupted_descriptions() {
            self.recover_interrupted_media(
                project_id,
                conversation_id,
                &image_id,
                MediaStage::Description,
                "startup_recovery",
            )?;
        }
        for (turn_id, stage) in workflow.interrupted_turn_stages() {
            let event = if stage == FailureStage::Speech {
                JournalWrite::speech_retry_requested(&turn_id, "startup_recovery")
            } else {
                JournalWrite::reply_retry_requested(&turn_id, "startup_recovery")
            };
            let expected_turn = turn_id.clone();
            self.append_if(project_id, conversation_id, event, move |records| {
                let workflow = ConversationWorkflow::from_records(records);
                let Some(turn) = workflow.turn(&expected_turn) else {
                    return false;
                };
                if stage == FailureStage::Speech {
                    matches!(turn.speech, Some(SpeechState::Attempting { .. }))
                } else {
                    matches!(turn.reply, ReplyState::Attempting { .. })
                }
            })?;
        }
        for turn in workflow.turns() {
            if matches!(turn.speech, Some(SpeechState::Succeeded(()))) {
                let path = self
                    .inner
                    .store
                    .speech_path(project_id, conversation_id, &turn.id)?;
                if hound::WavReader::open(&path).is_err() {
                    let expected_turn = turn.id.clone();
                    self.append_if(
                        project_id,
                        conversation_id,
                        JournalWrite::speech_retry_requested(&turn.id, "startup_validation"),
                        move |records| {
                            matches!(
                                ConversationWorkflow::from_records(records)
                                    .turn(&expected_turn)
                                    .and_then(|turn| turn.speech.as_ref()),
                                Some(SpeechState::Succeeded(()))
                            )
                        },
                    )?;
                }
            }
        }
        self.ensure_media_work(project_id, conversation_id)?;
        if !workflow.turns().is_empty() {
            self.wake_conversation(project_id.into(), conversation_id.into());
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

fn retry_deadline_ms(delay: Duration, owner_id: &str, attempt: u32) -> u64 {
    let delay_ms = u64::try_from(delay.as_millis()).unwrap_or(u64::MAX).max(1);
    let spread = delay_ms / 5;
    let mut hash = 0xcbf29ce484222325_u64 ^ u64::from(attempt);
    for byte in owner_id.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    let jitter = if spread > 0 {
        hash % spread.saturating_add(1)
    } else {
        0
    };
    epoch_millis()
        .saturating_add(delay_ms)
        .saturating_add(jitter)
}

async fn sleep_until_epoch_ms(deadline_ms: u64) {
    let remaining_ms = deadline_ms.saturating_sub(epoch_millis());
    if remaining_ms > 0 {
        // Tokio's timer is monotonic after this one wall-clock conversion.
        tokio::time::sleep(Duration::from_millis(remaining_ms)).await;
    }
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

fn stage_matches_runnable<T, F>(
    state: Option<&AttemptState<T, F>>,
    attempt: u32,
    retry_at_ms: u64,
) -> bool {
    match state {
        Some(AttemptState::Due { next_attempt }) => retry_at_ms == 0 && *next_attempt == attempt,
        Some(AttemptState::RetryScheduled {
            next_attempt,
            retry_at_ms: current_retry_at_ms,
            ..
        }) => *next_attempt == attempt && *current_retry_at_ms == retry_at_ms,
        _ => false,
    }
}

fn stage_matches_attempting<T, F>(state: Option<&AttemptState<T, F>>, attempt: u32) -> bool {
    matches!(
        state,
        Some(AttemptState::Attempting { attempt: current }) if *current == attempt
    )
}

fn stage_runnable_in(
    records: &[Value],
    stage: MediaStage,
    media_id: &str,
    attempt: u32,
    retry_at_ms: u64,
) -> bool {
    let workflow = ConversationWorkflow::from_records(records);
    match stage {
        MediaStage::Transcription => stage_matches_runnable(
            workflow.clip(media_id).map(|clip| &clip.transcript),
            attempt,
            retry_at_ms,
        ),
        MediaStage::Description => stage_matches_runnable(
            workflow.image(media_id).map(|image| &image.description),
            attempt,
            retry_at_ms,
        ),
    }
}

fn stage_attempting_in(records: &[Value], stage: MediaStage, media_id: &str, attempt: u32) -> bool {
    let workflow = ConversationWorkflow::from_records(records);
    match stage {
        MediaStage::Transcription => {
            stage_matches_attempting(workflow.clip(media_id).map(|clip| &clip.transcript), attempt)
        }
        MediaStage::Description => stage_matches_attempting(
            workflow.image(media_id).map(|image| &image.description),
            attempt,
        ),
    }
}

fn reply_runnable_in(records: &[Value], turn_id: &str, attempt: u32) -> bool {
    match ConversationWorkflow::from_records(records)
        .turn(turn_id)
        .map(|turn| &turn.reply)
    {
        Some(ReplyState::Due { next_attempt })
        | Some(ReplyState::RetryScheduled { next_attempt, .. }) => *next_attempt == attempt,
        _ => false,
    }
}

fn reply_attempting_in(records: &[Value], turn_id: &str, attempt: u32) -> bool {
    stage_matches_attempting(
        ConversationWorkflow::from_records(records)
            .turn(turn_id)
            .map(|turn| &turn.reply),
        attempt,
    )
}

// Request bounds (§3.4): every dimension of the provider call is bounded and
// deterministic — image parts, encoded payload, degraded reference lines, and
// total current-turn text. Nothing derived here is journaled.
const MAX_INLINE_IMAGE_PARTS: usize = 16;
const MAX_INLINE_IMAGE_ENCODED_BYTES: usize = 15 * 1024 * 1024;
const MAX_DEGRADED_IMAGE_LINES: usize = 24;
const MAX_CURRENT_TURN_TEXT_BYTES: usize = 32 * 1024;

/// One current-turn media element in TurnContent order.
enum TurnRequestItem {
    Text(String),
    Image {
        id: String,
        mime: String,
        data: Vec<u8>,
        description: Option<String>,
    },
}

struct BoundedTurnRequest {
    text: String,
    parts: Vec<ImagePart>,
}

fn turn_request_items(
    content: &crate::workflow::TurnContent,
    image_bytes: &HashMap<String, Vec<u8>>,
) -> Vec<TurnRequestItem> {
    let mut items = Vec::new();
    for item in &content.items {
        match item {
            TurnMedia::Transcript { text, .. } => {
                if crate::workflow::meaningful_user_text(text) {
                    items.push(TurnRequestItem::Text(text.clone()));
                }
            }
            TurnMedia::Image(image) => {
                // The caption is user text exactly once, at its media
                // position; image reference lines never repeat it.
                if let Some(caption) = image
                    .caption
                    .as_deref()
                    .map(str::trim)
                    .filter(|caption| !caption.is_empty())
                {
                    items.push(TurnRequestItem::Text(caption.to_string()));
                }
                items.push(TurnRequestItem::Image {
                    id: image.id.clone(),
                    mime: image.mime.clone(),
                    data: image_bytes.get(&image.id).cloned().unwrap_or_default(),
                    description: image.description.clone(),
                });
            }
        }
    }
    items
}

fn base64_encoded_len(bytes: usize) -> usize {
    bytes.div_ceil(3) * 4
}

/// Deterministically shape the current turn under the request bounds: inline
/// images newest-first within the part and encoded-byte caps; overflow images
/// degrade to reference lines (description or bare id, never the caption),
/// capped with a summary; total text collapses oldest-first into markers.
fn bound_current_turn(items: Vec<TurnRequestItem>) -> BoundedTurnRequest {
    let mut inline = HashSet::new();
    let mut encoded_total = 0usize;
    for (index, item) in items.iter().enumerate().rev() {
        let TurnRequestItem::Image { data, .. } = item else {
            continue;
        };
        if inline.len() >= MAX_INLINE_IMAGE_PARTS {
            break;
        }
        let encoded = base64_encoded_len(data.len());
        if encoded_total + encoded >= MAX_INLINE_IMAGE_ENCODED_BYTES {
            continue;
        }
        encoded_total += encoded;
        inline.insert(index);
    }

    enum Segment {
        UserText(String),
        ImageLine(String),
    }
    let mut segments = Vec::new();
    let mut parts = Vec::new();
    let mut summarized = 0usize;
    let mut degraded_lines = 0usize;
    for (index, item) in items.into_iter().enumerate() {
        match item {
            TurnRequestItem::Text(text) => segments.push(Segment::UserText(text)),
            TurnRequestItem::Image {
                id,
                mime,
                data,
                description,
            } => {
                if inline.contains(&index) {
                    parts.push(ImagePart { id, mime, data });
                } else if degraded_lines < MAX_DEGRADED_IMAGE_LINES {
                    degraded_lines += 1;
                    segments.push(Segment::ImageLine(match description {
                        Some(description) => format!("[Image {id}: {description}]"),
                        None => format!("[Image {id}]"),
                    }));
                } else {
                    summarized += 1;
                }
            }
        }
    }

    let render = |segments: &[Segment], truncated: bool, summarized: usize| {
        let mut lines = Vec::new();
        if truncated {
            lines.push("[+truncated]".to_string());
        }
        for segment in segments {
            match segment {
                Segment::UserText(text) | Segment::ImageLine(text) => lines.push(text.clone()),
            }
        }
        if summarized > 0 {
            lines.push(format!("[+{summarized} more images]"));
        }
        lines.join("\n")
    };

    let mut truncated = false;
    let mut start = 0usize;
    loop {
        let text = render(&segments[start..], truncated, summarized);
        if text.len() <= MAX_CURRENT_TURN_TEXT_BYTES {
            return BoundedTurnRequest { text, parts };
        }
        if start + 1 >= segments.len() {
            // A single oversized segment: hard-truncate on a character
            // boundary rather than losing the entire turn text.
            truncated = true;
            let markers = render(&[], truncated, summarized).len() + 1;
            let budget = MAX_CURRENT_TURN_TEXT_BYTES.saturating_sub(markers);
            if let Some(segment) = segments.get_mut(start) {
                let (Segment::UserText(text) | Segment::ImageLine(text)) = segment;
                let mut end = budget.min(text.len());
                while end > 0 && !text.is_char_boundary(end) {
                    end -= 1;
                }
                text.truncate(end);
            }
            return BoundedTurnRequest {
                text: render(&segments[start..], truncated, summarized),
                parts,
            };
        }
        // Collapse oldest-first: dropped image lines fold into the summary
        // count, dropped user text is marked once.
        match &segments[start] {
            Segment::UserText(_) => truncated = true,
            Segment::ImageLine(_) => summarized += 1,
        }
        start += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agentic::{CodexKnowledgeAgent, QueryEvent};
    use crate::store::{ClipUpload, CreateTurnOutcome, ImageUpload, PutImage, hex_sha256};

    #[test]
    fn conversation_supervision_preserves_a_wake_during_an_active_pass() {
        let mut supervision = ConversationSupervision::default();

        assert!(supervision.request("kibo/general"));
        assert!(!supervision.request("kibo/general"));
        assert!(
            supervision.finish_pass("kibo/general"),
            "the active task must reconcile work accepted during its pass"
        );
        assert!(!supervision.finish_pass("kibo/general"));
        assert!(
            supervision.request("kibo/general"),
            "a wake after atomic release must start a replacement task"
        );
    }

    #[test]
    fn history_uses_durable_turns_and_latest_provider_id() {
        let records = vec![
            json!({"kind":"clip","id":"c1"}),
            json!({"kind":"transcript","clip":"c1","text":"hello"}),
            json!({"kind":"turn","id":"t1","clips":["c1"]}),
            json!({"kind":"reply","turn":"t1","text":"hi","interaction_id":"provider-1"}),
            json!({"kind":"turn","id":"t2","clips":["c2"]}),
        ];
        let context = ConversationWorkflow::from_records(&records).history_before("t2");
        assert_eq!(context.turns.len(), 1);
        assert_eq!(context.turns[0].user, "hello");
        assert_eq!(context.turns[0].assistant, "hi");
        assert_eq!(
            context.previous_interaction_id.as_deref(),
            Some("provider-1")
        );
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
        state
            .reconcile_media("kibo", &conversation.id)
            .unwrap();
        let outcome = store
            .create_turn("kibo", conversation_id, "turn-1")
            .unwrap();
        assert!(matches!(outcome, CreateTurnOutcome::Created { .. }));
        state.wake_conversation("kibo".into(), conversation.id.clone());

        wait_for_event(&store, conversation_id, "speech_ready").await;
        let records = store.records("kibo", conversation_id).unwrap();
        let reply = records
            .iter()
            .find(|event| event["kind"] == "reply")
            .unwrap();
        let speech_started = records
            .iter()
            .find(|event| event["kind"] == "speech_started")
            .unwrap();
        assert_eq!(reply["speech_generation"], speech_started["generation"]);
        assert_eq!(reply["history_through_seq"], 0);
        assert!(
            store
                .speech_path("kibo", conversation_id, "turn-1")
                .unwrap()
                .exists()
        );

        put_test_clip(&store, conversation_id, "clip-2", wav, 2);
        state
            .reconcile_media("kibo", conversation_id)
            .unwrap();
        assert!(matches!(
            store
                .create_turn("kibo", conversation_id, "turn-2")
                .unwrap(),
            CreateTurnOutcome::Created { .. }
        ));
        state.wake_conversation("kibo".into(), conversation.id.clone());
        wait_for_matching_event(&store, conversation_id, |event| {
            event["kind"] == "reply" && event["turn"] == "turn-2"
        })
        .await;
        let records = store.records("kibo", conversation_id).unwrap();
        let first_reply_seq = records
            .iter()
            .find(|event| event["kind"] == "reply" && event["turn"] == "turn-1")
            .and_then(|event| event["seq"].as_u64())
            .unwrap();
        let second_reply = records
            .iter()
            .find(|event| event["kind"] == "reply" && event["turn"] == "turn-2")
            .unwrap();
        assert_eq!(second_reply["history_through_seq"], first_reply_seq);
    }

    #[tokio::test]
    async fn resume_synthesizes_a_reply_left_without_speech() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        store
            .append_fixture(
                "kibo",
                conversation_id,
                json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
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
    async fn resume_regenerates_a_ready_reply_whose_wav_is_missing() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        for event in [
            json!({"kind":"turn", "id":"turn-1", "clips":[]}),
            json!({"kind":"reply", "turn":"turn-1", "text":"Regenerate me", "audio":"tts/turn-1.wav"}),
            json!({"kind":"speech_started", "turn":"turn-1", "attempt":1, "generation":"lost-generation"}),
            json!({"kind":"speech_ready", "turn":"turn-1", "samples":10, "rate":24000}),
        ] {
            store
                .append_fixture("kibo", conversation_id, event)
                .unwrap();
        }

        let state = AppState::new(store.clone(), Ai::mock());
        state.resume().unwrap();

        wait_for_event_count(&store, conversation_id, "speech_ready", 2).await;
        let records = store.records("kibo", conversation_id).unwrap();
        assert!(records.iter().any(|event| {
            event["kind"] == "speech_retry_requested"
                && event["turn"] == "turn-1"
                && event["reason"] == "startup_validation"
        }));
        assert_eq!(
            records
                .iter()
                .filter(|event| event["kind"] == "speech_started" && event["turn"] == "turn-1")
                .count(),
            2
        );
        hound::WavReader::open(
            store
                .speech_path("kibo", conversation_id, "turn-1")
                .unwrap(),
        )
        .unwrap();
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
                .append_fixture("kibo", conversation_id, json!({"kind":"clip", "id":clip}))
                .unwrap();
            store
                .append_fixture(
                    "kibo",
                    conversation_id,
                    json!({"kind":"transcript", "clip":clip, "text":text}),
                )
                .unwrap();
            store
                .append_fixture(
                    "kibo",
                    conversation_id,
                    json!({"kind":"turn", "id":turn, "clips":[clip]}),
                )
                .unwrap();
        }
        let state = AppState::new(store.clone(), Ai::mock());
        // Even a later turn winning the request race cannot overtake the log.
        state.wake_conversation("kibo".into(), conversation.id.clone());
        state.wake_conversation("kibo".into(), conversation.id.clone());
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
    async fn startup_recovery_explicitly_reopens_every_interrupted_stage() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();

        let transcription = store
            .create_conversation("kibo", Some("Interrupted transcription"))
            .unwrap();
        put_test_clip(
            &store,
            &transcription.id,
            "clip-transcription",
            b"RIFF0000WAVE transcription",
            1,
        );
        store
            .append_fixture(
                "kibo",
                &transcription.id,
                json!({"kind":"transcript_started", "clip":"clip-transcription", "attempt":1}),
            )
            .unwrap();

        let reply = store
            .create_conversation("kibo", Some("Interrupted reply"))
            .unwrap();
        store
            .append_fixture("kibo", &reply.id, json!({"kind":"clip", "id":"clip-reply"}))
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &reply.id,
                json!({"kind":"transcript", "clip":"clip-reply", "text":"continue"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &reply.id,
                json!({"kind":"turn", "id":"turn-reply", "clips":["clip-reply"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &reply.id,
                json!({"kind":"reply_started", "turn":"turn-reply", "attempt":1}),
            )
            .unwrap();

        let speech = store
            .create_conversation("kibo", Some("Interrupted speech"))
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &speech.id,
                json!({"kind":"turn", "id":"turn-speech", "clips":[]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &speech.id,
                json!({"kind":"reply", "turn":"turn-speech", "text":"continue speech", "audio":"tts/turn-speech.wav"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &speech.id,
                json!({"kind":"speech_started", "turn":"turn-speech", "attempt":1}),
            )
            .unwrap();

        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );
        state.resume().unwrap();

        wait_for_event(&store, &transcription.id, "transcript").await;
        wait_for_event(&store, &reply.id, "reply").await;
        wait_for_event(&store, &speech.id, "speech_ready").await;
        for (conversation_id, kind) in [
            (&transcription.id, "transcript_retry_requested"),
            (&reply.id, "reply_retry_requested"),
            (&speech.id, "speech_retry_requested"),
        ] {
            assert!(
                store
                    .records("kibo", conversation_id)
                    .unwrap()
                    .iter()
                    .any(|event| event["kind"] == kind && event["reason"] == "startup_recovery")
            );
        }
    }

    #[tokio::test]
    async fn startup_recovery_fails_fast_instead_of_abandoning_an_interrupted_stage() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store
            .create_conversation("kibo", Some("Interrupted"))
            .unwrap();
        put_test_clip(
            &store,
            &conversation.id,
            "clip-1",
            b"RIFF0000WAVE interrupted",
            1,
        );
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"transcript_started", "clip":"clip-1", "attempt":1}),
            )
            .unwrap();
        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );

        store.fail_append_after(0);
        assert!(state.resume().is_err());
        state.resume().unwrap();
        wait_for_event(&store, &conversation.id, "transcript").await;
    }

    #[tokio::test]
    async fn supervised_reconciliation_retries_a_transient_scheduling_read_failure() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        put_test_clip(
            &store,
            &conversation.id,
            "clip-1",
            b"RIFF0000WAVE reconcile",
            1,
        );
        store
            .create_turn("kibo", &conversation.id, "turn-1")
            .unwrap();
        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );

        store.fail_next_record_reads(1);
        state.wake_conversation("kibo".into(), conversation.id.clone());
        tokio::time::timeout(Duration::from_secs(1), async {
            while store.record_read_failures_remaining() > 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        wait_for_event(&store, &conversation.id, "speech_ready").await;
    }

    #[tokio::test]
    async fn explicit_transcription_retry_survives_a_transient_supervisor_read_failure() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        put_test_clip(
            &store,
            &conversation.id,
            "clip-1",
            b"RIFF0000WAVE retry supervision",
            1,
        );
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({
                    "kind":"transcript_error", "clip":"clip-1", "attempt":1,
                    "stage":"transcription", "terminal":true, "error":"terminal"
                }),
            )
            .unwrap();
        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );

        assert!(
            state
                .retry_transcription("kibo", &conversation.id, "clip-1", "explicit_retry")
                .unwrap()
        );
        // The current-thread test runtime cannot poll the spawned supervisor
        // until this task yields, so this deterministically fails its first
        // post-commit reconciliation read.
        store.fail_next_record_reads(1);
        tokio::time::timeout(Duration::from_secs(1), async {
            while store.record_read_failures_remaining() > 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();

        wait_for_event(&store, &conversation.id, "transcript").await;
    }

    #[tokio::test]
    async fn partial_multi_clip_turn_retry_keeps_committed_work_supervised() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        for (clip_id, recorded_at) in [("clip-1", 1), ("clip-2", 2)] {
            put_test_clip(
                &store,
                &conversation.id,
                clip_id,
                format!("RIFF0000WAVE {clip_id}").as_bytes(),
                recorded_at,
            );
            store
                .append_fixture(
                    "kibo",
                    &conversation.id,
                    json!({
                        "kind":"transcript_error", "clip":clip_id, "attempt":1,
                        "stage":"transcription", "terminal":true, "error":"terminal"
                    }),
                )
                .unwrap();
        }
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"turn", "id":"turn-1", "clips":["clip-1", "clip-2"]}),
            )
            .unwrap();
        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );

        store.fail_append_after(1);
        let error = state
            .retry_turn("kibo", &conversation.id, "turn-1")
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("injected journal append failure")
        );

        wait_for_matching_event(&store, &conversation.id, |event| {
            event["kind"] == "transcript" && event["clip"] == "clip-1"
        })
        .await;
        let records = store.records("kibo", &conversation.id).unwrap();
        assert!(records.iter().any(|event| {
            event["kind"] == "transcript_retry_requested" && event["clip"] == "clip-1"
        }));
        assert!(!records.iter().any(|event| {
            event["kind"] == "transcript_retry_requested" && event["clip"] == "clip-2"
        }));
    }

    #[tokio::test]
    async fn transcription_retries_at_runtime_without_restart() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        let wav = b"RIFF0000WAVE retry me";
        put_test_clip(&store, conversation_id, "clip-1", wav, 1);

        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock_failing_transcriptions(1),
            test_workflow_policy(&[Duration::from_millis(1)], &[], &[]),
        );
        state
            .reconcile_media("kibo", &conversation.id)
            .unwrap();

        wait_for_matching_event(&store, conversation_id, |event| {
            event["kind"] == "transcript_retry_scheduled"
        })
        .await;
        wait_for_matching_event(&store, conversation_id, |event| {
            event["kind"] == "transcript" && event["clip"] == "clip-1"
        })
        .await;

        let records = store.records("kibo", conversation_id).unwrap();
        let attempts: Vec<_> = records
            .iter()
            .filter(|event| event["kind"] == "transcript_started")
            .filter_map(|event| event["attempt"].as_u64())
            .collect();
        assert_eq!(attempts, [1, 2]);
        let retry = records
            .iter()
            .find(|event| event["kind"] == "transcript_retry_scheduled")
            .unwrap();
        assert_eq!(retry["attempt"], 1);
        assert!(retry.get("terminal").is_none());
        assert!(retry["retry_at_ms"].as_u64().is_some());
    }

    #[tokio::test]
    async fn transcription_supervisor_recovers_a_durable_interrupted_attempt() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        put_test_clip(
            &store,
            conversation_id,
            "clip-1",
            b"RIFF0000WAVE recover infrastructure",
            1,
        );

        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );
        // Persist transcript_started, then fail the result append. The next
        // supervisor pass must turn that durable Attempting state back into
        // explicit runnable work instead of relying on its in-memory set.
        store.fail_append_after(1);
        state
            .reconcile_media("kibo", &conversation.id)
            .unwrap();

        wait_for_matching_event(&store, conversation_id, |event| {
            event["kind"] == "transcript" && event["clip"] == "clip-1"
        })
        .await;
        let records = store.records("kibo", conversation_id).unwrap();
        assert!(records.iter().any(|event| {
            event["kind"] == "transcript_retry_requested"
                && event["clip"] == "clip-1"
                && event["reason"] == "supervisor_recovery"
        }));
        assert_eq!(
            records
                .iter()
                .filter(|event| event["kind"] == "transcript_started")
                .count(),
            2
        );
    }

    #[tokio::test]
    async fn terminal_transcription_failure_does_not_starve_later_turns() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        let wav = b"RIFF0000WAVE mock";

        put_test_clip(&store, conversation_id, "clip-1", wav, 1);
        store
            .create_turn("kibo", conversation_id, "turn-1")
            .unwrap();
        std::fs::remove_file(store.clip_path("kibo", conversation_id, "clip-1").unwrap()).unwrap();

        put_test_clip(&store, conversation_id, "clip-2", wav, 2);
        store
            .append_fixture(
                "kibo",
                conversation_id,
                json!({"kind":"transcript", "clip":"clip-2", "text":"second"}),
            )
            .unwrap();
        store
            .create_turn("kibo", conversation_id, "turn-2")
            .unwrap();

        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );
        state
            .reconcile_media("kibo", &conversation.id)
            .unwrap();
        state.wake_conversation("kibo".into(), conversation.id.clone());

        wait_for_matching_event(&store, conversation_id, |event| {
            event["kind"] == "speech_ready" && event["turn"] == "turn-2"
        })
        .await;
        let records = store.records("kibo", conversation_id).unwrap();
        let terminal_transcript = records
            .iter()
            .find(|event| event["kind"] == "transcript_error" && event["clip"] == "clip-1")
            .unwrap();
        assert_eq!(terminal_transcript["attempt"], 1);
        assert_eq!(terminal_transcript["terminal"], true);
        let turn_errors: Vec<_> = records
            .iter()
            .filter(|event| event["kind"] == "reply_error" && event["turn"] == "turn-1")
            .collect();
        assert_eq!(turn_errors.len(), 1);
        assert_eq!(turn_errors[0]["terminal"], true);
        assert_eq!(turn_errors[0]["stage"], "transcription");
        assert!(
            records
                .iter()
                .any(|event| event["kind"] == "reply" && event["turn"] == "turn-2")
        );

        // The store distinguishes a real payload repair from an inert replay;
        // only the repair path explicitly reopens terminal transcription.
        put_test_clip(&store, conversation_id, "clip-1", wav, 1);
        state
            .retry_transcription("kibo", conversation_id, "clip-1", "payload_repaired")
            .unwrap();
        wait_for_matching_event(&store, conversation_id, |event| {
            event["kind"] == "transcript" && event["clip"] == "clip-1"
        })
        .await;
        wait_for_matching_event(&store, conversation_id, |event| {
            event["kind"] == "speech_ready" && event["turn"] == "turn-1"
        })
        .await;
        let recovered = store.records("kibo", conversation_id).unwrap();
        assert!(recovered.iter().any(|event| {
            event["kind"] == "transcript_retry_requested" && event["clip"] == "clip-1"
        }));
        assert!(!recovered.iter().any(|event| {
            event["kind"] == "reply_retry_requested" && event["turn"] == "turn-1"
        }));
        assert_eq!(
            recovered
                .iter()
                .filter(|event| event["kind"] == "reply" && event["turn"] == "turn-1")
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn repeated_terminal_transcription_failure_recloses_the_turn() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        put_test_clip(
            &store,
            conversation_id,
            "clip-1",
            b"RIFF0000WAVE missing twice",
            1,
        );
        store
            .create_turn("kibo", conversation_id, "turn-1")
            .unwrap();
        std::fs::remove_file(store.clip_path("kibo", conversation_id, "clip-1").unwrap()).unwrap();

        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );
        state
            .reconcile_media("kibo", conversation_id)
            .unwrap();
        state.wake_conversation("kibo".into(), conversation.id.clone());
        wait_for_event_count(&store, conversation_id, "reply_error", 1).await;

        assert!(
            state
                .retry_transcription("kibo", conversation_id, "clip-1", "explicit_retry")
                .unwrap()
        );
        wait_for_event_count(&store, conversation_id, "transcript_error", 2).await;
        wait_for_event_count(&store, conversation_id, "reply_error", 2).await;

        let records = store.records("kibo", conversation_id).unwrap();
        let turn_errors: Vec<_> = records
            .iter()
            .filter(|event| event["kind"] == "reply_error" && event["turn"] == "turn-1")
            .collect();
        assert_eq!(turn_errors.len(), 2);
        assert_eq!(turn_errors[1]["terminal"], true);
        assert_eq!(turn_errors[1]["stage"], "transcription");
        assert!(
            ConversationWorkflow::from_records(&records)
                .next_turn_action(epoch_millis())
                .is_none()
        );
    }

    #[tokio::test]
    async fn payload_repair_supersedes_an_in_flight_transcription_attempt() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let wav = b"RIFF0000WAVE canonical";
        put_test_clip(&store, &conversation.id, "clip-1", wav, 1);
        let (ai, provider_started, release_provider) = Ai::mock_blocking_transcription();
        let state =
            AppState::with_workflow_policy(store.clone(), ai, test_workflow_policy(&[], &[], &[]));
        state
            .reconcile_media("kibo", &conversation.id)
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), provider_started.notified())
            .await
            .unwrap();

        std::fs::write(
            store.clip_path("kibo", &conversation.id, "clip-1").unwrap(),
            b"damaged while the provider is running",
        )
        .unwrap();
        let sha = hex_sha256(wav);
        let (outcome, event) = store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id: &conversation.id,
                clip_id: "clip-1",
                bytes: wav,
                expected_sha256: &sha,
                duration_ms: 800,
                peak_pct: 20,
                recorded_at: 1,
            })
            .unwrap();
        assert_eq!(outcome, crate::store::PutClip::Repaired);
        state.publish_persisted("kibo", &conversation.id, event.unwrap());
        state
            .reconcile_media("kibo", &conversation.id)
            .unwrap();
        release_provider.notify_one();

        wait_for_event(&store, &conversation.id, "transcript").await;
        let records = store.records("kibo", &conversation.id).unwrap();
        let started: Vec<_> = records
            .iter()
            .filter(|event| event["kind"] == "transcript_started" && event["clip"] == "clip-1")
            .collect();
        assert_eq!(started.len(), 2);
        assert_eq!(started[0]["attempt"], 1);
        assert_eq!(started[1]["attempt"], 1);
        let repair_seq = records
            .iter()
            .find(|event| event["reason"] == "payload_repaired")
            .unwrap()["seq"]
            .as_u64()
            .unwrap();
        assert!(started[0]["seq"].as_u64().unwrap() < repair_seq);
        assert!(repair_seq < started[1]["seq"].as_u64().unwrap());
        assert_eq!(
            records
                .iter()
                .filter(|event| event["kind"] == "transcript")
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn corrupt_clip_bytes_cannot_produce_an_authoritative_transcript() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let wav = b"RIFF0000WAVE canonical";
        put_test_clip(&store, &conversation.id, "clip-1", wav, 1);
        std::fs::write(
            store.clip_path("kibo", &conversation.id, "clip-1").unwrap(),
            b"not the journaled payload",
        )
        .unwrap();
        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );
        state
            .reconcile_media("kibo", &conversation.id)
            .unwrap();

        wait_for_event(&store, &conversation.id, "transcript_error").await;
        let records = store.records("kibo", &conversation.id).unwrap();
        let failure = records
            .iter()
            .find(|event| event["kind"] == "transcript_error")
            .unwrap();
        assert_eq!(failure["terminal"], true);
        assert!(
            failure["error"]
                .as_str()
                .unwrap()
                .contains("does not match its durable SHA-256")
        );
        assert!(!records.iter().any(|event| event["kind"] == "transcript"));
    }

    #[tokio::test]
    async fn inert_clip_replay_does_not_reopen_terminal_provider_work() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let wav = b"RIFF0000WAVE provider failure";
        put_test_clip(&store, &conversation.id, "clip-1", wav, 1);
        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock_failing_transcriptions(1),
            test_workflow_policy(&[], &[], &[]),
        );
        state
            .reconcile_media("kibo", &conversation.id)
            .unwrap();
        wait_for_matching_event(&store, &conversation.id, |event| {
            event["kind"] == "transcript_error" && event["terminal"] == true
        })
        .await;

        let sha = hex_sha256(wav);
        let (outcome, _) = store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id: &conversation.id,
                clip_id: "clip-1",
                bytes: wav,
                expected_sha256: &sha,
                duration_ms: 800,
                peak_pct: 20,
                recorded_at: 1,
            })
            .unwrap();
        assert_eq!(outcome, crate::store::PutClip::AlreadyExists);
        state
            .reconcile_media("kibo", &conversation.id)
            .unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        let before_retry = store.records("kibo", &conversation.id).unwrap();
        assert!(
            !before_retry
                .iter()
                .any(|event| event["kind"] == "transcript_retry_requested")
        );

        assert!(
            state
                .retry_transcription("kibo", &conversation.id, "clip-1", "explicit_retry")
                .unwrap()
        );
        wait_for_event(&store, &conversation.id, "transcript").await;
        assert!(
            state
                .retry_transcription("kibo", &conversation.id, "clip-1", "stale_retry")
                .unwrap()
        );
        assert_eq!(
            store
                .records("kibo", &conversation.id)
                .unwrap()
                .iter()
                .filter(|event| event["kind"] == "transcript_retry_requested")
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn inert_turn_replay_does_not_reopen_terminal_reply_work() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"clip", "id":"clip-1"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"transcript", "clip":"clip-1", "text":"retry explicitly"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"reply_error", "turn":"turn-1", "attempt":3, "terminal":true, "stage":"reply", "error":"provider rejected"}),
            )
            .unwrap();
        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );

        // This is what the API does for an existing idempotency key.
        state.wake_conversation("kibo".into(), conversation.id.clone());
        tokio::time::sleep(Duration::from_millis(50)).await;
        let before_retry = store.records("kibo", &conversation.id).unwrap();
        assert!(
            !before_retry
                .iter()
                .any(|event| event["kind"] == "reply_retry_requested")
        );
        assert!(
            !before_retry
                .iter()
                .any(|event| event["kind"] == "reply_started")
        );

        assert!(
            state
                .retry_turn("kibo", &conversation.id, "turn-1")
                .unwrap()
        );
        wait_for_event(&store, &conversation.id, "reply").await;
        assert!(
            state
                .retry_turn("kibo", &conversation.id, "turn-1")
                .unwrap()
        );
        assert_eq!(
            store
                .records("kibo", &conversation.id)
                .unwrap()
                .iter()
                .filter(|event| event["kind"] == "reply_retry_requested")
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn legacy_reply_error_is_retried_by_the_running_supervisor() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        store
            .append_fixture(
                "kibo",
                conversation_id,
                json!({"kind":"clip", "id":"clip-1"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                conversation_id,
                json!({"kind":"transcript", "clip":"clip-1", "text":"retry me"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                conversation_id,
                json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                conversation_id,
                json!({"kind":"reply_error", "turn":"turn-1", "error":"legacy outage"}),
            )
            .unwrap();

        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );
        state.wake_conversation("kibo".into(), conversation.id.clone());
        wait_for_matching_event(&store, conversation_id, |event| {
            event["kind"] == "reply" && event["turn"] == "turn-1"
        })
        .await;
        let records = store.records("kibo", conversation_id).unwrap();
        assert!(records.iter().any(|event| {
            event["kind"] == "reply_started" && event["turn"] == "turn-1" && event["attempt"] == 1
        }));
    }

    #[tokio::test]
    async fn speech_retry_honors_millisecond_deadline_and_recovers() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        store
            .append_fixture(
                "kibo",
                conversation_id,
                json!({"kind":"turn", "id":"turn-1", "clips":["clip-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                conversation_id,
                json!({"kind":"reply", "turn":"turn-1", "text":"Recovered speech", "audio":"tts/turn-1.wav"}),
            )
            .unwrap();
        let deadline = epoch_millis() + 250;
        store
            .append_fixture(
                "kibo",
                conversation_id,
                json!({
                    "kind":"tts_error", "turn":"turn-1", "attempt":1,
                    "retry_at_ms":deadline, "terminal":false, "error":"temporary"
                }),
            )
            .unwrap();

        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );
        let started = std::time::Instant::now();
        state.wake_conversation("kibo".into(), conversation.id.clone());
        wait_for_matching_event(&store, conversation_id, |event| {
            event["kind"] == "speech_ready" && event["turn"] == "turn-1"
        })
        .await;
        assert!(started.elapsed() >= Duration::from_millis(180));
        let records = store.records("kibo", conversation_id).unwrap();
        assert!(records.iter().any(|event| {
            event["kind"] == "speech_started" && event["turn"] == "turn-1" && event["attempt"] == 2
        }));
    }

    #[tokio::test]
    async fn knowledge_ingestion_skips_unchanged_and_force_replaces_the_note() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store
            .create_conversation("kibo", Some("Design notes"))
            .unwrap();
        store
            .append_fixture(
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
            .append_fixture(
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
    async fn image_descriptions_dirty_the_note_again_after_the_turn_lands() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", Some("Camera roll")).unwrap();
        for event in [
            json!({"kind":"image", "id":"img-1", "recorded_at":1000, "caption":"whiteboard after standup"}),
            json!({"kind":"turn", "id":"turn-1", "images":["img-1"]}),
            json!({"kind":"reply", "turn":"turn-1", "text":"Looks busy."}),
        ] {
            store
                .append_fixture("kibo", &conversation.id, event)
                .unwrap();
        }
        let state = AppState::new(store.clone(), Ai::mock());
        let wiki_path = format!("wiki/sources/conversation--{}.md", conversation.id);
        let dirty = |store: &Store| {
            knowledge::source_statuses(store, "kibo")
                .unwrap()
                .iter()
                .any(|status| status.id == conversation.id && status.dirty)
        };

        // Transition one: the turn and reply land while the description is
        // still pending — the note compiles without any image reference.
        assert!(dirty(&store));
        let first = state
            .ingest_conversation("kibo", &conversation.id, false)
            .await
            .unwrap();
        assert!(matches!(first, IngestOutcome::Ingested(ref receipt) if receipt.generation == 1));
        let note = knowledge::read_markdown(&store, "kibo", &wiki_path).unwrap();
        assert!(note.contains("whiteboard after standup"));
        assert!(!note.contains("[Image"));
        assert!(!note.contains("## Images"));
        assert!(matches!(
            state
                .ingest_conversation("kibo", &conversation.id, false)
                .await
                .unwrap(),
            IngestOutcome::Skipped
        ));

        // Transition two: the description value lands and dirties the note a
        // second time; the recompiled note carries the reference line and the
        // mechanical appendix.
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"description", "image":"img-1", "text":"Sticky notes grouped into three lanes"}),
            )
            .unwrap();
        assert!(dirty(&store));
        let once = knowledge::conversation_document(&store, "kibo", &conversation.id).unwrap();
        let twice = knowledge::conversation_document(&store, "kibo", &conversation.id).unwrap();
        assert_eq!(once.body, twice.body);
        assert_eq!(once.content_sha256, twice.content_sha256);
        let second = state
            .ingest_conversation("kibo", &conversation.id, false)
            .await
            .unwrap();
        assert!(matches!(second, IngestOutcome::Ingested(ref receipt) if receipt.generation == 2));
        let note = knowledge::read_markdown(&store, "kibo", &wiki_path).unwrap();
        assert!(note.contains("[Image img-1: Sticky notes grouped into three lanes]"));
        assert!(note.contains("### Image img-1 <a id=\"img-img-1\"></a>"));
        assert!(note.contains("> Sticky notes grouped into three lanes"));
        // Caption uniformity: the caption appears once (as user text in the
        // compiled source material), never in the image line or appendix.
        assert_eq!(note.matches("whiteboard after standup").count(), 1);
        assert!(matches!(
            state
                .ingest_conversation("kibo", &conversation.id, false)
                .await
                .unwrap(),
            IngestOutcome::Skipped
        ));
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

    fn test_jpeg(payload: &[u8]) -> Vec<u8> {
        let mut bytes = vec![0xFF, 0xD8, 0xFF, 0xE0];
        bytes.extend_from_slice(payload);
        bytes
    }

    fn put_test_image(
        store: &Store,
        conversation_id: &str,
        image_id: &str,
        bytes: &[u8],
        recorded_at: u64,
        caption: Option<&str>,
    ) -> String {
        let sha = hex_sha256(bytes);
        store
            .put_image(ImageUpload {
                project_id: "kibo",
                conversation_id,
                image_id,
                bytes,
                expected_sha256: &sha,
                recorded_at,
                width: None,
                height: None,
                caption: caption.map(str::to_string),
            })
            .unwrap();
        sha
    }

    #[tokio::test]
    async fn mock_pipeline_answers_an_image_only_turn() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        let jpeg = test_jpeg(b"desk photo");
        let sha = put_test_image(&store, conversation_id, "img-1", &jpeg, 1, None);
        let state = AppState::new(store.clone(), Ai::mock());
        state.reconcile_media("kibo", conversation_id).unwrap();
        let outcome = store.create_turn("kibo", conversation_id, "turn-1").unwrap();
        let CreateTurnOutcome::Created { images, clips, .. } = outcome else {
            panic!("expected a new turn");
        };
        assert_eq!(images, ["img-1"]);
        assert!(clips.is_empty());
        state.wake_conversation("kibo".into(), conversation.id.clone());

        wait_for_event(&store, conversation_id, "speech_ready").await;
        wait_for_event(&store, conversation_id, "description").await;
        let records = store.records("kibo", conversation_id).unwrap();
        let reply = records
            .iter()
            .find(|event| event["kind"] == "reply")
            .unwrap();
        // The mock proves the model received the actual pixels, and the turn
        // was answerable with no text at all.
        assert_eq!(
            reply["text"],
            format!("I see 1 image(s): {}", &sha[..8])
        );
        assert!(reply["audio"].is_string());
        let description = records
            .iter()
            .find(|event| event["kind"] == "description")
            .unwrap();
        assert_eq!(
            description["text"],
            format!("MOCK IMAGE: {}", &sha[..8])
        );
        assert_eq!(description["model"], "mock");
        assert_eq!(description["prompt_version"], 1);
        assert!(
            !records
                .iter()
                .any(|event| event["text"] == "[nothing to answer]")
        );
    }

    #[tokio::test]
    async fn mock_pipeline_combines_text_captions_and_images() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        put_test_clip(&store, conversation_id, "clip-1", b"RIFF0000WAVE mock", 1);
        let jpeg = test_jpeg(b"desk photo");
        let sha = put_test_image(
            &store,
            conversation_id,
            "img-1",
            &jpeg,
            2,
            Some("on my desk"),
        );
        let state = AppState::new(store.clone(), Ai::mock());
        state.reconcile_media("kibo", conversation_id).unwrap();
        store.create_turn("kibo", conversation_id, "turn-1").unwrap();
        state.wake_conversation("kibo".into(), conversation.id.clone());

        wait_for_event(&store, conversation_id, "speech_ready").await;
        let records = store.records("kibo", conversation_id).unwrap();
        let reply = records
            .iter()
            .find(|event| event["kind"] == "reply")
            .unwrap();
        // Transcript then caption in media order, then the pixel receipt.
        assert_eq!(
            reply["text"],
            format!(
                "I heard you say: Mock voice transcript\non my desk [saw 1 image(s): {}]",
                &sha[..8]
            )
        );
    }

    #[tokio::test]
    async fn silent_clip_with_image_is_still_answerable() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        let wav = b"RIFF0000WAVE silent";
        let sha = hex_sha256(wav);
        store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id,
                clip_id: "clip-1",
                bytes: wav,
                expected_sha256: &sha,
                duration_ms: 800,
                peak_pct: 0, // transcribes to the [silent] sentinel
                recorded_at: 1,
            })
            .unwrap();
        let jpeg = test_jpeg(b"just pixels");
        let image_sha = put_test_image(&store, conversation_id, "img-1", &jpeg, 2, None);
        let state = AppState::new(store.clone(), Ai::mock());
        state.reconcile_media("kibo", conversation_id).unwrap();
        store.create_turn("kibo", conversation_id, "turn-1").unwrap();
        state.wake_conversation("kibo".into(), conversation.id.clone());

        wait_for_event(&store, conversation_id, "speech_ready").await;
        let records = store.records("kibo", conversation_id).unwrap();
        let reply = records
            .iter()
            .find(|event| event["kind"] == "reply")
            .unwrap();
        assert_eq!(
            reply["text"],
            format!("I see 1 image(s): {}", &image_sha[..8])
        );
    }

    #[tokio::test]
    async fn corrupt_image_bytes_cannot_reach_the_model() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        let jpeg = test_jpeg(b"original pixels");
        let sha = put_test_image(&store, conversation_id, "img-1", &jpeg, 1, None);
        store.create_turn("kibo", conversation_id, "turn-1").unwrap();
        std::fs::write(
            store.image_path("kibo", conversation_id, "img-1").unwrap(),
            b"not the journaled payload",
        )
        .unwrap();
        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );
        state.wake_conversation("kibo".into(), conversation.id.clone());

        wait_for_matching_event(&store, conversation_id, |event| {
            event["kind"] == "reply_error" && event["terminal"] == true
        })
        .await;
        let records = store.records("kibo", conversation_id).unwrap();
        let failure = records
            .iter()
            .find(|event| event["kind"] == "reply_error")
            .unwrap();
        assert!(
            failure["error"]
                .as_str()
                .unwrap()
                .contains("does not match its durable SHA-256")
        );
        assert!(!records.iter().any(|event| event["kind"] == "reply"));

        // Repair restores the bytes and reopens the closed reply; the turn
        // then completes against verified pixels.
        let upload_sha = sha.clone();
        let (outcome, events) = store
            .put_image(ImageUpload {
                project_id: "kibo",
                conversation_id,
                image_id: "img-1",
                bytes: &jpeg,
                expected_sha256: &upload_sha,
                recorded_at: 1,
                width: None,
                height: None,
                caption: None,
            })
            .unwrap();
        assert_eq!(outcome, PutImage::Repaired);
        assert!(
            events
                .iter()
                .any(|event| event["kind"] == "reply_retry_requested")
        );
        state.reconcile_media("kibo", conversation_id).unwrap();
        state.wake_conversation("kibo".into(), conversation.id.clone());
        wait_for_event(&store, conversation_id, "reply").await;
        let reply_text = store
            .records("kibo", conversation_id)
            .unwrap()
            .iter()
            .find(|event| event["kind"] == "reply")
            .unwrap()["text"]
            .clone();
        assert_eq!(reply_text, format!("I see 1 image(s): {}", &sha[..8]));
    }

    #[tokio::test]
    async fn payload_repair_supersedes_an_in_flight_reply_attempt() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        let jpeg = test_jpeg(b"raced pixels");
        let sha = put_test_image(&store, conversation_id, "img-1", &jpeg, 1, None);
        store.create_turn("kibo", conversation_id, "turn-1").unwrap();
        let (ai, chat_started, release_chat) = Ai::mock_blocking_chat();
        let state =
            AppState::with_workflow_policy(store.clone(), ai, test_workflow_policy(&[], &[], &[]));
        state.wake_conversation("kibo".into(), conversation.id.clone());
        tokio::time::timeout(Duration::from_secs(2), chat_started.notified())
            .await
            .unwrap();

        // The provider call is in flight; repair lands and reopens the turn.
        std::fs::write(
            store.image_path("kibo", conversation_id, "img-1").unwrap(),
            b"damaged while the provider is running",
        )
        .unwrap();
        let (outcome, events) = store
            .put_image(ImageUpload {
                project_id: "kibo",
                conversation_id,
                image_id: "img-1",
                bytes: &jpeg,
                expected_sha256: &sha,
                recorded_at: 1,
                width: None,
                height: None,
                caption: None,
            })
            .unwrap();
        assert_eq!(outcome, PutImage::Repaired);
        assert!(
            events
                .iter()
                .any(|event| event["kind"] == "reply_retry_requested")
        );
        release_chat.notify_one();

        wait_for_event(&store, conversation_id, "reply").await;
        let records = store.records("kibo", conversation_id).unwrap();
        let started: Vec<_> = records
            .iter()
            .filter(|event| event["kind"] == "reply_started")
            .collect();
        assert_eq!(started.len(), 2);
        assert_eq!(started[0]["attempt"], 1);
        assert_eq!(started[1]["attempt"], 1);
        let repair_seq = records
            .iter()
            .find(|event| {
                event["kind"] == "reply_retry_requested" && event["reason"] == "payload_repaired"
            })
            .unwrap()["seq"]
            .as_u64()
            .unwrap();
        // The superseded attempt's result was discarded: exactly one reply,
        // produced by the attempt started after the repair.
        assert!(started[0]["seq"].as_u64().unwrap() < repair_seq);
        assert!(repair_seq < started[1]["seq"].as_u64().unwrap());
        assert_eq!(
            records
                .iter()
                .filter(|event| event["kind"] == "reply")
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn startup_recovery_reopens_an_interrupted_description() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let conversation_id = conversation.id.as_str();
        let jpeg = test_jpeg(b"interrupted");
        let sha = put_test_image(&store, conversation_id, "img-1", &jpeg, 1, None);
        store
            .append_fixture(
                "kibo",
                conversation_id,
                json!({"kind":"description_started", "image":"img-1", "attempt":1}),
            )
            .unwrap();
        let state = AppState::with_workflow_policy(
            store.clone(),
            Ai::mock(),
            test_workflow_policy(&[], &[], &[]),
        );
        state.resume().unwrap();

        wait_for_event(&store, conversation_id, "description").await;
        let records = store.records("kibo", conversation_id).unwrap();
        assert!(records.iter().any(|event| {
            event["kind"] == "description_retry_requested"
                && event["image"] == "img-1"
                && event["reason"] == "startup_recovery"
        }));
        assert_eq!(
            records
                .iter()
                .find(|event| event["kind"] == "description")
                .unwrap()["text"],
            format!("MOCK IMAGE: {}", &sha[..8])
        );
    }

    #[test]
    fn bounded_request_encoded_boundary_is_exclusive() {
        // "stays under 15 MiB encoded": exactly-at-cap is rejected, one
        // base64 quantum under is inlined.
        let at_cap_raw = MAX_INLINE_IMAGE_ENCODED_BYTES / 4 * 3;
        assert_eq!(base64_encoded_len(at_cap_raw), MAX_INLINE_IMAGE_ENCODED_BYTES);
        let request = bound_current_turn(vec![TurnRequestItem::Image {
            id: "img-at".into(),
            mime: "image/jpeg".into(),
            data: vec![0u8; at_cap_raw],
            description: None,
        }]);
        assert!(request.parts.is_empty());
        assert_eq!(request.text, "[Image img-at]");

        let request = bound_current_turn(vec![TurnRequestItem::Image {
            id: "img-under".into(),
            mime: "image/jpeg".into(),
            data: vec![0u8; at_cap_raw - 3],
            description: None,
        }]);
        assert_eq!(request.parts.len(), 1);
        assert_eq!(request.text, "");
    }

    #[test]
    fn bounded_request_degrades_single_image_over_budget() {
        // One image whose encoding alone exceeds the cap still yields an
        // answerable request: it degrades to its reference line.
        let request = bound_current_turn(vec![TurnRequestItem::Image {
            id: "img-big".into(),
            mime: "image/jpeg".into(),
            data: vec![0u8; 12 * 1024 * 1024],
            description: Some("a mural".into()),
        }]);
        assert!(request.parts.is_empty());
        assert_eq!(request.text, "[Image img-big: a mural]");
    }

    #[test]
    fn bounded_request_caps_inline_parts_at_sixteen_newest() {
        let items: Vec<TurnRequestItem> = (0..17)
            .map(|index| TurnRequestItem::Image {
                id: format!("img-{index:02}"),
                mime: "image/jpeg".into(),
                data: vec![index as u8; 8],
                description: Some(format!("photo {index}")),
            })
            .collect();
        let request = bound_current_turn(items);
        assert_eq!(request.parts.len(), 16);
        // Newest sixteen inline, in media order; the oldest degrades.
        assert_eq!(request.parts[0].id, "img-01");
        assert_eq!(request.parts[15].id, "img-16");
        assert_eq!(request.text, "[Image img-00: photo 0]");
    }

    #[test]
    fn bounded_request_caps_encoded_bytes_and_degrades_oldest() {
        // Three 6 MiB images encode to 8 MiB each; only the newest fits the
        // 15 MiB encoded cap, so the older two degrade deterministically.
        let items: Vec<TurnRequestItem> = (0..3)
            .map(|index| TurnRequestItem::Image {
                id: format!("img-{index}"),
                mime: "image/jpeg".into(),
                data: vec![0u8; 6 * 1024 * 1024],
                description: (index == 0).then(|| "oldest".to_string()),
            })
            .collect();
        let request = bound_current_turn(items);
        assert_eq!(request.parts.len(), 1);
        assert_eq!(request.parts[0].id, "img-2");
        assert_eq!(request.text, "[Image img-0: oldest]\n[Image img-1]");
    }

    #[test]
    fn bounded_request_caps_degraded_lines_with_a_summary() {
        // 16 inline + 30 degraded: 24 reference lines plus a summary of 6.
        let items: Vec<TurnRequestItem> = (0..46)
            .map(|index| TurnRequestItem::Image {
                id: format!("img-{index:02}"),
                mime: "image/jpeg".into(),
                data: vec![1; 4],
                description: None,
            })
            .collect();
        let request = bound_current_turn(items);
        assert_eq!(request.parts.len(), 16);
        let lines: Vec<&str> = request.text.lines().collect();
        assert_eq!(lines.len(), 25);
        assert_eq!(lines[0], "[Image img-00]");
        assert_eq!(lines[23], "[Image img-23]");
        assert_eq!(lines[24], "[+6 more images]");
    }

    #[test]
    fn bounded_request_collapses_oversized_text_oldest_first() {
        let big = "x".repeat(20 * 1024);
        let items = vec![
            TurnRequestItem::Text(big.clone()),
            TurnRequestItem::Text(big.clone()),
            TurnRequestItem::Text("the newest words".to_string()),
        ];
        let request = bound_current_turn(items);
        assert!(request.text.len() <= MAX_CURRENT_TURN_TEXT_BYTES);
        assert!(request.text.starts_with("[+truncated]"));
        assert!(request.text.ends_with("the newest words"));

        // A single segment larger than the whole budget is truncated, not lost.
        let oversized = bound_current_turn(vec![TurnRequestItem::Text("y".repeat(40 * 1024))]);
        assert!(oversized.text.len() <= MAX_CURRENT_TURN_TEXT_BYTES);
        assert!(oversized.text.contains("yyy"));
    }

    async fn wait_for_event(store: &Store, conversation_id: &str, kind: &str) {
        wait_for_event_count(store, conversation_id, kind, 1).await;
    }

    fn test_workflow_policy(
        transcription: &[Duration],
        reply: &[Duration],
        speech: &[Duration],
    ) -> WorkflowPolicy {
        let retry = |delays: &[Duration]| RetryPolicy {
            retry_delays: Arc::from(delays.to_vec()),
        };
        WorkflowPolicy {
            transcription: retry(transcription),
            description: retry(transcription),
            reply: retry(reply),
            speech: retry(speech),
            infrastructure_delay: Duration::from_millis(25),
        }
    }

    fn put_test_clip(
        store: &Store,
        conversation_id: &str,
        clip_id: &str,
        wav: &[u8],
        recorded_at: u64,
    ) {
        let sha = hex_sha256(wav);
        store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id,
                clip_id,
                bytes: wav,
                expected_sha256: &sha,
                duration_ms: 800,
                peak_pct: 20,
                recorded_at,
            })
            .unwrap();
    }

    async fn wait_for_matching_event(
        store: &Store,
        conversation_id: &str,
        predicate: impl Fn(&Value) -> bool,
    ) {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if store
                    .records("kibo", conversation_id)
                    .unwrap()
                    .iter()
                    .any(&predicate)
                {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();
    }

    async fn wait_for_event_count(store: &Store, conversation_id: &str, kind: &str, count: usize) {
        tokio::time::timeout(Duration::from_secs(10), async {
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

use crate::ai::{Ai, HistoryTurn, TTS_RATE};
use crate::journal::JournalWrite;
use crate::knowledge::{self, Document, IngestReceipt, JinaReader, ReaderDocument, WebSource};
use crate::model::epoch_millis;
use crate::store::{AutoNameOutcome, Store, hex_sha256};
use crate::workflow::{
    ConversationWorkflow, FailureStage, HistoryContext, ReplyRecord, ReplyState, SpeechState,
    TranscriptState, TurnAction,
};
use anyhow::{Context, Result, anyhow};
use serde_json::Value;
#[cfg(test)]
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{Mutex as AsyncMutex, Semaphore, broadcast, watch};

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
    Reply(&'a str),
    Speech(&'a str),
}

impl Default for WorkflowPolicy {
    fn default() -> Self {
        let retry_delays: Arc<[Duration]> =
            Arc::from([Duration::from_secs(1), Duration::from_secs(5)]);
        Self {
            transcription: RetryPolicy {
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
            }),
        }
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

    /// Schedule currently due work for a newly available or replayed clip.
    /// This never reopens terminal work: an idempotent data submission is not
    /// a workflow control command.
    pub fn reconcile_transcriptions(&self, project_id: &str, conversation_id: &str) -> Result<()> {
        self.ensure_transcriptions(project_id, conversation_id)
    }

    /// Explicitly reopen a terminal transcription, then schedule all due clip
    /// work. Repeating this command while work is already open is inert.
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

    fn schedule_transcription(&self, project_id: String, conversation_id: String, clip_id: String) {
        let key = key3(&project_id, &conversation_id, &clip_id);
        if !self.inner.transcribing.lock().unwrap().insert(key.clone()) {
            return;
        }
        let state = self.clone();
        tokio::spawn(async move {
            let mut recover_infrastructure = false;
            loop {
                if recover_infrastructure {
                    tokio::time::sleep(state.inner.workflow_policy.infrastructure_delay).await;
                    match state.recover_interrupted_transcription(
                        &project_id,
                        &conversation_id,
                        &clip_id,
                        "supervisor_recovery",
                    ) {
                        Ok(()) => {}
                        Err(error) => {
                            tracing::error!(%project_id, %conversation_id, %clip_id, "recover transcription supervisor: {error:#}");
                            continue;
                        }
                    }
                }
                match state
                    .drive_transcription(&project_id, &conversation_id, &clip_id)
                    .await
                {
                    Ok(()) => break,
                    Err(error) => {
                        tracing::error!(%project_id, %conversation_id, %clip_id, "transcription infrastructure: {error:#}");
                        recover_infrastructure = true;
                    }
                }
            }
            state.inner.transcribing.lock().unwrap().remove(&key);
            if let Err(error) = state.ensure_transcriptions(&project_id, &conversation_id) {
                tracing::error!(%project_id, %conversation_id, %clip_id, "reschedule durable transcription work: {error:#}");
            }
            state.wake_conversation(project_id, conversation_id);
        });
    }

    async fn drive_transcription(
        &self,
        project_id: &str,
        conversation_id: &str,
        clip_id: &str,
    ) -> Result<()> {
        loop {
            let records = self.inner.store.records(project_id, conversation_id)?;
            let workflow = ConversationWorkflow::from_records(&records);
            let clip = workflow
                .clip(clip_id)
                .cloned()
                .ok_or_else(|| anyhow!("clip event is missing"))?;
            let (attempt, retry_at_ms) = match &clip.transcript {
                TranscriptState::Due { next_attempt } => (*next_attempt, 0),
                TranscriptState::RetryScheduled {
                    next_attempt,
                    retry_at_ms,
                    ..
                } => (*next_attempt, *retry_at_ms),
                TranscriptState::Attempting { .. }
                | TranscriptState::Succeeded(_)
                | TranscriptState::TerminalFailure(_) => return Ok(()),
            };
            sleep_until_epoch_ms(retry_at_ms).await;

            let expected_clip = clip_id.to_string();
            let started = self.append_if(
                project_id,
                conversation_id,
                JournalWrite::transcript_started(clip_id, attempt),
                move |records| {
                    let workflow = ConversationWorkflow::from_records(records);
                    match workflow.clip(&expected_clip).map(|clip| &clip.transcript) {
                        Some(TranscriptState::Due { next_attempt }) => {
                            retry_at_ms == 0 && *next_attempt == attempt
                        }
                        Some(TranscriptState::RetryScheduled {
                            next_attempt,
                            retry_at_ms: current_retry_at_ms,
                            ..
                        }) => *next_attempt == attempt && *current_retry_at_ms == retry_at_ms,
                        _ => false,
                    }
                },
            )?;
            if started.is_none() {
                continue;
            }

            match self
                .transcribe_once(project_id, conversation_id, &clip)
                .await
            {
                Ok(text) => {
                    let expected_clip = clip_id.to_string();
                    let transcript = self.append_if(
                        project_id,
                        conversation_id,
                        JournalWrite::transcript_succeeded(clip_id, text, attempt),
                        move |records| {
                            matches!(
                                ConversationWorkflow::from_records(records)
                                    .clip(&expected_clip)
                                    .map(|clip| &clip.transcript),
                                Some(TranscriptState::Attempting { attempt: current })
                                    if *current == attempt
                            )
                        },
                    )?;
                    if transcript.is_none() {
                        continue;
                    }
                    self.auto_name_conversation(project_id, conversation_id);
                    return Ok(());
                }
                Err(error) => {
                    let event = self.attempt_error_event(
                        AttemptFailure {
                            subject: AttemptSubject::Transcript(clip_id),
                            attempt,
                            error: format!("{error:#}"),
                            retryable: self.inner.ai.failure_is_retryable(&error),
                        },
                        &self.inner.workflow_policy.transcription,
                    );
                    let expected_clip = clip_id.to_string();
                    let failure =
                        self.append_if(project_id, conversation_id, event, move |records| {
                            matches!(
                                ConversationWorkflow::from_records(records)
                                    .clip(&expected_clip)
                                    .map(|clip| &clip.transcript),
                                Some(TranscriptState::Attempting { attempt: current })
                                    if *current == attempt
                            )
                        })?;
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
                AttemptSubject::Reply(turn_id) => {
                    JournalWrite::reply_failed(turn_id, failure.attempt, failure.error)
                }
                AttemptSubject::Speech(turn_id) => {
                    JournalWrite::speech_failed(turn_id, failure.attempt, failure.error)
                }
            }
        }
    }

    fn ensure_transcriptions(&self, project_id: &str, conversation_id: &str) -> Result<()> {
        let records = self.inner.store.records(project_id, conversation_id)?;
        for work in ConversationWorkflow::from_records(&records).transcription_work() {
            self.schedule_transcription(
                project_id.to_string(),
                conversation_id.to_string(),
                work.clip_id,
            );
        }
        Ok(())
    }

    fn recover_interrupted_transcription(
        &self,
        project_id: &str,
        conversation_id: &str,
        clip_id: &str,
        reason: &str,
    ) -> Result<()> {
        let expected_clip = clip_id.to_string();
        self.append_if(
            project_id,
            conversation_id,
            JournalWrite::transcript_retry_requested(clip_id, reason),
            move |records| {
                matches!(
                    ConversationWorkflow::from_records(records)
                        .clip(&expected_clip)
                        .map(|clip| &clip.transcript),
                    Some(TranscriptState::Attempting { .. })
                )
            },
        )?;
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
        self.ensure_transcriptions(project_id, conversation_id)?;
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
                TurnAction::GenerateReply { attempt, user_text } => {
                    self.run_reply_attempt(
                        project_id,
                        conversation_id,
                        &workflow,
                        &turn_id,
                        attempt,
                        &user_text,
                    )
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

    async fn run_reply_attempt(
        &self,
        project_id: &str,
        conversation_id: &str,
        workflow: &ConversationWorkflow,
        turn_id: &str,
        attempt: u32,
        user_text: &str,
    ) -> Result<()> {
        self.append(
            project_id,
            conversation_id,
            JournalWrite::reply_started(turn_id, attempt),
        )?;
        let turn = workflow
            .turn(turn_id)
            .ok_or_else(|| anyhow!("turn event is missing"))?;
        if turn.clips.is_empty() {
            self.append_attempt_error(
                project_id,
                conversation_id,
                AttemptFailure {
                    subject: AttemptSubject::Reply(turn_id),
                    attempt,
                    error: "turn has no clips".into(),
                    retryable: false,
                },
                &RetryPolicy {
                    retry_delays: Arc::from([]),
                },
            )?;
            return Ok(());
        }
        if user_text.is_empty() {
            self.append(
                project_id,
                conversation_id,
                JournalWrite::reply_text(turn_id, "[nothing to answer]", turn.clips.clone()),
            )?;
            return Ok(());
        }
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
                .chat(user_text, previous_interaction_id.as_deref(), &history)
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
                if let Err(error) = self.append(
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
                ) {
                    if let Some((key, stream)) = prepared {
                        self.discard_speech_endpoint(&key, &stream, &error);
                    }
                    return Err(error);
                }
            }
            Err(error) => {
                self.append_attempt_error(
                    project_id,
                    conversation_id,
                    AttemptFailure {
                        subject: AttemptSubject::Reply(turn_id),
                        attempt,
                        error: format!("{error:#}"),
                        retryable: self.inner.ai.failure_is_retryable(&error),
                    },
                    &self.inner.workflow_policy.reply,
                )?;
            }
        }
        Ok(())
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
            let expected_clip = clip_id.clone();
            self.append_if(
                project_id,
                conversation_id,
                JournalWrite::transcript_retry_requested(&clip_id, "startup_recovery"),
                move |records| {
                    matches!(
                        ConversationWorkflow::from_records(records)
                            .clip(&expected_clip)
                            .map(|clip| &clip.transcript),
                        Some(TranscriptState::Attempting { .. })
                    )
                },
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
        self.ensure_transcriptions(project_id, conversation_id)?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{ClipUpload, CreateTurnOutcome, hex_sha256};

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
            .reconcile_transcriptions("kibo", &conversation.id)
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
            .reconcile_transcriptions("kibo", conversation_id)
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
            .reconcile_transcriptions("kibo", &conversation.id)
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
            .reconcile_transcriptions("kibo", &conversation.id)
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
            .reconcile_transcriptions("kibo", &conversation.id)
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
            .reconcile_transcriptions("kibo", conversation_id)
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
            .reconcile_transcriptions("kibo", &conversation.id)
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
            .reconcile_transcriptions("kibo", &conversation.id)
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
            .reconcile_transcriptions("kibo", &conversation.id)
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
            .reconcile_transcriptions("kibo", &conversation.id)
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
            .reconcile_transcriptions("kibo", &conversation.id)
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

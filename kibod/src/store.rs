use crate::journal::{ImageFormat, JournalWrite};
use crate::model::{
    ConversationNameSource, KiboConversation, KiboProject, epoch, make_id, valid_id,
};
use crate::workflow::{AttemptState, ConversationWorkflow};
use anyhow::{Context, Result, anyhow, bail};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
#[cfg(test)]
use serde_json::json;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Clone)]
pub struct Store {
    root: Arc<PathBuf>,
    locks: Arc<Mutex<HashMap<String, Arc<Mutex<()>>>>>,
    _writer_lock: Arc<File>,
    #[cfg(test)]
    fail_activity_writes: Arc<AtomicBool>,
    #[cfg(test)]
    fail_appends: Arc<AtomicUsize>,
    #[cfg(test)]
    fail_record_reads: Arc<AtomicUsize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PutClip {
    Created,
    Repaired,
    AlreadyExists,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PutImage {
    Created,
    Repaired,
    AlreadyExists,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PutRecordingPart {
    Created,
    AlreadyExists,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompleteRecordingOutcome {
    Created,
    AlreadyExists,
    Repaired,
}

#[derive(Debug, Clone, PartialEq)]
pub enum CreateTurnOutcome {
    Created {
        record: Value,
        clips: Vec<String>,
        images: Vec<String>,
    },
    Existing {
        record: Value,
        clips: Vec<String>,
        images: Vec<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AutoNameOutcome {
    Named(KiboConversation),
    Unchanged(KiboConversation),
}

#[derive(Debug)]
pub struct ClipConflict;

impl std::fmt::Display for ClipConflict {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("clip ID already exists with different content")
    }
}

impl std::error::Error for ClipConflict {}

#[derive(Debug)]
pub struct ImageConflict;

impl std::fmt::Display for ImageConflict {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("image ID already exists with different content")
    }
}

impl std::error::Error for ImageConflict {}

#[derive(Debug)]
pub struct RecordingConflict(pub String);

impl std::fmt::Display for RecordingConflict {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for RecordingConflict {}

#[derive(Debug)]
pub struct NoPendingClips;

impl std::fmt::Display for NoPendingClips {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("no pending clips")
    }
}

impl std::error::Error for NoPendingClips {}

#[derive(Debug, Clone)]
pub struct ClipUpload<'a> {
    pub project_id: &'a str,
    pub conversation_id: &'a str,
    pub clip_id: &'a str,
    pub bytes: &'a [u8],
    pub expected_sha256: &'a str,
    pub duration_ms: u64,
    pub peak_pct: u32,
    pub recorded_at: u64,
}

#[derive(Debug, Clone)]
pub struct ImageUpload<'a> {
    pub project_id: &'a str,
    pub conversation_id: &'a str,
    pub image_id: &'a str,
    pub bytes: &'a [u8],
    pub expected_sha256: &'a str,
    pub recorded_at: u64,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub caption: Option<String>,
}

#[derive(Debug, Clone)]
pub struct RecordingPartUpload<'a> {
    pub project_id: &'a str,
    pub conversation_id: &'a str,
    pub recording_id: &'a str,
    pub sequence: u32,
    pub bytes: &'a [u8],
    pub expected_sha256: &'a str,
    pub sample_count: u64,
}

#[derive(Debug, Clone)]
pub struct RecordingCompletion<'a> {
    pub project_id: &'a str,
    pub conversation_id: &'a str,
    pub recording_id: &'a str,
    pub part_count: u32,
    pub total_samples: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RecordingManifest {
    version: u32,
    recorded_at: u64,
}

impl Store {
    pub fn open(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        fs::create_dir_all(root.join("projects"))
            .with_context(|| format!("create data directory {}", root.display()))?;
        sync_parent(&root.join("projects"))?;
        let writer_lock = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(root.join(".kibod.lock"))?;
        writer_lock
            .try_lock_exclusive()
            .with_context(|| format!("another kibod process already owns {}", root.display()))?;
        let store = Self {
            root: Arc::new(root),
            locks: Arc::new(Mutex::new(HashMap::new())),
            _writer_lock: Arc::new(writer_lock),
            #[cfg(test)]
            fail_activity_writes: Arc::new(AtomicBool::new(false)),
            #[cfg(test)]
            fail_appends: Arc::new(AtomicUsize::new(0)),
            #[cfg(test)]
            fail_record_reads: Arc::new(AtomicUsize::new(0)),
        };
        store.ensure_starter()?;
        store.reconcile_activity_caches();
        Ok(store)
    }

    pub fn root(&self) -> &Path {
        self.root.as_ref()
    }

    fn ensure_starter(&self) -> Result<()> {
        if self.list_projects()?.is_empty() {
            let project = KiboProject {
                id: "kibo".into(),
                name: "Kibo".into(),
                created_at: epoch(),
            };
            self.write_project(&project)?;
        }
        Ok(())
    }

    /// Rebuild the conversation activity cache from its authoritative event
    /// log. A corrupt log or failed metadata write is reported but does not
    /// make `Store::open` fail: reconciliation never edits the log, and normal
    /// readers/workers will still surface authoritative-log errors.
    fn reconcile_activity_caches(&self) {
        let conversations = match self.conversation_keys() {
            Ok(conversations) => conversations,
            Err(error) => {
                tracing::warn!(
                    "could not enumerate conversations for activity reconciliation: {error:#}"
                );
                return;
            }
        };
        for (project_id, conversation_id) in conversations {
            if let Err(error) = self.reconcile_conversation_activity(&project_id, &conversation_id)
            {
                tracing::warn!(
                    %project_id,
                    %conversation_id,
                    "could not reconcile conversation activity cache: {error:#}"
                );
            }
        }
    }

    fn reconcile_conversation_activity(
        &self,
        project_id: &str,
        conversation_id: &str,
    ) -> Result<()> {
        let lock = self.conversation_lock(project_id, conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut conversation = self.conversation(project_id, conversation_id)?;
        let last_activity_at = self
            .records_unlocked(project_id, conversation_id)?
            .iter()
            .filter_map(|record| record["at"].as_u64())
            .max()
            .unwrap_or(conversation.created_at)
            .max(conversation.created_at);
        if conversation.last_activity_at != last_activity_at {
            conversation.last_activity_at = last_activity_at;
            self.write_conversation(&conversation)?;
        }
        Ok(())
    }

    pub fn list_projects(&self) -> Result<Vec<KiboProject>> {
        let mut projects = Vec::new();
        for entry in fs::read_dir(self.root.join("projects"))? {
            let path = entry?.path().join("project.json");
            if path.exists() {
                projects.push(read_json(&path)?);
            }
        }
        projects.sort_by_key(|project: &KiboProject| project.created_at);
        Ok(projects)
    }

    pub fn project(&self, id: &str) -> Result<KiboProject> {
        self.check_id(id)?;
        read_json(&self.project_dir(id).join("project.json"))
            .with_context(|| format!("project {id} does not exist"))
    }

    pub fn create_project(&self, name: &str) -> Result<KiboProject> {
        let name = clean_name(name)?;
        let project = KiboProject {
            id: make_id(name),
            name: name.into(),
            created_at: epoch(),
        };
        self.write_project(&project)?;
        Ok(project)
    }

    fn write_project(&self, project: &KiboProject) -> Result<()> {
        let directory = self.project_dir(&project.id);
        fs::create_dir_all(directory.join("conversations"))?;
        sync_parent(&directory)?;
        File::open(&directory)?.sync_all()?;
        write_json_atomic(&directory.join("project.json"), project)
    }

    pub fn list_conversations(&self, project_id: &str) -> Result<Vec<KiboConversation>> {
        self.project(project_id)?;
        let mut conversations: Vec<KiboConversation> = Vec::new();
        for entry in fs::read_dir(self.project_dir(project_id).join("conversations"))? {
            let path = entry?.path().join("conversation.json");
            if path.exists() {
                conversations.push(read_json(&path)?);
            }
        }
        conversations.sort_by(|left, right| {
            right
                .activity_at()
                .cmp(&left.activity_at())
                .then_with(|| right.created_at.cmp(&left.created_at))
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(conversations)
    }

    pub fn conversation(&self, project_id: &str, id: &str) -> Result<KiboConversation> {
        self.check_pair(project_id, id)?;
        let conversation: KiboConversation = read_json(
            &self
                .conversation_dir(project_id, id)
                .join("conversation.json"),
        )
        .with_context(|| format!("conversation {project_id}/{id} does not exist"))?;
        if conversation.project_id != project_id {
            bail!("conversation belongs to another project");
        }
        Ok(conversation)
    }

    pub fn create_conversation(
        &self,
        project_id: &str,
        name: Option<&str>,
    ) -> Result<KiboConversation> {
        self.project(project_id)?;
        let (name, name_source) = match name {
            Some(name) => (clean_name(name)?, ConversationNameSource::Manual),
            None => ("New conversation", ConversationNameSource::Placeholder),
        };
        let created_at = epoch();
        let conversation = KiboConversation {
            id: make_id(name),
            project_id: project_id.into(),
            name: name.into(),
            name_source,
            created_at,
            last_activity_at: created_at,
        };
        self.write_conversation(&conversation)?;
        Ok(conversation)
    }

    /// Promote a placeholder name using the earliest useful transcript in
    /// the durable log. The conversation lock makes the source transition
    /// one-way even when several transcript workers finish together.
    pub fn auto_name_from_transcript(
        &self,
        project_id: &str,
        conversation_id: &str,
    ) -> Result<AutoNameOutcome> {
        self.check_pair(project_id, conversation_id)?;
        let lock = self.conversation_lock(project_id, conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut conversation = self.conversation(project_id, conversation_id)?;
        if conversation.name_source != ConversationNameSource::Placeholder {
            return Ok(AutoNameOutcome::Unchanged(conversation));
        }
        let records = self.records_unlocked(project_id, conversation_id)?;
        let Some(name) = records
            .iter()
            .filter(|record| record["kind"] == "transcript")
            .filter_map(|record| record["text"].as_str())
            .find_map(transcript_title)
        else {
            return Ok(AutoNameOutcome::Unchanged(conversation));
        };
        conversation.name = name;
        conversation.name_source = ConversationNameSource::Transcript;
        self.write_conversation(&conversation)?;
        Ok(AutoNameOutcome::Named(conversation))
    }

    fn write_conversation(&self, conversation: &KiboConversation) -> Result<()> {
        let directory = self.conversation_dir(&conversation.project_id, &conversation.id);
        fs::create_dir_all(directory.join("clips"))?;
        fs::create_dir_all(directory.join("tts"))?;
        sync_parent(&directory)?;
        File::open(&directory)?.sync_all()?;
        write_json_atomic(&directory.join("conversation.json"), conversation)
    }

    pub fn records(&self, project_id: &str, conversation_id: &str) -> Result<Vec<Value>> {
        #[cfg(test)]
        if self
            .fail_record_reads
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |remaining| {
                remaining.checked_sub(1)
            })
            .is_ok()
        {
            bail!("injected journal read failure");
        }
        self.conversation(project_id, conversation_id)?;
        let lock = self.conversation_lock(project_id, conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        self.records_unlocked(project_id, conversation_id)
    }

    fn records_unlocked(&self, project_id: &str, conversation_id: &str) -> Result<Vec<Value>> {
        let path = self
            .conversation_dir(project_id, conversation_id)
            .join("turns.jsonl");
        read_jsonl(&path)
    }

    pub(crate) fn append(
        &self,
        project_id: &str,
        conversation_id: &str,
        record: JournalWrite,
    ) -> Result<Value> {
        self.conversation(project_id, conversation_id)?;
        let lock = self.conversation_lock(project_id, conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        self.append_unlocked(project_id, conversation_id, record)
    }

    /// Append only while a predicate over the current durable journal still
    /// holds. The read, decision, and append share the conversation lock, so a
    /// dependent worker cannot publish a stale terminal event after the event
    /// that invalidated it.
    pub(crate) fn append_if<F>(
        &self,
        project_id: &str,
        conversation_id: &str,
        record: JournalWrite,
        predicate: F,
    ) -> Result<Option<Value>>
    where
        F: FnOnce(&[Value]) -> bool,
    {
        self.conversation(project_id, conversation_id)?;
        let lock = self.conversation_lock(project_id, conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let records = self.records_unlocked(project_id, conversation_id)?;
        if !predicate(&records) {
            return Ok(None);
        }
        self.append_unlocked(project_id, conversation_id, record)
            .map(Some)
    }

    fn append_unlocked(
        &self,
        project_id: &str,
        conversation_id: &str,
        record: JournalWrite,
    ) -> Result<Value> {
        self.append_value_unlocked(project_id, conversation_id, record.into_value()?)
    }

    #[cfg(test)]
    fn take_injected_append_failure(&self) -> bool {
        self.fail_appends
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |remaining| {
                (remaining > 0).then(|| remaining - 1)
            })
            == Ok(1)
    }

    fn append_value_unlocked(
        &self,
        project_id: &str,
        conversation_id: &str,
        mut record: Value,
    ) -> Result<Value> {
        #[cfg(test)]
        if self.take_injected_append_failure() {
            bail!("injected journal append failure");
        }
        let path = self
            .conversation_dir(project_id, conversation_id)
            .join("turns.jsonl");
        repair_jsonl_tail(&path)?;
        let seq = next_seq(&path)?;
        let object = record
            .as_object_mut()
            .ok_or_else(|| anyhow!("event must be a JSON object"))?;
        object.insert("seq".into(), seq.into());
        object.entry("at").or_insert_with(|| epoch().into());
        append_jsonl(&path, &record)?;
        self.record_activity_best_effort(project_id, conversation_id, record["at"].as_u64());
        Ok(record)
    }

    /// Append a batch of records as ONE multi-line write with a single fsync.
    /// This buys convergent repairability, not atomic visibility: a crash
    /// mid-batch leaves at most a torn final line for the tail repair, so an
    /// idempotent re-entry can skip the durable prefix and append what is
    /// missing. Returns every appended record in sequence order.
    fn append_all_unlocked(
        &self,
        project_id: &str,
        conversation_id: &str,
        records: Vec<JournalWrite>,
    ) -> Result<Vec<Value>> {
        if records.is_empty() {
            return Ok(Vec::new());
        }
        #[cfg(test)]
        if self.take_injected_append_failure() {
            bail!("injected journal append failure");
        }
        let path = self
            .conversation_dir(project_id, conversation_id)
            .join("turns.jsonl");
        repair_jsonl_tail(&path)?;
        let mut seq = next_seq(&path)?;
        let at = epoch();
        let mut values = Vec::with_capacity(records.len());
        let mut lines = Vec::new();
        for record in records {
            let mut value = record.into_value()?;
            let object = value
                .as_object_mut()
                .ok_or_else(|| anyhow!("event must be a JSON object"))?;
            object.insert("seq".into(), seq.into());
            object.entry("at").or_insert_with(|| at.into());
            lines.extend(serde_json::to_vec(&value)?);
            lines.push(b'\n');
            values.push(value);
            seq = seq
                .checked_add(1)
                .ok_or_else(|| anyhow!("event sequence exhausted"))?;
        }
        let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
        file.write_all(&lines)?;
        file.sync_all()?;
        sync_parent(&path)?;
        self.record_activity_best_effort(project_id, conversation_id, Some(at));
        Ok(values)
    }

    /// Raw journal input is deliberately available only to tests that need to
    /// model legacy, malformed, unknown, or externally written records.
    #[cfg(test)]
    pub(crate) fn append_fixture(
        &self,
        project_id: &str,
        conversation_id: &str,
        record: Value,
    ) -> Result<Value> {
        self.conversation(project_id, conversation_id)?;
        let lock = self.conversation_lock(project_id, conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        self.append_value_unlocked(project_id, conversation_id, record)
    }

    #[cfg(test)]
    pub(crate) fn append_fixture_if<F>(
        &self,
        project_id: &str,
        conversation_id: &str,
        record: Value,
        predicate: F,
    ) -> Result<Option<Value>>
    where
        F: FnOnce(&[Value]) -> bool,
    {
        self.conversation(project_id, conversation_id)?;
        let lock = self.conversation_lock(project_id, conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let records = self.records_unlocked(project_id, conversation_id)?;
        if !predicate(&records) {
            return Ok(None);
        }
        self.append_value_unlocked(project_id, conversation_id, record)
            .map(Some)
    }

    #[cfg(test)]
    pub(crate) fn fail_append_after(&self, successful_appends: usize) {
        self.fail_appends
            .store(successful_appends.saturating_add(1), Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(crate) fn fail_next_record_reads(&self, count: usize) {
        self.fail_record_reads.store(count, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub(crate) fn record_read_failures_remaining(&self) -> usize {
        self.fail_record_reads.load(Ordering::SeqCst)
    }

    pub fn put_clip(&self, upload: ClipUpload<'_>) -> Result<(PutClip, Option<Value>)> {
        self.conversation(upload.project_id, upload.conversation_id)?;
        self.check_id(upload.clip_id)?;
        let actual_sha = hex_sha256(upload.bytes);
        if !actual_sha.eq_ignore_ascii_case(upload.expected_sha256) {
            bail!("content SHA-256 does not match X-Content-Sha256");
        }
        let lock = self.conversation_lock(upload.project_id, upload.conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let existing = self
            .records_unlocked(upload.project_id, upload.conversation_id)?
            .into_iter()
            .find(|record| {
                (record["kind"] == "clip" || record["kind"] == "image")
                    && record["id"] == upload.clip_id
            });
        let directory = self.conversation_dir(upload.project_id, upload.conversation_id);
        let filename = format!("{}.wav", upload.clip_id);
        let final_path = directory.join("clips").join(&filename);
        if let Some(existing) = existing {
            // One media-ID namespace per conversation: an image already owns
            // this ID, whatever the bytes.
            if existing["kind"] == "image" {
                return Err(ClipConflict.into());
            }
            if existing["sha256"].as_str() == Some(&actual_sha) {
                // Restore a missing/corrupt payload after an interrupted write or
                // external damage. Persist the reopen intent before replacing
                // the bytes: a crash or append failure must not turn a completed
                // repair into an indistinguishable, workflow-inert replay.
                if file_sha256(&final_path).as_deref() != Some(actual_sha.as_str()) {
                    let event = self.append_unlocked(
                        upload.project_id,
                        upload.conversation_id,
                        JournalWrite::transcript_retry_requested(
                            upload.clip_id,
                            "payload_repaired",
                        ),
                    )?;
                    write_clip_atomic(&directory, upload.clip_id, upload.bytes)?;
                    return Ok((PutClip::Repaired, Some(event)));
                }
                return Ok((PutClip::AlreadyExists, None));
            }
            return Err(ClipConflict.into());
        }

        // A final payload without an event is possible if the process stopped
        // between the rename and JSONL append. Recover it only when its content
        // agrees with this retry; never overwrite a different clip silently.
        if final_path.exists() {
            if file_sha256(&final_path).as_deref() != Some(actual_sha.as_str()) {
                return Err(ClipConflict.into());
            }
        } else {
            write_clip_atomic(&directory, upload.clip_id, upload.bytes)?;
        }

        let path = directory.join("turns.jsonl");
        repair_jsonl_tail(&path)?;
        let record = self.append_unlocked(
            upload.project_id,
            upload.conversation_id,
            JournalWrite::clip(
                upload.clip_id,
                upload.duration_ms,
                upload.peak_pct,
                upload.recorded_at,
                actual_sha,
            ),
        )?;
        Ok((PutClip::Created, Some(record)))
    }

    /// Commit an image with the clip durability contract: sha verify →
    /// conversation lock → existing-event scan → atomic payload write → append.
    /// Returns every event appended by this request in sequence order so the
    /// API can publish them without a broadcast gap.
    pub fn put_image(&self, upload: ImageUpload<'_>) -> Result<(PutImage, Vec<Value>)> {
        self.conversation(upload.project_id, upload.conversation_id)?;
        self.check_id(upload.image_id)?;
        let format = sniff_image_format(upload.bytes)
            .ok_or_else(|| anyhow!("body must be a JPEG, PNG, or WebP image"))?;
        let actual_sha = hex_sha256(upload.bytes);
        if !actual_sha.eq_ignore_ascii_case(upload.expected_sha256) {
            bail!("content SHA-256 does not match X-Content-Sha256");
        }
        let lock = self.conversation_lock(upload.project_id, upload.conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let records = self.records_unlocked(upload.project_id, upload.conversation_id)?;
        // One media-ID namespace: the scan covers clips too, and a clip with
        // this ID is always a conflict.
        let existing = records
            .iter()
            .find(|record| {
                (record["kind"] == "image" || record["kind"] == "clip")
                    && record["id"] == upload.image_id
            })
            .cloned();
        let directory = self.conversation_dir(upload.project_id, upload.conversation_id);
        let images_directory = directory.join("images");
        fs::create_dir_all(&images_directory)?;
        sync_directory_chain(&images_directory, &directory)?;

        if let Some(existing) = existing {
            if existing["kind"] == "clip" {
                return Err(ImageConflict.into());
            }
            if existing["sha256"].as_str() != Some(actual_sha.as_str()) {
                return Err(ImageConflict.into());
            }
            // Same bytes always sniff to the durable format, so the event's
            // extension is authoritative; fall back to the sniff defensively.
            let extension = existing["file"]
                .as_str()
                .and_then(|file| file.rsplit('.').next())
                .filter(|extension| IMAGE_EXTENSIONS.contains(extension))
                .unwrap_or(format.extension());
            self.check_alternate_image_extensions(&images_directory, upload.image_id, extension)?;
            let final_path = images_directory.join(format!("{}.{extension}", upload.image_id));
            if file_sha256(&final_path).as_deref() == Some(actual_sha.as_str()) {
                return Ok((PutImage::AlreadyExists, Vec::new()));
            }
            // Restore a missing/corrupt payload. Persist every reopen intent
            // BEFORE replacing the bytes, as one batched single-fsync append:
            // a crash or append failure must not turn a completed repair into
            // an indistinguishable, workflow-inert replay, and a failed batch
            // leaves the bytes unrestored so the client's retry re-enters this
            // idempotent path (already-open work is skipped, the missing
            // intents are appended, then the bytes land).
            let workflow = ConversationWorkflow::from_records(&records);
            let mut reopens = Vec::new();
            for turn in workflow.turns() {
                if turn.images.iter().any(|image| image == upload.image_id)
                    && reopen_after_repair(&turn.reply)
                {
                    reopens.push(JournalWrite::reply_retry_requested(
                        &turn.id,
                        "payload_repaired",
                    ));
                }
            }
            if workflow
                .image(upload.image_id)
                .is_some_and(|image| reopen_after_repair(&image.description))
            {
                reopens.push(JournalWrite::description_retry_requested(
                    upload.image_id,
                    "payload_repaired",
                ));
            }
            let events =
                self.append_all_unlocked(upload.project_id, upload.conversation_id, reopens)?;
            write_file_atomic(&final_path, upload.bytes, "upload")?;
            return Ok((PutImage::Repaired, events));
        }

        // No durable event: the sniffed format is the extension authority. A
        // crash-left payload under a different extension is a conflict, never
        // silently superseded; a matching-extension payload without an event
        // is adopted only when its content agrees with this retry.
        self.check_alternate_image_extensions(
            &images_directory,
            upload.image_id,
            format.extension(),
        )?;
        let final_path =
            images_directory.join(format!("{}.{}", upload.image_id, format.extension()));
        if final_path.exists() {
            if file_sha256(&final_path).as_deref() != Some(actual_sha.as_str()) {
                return Err(ImageConflict.into());
            }
        } else {
            write_file_atomic(&final_path, upload.bytes, "upload")?;
        }
        let record = self.append_unlocked(
            upload.project_id,
            upload.conversation_id,
            JournalWrite::image(
                upload.image_id,
                format,
                actual_sha,
                upload.recorded_at,
                upload.width,
                upload.height,
                upload.caption.clone(),
            ),
        )?;
        Ok((PutImage::Created, vec![record]))
    }

    fn check_alternate_image_extensions(
        &self,
        images_directory: &Path,
        image_id: &str,
        extension: &str,
    ) -> Result<()> {
        for other in IMAGE_EXTENSIONS.iter().filter(|other| **other != extension) {
            if images_directory
                .join(format!("{image_id}.{other}"))
                .exists()
            {
                return Err(ImageConflict.into());
            }
        }
        Ok(())
    }

    /// Durably stage one independently retryable piece of a recording. Staged
    /// parts are deliberately kept outside the event log, so readers and turn
    /// creation cannot observe a recording until `complete_recording` commits
    /// its single assembled clip.
    pub fn put_recording_part(&self, upload: RecordingPartUpload<'_>) -> Result<PutRecordingPart> {
        self.conversation(upload.project_id, upload.conversation_id)?;
        self.check_id(upload.recording_id)?;
        let wav = canonical_wav(upload.bytes)?;
        if wav.sample_count != upload.sample_count {
            bail!(
                "sample count does not match X-Sample-Count: WAV has {}, header says {}",
                wav.sample_count,
                upload.sample_count
            );
        }
        let actual_sha = hex_sha256(upload.bytes);
        if !actual_sha.eq_ignore_ascii_case(upload.expected_sha256) {
            bail!("content SHA-256 does not match X-Content-Sha256");
        }

        let lock = self.conversation_lock(upload.project_id, upload.conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let conversation_directory =
            self.conversation_dir(upload.project_id, upload.conversation_id);
        let directory = self.recording_parts_dir(
            upload.project_id,
            upload.conversation_id,
            upload.recording_id,
        );
        let final_path = directory.join(recording_part_filename(upload.sequence));
        if final_path.exists() {
            sync_directory_chain(&directory, &conversation_directory)?;
            ensure_recording_manifest(&directory)?;
            return if file_sha256(&final_path).as_deref() == Some(actual_sha.as_str()) {
                Ok(PutRecordingPart::AlreadyExists)
            } else {
                Err(RecordingConflict(
                    "recording part already exists with different content".into(),
                )
                .into())
            };
        }

        let completed = self
            .records_unlocked(upload.project_id, upload.conversation_id)?
            .into_iter()
            .any(|record| record["kind"] == "clip" && record["id"] == upload.recording_id);
        if completed {
            return Err(RecordingConflict("recording is already complete".into()).into());
        }

        fs::create_dir_all(&directory)?;
        sync_directory_chain(&directory, &conversation_directory)?;
        ensure_recording_manifest(&directory)?;
        write_file_atomic(&final_path, upload.bytes, "part")?;
        Ok(PutRecordingPart::Created)
    }

    /// Assemble all staged parts into one canonical WAV and expose it with one
    /// ordinary clip event. The final WAV rename precedes the event append, so
    /// the only crash orphan is a complete payload that a retry can verify.
    /// Recording IDs share the one media-ID namespace with clips and images.
    pub fn complete_recording(
        &self,
        completion: RecordingCompletion<'_>,
    ) -> Result<(CompleteRecordingOutcome, Option<Value>)> {
        self.conversation(completion.project_id, completion.conversation_id)?;
        self.check_id(completion.recording_id)?;
        if completion.part_count == 0 {
            bail!("part_count must be greater than zero");
        }
        if completion.part_count > MAX_RECORDING_PARTS {
            bail!("part_count exceeds the supported maximum");
        }
        canonical_wav_data_len(completion.total_samples)?;

        let lock = self.conversation_lock(completion.project_id, completion.conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let directory = self.conversation_dir(completion.project_id, completion.conversation_id);
        let final_path = directory
            .join("clips")
            .join(format!("{}.wav", completion.recording_id));
        let existing = self
            .records_unlocked(completion.project_id, completion.conversation_id)?
            .into_iter()
            .find(|record| {
                (record["kind"] == "clip" || record["kind"] == "image")
                    && record["id"] == completion.recording_id
            });

        if existing
            .as_ref()
            .is_some_and(|record| record["kind"] == "image")
        {
            return Err(RecordingConflict("recording ID already names an image".into()).into());
        }
        if let Some(existing) = existing.as_ref() {
            if existing["part_count"].as_u64() != Some(u64::from(completion.part_count))
                || existing["samples"].as_u64() != Some(completion.total_samples)
            {
                return Err(RecordingConflict(
                    "recording was already completed with different parameters".into(),
                )
                .into());
            }
            let expected_sha = existing["sha256"]
                .as_str()
                .ok_or_else(|| anyhow!("completed recording event has no SHA-256"))?;
            if file_sha256(&final_path).as_deref() == Some(expected_sha) {
                return Ok((CompleteRecordingOutcome::AlreadyExists, None));
            }
        }

        let parts_directory = self.recording_parts_dir(
            completion.project_id,
            completion.conversation_id,
            completion.recording_id,
        );
        validate_part_set(&parts_directory, completion.part_count)?;
        let manifest = read_recording_manifest(&parts_directory)?;
        let assembled = assemble_recording(
            &directory,
            &parts_directory,
            completion.recording_id,
            completion.part_count,
            completion.total_samples,
        )?;

        if let Some(existing) = existing {
            let expected_sha = existing["sha256"].as_str().unwrap();
            if assembled.sha256 != expected_sha {
                let _ = fs::remove_file(&assembled.path);
                return Err(RecordingConflict(
                    "staged parts do not match the completed recording".into(),
                )
                .into());
            }
            // Restore a missing/corrupt payload exactly like put_clip: persist
            // the reopen intent before replacing the bytes, so a crash or
            // append failure cannot turn a completed repair into an
            // indistinguishable, workflow-inert replay.
            let event = self
                .append_unlocked(
                    completion.project_id,
                    completion.conversation_id,
                    JournalWrite::transcript_retry_requested(
                        completion.recording_id,
                        "payload_repaired",
                    ),
                )
                .inspect_err(|_| {
                    let _ = fs::remove_file(&assembled.path);
                })?;
            fs::rename(&assembled.path, &final_path).inspect_err(|_| {
                let _ = fs::remove_file(&assembled.path);
            })?;
            sync_parent(&final_path)?;
            return Ok((CompleteRecordingOutcome::Repaired, Some(event)));
        }

        if final_path.exists() {
            if file_sha256(&final_path).as_deref() != Some(assembled.sha256.as_str()) {
                let _ = fs::remove_file(&assembled.path);
                return Err(RecordingConflict(
                    "recording ID already has a different assembled payload".into(),
                )
                .into());
            }
            fs::remove_file(&assembled.path)?;
        } else {
            fs::rename(&assembled.path, &final_path).inspect_err(|_| {
                let _ = fs::remove_file(&assembled.path);
            })?;
            sync_parent(&final_path)?;
        }

        let duration_ms = completion
            .total_samples
            .saturating_mul(1000)
            .div_ceil(u64::from(RECORDING_SAMPLE_RATE));
        let record = self.append_unlocked(
            completion.project_id,
            completion.conversation_id,
            JournalWrite::recording_clip(
                completion.recording_id,
                duration_ms,
                assembled.peak_pct,
                manifest.recorded_at,
                assembled.sha256,
                completion.total_samples,
                RECORDING_SAMPLE_RATE,
                completion.part_count,
            ),
        )?;
        Ok((CompleteRecordingOutcome::Created, Some(record)))
    }

    pub fn clip_path(
        &self,
        project_id: &str,
        conversation_id: &str,
        clip_id: &str,
    ) -> Result<PathBuf> {
        self.check_pair(project_id, conversation_id)?;
        self.check_id(clip_id)?;
        Ok(self
            .conversation_dir(project_id, conversation_id)
            .join("clips")
            .join(format!("{clip_id}.wav")))
    }

    /// Resolve an image payload path. Bytes for an ID are hash-pinned and at
    /// most one extension can ever exist (alternates are upload conflicts), so
    /// the existing file is authoritative; a missing payload resolves to the
    /// canonical JPEG path so callers surface an ordinary read error.
    pub fn image_path(
        &self,
        project_id: &str,
        conversation_id: &str,
        image_id: &str,
    ) -> Result<PathBuf> {
        self.check_pair(project_id, conversation_id)?;
        self.check_id(image_id)?;
        let images_directory = self
            .conversation_dir(project_id, conversation_id)
            .join("images");
        for extension in IMAGE_EXTENSIONS {
            let path = images_directory.join(format!("{image_id}.{extension}"));
            if path.exists() {
                return Ok(path);
            }
        }
        Ok(images_directory.join(format!("{image_id}.jpg")))
    }

    fn recording_parts_dir(
        &self,
        project_id: &str,
        conversation_id: &str,
        recording_id: &str,
    ) -> PathBuf {
        self.conversation_dir(project_id, conversation_id)
            .join("recordings")
            .join(recording_id)
            .join("parts")
    }

    pub fn speech_path(
        &self,
        project_id: &str,
        conversation_id: &str,
        turn_id: &str,
    ) -> Result<PathBuf> {
        self.check_pair(project_id, conversation_id)?;
        self.check_id(turn_id)?;
        Ok(self
            .conversation_dir(project_id, conversation_id)
            .join("tts")
            .join(format!("{turn_id}.wav")))
    }

    pub fn pending_clip_ids(&self, project_id: &str, conversation_id: &str) -> Result<Vec<String>> {
        let records = self.records(project_id, conversation_id)?;
        Ok(unclaimed_clip_ids(&records))
    }

    /// Atomically create an AI turn and claim every clip and image that was
    /// pending at that instant. A retry with the same turn ID returns the
    /// original claim; a new turn with nothing to claim is rejected.
    pub fn create_turn(
        &self,
        project_id: &str,
        conversation_id: &str,
        turn_id: &str,
    ) -> Result<CreateTurnOutcome> {
        self.conversation(project_id, conversation_id)?;
        self.check_id(turn_id)?;
        let lock = self.conversation_lock(project_id, conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let path = self
            .conversation_dir(project_id, conversation_id)
            .join("turns.jsonl");
        repair_jsonl_tail(&path)?;
        let records = self.records_unlocked(project_id, conversation_id)?;

        if let Some(record) = records
            .iter()
            .find(|record| record["kind"] == "turn" && record["id"] == turn_id)
        {
            let clips = turn_clips(record)?;
            let images = turn_images(record);
            return Ok(CreateTurnOutcome::Existing {
                record: record.clone(),
                clips,
                images,
            });
        }

        let clips = unclaimed_clip_ids(&records);
        let images = unclaimed_image_ids(&records);
        if clips.is_empty() && images.is_empty() {
            return Err(NoPendingClips.into());
        }
        let record = self.append_unlocked(
            project_id,
            conversation_id,
            JournalWrite::turn(turn_id, clips, images),
        )?;
        Ok(CreateTurnOutcome::Created {
            clips: turn_clips(&record)?,
            images: turn_images(&record),
            record,
        })
    }

    pub fn conversation_keys(&self) -> Result<Vec<(String, String)>> {
        let mut keys = Vec::new();
        for project in self.list_projects()? {
            for conversation in self.list_conversations(&project.id)? {
                keys.push((project.id.clone(), conversation.id));
            }
        }
        Ok(keys)
    }

    fn project_dir(&self, project_id: &str) -> PathBuf {
        self.root.join("projects").join(project_id)
    }

    fn conversation_dir(&self, project_id: &str, conversation_id: &str) -> PathBuf {
        self.project_dir(project_id)
            .join("conversations")
            .join(conversation_id)
    }

    fn conversation_lock(&self, project_id: &str, conversation_id: &str) -> Arc<Mutex<()>> {
        let key = format!("{project_id}/{conversation_id}");
        self.locks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .entry(key)
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }

    fn record_activity_unlocked(
        &self,
        project_id: &str,
        conversation_id: &str,
        event_at: Option<u64>,
    ) -> Result<()> {
        #[cfg(test)]
        if self.fail_activity_writes.load(Ordering::Relaxed) {
            bail!("injected activity metadata write failure");
        }
        let mut conversation = self.conversation(project_id, conversation_id)?;
        conversation.last_activity_at = conversation
            .activity_at()
            .max(event_at.unwrap_or_else(epoch));
        self.write_conversation(&conversation)
    }

    fn record_activity_best_effort(
        &self,
        project_id: &str,
        conversation_id: &str,
        event_at: Option<u64>,
    ) {
        if let Err(error) = self.record_activity_unlocked(project_id, conversation_id, event_at) {
            tracing::warn!(
                %project_id,
                %conversation_id,
                "durable event committed but activity cache update failed: {error:#}"
            );
        }
    }

    fn check_id(&self, id: &str) -> Result<()> {
        if valid_id(id) {
            Ok(())
        } else {
            bail!("invalid ID")
        }
    }

    fn check_pair(&self, project_id: &str, conversation_id: &str) -> Result<()> {
        self.check_id(project_id)?;
        self.check_id(conversation_id)
    }
}

const RECORDING_SAMPLE_RATE: u32 = 16_000;
const CANONICAL_WAV_HEADER_LEN: usize = 44;
const MAX_RECORDING_PARTS: u32 = 10_000;
const IMAGE_EXTENSIONS: [&str; 3] = ["jpg", "png", "webp"];

/// Magic-byte sniff for the accepted image encodings; the sniff is the mime
/// authority, so anything else (HEIC included) is rejected at the door.
pub(crate) fn sniff_image_format(bytes: &[u8]) -> Option<ImageFormat> {
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some(ImageFormat::Jpeg)
    } else if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        Some(ImageFormat::Png)
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some(ImageFormat::Webp)
    } else {
        None
    }
}

/// Which stages a payload repair reopens. Due work is already open and will
/// rerun with the restored bytes (the inert-replay rule), and a durable
/// success stays authoritative; everything else — attempting, scheduled, or
/// terminal — may rest on the corrupt payload and is reopened. In-flight
/// attempts are superseded by the conditional result protocol.
fn reopen_after_repair<T, F>(state: &AttemptState<T, F>) -> bool {
    !matches!(
        state,
        AttemptState::Succeeded(_) | AttemptState::Due { .. }
    )
}

#[derive(Debug, Clone, Copy)]
struct CanonicalWav {
    sample_count: u64,
    peak_pct: u32,
}

#[derive(Debug)]
struct AssembledRecording {
    path: PathBuf,
    sha256: String,
    peak_pct: u32,
}

fn canonical_wav(bytes: &[u8]) -> Result<CanonicalWav> {
    if bytes.len() < CANONICAL_WAV_HEADER_LEN {
        bail!("body must be a canonical WAV file");
    }
    let u16_at = |offset: usize| u16::from_le_bytes(bytes[offset..offset + 2].try_into().unwrap());
    let u32_at = |offset: usize| u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
    let data_len = bytes.len() - CANONICAL_WAV_HEADER_LEN;
    if &bytes[0..4] != b"RIFF"
        || &bytes[8..12] != b"WAVE"
        || &bytes[12..16] != b"fmt "
        || u32_at(16) != 16
        || u16_at(20) != 1
        || u16_at(22) != 1
        || u32_at(24) != RECORDING_SAMPLE_RATE
        || u32_at(28) != RECORDING_SAMPLE_RATE * 2
        || u16_at(32) != 2
        || u16_at(34) != 16
        || &bytes[36..40] != b"data"
        || usize::try_from(u32_at(40)).ok() != Some(data_len)
        || u32::try_from(bytes.len() - 8).ok() != Some(u32_at(4))
        || !data_len.is_multiple_of(2)
    {
        bail!("WAV must be canonical mono 16 kHz signed 16-bit PCM");
    }
    let sample_count = u64::try_from(data_len / 2)?;
    let max_amplitude = bytes[CANONICAL_WAV_HEADER_LEN..]
        .chunks_exact(2)
        .map(|sample| i32::from(i16::from_le_bytes([sample[0], sample[1]])).unsigned_abs())
        .max()
        .unwrap_or(0);
    let peak_pct = ((max_amplitude * 100).div_ceil(i16::MAX as u32)).min(100);
    Ok(CanonicalWav {
        sample_count,
        peak_pct,
    })
}

fn canonical_wav_data_len(sample_count: u64) -> Result<u32> {
    let bytes = sample_count
        .checked_mul(2)
        .ok_or_else(|| anyhow!("total_samples is too large"))?;
    let data_len = u32::try_from(bytes).map_err(|_| anyhow!("recording is too large for WAV"))?;
    if data_len > u32::MAX - 36 {
        bail!("recording is too large for WAV");
    }
    Ok(data_len)
}

fn canonical_wav_header(sample_count: u64) -> Result<[u8; CANONICAL_WAV_HEADER_LEN]> {
    let data_len = canonical_wav_data_len(sample_count)?;
    let mut header = [0_u8; CANONICAL_WAV_HEADER_LEN];
    header[0..4].copy_from_slice(b"RIFF");
    header[4..8].copy_from_slice(&(36 + data_len).to_le_bytes());
    header[8..12].copy_from_slice(b"WAVE");
    header[12..16].copy_from_slice(b"fmt ");
    header[16..20].copy_from_slice(&16_u32.to_le_bytes());
    header[20..22].copy_from_slice(&1_u16.to_le_bytes());
    header[22..24].copy_from_slice(&1_u16.to_le_bytes());
    header[24..28].copy_from_slice(&RECORDING_SAMPLE_RATE.to_le_bytes());
    header[28..32].copy_from_slice(&(RECORDING_SAMPLE_RATE * 2).to_le_bytes());
    header[32..34].copy_from_slice(&2_u16.to_le_bytes());
    header[34..36].copy_from_slice(&16_u16.to_le_bytes());
    header[36..40].copy_from_slice(b"data");
    header[40..44].copy_from_slice(&data_len.to_le_bytes());
    Ok(header)
}

fn recording_part_filename(sequence: u32) -> String {
    format!("{sequence:08}.wav")
}

fn recording_manifest_path(parts_directory: &Path) -> Result<PathBuf> {
    Ok(parts_directory
        .parent()
        .ok_or_else(|| anyhow!("invalid recording parts directory"))?
        .join("manifest.json"))
}

fn ensure_recording_manifest(parts_directory: &Path) -> Result<RecordingManifest> {
    let path = recording_manifest_path(parts_directory)?;
    if path.exists() {
        return read_json(&path).with_context(|| "read recording manifest");
    }
    let manifest = RecordingManifest {
        version: 1,
        recorded_at: epoch(),
    };
    write_json_atomic(&path, &manifest)?;
    Ok(manifest)
}

fn read_recording_manifest(parts_directory: &Path) -> Result<RecordingManifest> {
    let manifest: RecordingManifest = read_json(&recording_manifest_path(parts_directory)?)
        .with_context(|| "recording manifest is missing or invalid")?;
    if manifest.version != 1 {
        bail!("unsupported recording manifest version");
    }
    Ok(manifest)
}

fn validate_part_set(directory: &Path, part_count: u32) -> Result<()> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(RecordingConflict("recording part 0 is missing".into()).into());
        }
        Err(error) => return Err(error.into()),
    };
    let mut sequences = HashSet::new();
    for entry in entries {
        let entry = entry?;
        if !entry.file_type()?.is_file()
            || entry.path().extension().and_then(|value| value.to_str()) != Some("wav")
        {
            continue;
        }
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let sequence = name
            .strip_suffix(".wav")
            .and_then(|stem| stem.parse::<u32>().ok())
            .ok_or_else(|| anyhow!("recording contains an invalid part filename"))?;
        sequences.insert(sequence);
    }
    for sequence in 0..part_count {
        if !sequences.contains(&sequence) {
            return Err(RecordingConflict(format!("recording part {sequence} is missing")).into());
        }
    }
    if sequences.len() != part_count as usize {
        let unexpected = sequences
            .iter()
            .copied()
            .filter(|sequence| *sequence >= part_count)
            .min()
            .unwrap_or(part_count);
        return Err(RecordingConflict(format!(
            "recording part {unexpected} is outside part_count"
        ))
        .into());
    }
    Ok(())
}

fn assemble_recording(
    conversation_directory: &Path,
    parts_directory: &Path,
    recording_id: &str,
    part_count: u32,
    total_samples: u64,
) -> Result<AssembledRecording> {
    let path = conversation_directory.join("clips").join(format!(
        ".{recording_id}.{}.recording",
        uuid::Uuid::new_v4().simple()
    ));
    let result = (|| {
        let mut output = File::create(&path)?;
        output.write_all(&canonical_wav_header(total_samples)?)?;
        let mut actual_samples = 0_u64;
        let mut peak_pct = 0_u32;
        for sequence in 0..part_count {
            let bytes = fs::read(parts_directory.join(recording_part_filename(sequence)))?;
            let wav = canonical_wav(&bytes).map_err(|error| {
                RecordingConflict(format!(
                    "recording part {sequence} is not canonical WAV: {error}"
                ))
            })?;
            actual_samples = actual_samples
                .checked_add(wav.sample_count)
                .ok_or_else(|| anyhow!("recording sample count overflow"))?;
            peak_pct = peak_pct.max(wav.peak_pct);
            output.write_all(&bytes[CANONICAL_WAV_HEADER_LEN..])?;
        }
        if actual_samples != total_samples {
            return Err(RecordingConflict(format!(
                "total_samples does not match staged parts: parts have {actual_samples}, request says {total_samples}"
            ))
            .into());
        }
        output.sync_all()?;
        drop(output);
        Ok(AssembledRecording {
            sha256: file_sha256_result(&path)?,
            path: path.clone(),
            peak_pct,
        })
    })();
    if result.is_err() {
        let _ = fs::remove_file(&path);
    }
    result
}

fn clean_name(name: &str) -> Result<&str> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 100 {
        bail!("name must be between 1 and 100 characters");
    }
    Ok(name)
}

fn transcript_title(transcript: &str) -> Option<String> {
    const MAX_WORDS: usize = 8;
    const MAX_CHARS: usize = 60;

    let transcript = transcript.trim();
    if transcript.is_empty() || (transcript.starts_with('[') && transcript.ends_with(']')) {
        return None;
    }
    let mut title = String::new();
    for word in transcript.split_whitespace().take(MAX_WORDS) {
        let separator = usize::from(!title.is_empty());
        let remaining = MAX_CHARS.saturating_sub(title.chars().count() + separator);
        if remaining == 0 {
            break;
        }
        let word_chars = word.chars().count();
        if word_chars > remaining {
            if title.is_empty() {
                title.extend(word.chars().take(remaining));
            }
            break;
        }
        if separator == 1 {
            title.push(' ');
        }
        title.push_str(word);
    }
    (!title.is_empty()).then_some(title)
}

fn turn_clips(record: &Value) -> Result<Vec<String>> {
    record["clips"]
        .as_array()
        .ok_or_else(|| anyhow!("turn event has no clips array"))?
        .iter()
        .map(|clip| {
            clip.as_str()
                .map(str::to_owned)
                .ok_or_else(|| anyhow!("turn event has a non-string clip ID"))
        })
        .collect()
}

fn unclaimed_clip_ids(records: &[Value]) -> Vec<String> {
    unclaimed_media_ids(records, "clip", "clips")
}

fn unclaimed_image_ids(records: &[Value]) -> Vec<String> {
    unclaimed_media_ids(records, "image", "images")
}

fn unclaimed_media_ids(records: &[Value], kind: &str, claim_field: &str) -> Vec<String> {
    let claimed: HashSet<&str> = records
        .iter()
        .filter(|record| record["kind"] == "turn")
        .flat_map(|record| {
            record[claim_field]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
        })
        .collect();
    let mut media: Vec<(u64, u64, String)> = records
        .iter()
        .filter(|record| record["kind"] == kind)
        .filter_map(|record| {
            let id = record["id"].as_str()?;
            (!claimed.contains(id)).then(|| {
                (
                    record["recorded_at"].as_u64().unwrap_or(0),
                    record["seq"].as_u64().unwrap_or(0),
                    id.to_owned(),
                )
            })
        })
        .collect();
    media.sort_by_key(|(recorded_at, seq, _)| (*recorded_at, *seq));
    media.into_iter().map(|(_, _, id)| id).collect()
}

fn turn_images(record: &Value) -> Vec<String> {
    record["images"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect()
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let bytes = fs::read(path)?;
    serde_json::from_slice(&bytes).with_context(|| format!("read {}", path.display()))
}

fn write_json_atomic(path: &Path, value: &impl serde::Serialize) -> Result<()> {
    let temporary = path.with_extension(format!("json.{}.part", uuid::Uuid::new_v4().simple()));
    let mut file = File::create(&temporary)?;
    serde_json::to_writer_pretty(&mut file, value)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    fs::rename(&temporary, path).inspect_err(|_| {
        let _ = fs::remove_file(&temporary);
    })?;
    sync_parent(path)?;
    Ok(())
}

fn next_seq(path: &Path) -> Result<u64> {
    read_jsonl(path)?
        .iter()
        .filter_map(|value| value["seq"].as_u64())
        .max()
        .unwrap_or(0)
        .checked_add(1)
        .ok_or_else(|| anyhow!("event sequence exhausted"))
}

fn read_jsonl(path: &Path) -> Result<Vec<Value>> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };
    let mut records = Vec::new();
    for (line_number, line) in bytes.split_inclusive(|byte| *byte == b'\n').enumerate() {
        let complete = line.ends_with(b"\n");
        let line = line.strip_suffix(b"\n").unwrap_or(line);
        if line.is_empty() {
            continue;
        }
        match serde_json::from_slice(line) {
            Ok(value) => records.push(value),
            // A crash may leave only the final append incomplete. It is safe to
            // ignore until the next writer truncates it; corruption earlier in
            // the log remains a hard error.
            Err(_) if !complete => break,
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("invalid event on line {}", line_number + 1));
            }
        }
    }
    Ok(records)
}

fn repair_jsonl_tail(path: &Path) -> Result<()> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if bytes.is_empty() || bytes.ends_with(b"\n") {
        return Ok(());
    }
    let tail_start = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |position| position + 1);
    let mut file = OpenOptions::new().append(true).open(path)?;
    if serde_json::from_slice::<Value>(&bytes[tail_start..]).is_ok() {
        file.write_all(b"\n")?;
    } else {
        file.set_len(tail_start as u64)?;
    }
    file.sync_all()?;
    Ok(())
}

fn append_jsonl(path: &Path, value: &Value) -> Result<()> {
    let mut line = serde_json::to_vec(value)?;
    line.push(b'\n');
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all(&line)?;
    file.sync_all()?;
    sync_parent(path)
}

fn write_clip_atomic(directory: &Path, clip_id: &str, bytes: &[u8]) -> Result<()> {
    let final_path = directory.join("clips").join(format!("{clip_id}.wav"));
    write_file_atomic(&final_path, bytes, "upload")
}

fn write_file_atomic(final_path: &Path, bytes: &[u8], suffix: &str) -> Result<()> {
    let parent = final_path
        .parent()
        .ok_or_else(|| anyhow!("destination has no parent directory"))?;
    let name = final_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow!("destination has no valid filename"))?;
    let temporary_path = parent.join(format!(
        ".{name}.{}.{suffix}",
        uuid::Uuid::new_v4().simple()
    ));
    let mut file = File::create(&temporary_path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fs::rename(&temporary_path, final_path).inspect_err(|_| {
        let _ = fs::remove_file(&temporary_path);
    })?;
    sync_parent(final_path)
}

fn file_sha256(path: &Path) -> Option<String> {
    file_sha256_result(path).ok()
}

fn file_sha256_result(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

/// Make every directory entry created below an already-durable ancestor
/// survive a successful response. `create_dir_all` can add several ancestors,
/// and syncing only the leaf or its immediate parent does not durably link the
/// upper entries on Unix filesystems.
fn sync_directory_chain(leaf: &Path, ancestor: &Path) -> Result<()> {
    if !leaf.starts_with(ancestor) {
        bail!("directory is outside its durable ancestor");
    }
    let mut directory = leaf;
    loop {
        File::open(directory)?.sync_all()?;
        if directory == ancestor {
            return Ok(());
        }
        directory = directory
            .parent()
            .ok_or_else(|| anyhow!("durable ancestor is not in directory chain"))?;
    }
}

fn sync_parent(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    File::open(parent)?.sync_all()?;
    Ok(())
}

pub fn hex_sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store_with_general() -> (tempfile::TempDir, Store) {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        store
            .write_conversation(&KiboConversation {
                id: "general".into(),
                project_id: "kibo".into(),
                name: "General".into(),
                name_source: ConversationNameSource::Manual,
                created_at: 1,
                last_activity_at: 1,
            })
            .unwrap();
        (temporary, store)
    }

    fn test_wav(samples: &[i16]) -> Vec<u8> {
        let mut bytes = canonical_wav_header(samples.len() as u64).unwrap().to_vec();
        bytes.extend(samples.iter().flat_map(|sample| sample.to_le_bytes()));
        bytes
    }

    fn put_test_part(
        store: &Store,
        recording_id: &str,
        sequence: u32,
        samples: &[i16],
    ) -> Result<PutRecordingPart> {
        let bytes = test_wav(samples);
        let sha = hex_sha256(&bytes);
        store.put_recording_part(RecordingPartUpload {
            project_id: "kibo",
            conversation_id: "general",
            recording_id,
            sequence,
            bytes: &bytes,
            expected_sha256: &sha,
            sample_count: samples.len() as u64,
        })
    }

    #[test]
    fn starter_and_new_projects_begin_without_conversations() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        assert_eq!(store.list_projects().unwrap()[0].id, "kibo");
        assert!(store.list_conversations("kibo").unwrap().is_empty());

        let project = store.create_project("Recipes").unwrap();
        assert!(store.list_conversations(&project.id).unwrap().is_empty());
    }

    #[test]
    fn append_sequence_is_durable_for_existing_general_data() {
        let (_temporary, store) = store_with_general();
        let one = store
            .append_fixture("kibo", "general", json!({"kind":"one"}))
            .unwrap();
        let two = store
            .append_fixture("kibo", "general", json!({"kind":"two"}))
            .unwrap();
        assert_eq!(one["seq"], 1);
        assert_eq!(two["seq"], 2);
        assert_eq!(store.records("kibo", "general").unwrap().len(), 2);
    }

    #[test]
    fn data_directory_has_one_writer() {
        let temporary = tempfile::tempdir().unwrap();
        let _first = Store::open(temporary.path()).unwrap();
        let error = Store::open(temporary.path()).err().unwrap();
        assert!(error.to_string().contains("another kibod process"));
    }

    #[test]
    fn clip_upload_is_idempotent_by_id_and_hash() {
        let (_temporary, store) = store_with_general();
        let bytes = b"RIFF tiny fake wav";
        let sha = hex_sha256(bytes);
        let upload = || ClipUpload {
            project_id: "kibo",
            conversation_id: "general",
            clip_id: "clip-1",
            bytes,
            expected_sha256: &sha,
            duration_ms: 1000,
            peak_pct: 10,
            recorded_at: 1,
        };
        assert_eq!(store.put_clip(upload()).unwrap().0, PutClip::Created);
        assert_eq!(store.put_clip(upload()).unwrap().0, PutClip::AlreadyExists);
        assert_eq!(store.records("kibo", "general").unwrap().len(), 1);
    }

    #[test]
    fn matching_upload_distinguishes_payload_repair_from_an_inert_replay() {
        let (_temporary, store) = store_with_general();
        let bytes = b"RIFF tiny fake wav";
        let sha = hex_sha256(bytes);
        let upload = || ClipUpload {
            project_id: "kibo",
            conversation_id: "general",
            clip_id: "clip-1",
            bytes,
            expected_sha256: &sha,
            duration_ms: 1000,
            peak_pct: 10,
            recorded_at: 1,
        };
        assert_eq!(store.put_clip(upload()).unwrap().0, PutClip::Created);
        let path = store.clip_path("kibo", "general", "clip-1").unwrap();
        fs::write(&path, b"damaged").unwrap();

        let (outcome, repair) = store.put_clip(upload()).unwrap();
        assert_eq!(outcome, PutClip::Repaired);
        assert_eq!(
            repair.as_ref().unwrap()["kind"],
            "transcript_retry_requested"
        );
        assert_eq!(repair.as_ref().unwrap()["reason"], "payload_repaired");
        assert_eq!(fs::read(path).unwrap(), bytes);
        assert_eq!(store.put_clip(upload()).unwrap().0, PutClip::AlreadyExists);
        assert_eq!(store.records("kibo", "general").unwrap().len(), 2);
    }

    #[test]
    fn payload_repair_persists_retry_intent_before_replacing_bytes() {
        let (_temporary, store) = store_with_general();
        let bytes = b"RIFF tiny fake wav";
        let sha = hex_sha256(bytes);
        let upload = || ClipUpload {
            project_id: "kibo",
            conversation_id: "general",
            clip_id: "clip-1",
            bytes,
            expected_sha256: &sha,
            duration_ms: 1000,
            peak_pct: 10,
            recorded_at: 1,
        };
        store.put_clip(upload()).unwrap();
        let path = store.clip_path("kibo", "general", "clip-1").unwrap();
        fs::write(&path, b"damaged").unwrap();

        store.fail_append_after(0);
        assert!(store.put_clip(upload()).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"damaged");
        assert_eq!(store.records("kibo", "general").unwrap().len(), 1);

        let (outcome, event) = store.put_clip(upload()).unwrap();
        assert_eq!(outcome, PutClip::Repaired);
        assert_eq!(event.unwrap()["reason"], "payload_repaired");
        assert_eq!(fs::read(path).unwrap(), bytes);
    }

    #[test]
    fn recording_parts_are_invisible_and_assemble_without_boundary_loss() {
        let (_temporary, store) = store_with_general();
        let first = [-32_768, -12, -1, 0];
        let second = [1, 12, 32_767];

        assert_eq!(
            put_test_part(&store, "long-note", 1, &second).unwrap(),
            PutRecordingPart::Created
        );
        assert_eq!(
            put_test_part(&store, "long-note", 0, &first).unwrap(),
            PutRecordingPart::Created
        );
        assert!(store.records("kibo", "general").unwrap().is_empty());
        assert!(
            store
                .pending_clip_ids("kibo", "general")
                .unwrap()
                .is_empty()
        );

        let (outcome, event) = store
            .complete_recording(RecordingCompletion {
                project_id: "kibo",
                conversation_id: "general",
                recording_id: "long-note",
                part_count: 2,
                total_samples: 7,
            })
            .unwrap();
        assert_eq!(outcome, CompleteRecordingOutcome::Created);
        let event = event.unwrap();
        assert_eq!(event["kind"], "clip");
        assert_eq!(event["part_count"], 2);
        assert_eq!(event["samples"], 7);
        assert_eq!(event["peak"], 100);
        assert!(event["recorded_at"].as_u64().unwrap() <= event["at"].as_u64().unwrap());

        let mut reader =
            hound::WavReader::open(store.clip_path("kibo", "general", "long-note").unwrap())
                .unwrap();
        let samples: Vec<i16> = reader.samples().collect::<Result<_, _>>().unwrap();
        assert_eq!(samples, first.into_iter().chain(second).collect::<Vec<_>>());
        assert_eq!(store.records("kibo", "general").unwrap().len(), 1);
    }

    #[test]
    fn recording_part_put_is_idempotent_and_conflicting_content_is_rejected() {
        let (_temporary, store) = store_with_general();
        assert_eq!(
            put_test_part(&store, "retryable", 0, &[1, 2, 3]).unwrap(),
            PutRecordingPart::Created
        );
        assert_eq!(
            put_test_part(&store, "retryable", 0, &[1, 2, 3]).unwrap(),
            PutRecordingPart::AlreadyExists
        );
        let error = put_test_part(&store, "retryable", 0, &[3, 2, 1]).unwrap_err();
        assert!(error.downcast_ref::<RecordingConflict>().is_some());
        assert!(store.records("kibo", "general").unwrap().is_empty());
    }

    #[test]
    fn recording_completion_reports_missing_and_bad_totals_then_is_idempotent() {
        let (_temporary, store) = store_with_general();
        put_test_part(&store, "checked", 1, &[30, 40]).unwrap();
        let completion = || RecordingCompletion {
            project_id: "kibo",
            conversation_id: "general",
            recording_id: "checked",
            part_count: 2,
            total_samples: 4,
        };
        let error = store.complete_recording(completion()).unwrap_err();
        assert!(error.downcast_ref::<RecordingConflict>().is_some());
        assert!(error.to_string().contains("part 0 is missing"));

        put_test_part(&store, "checked", 0, &[10, 20]).unwrap();
        let error = store
            .complete_recording(RecordingCompletion {
                total_samples: 5,
                ..completion()
            })
            .unwrap_err();
        assert!(error.downcast_ref::<RecordingConflict>().is_some());
        assert!(error.to_string().contains("total_samples"));

        assert_eq!(
            store.complete_recording(completion()).unwrap().0,
            CompleteRecordingOutcome::Created
        );
        assert_eq!(
            store.complete_recording(completion()).unwrap(),
            (CompleteRecordingOutcome::AlreadyExists, None)
        );
        assert_eq!(
            store
                .records("kibo", "general")
                .unwrap()
                .iter()
                .filter(|event| event["kind"] == "clip")
                .count(),
            1
        );

        assert_eq!(
            put_test_part(&store, "checked", 0, &[10, 20]).unwrap(),
            PutRecordingPart::AlreadyExists
        );
        let error = put_test_part(&store, "checked", 0, &[99, 20]).unwrap_err();
        assert!(error.downcast_ref::<RecordingConflict>().is_some());
    }

    #[test]
    fn recording_completion_recovers_payload_renamed_before_event_append() {
        let (_temporary, store) = store_with_general();
        put_test_part(&store, "crash-window", 0, &[10, 20, 30]).unwrap();
        let conversation_directory = store.conversation_dir("kibo", "general");
        let parts_directory = store.recording_parts_dir("kibo", "general", "crash-window");
        let assembled = assemble_recording(
            &conversation_directory,
            &parts_directory,
            "crash-window",
            1,
            3,
        )
        .unwrap();
        let final_path = store.clip_path("kibo", "general", "crash-window").unwrap();
        fs::rename(assembled.path, &final_path).unwrap();
        assert!(store.records("kibo", "general").unwrap().is_empty());

        assert_eq!(
            store
                .complete_recording(RecordingCompletion {
                    project_id: "kibo",
                    conversation_id: "general",
                    recording_id: "crash-window",
                    part_count: 1,
                    total_samples: 3,
                })
                .unwrap()
                .0,
            CompleteRecordingOutcome::Created
        );
        assert_eq!(store.records("kibo", "general").unwrap().len(), 1);
        assert_eq!(file_sha256(&final_path), Some(assembled.sha256));
    }

    #[test]
    fn recording_payload_repair_persists_retry_intent_before_restoring_bytes() {
        let (_temporary, store) = store_with_general();
        put_test_part(&store, "repairable", 0, &[10, 20]).unwrap();
        let completion = || RecordingCompletion {
            project_id: "kibo",
            conversation_id: "general",
            recording_id: "repairable",
            part_count: 1,
            total_samples: 2,
        };
        assert_eq!(
            store.complete_recording(completion()).unwrap().0,
            CompleteRecordingOutcome::Created
        );
        let path = store.clip_path("kibo", "general", "repairable").unwrap();
        fs::write(&path, b"damaged").unwrap();

        store.fail_append_after(0);
        assert!(store.complete_recording(completion()).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"damaged");
        assert_eq!(store.records("kibo", "general").unwrap().len(), 1);

        let (outcome, event) = store.complete_recording(completion()).unwrap();
        assert_eq!(outcome, CompleteRecordingOutcome::Repaired);
        let event = event.unwrap();
        assert_eq!(event["kind"], "transcript_retry_requested");
        assert_eq!(event["clip"], "repairable");
        assert_eq!(event["reason"], "payload_repaired");
        let mut reader = hound::WavReader::open(&path).unwrap();
        let samples: Vec<i16> = reader.samples().collect::<Result<_, _>>().unwrap();
        assert_eq!(samples, [10, 20]);
        assert_eq!(store.records("kibo", "general").unwrap().len(), 2);

        assert_eq!(
            store.complete_recording(completion()).unwrap(),
            (CompleteRecordingOutcome::AlreadyExists, None)
        );
    }

    #[test]
    fn recording_part_validates_hash_sample_count_and_canonical_format() {
        let (_temporary, store) = store_with_general();
        let bytes = test_wav(&[1, 2]);
        let sha = hex_sha256(&bytes);
        assert!(
            store
                .put_recording_part(RecordingPartUpload {
                    project_id: "kibo",
                    conversation_id: "general",
                    recording_id: "validated",
                    sequence: 0,
                    bytes: &bytes,
                    expected_sha256: "bad",
                    sample_count: 2,
                })
                .is_err()
        );
        assert!(
            store
                .put_recording_part(RecordingPartUpload {
                    project_id: "kibo",
                    conversation_id: "general",
                    recording_id: "validated",
                    sequence: 0,
                    bytes: &bytes,
                    expected_sha256: &sha,
                    sample_count: 3,
                })
                .is_err()
        );
        assert!(
            store
                .put_recording_part(RecordingPartUpload {
                    project_id: "kibo",
                    conversation_id: "general",
                    recording_id: "validated",
                    sequence: 0,
                    bytes: b"RIFF not a canonical wave",
                    expected_sha256: "bad",
                    sample_count: 0,
                })
                .is_err()
        );
        assert!(store.records("kibo", "general").unwrap().is_empty());
    }

    #[test]
    fn append_recovers_an_incomplete_final_jsonl_record() {
        let (_temporary, store) = store_with_general();
        store
            .append_fixture("kibo", "general", json!({"kind":"one"}))
            .unwrap();
        let path = store
            .conversation_dir("kibo", "general")
            .join("turns.jsonl");
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(br#"{"kind":"interrup"#)
            .unwrap();

        assert_eq!(store.records("kibo", "general").unwrap().len(), 1);
        let two = store
            .append_fixture("kibo", "general", json!({"kind":"two"}))
            .unwrap();
        assert_eq!(two["seq"], 2);
        assert_eq!(store.records("kibo", "general").unwrap().len(), 2);
    }

    #[test]
    fn orphaned_clip_is_recovered_but_never_overwritten() {
        let (_temporary, store) = store_with_general();
        let path = store.clip_path("kibo", "general", "clip-1").unwrap();
        fs::write(&path, b"different").unwrap();
        let bytes = b"RIFF tiny fake wav";
        let sha = hex_sha256(bytes);
        let upload = ClipUpload {
            project_id: "kibo",
            conversation_id: "general",
            clip_id: "clip-1",
            bytes,
            expected_sha256: &sha,
            duration_ms: 1000,
            peak_pct: 10,
            recorded_at: 1,
        };

        assert!(store.put_clip(upload).is_err());
        assert_eq!(fs::read(path).unwrap(), b"different");
        assert!(store.records("kibo", "general").unwrap().is_empty());
    }

    #[test]
    fn ids_cannot_escape_the_data_root() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        assert!(store.clip_path("..", "general", "clip-1").is_err());
        assert!(store.clip_path("kibo", "general", "../secret").is_err());
    }

    #[test]
    fn concurrent_appends_have_unique_monotonic_sequences() {
        let (_temporary, store) = store_with_general();
        let threads: Vec<_> = (0..4)
            .map(|thread| {
                let store = store.clone();
                std::thread::spawn(move || {
                    for event in 0..5 {
                        store
                            .append_fixture(
                                "kibo",
                                "general",
                                json!({"kind":"concurrent", "thread":thread, "event":event}),
                            )
                            .unwrap();
                    }
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }

        let records = store.records("kibo", "general").unwrap();
        let sequences: HashSet<_> = records
            .iter()
            .filter_map(|record| record["seq"].as_u64())
            .collect();
        assert_eq!(records.len(), 20);
        assert_eq!(sequences.len(), 20);
        assert_eq!(sequences.iter().min(), Some(&1));
        assert_eq!(sequences.iter().max(), Some(&20));
    }

    #[test]
    fn concurrent_conditional_appends_commit_one_reopen_transition() {
        let (_temporary, store) = store_with_general();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"transcript_error", "clip":"clip-1", "terminal":true}),
            )
            .unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(5));
        let threads: Vec<_> = (0..4)
            .map(|_| {
                let store = store.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    store
                        .append_fixture_if(
                            "kibo",
                            "general",
                            json!({"kind":"transcript_retry_requested", "clip":"clip-1"}),
                            |records| {
                                !records.iter().any(|event| {
                                    event["kind"] == "transcript_retry_requested"
                                        && event["clip"] == "clip-1"
                                })
                            },
                        )
                        .unwrap()
                })
            })
            .collect();
        barrier.wait();
        let committed = threads
            .into_iter()
            .filter_map(|thread| thread.join().unwrap())
            .count();

        assert_eq!(committed, 1);
        assert_eq!(
            store
                .records("kibo", "general")
                .unwrap()
                .iter()
                .filter(|event| event["kind"] == "transcript_retry_requested")
                .count(),
            1
        );
    }

    #[test]
    fn create_turn_claims_clips_once_and_is_idempotent() {
        let (_temporary, store) = store_with_general();
        let bytes = b"RIFF tiny fake wav";
        let sha = hex_sha256(bytes);
        store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id: "general",
                clip_id: "clip-1",
                bytes,
                expected_sha256: &sha,
                duration_ms: 1000,
                peak_pct: 10,
                recorded_at: 2,
            })
            .unwrap();
        store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id: "general",
                clip_id: "clip-older",
                bytes,
                expected_sha256: &sha,
                duration_ms: 1000,
                peak_pct: 10,
                recorded_at: 1,
            })
            .unwrap();

        let created = store.create_turn("kibo", "general", "turn-1").unwrap();
        let existing = store.create_turn("kibo", "general", "turn-1").unwrap();
        assert!(matches!(created, CreateTurnOutcome::Created { .. }));
        assert!(matches!(existing, CreateTurnOutcome::Existing { .. }));
        let CreateTurnOutcome::Created { record, clips, .. } = created else {
            unreachable!()
        };
        assert_eq!(clips, ["clip-older", "clip-1"]);
        assert_eq!(record["seq"], 3);
        assert!(store.create_turn("kibo", "general", "turn-2").is_err());
    }

    #[test]
    fn concurrent_turn_retries_share_one_claim() {
        let (_temporary, store) = store_with_general();
        let bytes = b"RIFF tiny fake wav";
        let sha = hex_sha256(bytes);
        store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id: "general",
                clip_id: "clip-1",
                bytes,
                expected_sha256: &sha,
                duration_ms: 1,
                peak_pct: 1,
                recorded_at: 1,
            })
            .unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let threads: Vec<_> = (0..2)
            .map(|_| {
                let store = store.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    store.create_turn("kibo", "general", "turn-1").unwrap()
                })
            })
            .collect();
        let outcomes: Vec<_> = threads
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .collect();

        assert_eq!(
            outcomes
                .iter()
                .filter(|outcome| matches!(outcome, CreateTurnOutcome::Created { .. }))
                .count(),
            1
        );
        assert_eq!(
            outcomes
                .iter()
                .filter(|outcome| matches!(outcome, CreateTurnOutcome::Existing { .. }))
                .count(),
            1
        );
        assert_eq!(store.records("kibo", "general").unwrap().len(), 2);
    }

    #[test]
    fn conversation_creation_records_why_it_has_its_name() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let placeholder = store.create_conversation("kibo", None).unwrap();
        let manual = store
            .create_conversation("kibo", Some("Road trip notes"))
            .unwrap();

        assert_eq!(placeholder.name, "New conversation");
        assert_eq!(placeholder.name_source, ConversationNameSource::Placeholder);
        assert_eq!(manual.name, "Road trip notes");
        assert_eq!(manual.name_source, ConversationNameSource::Manual);
        assert!(store.create_conversation("kibo", Some("  ")).is_err());
    }

    #[test]
    fn conversations_sort_by_persisted_recent_activity() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let mut older = store.create_conversation("kibo", None).unwrap();
        older.created_at = 1;
        older.last_activity_at = 1;
        store.write_conversation(&older).unwrap();
        let mut newer = store.create_conversation("kibo", None).unwrap();
        newer.created_at = 2;
        newer.last_activity_at = 2;
        store.write_conversation(&newer).unwrap();

        store
            .append_fixture(
                "kibo",
                &older.id,
                json!({"kind":"reply", "at":10, "turn":"turn-1", "text":"hello"}),
            )
            .unwrap();

        let conversations = store.list_conversations("kibo").unwrap();
        assert_eq!(conversations[0].id, older.id);
        assert_eq!(conversations[0].last_activity_at, 10);
        assert_eq!(conversations[1].id, newer.id);
    }

    #[test]
    fn startup_backfills_legacy_activity_from_newest_durable_event() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let mut conversation = store.create_conversation("kibo", None).unwrap();
        conversation.created_at = 1;
        conversation.last_activity_at = 1;
        store.write_conversation(&conversation).unwrap();
        store
            .append_fixture("kibo", &conversation.id, json!({"kind":"one", "at":40}))
            .unwrap();
        store
            .append_fixture("kibo", &conversation.id, json!({"kind":"two", "at":30}))
            .unwrap();
        let metadata_path = store
            .conversation_dir("kibo", &conversation.id)
            .join("conversation.json");
        let mut legacy: Value = read_json(&metadata_path).unwrap();
        legacy.as_object_mut().unwrap().remove("last_activity_at");
        write_json_atomic(&metadata_path, &legacy).unwrap();
        let conversation_id = conversation.id;
        drop(store);

        let reopened = Store::open(temporary.path()).unwrap();
        let reconciled = reopened.conversation("kibo", &conversation_id).unwrap();
        assert_eq!(reconciled.last_activity_at, 40);
        let persisted: Value = read_json(&metadata_path).unwrap();
        assert_eq!(persisted["last_activity_at"], 40);
    }

    #[test]
    fn durable_writes_succeed_when_activity_cache_writes_fail() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let mut conversation = store.create_conversation("kibo", None).unwrap();
        conversation.created_at = 1;
        conversation.last_activity_at = 1;
        store.write_conversation(&conversation).unwrap();
        store.fail_activity_writes.store(true, Ordering::Relaxed);

        store
            .append_fixture("kibo", &conversation.id, json!({"kind":"note", "at":50}))
            .unwrap();
        let bytes = b"RIFF tiny fake wav";
        let sha = hex_sha256(bytes);
        assert_eq!(
            store
                .put_clip(ClipUpload {
                    project_id: "kibo",
                    conversation_id: &conversation.id,
                    clip_id: "clip-1",
                    bytes,
                    expected_sha256: &sha,
                    duration_ms: 1,
                    peak_pct: 1,
                    recorded_at: 1,
                })
                .unwrap()
                .0,
            PutClip::Created
        );
        assert!(matches!(
            store
                .create_turn("kibo", &conversation.id, "turn-1")
                .unwrap(),
            CreateTurnOutcome::Created { .. }
        ));
        let records = store.records("kibo", &conversation.id).unwrap();
        assert_eq!(records.len(), 3);
        assert_eq!(
            store
                .conversation("kibo", &conversation.id)
                .unwrap()
                .last_activity_at,
            1
        );
        let durable_activity = records
            .iter()
            .filter_map(|record| record["at"].as_u64())
            .max()
            .unwrap();
        let conversation_id = conversation.id;
        drop(store);

        let reopened = Store::open(temporary.path()).unwrap();
        assert_eq!(
            reopened
                .conversation("kibo", &conversation_id)
                .unwrap()
                .last_activity_at,
            durable_activity
        );
    }

    #[test]
    fn clip_and_turn_creation_advance_persisted_activity() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let mut conversation = store.create_conversation("kibo", None).unwrap();
        conversation.created_at = 1;
        conversation.last_activity_at = 1;
        store.write_conversation(&conversation).unwrap();
        let bytes = b"RIFF tiny fake wav";
        let sha = hex_sha256(bytes);

        let (_, Some(clip)) = store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id: &conversation.id,
                clip_id: "clip-1",
                bytes,
                expected_sha256: &sha,
                duration_ms: 1,
                peak_pct: 1,
                recorded_at: 1,
            })
            .unwrap()
        else {
            panic!("new clip should have an event")
        };
        assert_eq!(
            store
                .conversation("kibo", &conversation.id)
                .unwrap()
                .last_activity_at,
            clip["at"].as_u64().unwrap()
        );

        let CreateTurnOutcome::Created { record, .. } = store
            .create_turn("kibo", &conversation.id, "turn-1")
            .unwrap()
        else {
            panic!("new turn should be created")
        };
        assert_eq!(
            store
                .conversation("kibo", &conversation.id)
                .unwrap()
                .last_activity_at,
            record["at"].as_u64().unwrap()
        );
    }

    #[test]
    fn placeholder_uses_first_useful_transcript_once() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        for text in ["", "[silent]", "  [mock transcript]  "] {
            store
                .append_fixture(
                    "kibo",
                    &conversation.id,
                    json!({"kind":"transcript", "clip":"ignored", "text":text}),
                )
                .unwrap();
        }
        assert!(matches!(
            store
                .auto_name_from_transcript("kibo", &conversation.id)
                .unwrap(),
            AutoNameOutcome::Unchanged(_)
        ));

        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({
                    "kind":"transcript",
                    "clip":"useful",
                    "text":"  Plan   a route through Oregon with two friends next weekend please  "
                }),
            )
            .unwrap();
        let AutoNameOutcome::Named(named) = store
            .auto_name_from_transcript("kibo", &conversation.id)
            .unwrap()
        else {
            panic!("placeholder should have been named")
        };
        assert_eq!(named.name, "Plan a route through Oregon with two friends");
        assert_eq!(named.name_source, ConversationNameSource::Transcript);

        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"transcript", "clip":"later", "text":"A different title"}),
            )
            .unwrap();
        assert!(matches!(
            store
                .auto_name_from_transcript("kibo", &conversation.id)
                .unwrap(),
            AutoNameOutcome::Unchanged(current) if current.name == named.name
        ));
    }

    #[test]
    fn transcript_name_has_a_unicode_safe_character_cap() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        let long_word = "é".repeat(80);
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"transcript", "clip":"one", "text":long_word}),
            )
            .unwrap();
        let AutoNameOutcome::Named(named) = store
            .auto_name_from_transcript("kibo", &conversation.id)
            .unwrap()
        else {
            panic!("placeholder should have been named")
        };
        assert_eq!(named.name.chars().count(), 60);
        assert!(named.name.chars().all(|character| character == 'é'));
    }

    fn test_jpeg(payload: &[u8]) -> Vec<u8> {
        let mut bytes = vec![0xFF, 0xD8, 0xFF, 0xE0];
        bytes.extend_from_slice(payload);
        bytes
    }

    fn test_png(payload: &[u8]) -> Vec<u8> {
        let mut bytes = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        bytes.extend_from_slice(payload);
        bytes
    }

    fn image_upload<'a>(image_id: &'a str, bytes: &'a [u8], sha: &'a str) -> ImageUpload<'a> {
        ImageUpload {
            project_id: "kibo",
            conversation_id: "general",
            image_id,
            bytes,
            expected_sha256: sha,
            recorded_at: 1,
            width: None,
            height: None,
            caption: None,
        }
    }

    #[test]
    fn image_format_sniffing_is_the_mime_authority() {
        assert_eq!(
            sniff_image_format(&test_jpeg(b"pixels")),
            Some(ImageFormat::Jpeg)
        );
        assert_eq!(
            sniff_image_format(&test_png(b"pixels")),
            Some(ImageFormat::Png)
        );
        let mut webp = b"RIFF".to_vec();
        webp.extend_from_slice(&[0, 0, 0, 0]);
        webp.extend_from_slice(b"WEBPpixels");
        assert_eq!(sniff_image_format(&webp), Some(ImageFormat::Webp));

        // HEIC, WAV, and garbage are rejected at the door.
        assert_eq!(sniff_image_format(b"\x00\x00\x00\x18ftypheic\x00\x00"), None);
        assert_eq!(sniff_image_format(b"RIFF0000WAVEfmt "), None);
        assert_eq!(sniff_image_format(b"plain text"), None);
        assert_eq!(sniff_image_format(b""), None);
    }

    #[test]
    fn image_upload_is_idempotent_by_id_and_hash() {
        let (_temporary, store) = store_with_general();
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        let (outcome, events) = store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        assert_eq!(outcome, PutImage::Created);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["kind"], "image");
        assert_eq!(events[0]["file"], "images/img-1.jpg");
        assert_eq!(events[0]["mime"], "image/jpeg");

        let (outcome, events) = store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        assert_eq!(outcome, PutImage::AlreadyExists);
        assert!(events.is_empty());
        assert_eq!(store.records("kibo", "general").unwrap().len(), 1);
    }

    #[test]
    fn image_upload_conflicts_on_different_bytes_and_cross_kind_ids() {
        let (_temporary, store) = store_with_general();
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();

        let different = test_jpeg(b"other pixels");
        let different_sha = hex_sha256(&different);
        let error = store
            .put_image(image_upload("img-1", &different, &different_sha))
            .unwrap_err();
        assert!(error.downcast_ref::<ImageConflict>().is_some());
        let path = store.image_path("kibo", "general", "img-1").unwrap();
        assert_eq!(fs::read(&path).unwrap(), bytes);

        // One media-ID namespace: a clip cannot take an image's ID and an
        // image cannot take a clip's, whatever the bytes.
        let wav = b"RIFF tiny fake wav";
        let wav_sha = hex_sha256(wav);
        let clip_error = store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id: "general",
                clip_id: "img-1",
                bytes: wav,
                expected_sha256: &wav_sha,
                duration_ms: 1,
                peak_pct: 1,
                recorded_at: 1,
            })
            .unwrap_err();
        assert!(clip_error.downcast_ref::<ClipConflict>().is_some());

        store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id: "general",
                clip_id: "clip-1",
                bytes: wav,
                expected_sha256: &wav_sha,
                duration_ms: 1,
                peak_pct: 1,
                recorded_at: 1,
            })
            .unwrap();
        let image_error = store
            .put_image(image_upload("clip-1", &bytes, &sha))
            .unwrap_err();
        assert!(image_error.downcast_ref::<ImageConflict>().is_some());
    }

    #[test]
    fn image_file_without_event_is_adopted_by_matching_retry() {
        let (_temporary, store) = store_with_general();
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        let directory = store.conversation_dir("kibo", "general").join("images");
        fs::create_dir_all(&directory).unwrap();
        fs::write(directory.join("img-1.jpg"), &bytes).unwrap();

        let (outcome, events) = store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        assert_eq!(outcome, PutImage::Created);
        assert_eq!(events.len(), 1);

        // Different orphan bytes are never overwritten.
        fs::write(directory.join("img-2.jpg"), b"unrelated").unwrap();
        let error = store
            .put_image(image_upload("img-2", &bytes, &sha))
            .unwrap_err();
        assert!(error.downcast_ref::<ImageConflict>().is_some());
        assert_eq!(fs::read(directory.join("img-2.jpg")).unwrap(), b"unrelated");
    }

    #[test]
    fn crash_left_alternate_extension_is_a_conflict_never_superseded() {
        let (_temporary, store) = store_with_general();
        let directory = store.conversation_dir("kibo", "general").join("images");
        fs::create_dir_all(&directory).unwrap();
        // A crash-left PNG under this ID: a JPEG retry must conflict, both
        // before an event exists and after one is forged for the JPEG.
        fs::write(directory.join("img-1.png"), test_png(b"crash leftover")).unwrap();
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        let error = store
            .put_image(image_upload("img-1", &bytes, &sha))
            .unwrap_err();
        assert!(error.downcast_ref::<ImageConflict>().is_some());
        assert!(store.records("kibo", "general").unwrap().is_empty());

        let (outcome, _) = store.put_image(image_upload("img-2", &bytes, &sha)).unwrap();
        assert_eq!(outcome, PutImage::Created);
        fs::write(directory.join("img-2.webp"), b"other leftover").unwrap();
        let error = store
            .put_image(image_upload("img-2", &bytes, &sha))
            .unwrap_err();
        assert!(error.downcast_ref::<ImageConflict>().is_some());
    }

    #[test]
    fn image_repair_appends_reopen_intents_before_restoring_bytes() {
        let (_temporary, store) = store_with_general();
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        // Two claiming turns in non-successful reply states plus a terminal
        // description: repair must reopen all of them, in one batch.
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"turn", "id":"turn-1", "clips":[], "images":["img-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "stage":"reply", "error":"corrupt input"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"turn", "id":"turn-2", "clips":[], "images":["img-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"reply_started", "turn":"turn-2", "attempt":1}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"description_error", "image":"img-1", "attempt":1, "terminal":true, "error":"corrupt input"}),
            )
            .unwrap();
        let path = store.image_path("kibo", "general", "img-1").unwrap();
        fs::write(&path, b"damaged").unwrap();

        let (outcome, events) = store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        assert_eq!(outcome, PutImage::Repaired);
        let kinds: Vec<(&str, &str)> = events
            .iter()
            .map(|event| {
                (
                    event["kind"].as_str().unwrap(),
                    event["turn"].as_str().or(event["image"].as_str()).unwrap(),
                )
            })
            .collect();
        assert_eq!(
            kinds,
            [
                ("reply_retry_requested", "turn-1"),
                ("reply_retry_requested", "turn-2"),
                ("description_retry_requested", "img-1"),
            ]
        );
        // Contiguous sequence numbers: the API can publish without a WS gap.
        let seqs: Vec<u64> = events
            .iter()
            .map(|event| event["seq"].as_u64().unwrap())
            .collect();
        assert!(seqs.windows(2).all(|pair| pair[1] == pair[0] + 1));
        assert!(
            events
                .iter()
                .all(|event| event["reason"] == "payload_repaired")
        );
        assert_eq!(fs::read(&path).unwrap(), bytes);

        // Replay after repair is inert: the reopened stages are Due (open
        // work), so nothing is appended twice.
        let (outcome, events) = store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        assert_eq!(outcome, PutImage::AlreadyExists);
        assert!(events.is_empty());
    }

    #[test]
    fn failed_repair_batch_restores_nothing_and_reentry_converges() {
        let (_temporary, store) = store_with_general();
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"turn", "id":"turn-1", "clips":[], "images":["img-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "stage":"reply", "error":"corrupt input"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"description_error", "image":"img-1", "attempt":1, "terminal":true, "error":"corrupt input"}),
            )
            .unwrap();
        let path = store.image_path("kibo", "general", "img-1").unwrap();
        fs::write(&path, b"damaged").unwrap();

        // The batched intent write fails: no event is durable and the bytes
        // are NOT restored, so the failure cannot masquerade as a repair.
        store.fail_append_after(0);
        assert!(store.put_image(image_upload("img-1", &bytes, &sha)).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"damaged");
        assert_eq!(store.records("kibo", "general").unwrap().len(), 4);

        // Idempotent re-entry appends the missing intents, then restores.
        let (outcome, events) = store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        assert_eq!(outcome, PutImage::Repaired);
        assert_eq!(events.len(), 2);
        assert_eq!(fs::read(&path).unwrap(), bytes);
        assert_eq!(
            store.put_image(image_upload("img-1", &bytes, &sha)).unwrap(),
            (PutImage::AlreadyExists, Vec::new())
        );
    }

    #[test]
    fn repair_batch_durable_but_bytes_unrestored_converges_on_retry() {
        // Crash window: the intent batch committed but the process died
        // before the bytes were restored. Re-entry must append nothing new
        // (the reopened stages are Due) and still restore the payload.
        let (_temporary, store) = store_with_general();
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"turn", "id":"turn-1", "clips":[], "images":["img-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "stage":"reply", "error":"corrupt input"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"reply_retry_requested", "turn":"turn-1", "reason":"payload_repaired"}),
            )
            .unwrap();
        let path = store.image_path("kibo", "general", "img-1").unwrap();
        fs::write(&path, b"damaged").unwrap();
        let records_before = store.records("kibo", "general").unwrap().len();

        let (outcome, events) = store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        assert_eq!(outcome, PutImage::Repaired);
        assert!(events.is_empty());
        assert_eq!(fs::read(&path).unwrap(), bytes);
        assert_eq!(store.records("kibo", "general").unwrap().len(), records_before);
    }

    #[test]
    fn torn_repair_batch_tail_repairs_and_reentry_appends_missing_intents() {
        // Crash window: the batch tore mid-write — a durable reply reopen
        // plus a partial final line. Re-entry must repair the tail, skip the
        // already-open reply, append only the missing description intent,
        // then restore the bytes.
        let (_temporary, store) = store_with_general();
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"turn", "id":"turn-1", "clips":[], "images":["img-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"reply_error", "turn":"turn-1", "attempt":1, "terminal":true, "stage":"reply", "error":"corrupt input"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"description_error", "image":"img-1", "attempt":1, "terminal":true, "error":"corrupt input"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"reply_retry_requested", "turn":"turn-1", "reason":"payload_repaired"}),
            )
            .unwrap();
        let journal = store.conversation_dir("kibo", "general").join("turns.jsonl");
        {
            use std::io::Write as _;
            let mut file = fs::OpenOptions::new().append(true).open(&journal).unwrap();
            file.write_all(br#"{"kind":"description_retry_req"#).unwrap();
        }
        let path = store.image_path("kibo", "general", "img-1").unwrap();
        fs::write(&path, b"damaged").unwrap();

        let (outcome, events) = store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        assert_eq!(outcome, PutImage::Repaired);
        let kinds: Vec<&str> = events
            .iter()
            .map(|event| event["kind"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, ["description_retry_requested"]);
        assert_eq!(fs::read(&path).unwrap(), bytes);
        // The torn tail is gone: every journal line parses.
        for line in fs::read_to_string(&journal).unwrap().lines() {
            serde_json::from_str::<Value>(line).unwrap();
        }
    }

    #[test]
    fn image_repair_skips_open_work_and_successful_values() {
        let (_temporary, store) = store_with_general();
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        // Successful reply and description: repair restores bytes silently.
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"turn", "id":"turn-1", "clips":[], "images":["img-1"]}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"reply", "turn":"turn-1", "text":"answered"}),
            )
            .unwrap();
        store
            .append_fixture(
                "kibo",
                "general",
                json!({"kind":"description", "image":"img-1", "text":"a photo", "attempt":1, "model":"mock", "prompt_version":1}),
            )
            .unwrap();
        let path = store.image_path("kibo", "general", "img-1").unwrap();
        fs::write(&path, b"damaged").unwrap();

        let (outcome, events) = store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        assert_eq!(outcome, PutImage::Repaired);
        assert!(events.is_empty(), "first success stays authoritative");
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }

    #[test]
    fn create_turn_claims_pending_images_sorted_by_recorded_at() {
        let (_temporary, store) = store_with_general();
        let wav = b"RIFF tiny fake wav";
        let wav_sha = hex_sha256(wav);
        store
            .put_clip(ClipUpload {
                project_id: "kibo",
                conversation_id: "general",
                clip_id: "clip-1",
                bytes: wav,
                expected_sha256: &wav_sha,
                duration_ms: 1,
                peak_pct: 1,
                recorded_at: 2,
            })
            .unwrap();
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        store
            .put_image(ImageUpload {
                recorded_at: 3,
                ..image_upload("img-late", &bytes, &sha)
            })
            .unwrap();
        store
            .put_image(ImageUpload {
                recorded_at: 1,
                ..image_upload("img-early", &bytes, &sha)
            })
            .unwrap();

        let CreateTurnOutcome::Created {
            record,
            clips,
            images,
        } = store.create_turn("kibo", "general", "turn-1").unwrap()
        else {
            panic!("expected a new turn");
        };
        assert_eq!(clips, ["clip-1"]);
        assert_eq!(images, ["img-early", "img-late"]);
        assert_eq!(record["images"], json!(["img-early", "img-late"]));

        // Idempotent replay returns the original claim.
        let CreateTurnOutcome::Existing { images, .. } =
            store.create_turn("kibo", "general", "turn-1").unwrap()
        else {
            panic!("expected the existing turn");
        };
        assert_eq!(images, ["img-early", "img-late"]);
        // Everything claimed: a new turn has nothing to answer.
        assert!(store.create_turn("kibo", "general", "turn-2").is_err());
    }

    #[test]
    fn image_only_turn_is_legal_and_empty_turn_still_conflicts() {
        let (_temporary, store) = store_with_general();
        assert!(
            store
                .create_turn("kibo", "general", "turn-none")
                .unwrap_err()
                .downcast_ref::<NoPendingClips>()
                .is_some()
        );
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        store.put_image(image_upload("img-1", &bytes, &sha)).unwrap();
        let CreateTurnOutcome::Created { clips, images, record } =
            store.create_turn("kibo", "general", "turn-1").unwrap()
        else {
            panic!("expected a new turn");
        };
        assert!(clips.is_empty());
        assert_eq!(images, ["img-1"]);
        assert_eq!(record["clips"], json!([]));
    }

    #[test]
    fn recording_ids_cannot_collide_with_images() {
        let (_temporary, store) = store_with_general();
        let bytes = test_jpeg(b"pixels");
        let sha = hex_sha256(&bytes);
        store
            .put_image(image_upload("shared-id", &bytes, &sha))
            .unwrap();
        put_test_part(&store, "shared-id", 0, &[1, 2]).unwrap();
        let error = store
            .complete_recording(RecordingCompletion {
                project_id: "kibo",
                conversation_id: "general",
                recording_id: "shared-id",
                part_count: 1,
                total_samples: 2,
            })
            .unwrap_err();
        assert!(error.downcast_ref::<RecordingConflict>().is_some());
    }

    #[test]
    fn concurrent_auto_name_attempts_make_one_transition() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        store
            .append_fixture(
                "kibo",
                &conversation.id,
                json!({"kind":"transcript", "clip":"one", "text":"Stable title"}),
            )
            .unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let threads: Vec<_> = (0..2)
            .map(|_| {
                let store = store.clone();
                let conversation_id = conversation.id.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    store
                        .auto_name_from_transcript("kibo", &conversation_id)
                        .unwrap()
                })
            })
            .collect();
        let outcomes: Vec<_> = threads
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .collect();

        assert_eq!(
            outcomes
                .iter()
                .filter(|outcome| matches!(outcome, AutoNameOutcome::Named(_)))
                .count(),
            1
        );
        assert_eq!(
            outcomes
                .iter()
                .filter(|outcome| matches!(outcome, AutoNameOutcome::Unchanged(_)))
                .count(),
            1
        );
    }
}

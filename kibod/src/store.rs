use crate::model::{
    ConversationNameSource, KiboConversation, KiboProject, epoch, make_id, valid_id,
};
use anyhow::{Context, Result, anyhow, bail};
use fs2::FileExt;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Clone)]
pub struct Store {
    root: Arc<PathBuf>,
    locks: Arc<Mutex<HashMap<String, Arc<Mutex<()>>>>>,
    _writer_lock: Arc<File>,
    #[cfg(test)]
    fail_activity_writes: Arc<AtomicBool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PutClip {
    Created,
    AlreadyExists,
}

#[derive(Debug, Clone, PartialEq)]
pub enum CreateTurnOutcome {
    Created { record: Value, clips: Vec<String> },
    Existing { record: Value, clips: Vec<String> },
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

    pub fn append(
        &self,
        project_id: &str,
        conversation_id: &str,
        mut record: Value,
    ) -> Result<Value> {
        self.conversation(project_id, conversation_id)?;
        let lock = self.conversation_lock(project_id, conversation_id);
        let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
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
            .find(|record| record["kind"] == "clip" && record["id"] == upload.clip_id);
        let directory = self.conversation_dir(upload.project_id, upload.conversation_id);
        let filename = format!("{}.wav", upload.clip_id);
        let final_path = directory.join("clips").join(&filename);
        if let Some(existing) = existing {
            if existing["sha256"].as_str() == Some(&actual_sha) {
                // Restore a missing/corrupt payload after an interrupted write or
                // external damage while keeping the event idempotent.
                if file_sha256(&final_path).as_deref() != Some(actual_sha.as_str()) {
                    write_clip_atomic(&directory, upload.clip_id, upload.bytes)?;
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
        let seq = next_seq(&path)?;
        let record = json!({
            "kind": "clip",
            "seq": seq,
            "at": epoch(),
            "id": upload.clip_id,
            "file": format!("clips/{filename}"),
            "mime": "audio/wav",
            "ms": upload.duration_ms,
            "peak": upload.peak_pct,
            "recorded_at": upload.recorded_at,
            "sha256": actual_sha,
        });
        append_jsonl(&path, &record)?;
        self.record_activity_best_effort(
            upload.project_id,
            upload.conversation_id,
            record["at"].as_u64(),
        );
        Ok((PutClip::Created, Some(record)))
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

    /// Atomically create an AI turn and claim every clip that was pending at
    /// that instant. A retry with the same turn ID returns the original claim;
    /// a new turn with no pending clips is rejected.
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
            return Ok(CreateTurnOutcome::Existing {
                record: record.clone(),
                clips,
            });
        }

        let clips = unclaimed_clip_ids(&records);
        if clips.is_empty() {
            return Err(NoPendingClips.into());
        }
        let record = json!({
            "kind": "turn",
            "seq": next_seq(&path)?,
            "at": epoch(),
            "id": turn_id,
            "clips": clips,
        });
        append_jsonl(&path, &record)?;
        self.record_activity_best_effort(project_id, conversation_id, record["at"].as_u64());
        Ok(CreateTurnOutcome::Created {
            clips: turn_clips(&record)?,
            record,
        })
    }

    pub fn untranscribed(&self, project_id: &str, conversation_id: &str) -> Result<Vec<String>> {
        let records = self.records(project_id, conversation_id)?;
        let finished: HashSet<String> = records
            .iter()
            .filter(|record| record["kind"] == "transcript")
            .filter_map(|record| record["clip"].as_str().map(str::to_string))
            .collect();
        Ok(records
            .iter()
            .filter(|record| record["kind"] == "clip")
            .filter_map(|record| record["id"].as_str())
            .filter(|id| !finished.contains(*id))
            .map(str::to_string)
            .collect())
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
    let claimed: HashSet<&str> = records
        .iter()
        .filter(|record| record["kind"] == "turn")
        .flat_map(|record| {
            record["clips"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
        })
        .collect();
    let mut clips: Vec<(u64, u64, String)> = records
        .iter()
        .filter(|record| record["kind"] == "clip")
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
    clips.sort_by_key(|(recorded_at, seq, _)| (*recorded_at, *seq));
    clips.into_iter().map(|(_, _, id)| id).collect()
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
    let temporary_path = directory.join("clips").join(format!(
        ".{clip_id}.{}.upload",
        uuid::Uuid::new_v4().simple()
    ));
    let mut file = File::create(&temporary_path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fs::rename(&temporary_path, &final_path).inspect_err(|_| {
        let _ = fs::remove_file(&temporary_path);
    })?;
    sync_parent(&final_path)
}

fn file_sha256(path: &Path) -> Option<String> {
    fs::read(path).ok().map(|bytes| hex_sha256(&bytes))
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
            .append("kibo", "general", json!({"kind":"one"}))
            .unwrap();
        let two = store
            .append("kibo", "general", json!({"kind":"two"}))
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
    fn append_recovers_an_incomplete_final_jsonl_record() {
        let (_temporary, store) = store_with_general();
        store
            .append("kibo", "general", json!({"kind":"one"}))
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
            .append("kibo", "general", json!({"kind":"two"}))
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
                            .append(
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
        let CreateTurnOutcome::Created { record, clips } = created else {
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
            .append(
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
            .append("kibo", &conversation.id, json!({"kind":"one", "at":40}))
            .unwrap();
        store
            .append("kibo", &conversation.id, json!({"kind":"two", "at":30}))
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
            .append("kibo", &conversation.id, json!({"kind":"note", "at":50}))
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
                .append(
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
            .append(
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
            .append(
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
            .append(
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

    #[test]
    fn concurrent_auto_name_attempts_make_one_transition() {
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path()).unwrap();
        let conversation = store.create_conversation("kibo", None).unwrap();
        store
            .append(
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

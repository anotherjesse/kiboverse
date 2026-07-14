//! Push-to-talk prototype driven by a joystick (/dev/input/jsN).
//!
//! Hold the record button to record a clip; release to save it. Press the
//! AI button for "the AI's turn to answer" — for now simulated by playing
//! back every clip since the last reply, then logging the reply.
//!
//! Durability rules (see voiceflow.md — NEVER LOSE USER DATA): the clip is
//! finalized on disk (atomic rename to recording-<uuid>.wav) and logged in
//! turns.jsonl before anything else happens to it. Clips are never deleted
//! by an AI turn; the reply is just another line in the log.

use recplay::{chime, run};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const RECORD_BTN: u8 = 0;
const AI_BTN: u8 = 1;
const MIN_CLIP: Duration = Duration::from_millis(500);

fn main() -> std::io::Result<()> {
    let frag = std::env::args().nth(1).unwrap_or_else(|| "USB Gamepad".into());
    let js = find_js(&frag)
        .ok_or_else(|| std::io::Error::other(format!("no joystick matching {frag:?}")))?;
    let dir = data_dir()?;
    println!("joystick: {}", js.display());
    println!("data dir: {}", dir.display());
    println!("hold button {RECORD_BTN} to record, press button {AI_BTN} for the AI's turn");

    let mut dev = File::open(&js)?;
    let mut buf = [0u8; 8]; // struct js_event: u32 time, i16 value, u8 type, u8 number
    let mut rec: Option<(Child, Instant, PathBuf)> = None;

    loop {
        dev.read_exact(&mut buf)?;
        let value = i16::from_le_bytes([buf[4], buf[5]]);
        let etype = buf[6];
        let number = buf[7];
        if etype & 0x80 != 0 || etype != 0x01 {
            continue; // skip init burst and axis events
        }
        match (number, value, &rec) {
            (RECORD_BTN, 1, None) => {
                let work = dir.join("current-recording.wav");
                chime(&[660.0, 880.0])?;
                let child = Command::new("arecord")
                    .args(["-q", "-f", "S16_LE", "-r", "44100", "-c", "1"])
                    .arg(&work)
                    .spawn()?;
                println!("recording...");
                rec = Some((child, Instant::now(), work));
            }
            (RECORD_BTN, 0, Some(_)) => {
                let (mut child, started, work) = rec.take().unwrap();
                let elapsed = started.elapsed();
                // SIGINT so arecord finalizes the WAV header (SIGKILL corrupts it)
                run("kill", &["-INT", &child.id().to_string()])?;
                child.wait()?;
                if elapsed < MIN_CLIP {
                    let _ = fs::remove_file(&work);
                    println!("discarded accidental tap ({}ms)", elapsed.as_millis());
                    chime(&[220.0])?;
                } else {
                    let (id, file) = clip_name(&dir);
                    fs::rename(&work, dir.join(&file))?;
                    append_turn(
                        &dir,
                        &format!(
                            r#"{{"kind":"clip","id":"{id}","file":"{file}","ms":{},"at":{}}}"#,
                            elapsed.as_millis(),
                            epoch()
                        ),
                    )?;
                    println!("saved {file} ({}ms)", elapsed.as_millis());
                    chime(&[880.0, 660.0])?;
                }
            }
            (AI_BTN, 1, None) => ai_turn(&dir)?,
            (AI_BTN, 1, Some(_)) => println!("still recording — release first"),
            (n, 1, _) => println!("button {n} (unmapped)"),
            _ => {}
        }
    }
}

/// Play back every clip since the last reply, then log the reply.
fn ai_turn(dir: &Path) -> std::io::Result<()> {
    let log = fs::read_to_string(dir.join("turns.jsonl")).unwrap_or_default();
    let mut pending: Vec<(String, String)> = Vec::new();
    for line in log.lines() {
        if line.contains(r#""kind":"reply""#) {
            pending.clear();
        } else if line.contains(r#""kind":"clip""#) {
            if let (Some(id), Some(file)) = (field(line, "id"), field(line, "file")) {
                pending.push((id, file));
            }
        }
    }
    if pending.is_empty() {
        println!("nothing new to answer");
        chime(&[330.0, 220.0])?;
        return Ok(());
    }
    println!("AI turn: answering {} clip(s)", pending.len());
    chime(&[523.0, 659.0, 784.0])?;
    for (_, file) in &pending {
        run("aplay", &["-q", dir.join(file).to_str().unwrap()])?;
    }
    let ids: Vec<String> = pending.iter().map(|(id, _)| format!("\"{id}\"")).collect();
    append_turn(
        dir,
        &format!(r#"{{"kind":"reply","answers":[{}],"at":{}}}"#, ids.join(","), epoch()),
    )?;
    chime(&[784.0, 1046.0])?;
    Ok(())
}

fn find_js(frag: &str) -> Option<PathBuf> {
    (0..8).find_map(|i| {
        let name = fs::read_to_string(format!("/sys/class/input/js{i}/device/name")).ok()?;
        name.trim()
            .contains(frag)
            .then(|| PathBuf::from(format!("/dev/input/js{i}")))
    })
}

fn data_dir() -> std::io::Result<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    let dir = PathBuf::from(home).join("kibo-data");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn append_turn(dir: &Path, line: &str) -> std::io::Result<()> {
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("turns.jsonl"))?;
    writeln!(f, "{line}")?;
    f.sync_all()
}

/// Pull a string field out of one of our own turns.jsonl lines.
fn field(line: &str, key: &str) -> Option<String> {
    let tag = format!("\"{key}\":\"");
    let start = line.find(&tag)? + tag.len();
    let end = line[start..].find('"')? + start;
    Some(line[start..end].to_string())
}

/// Timestamped clip id/filename; suffixed if the name is somehow taken so an
/// existing recording is never overwritten.
fn clip_name(dir: &Path) -> (String, String) {
    let base = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
    let mut id = base.clone();
    let mut n = 1;
    while dir.join(format!("recording-{id}.wav")).exists() {
        n += 1;
        id = format!("{base}-{n}");
    }
    (id.clone(), format!("recording-{id}.wav"))
}

fn epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

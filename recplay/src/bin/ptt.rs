//! Push-to-talk voice companion driven by a joystick (/dev/input/jsN).
//!
//! Hold the record button to record a clip; release to save it. Each clip is
//! transcribed (Gemini). Press the AI button for "the AI's turn to answer":
//! the transcripts since the last reply become one user turn, gemini-3.5-flash
//! writes a reply (conversation memory lives server-side via
//! previous_interaction_id), and the reply is spoken through the speaker
//! (Gemini TTS). Starting a recording pauses playback; when the clip is
//! saved, playback resumes rewound ~1s. Pressing the AI button while kibo is
//! speaking skips the rest of the speech.
//!
//! Durability rules (see voiceflow.md — NEVER LOSE USER DATA): the clip is
//! finalized on disk and logged in turns.jsonl before anything else happens
//! to it; transcripts, reply text, and errors are all durable records, and
//! reply text is saved before speech synthesis begins. On startup, clips
//! without transcripts are picked up again.
//!
//! arecord/aplay/curl are kept as thin shims so the Mac→Pi cross-compile
//! stays pure Rust; audio and JSON flow through us.

use base64::Engine;
use recplay::{audio_dev, chime};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const RECORD_BTN: u8 = 0; // X on the DragonRise pad
const AI_BTN: u8 = 1; // A
const MIN_CLIP: Duration = Duration::from_millis(500);

const GEMINI_MODEL: &str = "gemini-3.5-flash";
const TTS_MODEL: &str = "gemini-3.1-flash-tts-preview";
const TTS_VOICE: &str = "Kore";
const TTS_RATE: u32 = 24_000;
const REWIND_SAMPLES: usize = TTS_RATE as usize; // ~1s, voiceflow-style
const PERSONA: &str = "You are kibo, a small robot voice companion. You hear \
transcribed voice notes and reply out loud through a speaker. Keep replies \
short and conversational - one to three sentences, easy to listen to.";

struct Recording {
    arecord: Child,
    writer: JoinHandle<std::io::Result<i16>>,
    started: Instant,
    work: PathBuf,
}

fn main() -> std::io::Result<()> {
    let frag = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "USB Gamepad".into());
    let js = find_js(&frag)
        .ok_or_else(|| std::io::Error::other(format!("no joystick matching {frag:?}")))?;
    let dir = data_dir()?;
    println!("joystick: {}", js.display());
    println!("data dir: {}", dir.display());
    println!("hold button {RECORD_BTN} to record, press button {AI_BTN} for the AI's turn");

    let player = Arc::new(Player::new());
    let ai_busy = Arc::new(AtomicBool::new(false));

    // Processing is replayable: transcribe anything that was recorded but
    // never transcribed (crash, network outage, pre-transcription clips).
    {
        let dir = dir.clone();
        std::thread::spawn(move || {
            for (id, file, silent) in untranscribed_clips(&dir) {
                if silent {
                    skip_silent_clip(&dir, &id);
                } else {
                    transcribe_and_log(&dir, &id, &file);
                }
            }
        });
    }

    let mut dev = File::open(&js)?;
    let mut buf = [0u8; 8]; // struct js_event: u32 time, i16 value, u8 type, u8 number
    let mut rec: Option<Recording> = None;

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
                player.pause(); // stop speech before the mic opens
                let _ = chime(&[660.0, 880.0]); // never fatal: a beep must not kill the robot
                rec = Some(start_recording(&dir)?);
                println!("recording...");
            }
            (RECORD_BTN, 0, Some(_)) => {
                let Recording {
                    mut arecord,
                    writer,
                    started,
                    work,
                } = rec.take().unwrap();
                let elapsed = started.elapsed();
                arecord.kill()?; // raw stream on stdout: no header to corrupt
                arecord.wait()?;
                let peak = writer
                    .join()
                    .map_err(|_| std::io::Error::other("writer thread panicked"))??;
                if elapsed < MIN_CLIP {
                    let _ = fs::remove_file(&work);
                    println!("discarded accidental tap ({}ms)", elapsed.as_millis());
                    let _ = chime(&[220.0]); // never fatal: a beep must not kill the robot
                } else {
                    let (id, file) = clip_name(&dir);
                    fs::rename(&work, dir.join(&file))?;
                    let peak_pct = peak as u32 * 100 / i16::MAX as u32;
                    append_turn(
                        &dir,
                        &format!(
                            r#"{{"kind":"clip","id":"{id}","file":"{file}","ms":{},"peak":{peak_pct},"at":{}}}"#,
                            elapsed.as_millis(),
                            epoch()
                        ),
                    )?;
                    println!("saved {file} ({}ms, peak {peak_pct}%)", elapsed.as_millis());
                    let _ = chime(&[880.0, 660.0]); // never fatal: a beep must not kill the robot
                    if peak_pct == 0 {
                        println!("WARNING: clip is silent — check mic / USB bandwidth");
                        skip_silent_clip(&dir, &id);
                    } else {
                        let (dir, id) = (dir.clone(), id.clone());
                        std::thread::spawn(move || transcribe_and_log(&dir, &id, &file));
                    }
                }
                player.resume(); // continue any paused speech, rewound
            }
            (AI_BTN, 1, None) => {
                if ai_busy.swap(true, SeqCst) {
                    println!("already thinking...");
                } else {
                    if player.speaking() {
                        println!("interrupting speech for a new turn");
                        player.skip();
                    }
                    let (dir, player, ai_busy) = (dir.clone(), player.clone(), ai_busy.clone());
                    std::thread::spawn(move || {
                        if let Err(e) = ai_turn(&dir, &player) {
                            println!("AI turn FAILED: {e}");
                            let _ = chime(&[220.0, 180.0]);
                        }
                        ai_busy.store(false, SeqCst);
                    });
                }
            }
            (AI_BTN, 1, Some(_)) => println!("still recording — release first"),
            (n, 1, _) => println!("button {n} (unmapped)"),
            _ => {}
        }
    }
}

// ---------------- the AI turn: transcripts -> reply -> speech ----------------

fn ai_turn(dir: &Path, player: &Arc<Player>) -> std::io::Result<()> {
    let pending = pending_clips(dir);
    if pending.is_empty() {
        println!("nothing new to answer");
        let _ = chime(&[330.0, 220.0]); // never fatal: a beep must not kill the robot
        return Ok(());
    }
    let _ = chime(&[523.0, 659.0, 784.0]); // never fatal: a beep must not kill the robot

    let ids: Vec<String> = pending.iter().map(|(id, _)| id.clone()).collect();
    let transcripts = wait_for_transcripts(dir, &ids, Duration::from_secs(25));
    let heard: Vec<String> = transcripts
        .iter()
        .filter(|(_, t)| !t.is_empty() && t != "[silent]" && t != "[no speech]")
        .map(|(_, t)| t.clone())
        .collect();

    if heard.is_empty() {
        println!("no intelligible speech in {} clip(s)", pending.len());
        append_turn(
            dir,
            &serde_json::json!({
                "kind":"reply","answers":ids,"text":"[nothing to answer]","at":epoch()
            })
            .to_string(),
        )?;
        let _ = chime(&[330.0, 220.0]); // never fatal: a beep must not kill the robot
        return Ok(());
    }

    let user_text = heard.join("\n");
    println!("user turn ({} clip(s)): {user_text}", heard.len());

    let prev = last_interaction_id(dir);
    let (reply, interaction_id) = match chat(&user_text, prev.as_deref()) {
        Ok(r) => r,
        Err(e) if prev.is_some() => {
            // Server-side history can expire; retry as a fresh conversation.
            println!("chat with history failed ({e}); retrying fresh");
            chat(&user_text, None)?
        }
        Err(e) => return Err(e),
    };

    // Reply text is durable BEFORE speech synthesis: a TTS failure must
    // never destroy the answer. The audio filename is chosen now so the
    // reply record and the WAV cross-link (blob+metadata rule).
    let name = format!("tts-{}.wav", chrono::Local::now().format("%Y%m%d-%H%M%S"));
    append_turn(
        dir,
        &serde_json::json!({
            "kind":"reply","answers":ids,"text":reply,"audio":name,
            "interaction_id":interaction_id,"at":epoch()
        })
        .to_string(),
    )?;
    println!("kibo: {reply}");

    match tts_stream(&reply, dir.join(&name)) {
        Ok(stream) => player.play(stream),
        Err(e) => {
            println!("TTS FAILED (reply text is safe): {e}");
            append_turn(
                dir,
                &serde_json::json!({"kind":"tts_error","error":e.to_string(),"at":epoch()})
                    .to_string(),
            )?;
            let _ = chime(&[220.0, 180.0]); // never fatal: a beep must not kill the robot
        }
    }
    Ok(())
}

/// Ask gemini for a reply. Returns (reply text, interaction id).
fn chat(user_text: &str, prev: Option<&str>) -> std::io::Result<(String, String)> {
    let input = match prev {
        Some(_) => user_text.to_string(),
        None => format!("{PERSONA}\n\n{user_text}"),
    };
    let mut body = serde_json::json!({"model": GEMINI_MODEL, "input": input});
    if let Some(p) = prev {
        body["previous_interaction_id"] = p.into();
    }
    let resp = gemini(&body)?;
    let id = resp["id"].as_str().unwrap_or_default().to_string();
    let text = model_output(&resp)
        .and_then(|c| c["text"].as_str())
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
        .ok_or_else(|| std::io::Error::other(format!("no reply text in: {}", excerpt(&resp))))?;
    Ok((text, id))
}

/// TTS audio as it streams in: samples grow while `done` is false. The
/// player reads it by position, so pause/rewind/skip work mid-download.
#[derive(Default)]
struct AudioStream {
    samples: Mutex<Vec<i16>>,
    done: AtomicBool,
}

/// Start streaming speech synthesis (SSE deltas of little-endian PCM at
/// TTS_RATE, despite the audio/l16 label — verified empirically). Returns
/// once the first audio arrives, so callers see synthesis errors; a
/// background thread keeps filling the stream and saves the finished WAV.
fn tts_stream(text: &str, save_path: PathBuf) -> std::io::Result<Arc<AudioStream>> {
    let key = std::env::var("GEMINI_API_KEY")
        .map_err(|_| std::io::Error::other("GEMINI_API_KEY not set"))?;
    let body = serde_json::json!({
        "model": TTS_MODEL,
        "input": text,
        "response_format": {"type": "audio"},
        "generation_config": {"speech_config": [{"voice": TTS_VOICE}]},
        "stream": true
    });
    let mut curl = Command::new("curl")
        .args([
            "-sN",
            "--max-time",
            "300",
            "-X",
            "POST",
            "https://generativelanguage.googleapis.com/v1beta/interactions",
            "-H",
            &format!("x-goog-api-key: {key}"),
            "-H",
            "Content-Type: application/json",
            "-d",
            "@-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    curl.stdin
        .take()
        .unwrap()
        .write_all(body.to_string().as_bytes())?;
    let stdout = curl.stdout.take().unwrap();

    let stream = Arc::new(AudioStream::default());
    let (tx, rx) = mpsc::channel::<std::io::Result<()>>();
    {
        let stream = stream.clone();
        std::thread::spawn(move || {
            let result = read_sse_audio(stdout, &stream, &tx);
            stream.done.store(true, SeqCst);
            let _ = curl.wait();
            if let Err(e) = result {
                let _ = tx.send(Err(e)); // only reaches rx if no audio ever arrived
            }
            // clone so the disk write never blocks the live playback reader
            let samples = stream.samples.lock().unwrap().clone();
            if samples.is_empty() {
                return;
            }
            if let Err(e) = save_wav(&save_path, &samples, TTS_RATE) {
                eprintln!("failed to save {}: {e}", save_path.display());
            }
        });
    }
    rx.recv()
        .map_err(|_| std::io::Error::other("tts stream ended before any audio"))?
        .map(|_| stream)
}

/// Parse SSE lines from curl, appending each audio delta's samples to the
/// stream. Signals `tx` once ~0.5s of audio is buffered (or the stream ends
/// with less), so playback starts with an underrun cushion.
fn read_sse_audio(
    stdout: impl Read,
    stream: &AudioStream,
    tx: &mpsc::Sender<std::io::Result<()>>,
) -> std::io::Result<()> {
    const PREBUFFER: usize = TTS_RATE as usize / 2;
    let mut total = 0usize;
    let mut signaled = false;
    let mut leftover: Option<u8> = None; // deltas can split a sample across events
    for line in BufReader::new(stdout).lines() {
        let line = line?;
        let Some(payload) = line.strip_prefix("data: ") else {
            continue;
        };
        if payload == "[DONE]" {
            break;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(payload) else {
            continue;
        };
        let Some(b64) = v["delta"]["data"]
            .as_str()
            .filter(|_| v["delta"]["type"] == "audio")
        else {
            continue;
        };
        let pcm = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|e| std::io::Error::other(format!("bad base64 audio: {e}")))?;
        let mut data: &[u8] = &pcm;
        if data.is_empty() {
            continue;
        }
        let mut samples = stream.samples.lock().unwrap();
        if let Some(lo) = leftover.take() {
            samples.push(i16::from_le_bytes([lo, data[0]]));
            data = &data[1..];
        }
        samples.extend(
            data.chunks_exact(2)
                .map(|c| i16::from_le_bytes([c[0], c[1]])),
        );
        if data.len() % 2 == 1 {
            leftover = Some(data[data.len() - 1]);
        }
        total = samples.len();
        drop(samples);
        if !signaled && total >= PREBUFFER {
            signaled = true;
            let _ = tx.send(Ok(()));
        }
    }
    if total == 0 {
        return Err(std::io::Error::other("tts stream produced no audio"));
    }
    if !signaled {
        let _ = tx.send(Ok(())); // reply shorter than the prebuffer
    }
    Ok(())
}

/// POST one interactions-API request via curl (our HTTP shim).
fn gemini(body: &serde_json::Value) -> std::io::Result<serde_json::Value> {
    let key = std::env::var("GEMINI_API_KEY")
        .map_err(|_| std::io::Error::other("GEMINI_API_KEY not set"))?;
    let mut curl = Command::new("curl")
        .args([
            "-s",
            "--max-time",
            "120",
            "-X",
            "POST",
            "https://generativelanguage.googleapis.com/v1beta/interactions",
            "-H",
            &format!("x-goog-api-key: {key}"),
            "-H",
            "Content-Type: application/json",
            "-d",
            "@-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    curl.stdin
        .take()
        .unwrap()
        .write_all(body.to_string().as_bytes())?;
    let out = curl.wait_with_output()?;
    if !out.status.success() {
        return Err(std::io::Error::other(format!("curl exited {}", out.status)));
    }
    serde_json::from_slice(&out.stdout)
        .map_err(|e| std::io::Error::other(format!("bad JSON from API: {e}")))
}

/// The first content block of the model_output step, if any.
fn model_output(resp: &serde_json::Value) -> Option<&serde_json::Value> {
    resp["steps"]
        .as_array()?
        .iter()
        .find(|s| s["type"] == "model_output")
        .map(|s| &s["content"][0])
}

fn excerpt(resp: &serde_json::Value) -> String {
    resp.to_string().chars().take(300).collect()
}

// ---------------- speech playback with pause / rewind / skip ----------------

/// Plays TTS samples through aplay, pausing (and rewinding on resume)
/// around recordings, per the voiceflow interaction model.
struct Player {
    mic_active: AtomicBool,
    skip_flag: AtomicBool,
    speaking: AtomicBool,
    current: Mutex<Option<Child>>,
}

impl Player {
    fn new() -> Self {
        Player {
            mic_active: AtomicBool::new(false),
            skip_flag: AtomicBool::new(false),
            speaking: AtomicBool::new(false),
            current: Mutex::new(None),
        }
    }

    fn speaking(&self) -> bool {
        self.speaking.load(SeqCst)
    }

    /// Called when the mic is about to open: silences playback immediately.
    fn pause(&self) {
        self.mic_active.store(true, SeqCst);
        self.kill_current();
    }

    fn resume(&self) {
        self.mic_active.store(false, SeqCst);
    }

    fn skip(&self) {
        self.skip_flag.store(true, SeqCst);
        self.kill_current();
    }

    fn kill_current(&self) {
        if let Some(mut c) = self.current.lock().unwrap().take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }

    fn play(self: &Arc<Self>, stream: Arc<AudioStream>) {
        let st = self.clone();
        st.speaking.store(true, SeqCst);
        st.skip_flag.store(false, SeqCst);
        std::thread::spawn(move || {
            st.playback_loop(&stream);
            st.speaking.store(false, SeqCst);
        });
    }

    fn playback_loop(&self, stream: &AudioStream) {
        const CHUNK: usize = 4800; // 200ms at 24k
        let rate = TTS_RATE as usize;
        let mut pos = 0usize;
        while !stream.finished(pos) {
            // paused (or queued behind an active recording)
            while self.mic_active.load(SeqCst) {
                if self.skip_flag.swap(false, SeqCst) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            if self.skip_flag.swap(false, SeqCst) {
                return;
            }
            let mut child = match Command::new("aplay")
                .args(["-q", "-D", &audio_dev()])
                .args(["-t", "raw", "-f", "S16_LE", "-c", "1"])
                .args(["-r", &TTS_RATE.to_string(), "-"])
                .stdin(Stdio::piped())
                .spawn()
            {
                Ok(c) => c,
                Err(e) => {
                    println!("playback failed: {e}");
                    return;
                }
            };
            let mut stdin = child.stdin.take().unwrap();
            *self.current.lock().unwrap() = Some(child);
            let seg_start = Instant::now();
            let seg_base = pos;
            let mut interrupted = false; // by mic or skip, incl. during drain
            loop {
                if self.mic_active.load(SeqCst) || self.skip_flag.load(SeqCst) {
                    interrupted = true;
                    break;
                }
                // Pace writes so `pos` tracks what has actually played
                // (~600ms ahead at most) — the rewind stays meaningful.
                let audio_ms = (pos - seg_base) * 1000 / rate;
                let elapsed = seg_start.elapsed().as_millis() as usize;
                if audio_ms > elapsed + 600 {
                    std::thread::sleep(Duration::from_millis(50));
                    continue; // re-check flags while throttled
                }
                let chunk = stream.chunk(pos, CHUNK);
                if chunk.is_empty() {
                    if stream.finished(pos) {
                        break;
                    }
                    // buffer momentarily dry: synthesis is still ahead of us
                    std::thread::sleep(Duration::from_millis(20));
                    continue;
                }
                let bytes: Vec<u8> = chunk.iter().flat_map(|s| s.to_le_bytes()).collect();
                if stdin.write_all(&bytes).is_err() {
                    interrupted = true; // aplay was killed under us
                    break;
                }
                pos += chunk.len();
            }
            drop(stdin);
            if !interrupted {
                // Natural end: let aplay drain its tail, but stay killable —
                // the mic or a skip must still be able to cut it off, and the
                // child must stay in self.current so kill_current can see it.
                interrupted = loop {
                    if self.skip_flag.load(SeqCst) || self.mic_active.load(SeqCst) {
                        self.kill_current();
                        break true;
                    }
                    let drained = {
                        let mut cur = self.current.lock().unwrap();
                        match cur.as_mut() {
                            None => true, // killed from outside
                            Some(c) => match c.try_wait() {
                                Ok(None) => false,
                                _ => {
                                    cur.take();
                                    true
                                }
                            },
                        }
                    };
                    if drained {
                        break false;
                    }
                    std::thread::sleep(Duration::from_millis(20));
                };
            }
            if interrupted {
                self.kill_current();
                if self.skip_flag.swap(false, SeqCst) {
                    return;
                }
                pos = pos.saturating_sub(REWIND_SAMPLES);
            }
        }
    }
}

impl AudioStream {
    /// Up to `max` samples starting at `pos`; empty if none are ready yet.
    fn chunk(&self, pos: usize, max: usize) -> Vec<i16> {
        let samples = self.samples.lock().unwrap();
        let end = (pos + max).min(samples.len());
        samples
            .get(pos..end)
            .map(<[i16]>::to_vec)
            .unwrap_or_default()
    }

    /// True once every received sample has been consumed and no more can come.
    fn finished(&self, pos: usize) -> bool {
        self.done.load(SeqCst) && pos >= self.samples.lock().unwrap().len()
    }
}

// ---------------- recording ----------------

/// Spawn arecord emitting raw PCM and a thread that streams it into a WAV.
fn start_recording(dir: &Path) -> std::io::Result<Recording> {
    let work = dir.join("current-recording.wav");
    let mut arecord = Command::new("arecord")
        .args(["-q", "-D", &audio_dev()])
        .args(["-t", "raw", "-f", "S16_LE", "-r", "44100", "-c", "1", "-"])
        .stdout(Stdio::piped())
        .spawn()?;
    let stdout = arecord.stdout.take().unwrap();
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: recplay::RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let wav = hound::WavWriter::create(&work, spec).map_err(io_err)?;
    Ok(Recording {
        arecord,
        writer: std::thread::spawn(move || stream_to_wav(stdout, wav)),
        started: Instant::now(),
        work,
    })
}

/// Copy raw PCM from arecord's stdout into the WAV as it arrives, tracking
/// the peak level. Audio hits the disk continuously while recording, so a
/// crash mid-clip loses at most the header, not the samples.
fn stream_to_wav(
    mut src: impl Read,
    mut wav: hound::WavWriter<BufWriter<File>>,
) -> std::io::Result<i16> {
    let mut buf = [0u8; 4096];
    let mut leftover: Option<u8> = None;
    let mut peak: i16 = 0;
    loop {
        let n = src.read(&mut buf)?;
        if n == 0 {
            break;
        }
        let mut data: &[u8] = &buf[..n];
        // pipe reads can split a 2-byte sample; carry the odd byte over
        let first = leftover.take().map(|lo| {
            let s = i16::from_le_bytes([lo, data[0]]);
            data = &data[1..];
            s
        });
        let rest = data
            .chunks_exact(2)
            .map(|c| i16::from_le_bytes([c[0], c[1]]));
        for s in first.into_iter().chain(rest) {
            peak = peak.max(s.saturating_abs());
            wav.write_sample(s).map_err(io_err)?;
        }
        if data.len() % 2 == 1 {
            leftover = Some(data[data.len() - 1]);
        }
    }
    wav.finalize().map_err(io_err)?;
    Ok(peak)
}

// ---------------- transcription ----------------

/// Silent clips never go to the API: Gemini hallucinates plausible speech
/// from pure silence. Log a durable [silent] transcript instead.
fn skip_silent_clip(dir: &Path, id: &str) {
    println!("clip {id} is silent — skipping transcription");
    let record = serde_json::json!({"kind":"transcript","clip":id,"text":"[silent]","at":epoch()});
    if let Err(e) = append_turn(dir, &record.to_string()) {
        eprintln!("FAILED to log silent marker for {id}: {e}");
    }
}

/// Transcribe one clip and append the result (or the failure — errors are
/// durable states too) to turns.jsonl.
fn transcribe_and_log(dir: &Path, id: &str, file: &str) {
    println!("transcribing {id}...");
    let record = match transcribe(&dir.join(file)) {
        Ok(text) => {
            println!("transcript {id}: {text}");
            serde_json::json!({"kind":"transcript","clip":id,"text":text,"at":epoch()})
        }
        Err(e) => {
            println!("transcription FAILED {id}: {e}");
            serde_json::json!({"kind":"transcript_error","clip":id,"error":e.to_string(),"at":epoch()})
        }
    };
    if let Err(e) = append_turn(dir, &record.to_string()) {
        eprintln!("FAILED to log transcript for {id}: {e}");
    }
}

/// Send a WAV to Gemini and return the transcript.
fn transcribe(wav: &Path) -> std::io::Result<String> {
    let audio = fs::read(wav)?;
    let body = serde_json::json!({
        "model": GEMINI_MODEL,
        "input": [
            {"type": "text", "text": "Generate a transcript of the speech. \
              Return only the transcript text. If there is no speech, return [no speech]."},
            {"type": "audio",
             "data": base64::engine::general_purpose::STANDARD.encode(&audio),
             "mime_type": "audio/wav"}
        ]
    });
    let resp = gemini(&body)?;
    model_output(&resp)
        .and_then(|c| c["text"].as_str())
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
        .ok_or_else(|| std::io::Error::other(format!("no transcript in: {}", excerpt(&resp))))
}

// ---------------- turns.jsonl ----------------

fn log_records(dir: &Path) -> Vec<serde_json::Value> {
    fs::read_to_string(dir.join("turns.jsonl"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

/// Clips recorded since the last reply, oldest first.
fn pending_clips(dir: &Path) -> Vec<(String, String)> {
    let mut pending = Vec::new();
    for v in log_records(dir) {
        match v["kind"].as_str() {
            Some("reply") => pending.clear(),
            Some("clip") => {
                if let (Some(id), Some(file)) = (v["id"].as_str(), v["file"].as_str()) {
                    pending.push((id.to_string(), file.to_string()));
                }
            }
            _ => {}
        }
    }
    pending
}

/// Clips that have no transcript record yet, oldest first, with a flag for
/// clips known to be silent (recorded with peak 0).
fn untranscribed_clips(dir: &Path) -> Vec<(String, String, bool)> {
    let mut clips = Vec::new();
    let mut done = std::collections::HashSet::new();
    for v in log_records(dir) {
        match v["kind"].as_str() {
            Some("clip") => {
                if let (Some(id), Some(file)) = (v["id"].as_str(), v["file"].as_str()) {
                    clips.push((id.to_string(), file.to_string(), v["peak"] == 0));
                }
            }
            Some("transcript") => {
                if let Some(id) = v["clip"].as_str() {
                    done.insert(id.to_string());
                }
            }
            _ => {}
        }
    }
    clips.retain(|(id, _, _)| !done.contains(id));
    clips
}

/// Transcript texts for the given clip ids, waiting for in-flight
/// transcriptions up to the timeout.
fn wait_for_transcripts(dir: &Path, ids: &[String], timeout: Duration) -> Vec<(String, String)> {
    let deadline = Instant::now() + timeout;
    loop {
        let mut found = Vec::new();
        for v in log_records(dir) {
            if v["kind"] == "transcript"
                && let Some(clip) = v["clip"].as_str()
                && ids.iter().any(|id| id == clip)
            {
                let text = v["text"].as_str().unwrap_or("").to_string();
                found.push((clip.to_string(), text));
            }
        }
        if found.len() >= ids.len() || Instant::now() >= deadline {
            if found.len() < ids.len() {
                println!("proceeding with {}/{} transcripts", found.len(), ids.len());
            }
            return found;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

/// The most recent interaction id — continues the server-side conversation.
fn last_interaction_id(dir: &Path) -> Option<String> {
    log_records(dir)
        .iter()
        .rev()
        .find_map(|v| v["interaction_id"].as_str().map(str::to_string))
}

fn append_turn(dir: &Path, line: &str) -> std::io::Result<()> {
    static LOG_LOCK: Mutex<()> = Mutex::new(()); // appends come from several threads
    let _guard = LOG_LOCK.lock().unwrap();
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("turns.jsonl"))?;
    writeln!(f, "{line}")?;
    f.sync_all()
}

// ---------------- plumbing ----------------

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

fn save_wav(path: &Path, samples: &[i16], rate: u32) -> std::io::Result<()> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut w = hound::WavWriter::create(path, spec).map_err(io_err)?;
    for &s in samples {
        w.write_sample(s).map_err(io_err)?;
    }
    w.finalize().map_err(io_err)
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

fn io_err(e: hound::Error) -> std::io::Error {
    std::io::Error::other(e.to_string())
}

fn epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

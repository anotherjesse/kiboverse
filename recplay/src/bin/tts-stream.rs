//! Spike: streaming TTS straight to the speaker, measuring time-to-first-sound.
//!
//! Sends fixed text to the Gemini TTS model with "stream": true and pipes
//! each SSE audio delta's PCM into aplay as it arrives, instead of waiting
//! for the whole synthesis. Wire format (probed 2026-07-14): SSE lines,
//! audio deltas at `data: {"delta":{"type":"audio","data":<b64 LE PCM>,
//! "sample_rate":24000,...}}`, terminated by `data: [DONE]`. ~40ms of audio
//! per delta, delivered ~2.5x faster than realtime; first delta ~1s in.

use base64::Engine;
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::time::Instant;

const TEXT: &str = "Hello Jesse! This is the streaming test. If you can hear \
this within about a second of starting the program, the spike worked. \
Under the old approach, kibo synthesized the entire reply before saying \
anything at all, which meant long answers came with long awkward pauses. \
With streaming, the first chunk of audio arrives while the rest is still \
being generated, so the conversation feels immediate. \
Here is a second paragraph to make the clip long enough to matter. The \
robot lives on a Raspberry Pi four, talks through a small USB speaker puck, \
and listens through the same device. Its brain is far away in a data \
center, but its voice starts right here, right now, almost as soon as you \
ask. That is the whole point of this test.";

fn main() -> std::io::Result<()> {
    let key = std::env::var("GEMINI_API_KEY")
        .map_err(|_| std::io::Error::other("GEMINI_API_KEY not set"))?;
    let body = serde_json::json!({
        "model": "gemini-3.1-flash-tts-preview",
        "input": TEXT,
        "response_format": {"type": "audio"},
        "generation_config": {"speech_config": [{"voice": "Kore"}]},
        "stream": true
    });

    let t0 = Instant::now();
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

    let reader = BufReader::new(curl.stdout.take().unwrap());
    let mut aplay: Option<std::process::Child> = None;
    let mut samples = 0usize;
    for line in reader.lines() {
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
        if v["delta"]["type"] != "audio" {
            continue;
        }
        let Some(b64) = v["delta"]["data"].as_str() else {
            continue;
        };
        let pcm = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|e| std::io::Error::other(format!("bad base64: {e}")))?;
        if aplay.is_none() {
            println!("first audio after {:?} — speaker starting", t0.elapsed());
            aplay = Some(
                Command::new("aplay")
                    .args(["-q", "-D", &recplay::audio_dev()])
                    .args(["-t", "raw", "-f", "S16_LE", "-c", "1", "-r", "24000", "-"])
                    .stdin(Stdio::piped())
                    .spawn()?,
            );
        }
        samples += pcm.len() / 2;
        aplay
            .as_mut()
            .unwrap()
            .stdin
            .as_mut()
            .unwrap()
            .write_all(&pcm)?;
    }
    println!(
        "stream done at {:?} ({:.1}s of audio)",
        t0.elapsed(),
        samples as f32 / 24000.0
    );
    if let Some(mut ch) = aplay {
        drop(ch.stdin.take());
        ch.wait()?;
    }
    println!("playback finished at {:?}", t0.elapsed());
    let _ = curl.wait();
    Ok(())
}

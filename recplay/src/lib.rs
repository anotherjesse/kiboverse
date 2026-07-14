use std::io::Write;
use std::process::{Command, Stdio};

pub const RATE: u32 = 44_100;

/// ALSA device all audio goes through. Explicit on purpose: the system
/// "default" on Pi OS is owned by pulse/pipewire, which can silently
/// reroute it (we lost hours to default-capture recording pure zeros).
pub fn audio_dev() -> String {
    std::env::var("KIBO_AUDIO_DEV").unwrap_or_else(|_| "plughw:A01,0".into())
}

/// One sine note with a soft attack and exponential decay (no clicks).
pub fn note(freq: f32, secs: f32) -> Vec<i16> {
    let n = (RATE as f32 * secs) as usize;
    let attack = (RATE as f32 * 0.008) as usize;
    (0..n)
        .map(|i| {
            let t = i as f32 / RATE as f32;
            let env = if i < attack {
                i as f32 / attack as f32
            } else {
                (-6.0 * (i - attack) as f32 / n as f32).exp()
            };
            let s = (2.0 * std::f32::consts::PI * freq * t).sin();
            (s * env * 0.4 * i16::MAX as f32) as i16
        })
        .collect()
}

/// Play a quick chime of consecutive notes through the default ALSA device.
pub fn chime(freqs: &[f32]) -> std::io::Result<()> {
    let mut samples = Vec::new();
    for &f in freqs {
        samples.extend(note(f, 0.11));
    }
    let mut child = Command::new("aplay")
        .args(["-q", "-D", &audio_dev()])
        .args(["-t", "raw", "-f", "S16_LE", "-r", "44100", "-c", "1", "-"])
        .stdin(Stdio::piped())
        .spawn()?;
    let bytes: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
    child.stdin.take().unwrap().write_all(&bytes)?;
    child.wait()?;
    Ok(())
}

pub fn run(cmd: &str, args: &[&str]) -> std::io::Result<()> {
    let status = Command::new(cmd).args(args).status()?;
    if !status.success() {
        return Err(std::io::Error::other(format!("{cmd} exited with {status}")));
    }
    Ok(())
}

use recplay::{chime, run};

const WAV_PATH: &str = "/tmp/kibo-rec.wav";

fn main() -> std::io::Result<()> {
    let secs: u32 = std::env::args()
        .nth(1)
        .and_then(|a| a.parse().ok())
        .unwrap_or(5);

    println!("recording {secs}s...");
    chime(&[660.0, 880.0])?;
    run(
        "arecord",
        &["-q", "-d", &secs.to_string(), "-f", "S16_LE", "-r", "44100", WAV_PATH],
    )?;
    chime(&[880.0, 660.0])?;

    println!("playing back...");
    run("aplay", &["-q", WAV_PATH])?;
    println!("done");
    Ok(())
}

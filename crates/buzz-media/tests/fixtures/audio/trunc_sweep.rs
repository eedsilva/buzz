//! Truncation battery + black-box reachability witness for the audio validators.
//!
//! Instrument discipline: a green sweep is worthless unless the sweep provably
//! executed the code it claims to cover. `fmt_field_checks_are_live` is that
//! witness — it needs no source instrumentation, only the observation that
//! mutating a `fmt ` field must flip the verdict. If it fails, every "no panic"
//! result below is vacuous and must not be reported as a pass.

fn cfg() -> buzz_media::config::MediaConfig {
    buzz_media::config::MediaConfig {
        s3_endpoint: String::new(), s3_access_key: String::new(),
        s3_secret_key: String::new(), s3_bucket: String::new(),
        s3_region: "us-east-1".into(),
        s3_addressing_style: buzz_media::config::S3AddressingStyle::Path,
        max_image_bytes: 50 * 1024 * 1024, max_gif_bytes: 10 * 1024 * 1024,
        max_video_bytes: 524_288_000, max_file_bytes: 104_857_600,
        max_audio_bytes: 26_214_400,
        public_base_url: "http://localhost:3000/media".into(),
        upload_records_enabled: false, upload_ip_header: None, upload_port_header: None,
    }
}

fn v(bytes: &[u8]) -> Result<(String, String), buzz_media::error::MediaError> {
    buzz_media::validation::validate_file_content(bytes, &cfg())
}

fn dir() -> std::path::PathBuf {
    std::path::PathBuf::from(std::env::var("DAWN_SAN").expect("DAWN_SAN"))
}

/// Rewrite the RIFF declared size to match actual length. Without this a
/// truncated WAV dies at `declared + 8 == len` and never reaches the fmt walk.
fn repair_riff(b: &mut [u8]) {
    if b.len() >= 8 {
        let d = (b.len() - 8) as u32;
        b[4..8].copy_from_slice(&d.to_le_bytes());
    }
}

/// REACHABILITY WITNESS. Proves the fmt field reads execute, black-box.
#[test]
fn fmt_field_checks_are_live() {
    let good = std::fs::read(dir().join("tagged.wav")).unwrap();
    assert!(v(&good).is_ok(), "baseline WAV must validate; got {:?}", v(&good));

    // fmt body starts at 20: channels@22, sample_rate@24, byte_rate@28,
    // block_align@32, bits@34. Corrupting any must flip Ok -> Err, which is
    // only possible if those bytes were actually read.
    for (name, off, val) in [
        ("channels", 22usize, 0u16),
        ("block_align", 32, 0xffff),
        ("bits", 34, 7),
    ] {
        let mut bad = good.clone();
        bad[off..off + 2].copy_from_slice(&val.to_le_bytes());
        assert!(v(&bad).is_err(), "mutating {name} did not change the verdict -> field is not read");
    }
    eprintln!("reachability witness OK: fmt field reads are live");
}

fn sweep(name: &str, full: &[u8], repair: bool) -> Option<usize> {
    let lens: Vec<usize> = (0..full.len().min(600))
        .chain((600..full.len()).step_by(97))
        .collect();
    let mut first = None;
    for n in lens {
        let mut slice = full[..n].to_vec();
        if repair { repair_riff(&mut slice); }
        let hit = std::panic::catch_unwind(|| { let _ = v(&slice); }).is_err();
        if hit && first.is_none() { first = Some(n); }
    }
    match first {
        None => eprintln!("{name:26} OK  (no panic at any prefix)"),
        Some(n) => eprintln!("{name:26} *** first panic at prefix {n} ***"),
    }
    first
}

#[test]
fn truncation_battery_no_panics() {
    let d = dir();
    let mut bad = Vec::new();
    for name in ["tagged.mp3", "mpeg2_22k.mp3", "mpeg25_11k.mp3", "tagged.ogg", "bigart.ogg", "long.ogg"] {
        let full = std::fs::read(d.join(name)).unwrap();
        if sweep(name, &full, false).is_some() { bad.push(name.to_string()); }
    }
    // WAV both ways. The naive arm is kept ONLY to keep the contrast visible;
    // it is not evidence. The repaired arm is the one that reaches the fields.
    let wav = std::fs::read(d.join("tagged.wav")).unwrap();
    if sweep("tagged.wav (naive)", &wav, false).is_some() { bad.push("wav-naive".into()); }
    if sweep("tagged.wav (riff-repaired)", &wav, true).is_some() { bad.push("wav-repaired".into()); }
    assert!(bad.is_empty(), "validator panicked on truncated input: {bad:?}");
}

//! Canonical metadata-free audio containers for relay upload admission.

const EMPTY_VORBIS_COMMENT: &[u8] = b"\x03vorbis\0\0\0\0\0\0\0\0\x01";

pub(super) fn sniff_audio_mime(body: &[u8]) -> Option<&'static str> {
    if body.len() >= 12 && body.starts_with(b"RIFF") && &body[8..12] == b"WAVE" {
        Some("audio/wav")
    } else if body.starts_with(b"OggS") {
        Some("audio/ogg")
    } else if mp3_audio_start(body).is_some() {
        Some("audio/mpeg")
    } else {
        None
    }
}

pub(super) fn sanitize_for_upload(body: Vec<u8>, mime: &str) -> Result<Vec<u8>, String> {
    let body = sanitize_audio(body, mime)?;
    super::media::sanitize_image_for_upload(body, mime)
}

pub(super) fn sanitize_audio(body: Vec<u8>, mime: &str) -> Result<Vec<u8>, String> {
    match mime {
        "audio/mpeg" | "audio/mp3" => sanitize_mp3(&body),
        "audio/wav" | "audio/x-wav" | "audio/wave" => sanitize_wav(&body),
        "audio/ogg" | "application/ogg" => sanitize_ogg_vorbis(&body),
        _ => Ok(body),
    }
}

fn synchsafe(value: &[u8]) -> Option<usize> {
    (value.len() == 4 && value.iter().all(|byte| byte & 0x80 == 0)).then(|| {
        value
            .iter()
            .fold(0usize, |out, byte| (out << 7) | usize::from(*byte))
    })
}

fn mp3_audio_start(body: &[u8]) -> Option<usize> {
    let start = if body.starts_with(b"ID3") {
        if body.len() < 10 {
            return None;
        }
        let size = synchsafe(&body[6..10])?;
        let footer = usize::from(body[5] & 0x10 != 0) * 10;
        10usize.checked_add(size)?.checked_add(footer)?
    } else {
        0
    };
    mp3_frame_len(body.get(start..start + 4)?).map(|_| start)
}

fn mp3_frame_len(header: &[u8]) -> Option<usize> {
    let bits = u32::from_be_bytes(header.try_into().ok()?);
    if bits >> 21 != 0x7ff {
        return None;
    }
    let version = (bits >> 19) & 3;
    let layer = (bits >> 17) & 3;
    let bitrate_index = ((bits >> 12) & 0xf) as usize;
    let sample_index = ((bits >> 10) & 3) as usize;
    if version == 1 || layer != 1 || bitrate_index == 0 || bitrate_index == 15 || sample_index == 3
    {
        return None;
    }
    const MPEG1_BITRATES: [usize; 16] = [
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
    ];
    const MPEG2_BITRATES: [usize; 16] = [
        0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
    ];
    let bitrate = if version == 3 {
        MPEG1_BITRATES[bitrate_index]
    } else {
        MPEG2_BITRATES[bitrate_index]
    } * 1000;
    let base_rate = [44_100usize, 48_000, 32_000][sample_index];
    let sample_rate = match version {
        3 => base_rate,
        2 => base_rate / 2,
        0 => base_rate / 4,
        _ => return None,
    };
    let coefficient = if version == 3 { 144 } else { 72 };
    Some(coefficient * bitrate / sample_rate + ((bits >> 9) & 1) as usize)
}

fn sanitize_mp3(body: &[u8]) -> Result<Vec<u8>, String> {
    let start = mp3_audio_start(body).ok_or("invalid MP3 header")?;
    let mut offset = start;
    let mut end = start;
    while let Some(header) = body.get(offset..offset + 4) {
        let Some(length) = mp3_frame_len(header) else {
            break;
        };
        let next = offset
            .checked_add(length)
            .ok_or("MP3 frame length overflow")?;
        if next > body.len() {
            return Err("truncated MP3 frame".into());
        }
        end = next;
        offset = next;
    }
    if end == start {
        return Err("MP3 contains no complete frames".into());
    }
    // Known and arbitrary trailers are all removed by returning only the walked frame run.
    Ok(body[start..end].to_vec())
}

fn sanitize_wav(body: &[u8]) -> Result<Vec<u8>, String> {
    if body.len() < 12 || !body.starts_with(b"RIFF") || &body[8..12] != b"WAVE" {
        return Err("invalid RIFF/WAVE header".into());
    }
    let declared = u32::from_le_bytes(body[4..8].try_into().unwrap()) as usize;
    let riff_end = declared.checked_add(8).ok_or("WAV RIFF length overflow")?;
    if riff_end > body.len() {
        return Err("invalid WAV RIFF length".into());
    }
    let mut offset = 12usize;
    let mut fmt = None;
    let mut data = None;
    while offset < riff_end {
        if offset + 8 > riff_end {
            return Err("truncated WAV chunk".into());
        }
        let id = &body[offset..offset + 4];
        let length = u32::from_le_bytes(body[offset + 4..offset + 8].try_into().unwrap()) as usize;
        let payload_start = offset + 8;
        let payload_end = payload_start
            .checked_add(length)
            .ok_or("WAV chunk length overflow")?;
        let end = payload_end
            .checked_add(length & 1)
            .ok_or("WAV chunk length overflow")?;
        if end > riff_end {
            return Err("truncated WAV chunk".into());
        }
        match id {
            b"fmt " if fmt.is_none() => fmt = Some(body[payload_start..payload_end].to_vec()),
            b"fmt " => return Err("WAV contains duplicate fmt chunk".into()),
            b"data" if data.is_none() => data = Some(body[payload_start..payload_end].to_vec()),
            b"data" => return Err("WAV contains duplicate data chunk".into()),
            _ => {}
        }
        offset = end;
    }
    let fmt = fmt.ok_or("WAV is missing fmt chunk")?;
    let data = data.ok_or("WAV is missing data chunk")?;
    let mut out = b"RIFF\0\0\0\0WAVE".to_vec();
    append_riff_chunk(&mut out, b"fmt ", &fmt)?;
    append_riff_chunk(&mut out, b"data", &data)?;
    let size = u32::try_from(out.len() - 8).map_err(|_| "WAV is too large")?;
    out[4..8].copy_from_slice(&size.to_le_bytes());
    Ok(out)
}

fn append_riff_chunk(out: &mut Vec<u8>, id: &[u8; 4], payload: &[u8]) -> Result<(), String> {
    out.extend_from_slice(id);
    out.extend_from_slice(
        &u32::try_from(payload.len())
            .map_err(|_| "WAV chunk is too large")?
            .to_le_bytes(),
    );
    out.extend_from_slice(payload);
    if payload.len() & 1 != 0 {
        out.push(0);
    }
    Ok(())
}

#[derive(Clone, Debug)]
struct OggPacket {
    bytes: Vec<u8>,
    granule: u64,
}

fn sanitize_ogg_vorbis(body: &[u8]) -> Result<Vec<u8>, String> {
    let (serial, mut packets) = parse_ogg(body)?;
    if packets
        .first()
        .is_some_and(|p| p.bytes.starts_with(b"OpusHead"))
    {
        return Err("Opus audio is not supported".into());
    }
    if packets.len() < 3
        || !packets[0].bytes.starts_with(b"\x01vorbis")
        || !packets[1].bytes.starts_with(b"\x03vorbis")
        || !packets[2].bytes.starts_with(b"\x05vorbis")
    {
        return Err("invalid Vorbis headers".into());
    }
    packets[1].bytes = EMPTY_VORBIS_COMMENT.to_vec();
    // Header packets always have position zero. Parsed packets may carry the
    // unknown-position sentinel when another packet completed later on their
    // source page; do not leak that sentinel into isolated header pages.
    for packet in &mut packets[..3] {
        packet.granule = 0;
    }
    let mut out = Vec::new();
    let mut sequence = 0u32;
    for (index, packet) in packets[..3].iter().enumerate() {
        emit_packet_pages(
            &mut out,
            serial,
            &mut sequence,
            packet,
            index == 0,
            packets.len() == 3 && index == 2,
        )?;
    }
    if packets.len() > 3 {
        emit_packet_stream(&mut out, serial, &mut sequence, &packets[3..])?;
    }
    Ok(out)
}

fn parse_ogg(body: &[u8]) -> Result<(u32, Vec<OggPacket>), String> {
    let mut offset = 0usize;
    let mut serial = None;
    let mut expected_sequence = 0u32;
    let mut partial = Vec::new();
    let mut packets = Vec::new();
    let mut saw_eos = false;
    while offset < body.len() {
        if saw_eos
            || offset + 27 > body.len()
            || &body[offset..offset + 4] != b"OggS"
            || body[offset + 4] != 0
        {
            return Err("malformed Ogg page or trailing bytes".into());
        }
        let flags = body[offset + 5];
        let granule = u64::from_le_bytes(body[offset + 6..offset + 14].try_into().unwrap());
        let page_serial = u32::from_le_bytes(body[offset + 14..offset + 18].try_into().unwrap());
        let sequence = u32::from_le_bytes(body[offset + 18..offset + 22].try_into().unwrap());
        if serial.get_or_insert(page_serial) != &page_serial {
            return Err("multiplexed Ogg streams are not supported".into());
        }
        if sequence != expected_sequence {
            return Err("invalid Ogg page sequence".into());
        }
        expected_sequence = expected_sequence
            .checked_add(1)
            .ok_or("Ogg sequence overflow")?;
        if (flags & 1 != 0) != !partial.is_empty() {
            return Err("invalid Ogg packet continuation".into());
        }
        if sequence == 0 && flags & 2 == 0 {
            return Err("Ogg stream is missing BOS".into());
        }
        let segments = body[offset + 26] as usize;
        let header_end = offset + 27 + segments;
        if header_end > body.len() {
            return Err("truncated Ogg lacing table".into());
        }
        let payload_len: usize = body[offset + 27..header_end]
            .iter()
            .map(|v| *v as usize)
            .sum();
        let page_end = header_end
            .checked_add(payload_len)
            .ok_or("Ogg page length overflow")?;
        if page_end > body.len() {
            return Err("truncated Ogg page".into());
        }
        let mut page = body[offset..page_end].to_vec();
        let stored_crc = u32::from_le_bytes(page[22..26].try_into().unwrap());
        page[22..26].fill(0);
        if ogg_crc(&page) != stored_crc {
            return Err("invalid Ogg page CRC".into());
        }
        let mut cursor = header_end;
        let first_packet_on_page = packets.len();
        for lace in &body[offset + 27..header_end] {
            let end = cursor + *lace as usize;
            partial.extend_from_slice(&body[cursor..end]);
            cursor = end;
            if *lace < 255 {
                packets.push(OggPacket {
                    bytes: std::mem::take(&mut partial),
                    // An Ogg page's granule applies only to its final completed
                    // packet. Earlier completions have an unknown position.
                    granule: u64::MAX,
                });
            }
        }
        if packets.len() > first_packet_on_page {
            packets.last_mut().unwrap().granule = granule;
        }
        saw_eos = flags & 4 != 0;
        offset = page_end;
    }
    if !saw_eos || !partial.is_empty() || packets.is_empty() {
        return Err("incomplete Ogg stream".into());
    }
    Ok((serial.unwrap(), packets))
}

fn emit_packet_stream(
    out: &mut Vec<u8>,
    serial: u32,
    sequence: &mut u32,
    packets: &[OggPacket],
) -> Result<(), String> {
    let mut index = 0usize;
    while index < packets.len() {
        let mut page_packets = 0usize;
        let mut segment_count = 0usize;
        let mut payload_len = 0usize;
        while index + page_packets < packets.len() {
            let packet = &packets[index + page_packets];
            let segments = packet.bytes.len() / 255 + 1;
            if page_packets > 0
                && (segments > 255 - segment_count || payload_len + packet.bytes.len() > 65_025)
            {
                break;
            }
            if segments > 255 {
                break;
            }
            page_packets += 1;
            segment_count += segments;
            payload_len += packet.bytes.len();
            // Preserve each source page's completed-packet grouping so its
            // granule position remains attached to the same terminal packet.
            if packet.granule != u64::MAX {
                break;
            }
        }
        if page_packets == 0 {
            emit_packet_pages(
                out,
                serial,
                sequence,
                &packets[index],
                false,
                index + 1 == packets.len(),
            )?;
            index += 1;
            continue;
        }
        let selected = &packets[index..index + page_packets];
        let segment_count: usize = selected
            .iter()
            .map(|packet| packet.bytes.len() / 255 + 1)
            .sum();
        let mut page = Vec::with_capacity(27 + segment_count + payload_len);
        page.extend_from_slice(b"OggS\0");
        page.push(if index + page_packets == packets.len() {
            4
        } else {
            0
        });
        page.extend_from_slice(&selected.last().unwrap().granule.to_le_bytes());
        page.extend_from_slice(&serial.to_le_bytes());
        page.extend_from_slice(&sequence.to_le_bytes());
        page.extend_from_slice(&[0; 4]);
        page.push(segment_count as u8);
        for packet in selected {
            page.extend(std::iter::repeat_n(255, packet.bytes.len() / 255));
            page.push((packet.bytes.len() % 255) as u8);
        }
        for packet in selected {
            page.extend_from_slice(&packet.bytes);
        }
        let crc = ogg_crc(&page);
        page[22..26].copy_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&page);
        *sequence = sequence.checked_add(1).ok_or("Ogg sequence overflow")?;
        index += page_packets;
    }
    Ok(())
}

fn emit_packet_pages(
    out: &mut Vec<u8>,
    serial: u32,
    sequence: &mut u32,
    packet: &OggPacket,
    bos: bool,
    eos: bool,
) -> Result<(), String> {
    let mut consumed = 0usize;
    let mut first = true;
    loop {
        let remaining = packet.bytes.len() - consumed;
        let full = remaining / 255;
        let terminates = full < 255;
        let segment_count = if terminates { full + 1 } else { 255 };
        let payload_len = if terminates { remaining } else { 255 * 255 };
        let mut page = Vec::with_capacity(27 + segment_count + payload_len);
        page.extend_from_slice(b"OggS\0");
        let mut flags = if first && bos {
            2
        } else if !first {
            1
        } else {
            0
        };
        if terminates && eos {
            flags |= 4;
        }
        page.push(flags);
        page.extend_from_slice(&(if terminates { packet.granule } else { u64::MAX }).to_le_bytes());
        page.extend_from_slice(&serial.to_le_bytes());
        page.extend_from_slice(&sequence.to_le_bytes());
        page.extend_from_slice(&[0; 4]);
        page.push(segment_count as u8);
        page.extend(std::iter::repeat_n(
            255,
            if terminates { full } else { 255 },
        ));
        if terminates {
            page.push((remaining % 255) as u8);
        }
        page.extend_from_slice(&packet.bytes[consumed..consumed + payload_len]);
        let crc = ogg_crc(&page);
        page[22..26].copy_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&page);
        *sequence = sequence.checked_add(1).ok_or("Ogg sequence overflow")?;
        consumed += payload_len;
        if terminates {
            return Ok(());
        }
        first = false;
    }
}

fn ogg_crc(bytes: &[u8]) -> u32 {
    let mut crc = 0u32;
    for byte in bytes {
        crc ^= u32::from(*byte) << 24;
        for _ in 0..8 {
            crc = if crc & 0x8000_0000 != 0 {
                (crc << 1) ^ 0x04c1_1db7
            } else {
                crc << 1
            };
        }
    }
    crc
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mp3_frame(version: u8, bitrate_index: u8, sample_index: u8) -> Vec<u8> {
        let bits = 0xffe0_0000u32
            | ((version as u32) << 19)
            | (1 << 17)
            | (1 << 16)
            | ((bitrate_index as u32) << 12)
            | ((sample_index as u32) << 10);
        let header = bits.to_be_bytes();
        let mut frame = vec![0; mp3_frame_len(&header).unwrap()];
        frame[..4].copy_from_slice(&header);
        frame
    }

    #[test]
    fn mp3_strips_id3_and_all_trailing_bytes_for_every_mpeg_generation() {
        for version in [3, 2, 0] {
            let frame = mp3_frame(version, 9, 0);
            let mut tagged = b"ID3\x04\0\0\0\0\0\x03abc".to_vec();
            tagged.extend_from_slice(&frame);
            tagged.extend_from_slice(b"TAGarbitrary APE");
            assert_eq!(sanitize_mp3(&tagged).unwrap(), frame);
        }
    }

    #[test]
    fn mp3_rejects_truncated_and_invalid_frames() {
        let mut frame = mp3_frame(3, 9, 0);
        frame.pop();
        assert!(sanitize_mp3(&frame).is_err());
        assert!(sanitize_mp3(&[0xff, 0xfb, 0xf0, 0]).is_err());
    }

    fn riff(chunks: &[(&[u8; 4], &[u8])]) -> Vec<u8> {
        let mut out = b"RIFF\0\0\0\0WAVE".to_vec();
        for (id, bytes) in chunks {
            append_riff_chunk(&mut out, id, bytes).unwrap();
        }
        let len = (out.len() - 8) as u32;
        out[4..8].copy_from_slice(&len.to_le_bytes());
        out
    }

    #[test]
    fn wav_keeps_only_fmt_then_data_with_canonical_padding() {
        let input = riff(&[
            (b"LIST", b"metadata"),
            (b"data", b"abc"),
            (b"fmt ", b"format"),
        ]);
        let expected = riff(&[(b"fmt ", b"format"), (b"data", b"abc")]);
        assert_eq!(sanitize_wav(&input).unwrap(), expected);
    }

    #[test]
    fn wav_rejects_bad_lengths_and_duplicate_required_chunks() {
        let mut truncated = riff(&[(b"fmt ", b"f"), (b"data", b"d")]);
        truncated.pop();
        assert!(sanitize_wav(&truncated).is_err());
        assert!(sanitize_wav(&riff(&[(b"fmt ", b"a"), (b"fmt ", b"b"), (b"data", b"d")])).is_err());
    }

    fn packet_page(
        serial: u32,
        sequence: &mut u32,
        packet: &[u8],
        bos: bool,
        eos: bool,
    ) -> Vec<u8> {
        let packet = OggPacket {
            bytes: packet.to_vec(),
            granule: 0,
        };
        let mut out = Vec::new();
        emit_packet_pages(&mut out, serial, sequence, &packet, bos, eos).unwrap();
        out
    }

    #[test]
    fn ogg_replaces_comment_and_emits_canonical_crc_and_sequences() {
        let mut sequence = 0;
        let mut input = packet_page(7, &mut sequence, b"\x01vorbis-ident", true, false);
        input.extend(packet_page(
            7,
            &mut sequence,
            b"\x03vorbis-secret metadata",
            false,
            false,
        ));
        input.extend(packet_page(
            7,
            &mut sequence,
            b"\x05vorbis-setup",
            false,
            false,
        ));
        input.extend(packet_page(7, &mut sequence, b"audio", false, true));
        let output = sanitize_ogg_vorbis(&input).unwrap();
        let (_, packets) = parse_ogg(&output).unwrap();
        assert_eq!(packets[1].bytes, EMPTY_VORBIS_COMMENT);
        assert!(!output.windows(6).any(|w| w == b"secret"));
        assert_eq!(output.windows(4).filter(|w| *w == b"OggS").count(), 4);
    }

    fn relay_config() -> buzz_media_pkg::MediaConfig {
        buzz_media_pkg::MediaConfig {
            s3_endpoint: String::new(),
            s3_access_key: String::new(),
            s3_secret_key: String::new(),
            s3_bucket: String::new(),
            s3_region: "us-east-1".into(),
            s3_addressing_style: buzz_media_pkg::S3AddressingStyle::Path,
            max_image_bytes: 50 * 1024 * 1024,
            max_gif_bytes: 10 * 1024 * 1024,
            max_video_bytes: 524_288_000,
            max_file_bytes: 104_857_600,
            max_audio_bytes: 26_214_400,
            public_base_url: "http://localhost:3000/media".into(),
            upload_records_enabled: false,
            upload_ip_header: None,
            upload_port_header: None,
        }
    }

    #[test]
    #[ignore = "requires ffmpeg-generated fixtures; run with BUZZ_AUDIO_FIXTURES"]
    fn real_fixture_sanitizer_output_is_relay_admissible() {
        let input_dir = std::path::PathBuf::from(
            std::env::var("BUZZ_AUDIO_FIXTURES").expect("BUZZ_AUDIO_FIXTURES input directory"),
        );
        let config = relay_config();
        for (name, mime, ext) in [
            ("tagged.mp3", "audio/mpeg", "mp3"),
            ("mpeg2_22k.mp3", "audio/mpeg", "mp3"),
            ("mpeg25_11k.mp3", "audio/mpeg", "mp3"),
            ("tagged.wav", "audio/wav", "wav"),
            ("tagged.ogg", "audio/ogg", "ogg"),
            ("bigart.ogg", "audio/ogg", "ogg"),
            ("long.ogg", "audio/ogg", "ogg"),
        ] {
            let body = std::fs::read(input_dir.join(name)).unwrap();
            let sanitized = sanitize_audio(body, mime).unwrap();
            assert_eq!(
                buzz_media_pkg::validation::validate_file_content(&sanitized, &config).unwrap(),
                (mime.to_string(), ext.to_string()),
                "relay rejected sanitizer output for {name}",
            );
        }
        // Negative control: acceptance above proves nothing if the relay also
        // accepts the original metadata-bearing bytes.
        for name in ["tagged.mp3", "tagged.wav", "tagged.ogg", "bigart.ogg"] {
            let body = std::fs::read(input_dir.join(name)).unwrap();
            let error = buzz_media_pkg::validation::validate_file_content(&body, &config)
                .expect_err("relay accepted unstripped metadata-bearing bytes");
            assert_eq!(
                format!("{error:?}"),
                "MetadataForbidden",
                "relay rejected unstripped fixture {name} for the wrong reason",
            );
        }
    }

    #[test]
    fn ogg_rejects_opus_crc_and_sequence_corruption() {
        let mut sequence = 0;
        let opus = packet_page(1, &mut sequence, b"OpusHead", true, true);
        assert!(sanitize_ogg_vorbis(&opus).unwrap_err().contains("Opus"));
        let mut broken = opus.clone();
        broken[22] ^= 1;
        assert!(parse_ogg(&broken).unwrap_err().contains("CRC"));
        let mut broken = opus;
        broken[18] = 2;
        broken[22..26].fill(0);
        let crc = ogg_crc(&broken);
        broken[22..26].copy_from_slice(&crc.to_le_bytes());
        assert!(parse_ogg(&broken).unwrap_err().contains("sequence"));
    }
}

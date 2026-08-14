# Audio metadata-strip verification harness

Shared evidence for the inline-audio work: the desktop client strips audio
metadata before upload, and the relay validates the stripped shape. Both
sides must agree on exact bytes, so both sides test against these fixtures.

Unlike the `ios/` and `android/` fixtures, the files here are **generated,
not committed** — they come from `ffmpeg` deterministically, and one of them
is 127 KB of synthetic album art that has no business in git history.

## Generating

```sh
./make_fixtures.sh [output-dir]   # defaults to ./fixtures
```

Requires `ffmpeg`/`ffprobe` on PATH. Every fixture embeds a known location
marker (`GPS 37.7749N 122.4194W`), so a stripper that does nothing cannot
pass — see the negative control in `check_strip.sh`.

## The fixtures that carry weight

| Fixture | Why it exists |
|---|---|
| `tagged.{mp3,ogg,wav}` | Baseline: title + location comment in each container. |
| `mpeg2_22k.mp3` | 22.05 kHz MPEG-2 mp3. Frame sync is `FF F3`. |
| `mpeg25_11k.mp3` | 11.025 kHz MPEG-2.5 mp3. Frame sync is `FF E3`. |
| `bigart.ogg` | 120 KB comment value, so the Vorbis comment packet **spans pages**. |
| `long.ogg` | 30 s, multiple audio pages after setup. |

`infer::is_mp3` (infer 0.19.0, `src/matchers/audio.rs`) matches only ID3
magic or the MPEG-1 sync `FF FB`. The two MPEG-2/2.5 fixtures are therefore
recognised *solely* by their ID3 header: strip it and `infer::get()` returns
`None`. Any acceptance path that consults `infer` for mp3 will silently
downgrade these files to generic attachments, so both the client sniff and
the relay validator must key on MPEG frame structure instead.

`bigart.ogg` is the Ogg correctness case. Its comment packet exhausts one
page's 255 lacing values and continues onto the next (continuation bit set in
the following page header), so the comment cannot be excised in place — the
header region must be demuxed into packets and re-paginated, with
`page_sequence_number` renumbered and every page CRC recomputed
(RFC 3533 §6, polynomial `0x04c11db7`).

## Checking a stripper

```sh
./check_strip.sh <original> <stripped> [marker-regex]
```

Four independent instruments, all of which must pass:

1. **Marker grep**, with a negative control on the original — did it strip?
   (If the marker is absent from the original the check reports itself blind
   rather than passing.)
2. **`ffmpeg -f null -`** — does it still decode?
3. **`ffprobe` duration** — did it truncate?
4. **PCM SHA compare** — decode both files to raw `s16le` and compare. This
   is the only instrument that proves the strip is *lossless*.

Instruments 2 and 3 both pass on a file that still contains the metadata you
believe you removed; that failure was observed during development, on an Ogg
rewrite that dropped continuation pages while leaving 58 KB of payload behind
and still reporting the correct duration. Do not rely on decodability alone.

## Checking Ogg page structure

```sh
python3 verify_contract.py <file.ogg>...
```

Asserts the canonical layout the client emits: one logical stream, page
sequence contiguous from 0, every page CRC recomputed and re-verified, the
identification packet alone on the BOS page, the canonical empty comment
packet alone on page 1 with a single lacing value, the setup packet
isolated on its own page(s), and granule 0 (never the `-1` sentinel) on
every header page that completes a packet. Written from RFC 3533 rather than
from any particular stripper implementation, so it is an independent oracle.

The granule assertion was added after all four instruments above — plus this
oracle's earlier revision — passed an implementation that leaked the RFC 3533
§6.2 "no packet completes here" sentinel (`0xFF..FF`) onto the comment page.
Every decoder ignores that field on header pages, so the file decoded, timed,
and PCM-compared perfectly while being wire-invalid. An oracle is only as
strong as its strictest clause; when the relay validator rejects something
this script blesses, the script is what's wrong.

## Instrument 5: truncation sweep (`dawn_trunc_sweep.rs`)

Added 2026-08-14 after finding a remotely reachable panic in the relay's WAV
validator (`validation.rs:252-258`): five raw `bytes[offset + N..]` indexes
guarded only by the *declared* `fmt ` chunk length, never by bytes actually
present. A 22-byte upload reached it; 14 of 16 truncation points in the fmt
body panicked. Reachable before auth (`upload.rs:82-85` validates ahead of
`verify_blossom_upload_auth`), and the repo has no `CatchPanicLayer`.

### The vacuity trap — READ BEFORE WRITING A TRUNCATION SWEEP

Truncating a real WAV leaves the RIFF size field stale, so
`declared + 8 == bytes.len()` rejects every input a few lines into the walker
and the sweep never reaches the code under test. Measured with a three-stage
probe over 400 prefixes:

```text
naive          enter=396  past_size_gate=0    at_fmt_fields=0
riff-repaired  enter=396  past_size_gate=388  at_fmt_fields=378
```

The naive sweep enters the function 396 times and reaches the vulnerable
reads ZERO times. It reported a confident `OK` against a validator already
proven to panic. **Any container with a self-describing length field must have
that field repaired to match the truncated length**, or the sweep is vacuous
while looking thorough. For WAV: rewrite `bytes[4..8] = (len - 8) as u32` after
truncating. Keep BOTH arms in the test so the contrast stays visible.

"Entered the function" is not "reached the code." Instrument the specific
line you care about, not the function containing it.

### Why MP3/Ogg were clean (construction, not luck)

- MP3 (`:164-219`): every header via `.get(offset..offset + 4).ok_or(...)?`;
  `frame_len` bounded with `checked_add` + `end > bytes.len()` before advancing.
- Ogg (`:322-355`): binds `header` via `.get(offset..offset + 27).ok_or(...)?`
  FIRST, so `header[6..14]` etc. are in-bounds off a checked slice.

That is the pattern WAV is missing: it checks a prefix, then indexes the
ORIGINAL buffer past it. Fix shape is one whole-body slice —
`bytes.get(offset + 8..offset + 24).ok_or(MetadataForbidden)?` — then slice
the six fields from it. Removes the class, not the instance.

### Reachability witness (added after the sweep itself proved untrustworthy)

The sweep now ships with `fmt_field_checks_are_live`, a black-box witness that
needs no source instrumentation: mutate `channels` / `block_align` / `bits` in a
known-good WAV and assert the verdict flips Ok -> Err. It can only pass if those
bytes are actually read.

Self-tested both directions, which is the only reason to trust it:
- Against the unfixed validator: witness PASSES, battery FAILS on the
  `riff-repaired` arm at prefix 22 (and only that arm).
- With the fmt field checks made inert as a negative control: witness FAILS with
  "mutating channels did not change the verdict -> field is not read".

**If the witness fails, every "no panic" line below it is vacuous and must not be
reported as a pass.** That ordering is the whole point — this harness has twice
produced confident green output while touching nothing.

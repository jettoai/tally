//! One tick of the supervisor's transcript scan, read in one call: the block loop, the carry of a
//! line split across blocks, the line split and each line's fields. A TWIN of the read loop in
//! `sawCapHit` (TallyCLI/TranscriptWatcherScan.swift), which still runs when this cannot answer;
//! change both together. Nothing here decides anything about a line: Swift applies the lines in
//! order, and only it knows whether an earlier line in the same tick opened a login failure, which
//! sends every later line down the full path.

use crate::line::{read_line, TallyNeedles};
use crate::{iso, TallyLineFields, TallyScanLine};
use memchr::{memchr, memchr_iter, memrchr};
use std::fs::File;
use std::io::{ErrorKind, Read, Seek, SeekFrom};

pub const LINE_HISTORY_CANDIDATE: u32 = 1;
pub const LINE_HISTORY_UNDECIDED: u32 = 2;
pub const LINE_SIDECHAIN: u32 = 4;
pub const LINE_TYPE_ASSISTANT: u32 = 8;
pub const LINE_TYPE_USER: u32 = 16;

/// Seconds between 1970 and 2001, the epoch Swift's `Date` compares in.
const REFERENCE_EPOCH: f64 = 978_307_200.0;

/// The launch instant `transcriptLineStampedBefore` compares against: `since` as
/// `timeIntervalSinceReferenceDate`, and `transcriptSecondKey(since)`.
pub struct Since<'a> {
    pub reference: f64,
    pub key: &'a [u8],
}

pub struct Scan {
    pub start: u64,
    pub new_offset: u64,
    pub end: u64,
    pub at_end: bool,
    pub truncated: bool,
    pub bytes: Vec<u8>,
    pub lines: Vec<TallyScanLine>,
    pub tail: Option<TallyScanLine>,
}

enum Stamp {
    Before,
    NotBefore,
    /// A stamp `iso::parse` does not answer: Swift parses it with its formatters.
    Undecided,
}

/// `transcriptLineStampedBefore`: the first stamp, the text compare on whole seconds, then the
/// parse. A stamp the strict parser refuses goes back to Swift rather than guessing what
/// `transcriptParseISO` says about it.
fn stamp_before(line: &[u8], n: &TallyNeedles, since: &Since) -> Stamp {
    let Some(key) = n.timestamp.find(line) else { return Stamp::NotBefore };
    let start = key + n.timestamp.needle().len();
    let Some(close) = memchr(b'"', &line[start..]) else { return Stamp::NotBefore };
    let end = start + close;
    if since.key.len() == 19
        && end - start >= 20
        && line[end - 1] == b'Z'
        && (line[start + 19] == b'Z' || line[start + 19] == b'.')
    {
        let mut shaped = true;
        let mut earlier: Option<bool> = None;
        for index in 0..19 {
            let byte = line[start + index];
            shaped = match index {
                4 | 7 => byte == b'-',
                10 => byte == b'T',
                13 | 16 => byte == b':',
                _ => byte.is_ascii_digit(),
            };
            if !shaped {
                break;
            }
            if earlier.is_none() && byte != since.key[index] {
                earlier = Some(byte < since.key[index]);
            }
        }
        if shaped && earlier == Some(true) {
            return Stamp::Before;
        }
    }
    match iso::parse(&line[start..end]) {
        // The same arithmetic RustLineView.timestamp builds its Date with.
        Some((seconds, millis)) => {
            let unix = seconds as f64 + f64::from(millis) / 1000.0;
            if unix - REFERENCE_EPOCH < since.reference {
                Stamp::Before
            } else {
                Stamp::NotBefore
            }
        }
        None => Stamp::Undecided,
    }
}

/// One line: its fields, and for a line that may be history, what `consumedAsHistory` asks of it.
/// `history` holds sidechain, type assistant, type user, then the full-path needles.
fn scan_line(
    bytes: &[u8],
    off: usize,
    len: usize,
    n: &TallyNeedles,
    history: &TallyNeedles,
    since: &Since,
) -> TallyScanLine {
    let line = &bytes[off..off + len];
    #[cfg(feature = "panic-probe")]
    if line == b"__tally_panic_probe__" {
        panic!("panic-probe");
    }
    let fields: TallyLineFields = read_line(n, line);
    let flags = &history.flags;
    let mut kind = match stamp_before(line, n, since) {
        Stamp::NotBefore => 0,
        _ if flags[3..].iter().any(|f| f.find(line).is_some()) => 0,
        Stamp::Before => LINE_HISTORY_CANDIDATE,
        Stamp::Undecided => LINE_HISTORY_UNDECIDED,
    };
    if kind != 0 {
        for (bit, f) in [LINE_SIDECHAIN, LINE_TYPE_ASSISTANT, LINE_TYPE_USER].iter().zip(flags) {
            if f.find(line).is_some() {
                kind |= bit;
            }
        }
    }
    TallyScanLine { fields, off: off as i64, len: len as i64, kind, reserved: 0 }
}

/// Appends up to `want` bytes; fewer only at the end of the file. A read error ends the file too,
/// as `try? handle.read(upToCount:)` returning nil did.
fn read_block(file: &mut File, buf: &mut Vec<u8>, want: usize) -> usize {
    let start = buf.len();
    buf.resize(start + want, 0);
    let mut got = 0;
    while got < want {
        match file.read(&mut buf[start + got..]) {
            Ok(0) => break,
            Ok(k) => got += k,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    buf.truncate(start + got);
    got
}

/// Err only when the file cannot be opened or sized (`TALLY_ERR_NOFILE`).
pub fn scan(
    path: &str,
    offset: u64,
    budget: u64,
    block: u64,
    n: &TallyNeedles,
    history: &TallyNeedles,
    since: &Since,
) -> std::io::Result<Scan> {
    let mut file = File::open(path)?;
    let end = file.seek(SeekFrom::End(0))?;
    let truncated = end < offset;
    let start = if truncated { 0 } else { offset };
    let mut out = Scan {
        start,
        new_offset: start,
        end,
        at_end: false,
        truncated,
        bytes: Vec::new(),
        lines: Vec::new(),
        tail: None,
    };
    if end <= start {
        return Ok(out);
    }
    file.seek(SeekFrom::Start(start))?;
    let block = block.min(budget).max(1) as usize;
    let mut buf = Vec::new();
    // Bytes before this index are ended by a newline and split into lines.
    let mut consumed = 0usize;
    let mut read = 0u64;
    loop {
        // The budget stops the read only once a line has been consumed: a single line larger
        // than the budget is read whole, or every tick would re-read it and never move.
        if read >= budget && consumed > 0 {
            break;
        }
        let got = read_block(&mut file, &mut buf, block);
        if got == 0 {
            out.at_end = true;
            break;
        }
        if got < block {
            out.at_end = true;
        }
        read += got as u64;
        // Only the part just appended can hold a newline: the carry before it never keeps one.
        let from = buf.len() - got;
        if let Some(at) = memrchr(b'\n', &buf[from..]) {
            let newline = from + at;
            let mut line_start = consumed;
            for nl in memchr_iter(b'\n', &buf[consumed..=newline]).map(|i| consumed + i) {
                if nl > line_start {
                    out.lines.push(scan_line(&buf, line_start, nl - line_start, n, history, since));
                }
                line_start = nl + 1;
            }
            consumed = newline + 1;
        }
        if out.at_end {
            break;
        }
    }
    if out.at_end && consumed < buf.len() {
        out.tail = Some(scan_line(&buf, consumed, buf.len() - consumed, n, history, since));
    }
    out.new_offset = start + consumed as u64;
    out.bytes = buf;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    const KEY: &[u8] = b"2026-10-03T08:16:00";

    fn tables() -> (TallyNeedles, TallyNeedles) {
        let n = TallyNeedles::new(&[b"tool_result"]);
        let h = TallyNeedles::new(&[
            b"\"isSidechain\":true",
            b"\"type\":\"assistant\"",
            b"\"type\":\"user\"",
            b"\"isApiErrorMessage\":true",
        ]);
        (n, h)
    }

    /// `since` = 2026-10-03T08:16:00Z.
    fn since() -> Since<'static> {
        Since { reference: 1_791_015_360.0 - REFERENCE_EPOCH, key: KEY }
    }

    fn file(name: &str, body: &[u8]) -> String {
        let path = std::env::temp_dir().join(format!("tally-scan-{}-{name}", std::process::id()));
        File::create(&path).unwrap().write_all(body).unwrap();
        path.to_string_lossy().into_owned()
    }

    fn texts(s: &Scan) -> Vec<String> {
        s.lines
            .iter()
            .map(|l| String::from_utf8_lossy(&s.bytes[l.off as usize..(l.off + l.len) as usize]).into())
            .collect()
    }

    #[test]
    fn blocks_carry_and_tail() {
        let (n, h) = tables();
        let p = file("carry", b"aaaa\n\nbbbbbbbbbb\ncc\ndd");
        let s = scan(&p, 0, 1 << 20, 3, &n, &h, &since()).unwrap();
        assert_eq!(texts(&s), ["aaaa", "bbbbbbbbbb", "cc"]);
        assert!(s.at_end && !s.truncated);
        assert_eq!(s.new_offset, 20);
        let t = s.tail.unwrap();
        assert_eq!((t.off, t.len), (20, 2));
        let s = scan(&p, 5, 1 << 20, 4, &n, &h, &since()).unwrap();
        assert_eq!(texts(&s), ["bbbbbbbbbb", "cc"]);
        assert_eq!(s.new_offset, 20);
    }

    #[test]
    fn budget_stops_after_a_line_but_reads_a_long_line_whole() {
        let (n, h) = tables();
        let p = file("budget", b"0123456789\nab\ncd\n");
        let s = scan(&p, 0, 4, 4, &n, &h, &since()).unwrap();
        assert_eq!(texts(&s), ["0123456789"]);
        assert!(!s.at_end);
        assert_eq!(s.new_offset, 11);
        let s = scan(&p, 11, 4, 4, &n, &h, &since()).unwrap();
        assert_eq!(texts(&s), ["ab"]);
        assert_eq!(s.new_offset, 14);
    }

    #[test]
    fn truncation_and_caught_up() {
        let (n, h) = tables();
        let p = file("trunc", b"ab\n");
        let s = scan(&p, 10, 1 << 20, 4, &n, &h, &since()).unwrap();
        assert!(s.truncated);
        assert_eq!((s.start, s.new_offset, s.end), (0, 3, 3));
        let s = scan(&p, 3, 1 << 20, 4, &n, &h, &since()).unwrap();
        assert!(s.lines.is_empty() && !s.truncated && s.end == 3);
        assert!(scan("/nonexistent/tally", 0, 1, 1, &n, &h, &since()).is_err());
    }

    #[test]
    fn history_kinds() {
        let (n, h) = tables();
        let s = since();
        let kind = |line: &str| scan_line(line.as_bytes(), 0, line.len(), &n, &h, &s).kind;
        let old = r#""timestamp":"2026-10-03T08:15:59.999Z""#;
        assert_eq!(kind(&format!(r#"{{"type":"user",{old}}}"#)), LINE_HISTORY_CANDIDATE | LINE_TYPE_USER);
        assert_eq!(
            kind(&format!(r#"{{"isSidechain":true,"type":"assistant",{old}}}"#)),
            LINE_HISTORY_CANDIDATE | LINE_SIDECHAIN | LINE_TYPE_ASSISTANT
        );
        assert_eq!(kind(&format!(r#"{{"isApiErrorMessage":true,{old}}}"#)), 0);
        // Same second: decided by the parse, to the millisecond.
        assert_eq!(kind(r#"{"timestamp":"2026-10-03T08:16:00Z"}"#), 0);
        assert_eq!(kind(r#"{"timestamp":"2026-10-03T08:16:00.001Z"}"#), 0);
        assert_eq!(kind(r#"{"timestamp":"2026-10-03T08:17:00Z"}"#), 0);
        // Shapes the strict parser refuses go back to Swift; a fast-path hit does not need it.
        assert_eq!(kind(r#"{"timestamp":"2026-10-03T16:16:00+08:00"}"#), LINE_HISTORY_UNDECIDED);
        assert_eq!(kind(r#"{"timestamp":"2026-10-03T08:16:00.1234Z"}"#), LINE_HISTORY_UNDECIDED);
        assert_eq!(kind(r#"{"timestamp":"2026-09-31T08:16:00Z"}"#), LINE_HISTORY_CANDIDATE);
        assert_eq!(kind(r#"{"timestamp":"2026-10-03T08:16:00Z"#), 0);
        assert_eq!(kind(r#"{"uuid":"x"}"#), 0);
        // Not valid UTF-8: no fields, but history is judged off the bytes as Swift does.
        let bad = [&br#"{"type":"user","timestamp":"2026-01-01T00:00:00Z","x":""#[..], b"\xff\"}"].concat();
        let l = scan_line(&bad, 0, bad.len(), &n, &h, &s);
        assert_eq!((l.fields.utf8_valid, l.kind), (0, LINE_HISTORY_CANDIDATE | LINE_TYPE_USER));
    }
}

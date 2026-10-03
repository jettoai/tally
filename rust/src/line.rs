//! One transcript line read off its bytes. A THIRD TWIN of the line readers: the substring ones
//! (`lineUUID`, `userExcerpt`, `lineParentUUID`, `lineTimestamp`, the `"model":"` read in
//! `scanLine`, `contextTokens(inLine:)`) and the byte ones in TallyCLI/TranscriptLineBytes.swift.
//! Change all three together. The keys below are part of those extraction algorithms, not markers
//! a decision tests for; those are the needles Swift hands over (`LineNeedle.table`).

use crate::{iso, TallyLineFields, TallySpan, TS_PARSED, TS_RAW};
use memchr::memchr;
use memchr::memmem::Finder;

/// The finders one process builds once: the presence needles from Swift, and the extraction keys.
pub struct TallyNeedles {
    flags: Vec<Finder<'static>>,
    uuid: Finder<'static>,
    parent: Finder<'static>,
    model: Finder<'static>,
    timestamp: Finder<'static>,
    content: Finder<'static>,
    text: Finder<'static>,
    usage: Finder<'static>,
    iterations: Finder<'static>,
    inputs: [Finder<'static>; 3],
    output: Finder<'static>,
}

fn finder(key: &[u8]) -> Finder<'static> {
    Finder::new(key).into_owned()
}

impl TallyNeedles {
    pub fn new(flags: &[&[u8]]) -> Self {
        TallyNeedles {
            flags: flags.iter().map(|n| finder(n)).collect(),
            uuid: finder(b"\"uuid\":\""),
            parent: finder(b"\"parentUuid\":\""),
            model: finder(b"\"model\":\""),
            timestamp: finder(b"\"timestamp\":\""),
            content: finder(b"\"content\":"),
            text: finder(b"\"text\":\""),
            usage: finder(b"\"usage\":{"),
            iterations: finder(b"\"iterations\":"),
            // contextTokenFields (TallyCLI/SessionContext.swift)
            inputs: [
                finder(b"\"input_tokens\":"),
                finder(b"\"cache_creation_input_tokens\":"),
                finder(b"\"cache_read_input_tokens\":"),
            ],
            output: finder(b"\"output_tokens\":"),
        }
    }
}

fn span(start: usize, end: usize) -> TallySpan {
    TallySpan { off: start as i64, len: (end - start) as i64 }
}

/// The value from `start` to the next quote; absent when no quote closes it.
fn quoted_from(line: &[u8], start: usize) -> TallySpan {
    match memchr(b'"', &line[start..]) {
        Some(end) => span(start, start + end),
        None => TallySpan::ABSENT,
    }
}

/// The quoted value right after the first `key`.
fn quoted_after(line: &[u8], key: &Finder) -> TallySpan {
    match key.find(line) {
        Some(at) => quoted_from(line, at + key.needle().len()),
        None => TallySpan::ABSENT,
    }
}

/// `userExcerpt`: a string `content`, else the first `text` after the `content` key.
fn excerpt(line: &[u8], n: &TallyNeedles) -> TallySpan {
    let Some(at) = n.content.find(line) else { return TallySpan::ABSENT };
    let rest = at + n.content.needle().len();
    if line.get(rest) == Some(&b'"') {
        return quoted_from(line, rest + 1);
    }
    match n.text.find(&line[rest..]) {
        Some(t) => quoted_from(line, rest + t + n.text.needle().len()),
        None => TallySpan::ABSENT,
    }
}

/// `tokenField`: the ASCII digits right after `key`; None when there are none or they overflow.
fn token_field(window: &[u8], key: &Finder) -> Option<i64> {
    let at = key.find(window)? + key.needle().len();
    let digits = window[at..].iter().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 {
        return None;
    }
    window[at..at + digits]
        .iter()
        .try_fold(0i64, |v, &b| v.checked_mul(10)?.checked_add(i64::from(b - b'0')))
}

/// `contextTokens(inLine:)`: top-level totals only (the window stops at `iterations`), all three
/// input figures or nothing, output when present, zero is nothing.
fn context_tokens(line: &[u8], n: &TallyNeedles) -> Option<i64> {
    let start = n.usage.find(line)? + n.usage.needle().len();
    let end = n.iterations.find(&line[start..]).map_or(line.len(), |i| start + i);
    let window = &line[start..end];
    let mut total = 0i64;
    for key in &n.inputs {
        total = total.checked_add(token_field(window, key)?)?;
    }
    total = total.checked_add(token_field(window, &n.output).unwrap_or(0))?;
    (total > 0).then_some(total)
}

pub fn read_line(n: &TallyNeedles, line: &[u8]) -> TallyLineFields {
    let mut out = TallyLineFields::default();
    // Not valid UTF-8: the scan skips the line, as `String(bytes:encoding:)` returning nil did.
    if std::str::from_utf8(line).is_err() {
        return out;
    }
    out.utf8_valid = 1;
    for (bit, f) in n.flags.iter().enumerate() {
        if f.find(line).is_some() {
            out.present |= 1 << bit;
        }
    }
    out.uuid = quoted_after(line, &n.uuid);
    out.parent_uuid = quoted_after(line, &n.parent);
    out.model = quoted_after(line, &n.model);
    out.excerpt = excerpt(line, n);
    out.ts_raw = quoted_after(line, &n.timestamp);
    if out.ts_raw.len >= 0 {
        let raw = &line[out.ts_raw.off as usize..(out.ts_raw.off + out.ts_raw.len) as usize];
        match iso::parse(raw) {
            Some((seconds, millis)) => {
                out.ts_kind = TS_PARSED;
                out.ts_seconds = seconds;
                out.ts_millis = millis;
            }
            None => out.ts_kind = TS_RAW,
        }
    }
    out.context_tokens = context_tokens(line, n).unwrap_or(-1);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(line: &str) -> (TallyLineFields, String) {
        let n = TallyNeedles::new(&[b"\"isSidechain\":true", b"tool_result"]);
        (read_line(&n, line.as_bytes()), line.to_string())
    }

    fn val(line: &str, s: TallySpan) -> Option<&str> {
        (s.len >= 0).then(|| &line[s.off as usize..(s.off + s.len) as usize])
    }

    #[test]
    fn fields() {
        let line = r#"{"parentUuid":"p1","isSidechain":true,"type":"user","message":{"content":"hi there"},"uuid":"u1","timestamp":"2026-10-03T08:15:30.120Z"}"#;
        let (f, l) = read(line);
        assert_eq!(f.utf8_valid, 1);
        assert_eq!(f.present, 1);
        assert_eq!(val(&l, f.uuid), Some("u1"));
        assert_eq!(val(&l, f.parent_uuid), Some("p1"));
        assert_eq!(val(&l, f.excerpt), Some("hi there"));
        assert_eq!(val(&l, f.model), None);
        assert_eq!((f.ts_kind, f.ts_millis), (TS_PARSED, 120));
        assert_eq!(f.context_tokens, -1);
    }

    #[test]
    fn excerpt_from_text_array_and_unclosed_values() {
        let (f, l) = read(r#"{"content":[{"type":"tool_result","text":"abc"}],"uuid":"x"#);
        assert_eq!(f.present, 2);
        assert_eq!(val(&l, f.excerpt), Some("abc"));
        assert_eq!(f.uuid.len, -1);
        let (f, _) = read(r#"{"timestamp":"2026-01-01T00:00:00+08:00"}"#);
        assert_eq!(f.ts_kind, TS_RAW);
        let (f, _) = read(r#"{"timestamp":"2026-01-01T00:00:00Z"#);
        assert_eq!(f.ts_kind, crate::TS_NONE);
    }

    #[test]
    fn context() {
        let usage = r#""usage":{"input_tokens":3,"cache_creation_input_tokens":40,"cache_read_input_tokens":500,"output_tokens":6000"#;
        assert_eq!(read(&format!("{{{usage}}}")).0.context_tokens, 6543);
        let no_out = r#""usage":{"input_tokens":3,"cache_creation_input_tokens":40,"cache_read_input_tokens":500,"iterations":[{"output_tokens":6000}]}"#;
        assert_eq!(read(&format!("{{{no_out}}}")).0.context_tokens, 543);
        let missing = r#""usage":{"input_tokens":3,"iterations":[{"cache_creation_input_tokens":40,"cache_read_input_tokens":500}]}"#;
        assert_eq!(read(&format!("{{{missing}}}")).0.context_tokens, -1);
        let zero = r#""usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}"#;
        assert_eq!(read(&format!("{{{zero}}}")).0.context_tokens, -1);
        let huge = r#""usage":{"input_tokens":99999999999999999999,"cache_creation_input_tokens":0,"cache_read_input_tokens":1}"#;
        assert_eq!(read(&format!("{{{huge}}}")).0.context_tokens, -1);
        let null = r#""usage":{"input_tokens":null,"cache_creation_input_tokens":0,"cache_read_input_tokens":1}"#;
        assert_eq!(read(&format!("{{{null}}}")).0.context_tokens, -1);
    }

    #[test]
    fn invalid_utf8_reads_nothing() {
        let n = TallyNeedles::new(&[b"a"]);
        for bad in [&b"a\xff"[..], b"a\xc0\x80", b"a\xed\xa0\x80", b"a\x80"] {
            let f = read_line(&n, bad);
            assert_eq!((f.utf8_valid, f.present), (0, 0));
        }
        let f = read_line(&n, "\u{feff}a\0".as_bytes());
        assert_eq!((f.utf8_valid, f.present), (1, 1));
    }
}

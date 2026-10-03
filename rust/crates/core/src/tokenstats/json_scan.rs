//! A shallow reader over one JSON object's top-level members, on bytes. Not a validator:
//! malformed input stops the walk and reports what was read so far, which is how the scanner
//! skips a bad or half-written line. Ported from JSONScan.swift; every quirk below is that file's.

use std::ops::Range;

pub struct Scan<'a> {
    pub bytes: &'a [u8],
}

impl<'a> Scan<'a> {
    /// Calls `body` for each `key: value` directly inside the object starting at `object.start`,
    /// with the key's range (quotes excluded) and the value's (quotes and braces included).
    pub fn for_each_member(&self, object: Range<usize>, mut body: impl FnMut(Range<usize>, Range<usize>)) {
        let b = self.bytes;
        let end = object.end;
        let mut i = object.start;
        if !(i < end && b[i] == b'{') {
            return;
        }
        i += 1;
        while i < end {
            i = self.skip_space(i, end);
            if i >= end {
                return;
            }
            let c = b[i];
            if c == b'}' {
                return;
            }
            if c == b',' {
                i += 1;
                continue;
            }
            if c != b'"' {
                return;
            }
            // A key whose closing quote is not in the buffer (a live file's half-flushed last
            // line) stops the walk like any other malformed input.
            let key_end = self.end_of_string(i, end);
            if !(key_end > i + 1 && b[key_end - 1] == b'"') {
                return;
            }
            let key = i + 1..key_end - 1;
            i = self.skip_space(key_end, end);
            if !(i < end && b[i] == b':') {
                return;
            }
            i = self.skip_space(i + 1, end);
            if i >= end {
                return;
            }
            let value_end = self.end_of_value(i, end);
            body(key, i..value_end);
            i = value_end;
        }
    }

    /// The FIRST member named `key`, or None.
    pub fn member(&self, key: &[u8], object: Range<usize>) -> Option<Range<usize>> {
        let mut found = None;
        self.for_each_member(object, |k, v| {
            if found.is_none() && self.key_is(&k, key) {
                found = Some(v);
            }
        });
        found
    }

    pub fn key_is(&self, range: &Range<usize>, literal: &[u8]) -> bool {
        &self.bytes[range.clone()] == literal
    }

    /// A plain non-negative integer, or None (also for one too large for i64, where Swift traps).
    pub fn int64(&self, range: Range<usize>) -> Option<i64> {
        let mut value: i64 = 0;
        let mut any = false;
        for &c in &self.bytes[range] {
            if !c.is_ascii_digit() {
                return None;
            }
            value = value.checked_mul(10)?.checked_add(i64::from(c - b'0'))?;
            any = true;
        }
        any.then_some(value)
    }

    /// A string value, unescaped the way the Swift reader did: `\n` `\t` `\r` translated, any
    /// other escaped byte written as itself (so `\u00e9` reads `u00e9`), a final lone backslash
    /// kept. Invalid UTF-8 is replaced by U+FFFD per maximal subpart, as `String(decoding:)` does.
    pub fn string(&self, range: Range<usize>) -> Option<String> {
        let b = self.bytes;
        if range.len() < 2 || b[range.start] != b'"' {
            return None;
        }
        let (start, end) = (range.start + 1, range.end - 1);
        let mut out = Vec::with_capacity(end - start);
        let mut i = start;
        while i < end {
            let c = b[i];
            if c == b'\\' && i + 1 < end {
                out.push(match b[i + 1] {
                    b'n' => b'\n',
                    b't' => b'\t',
                    b'r' => b'\r',
                    other => other,
                });
                i += 2;
            } else {
                out.push(c);
                i += 1;
            }
        }
        Some(String::from_utf8_lossy(&out).into_owned())
    }

    fn skip_space(&self, from: usize, end: usize) -> usize {
        let mut i = from;
        while i < end && matches!(self.bytes[i], b' ' | b'\t' | b'\n' | b'\r') {
            i += 1;
        }
        i
    }

    /// Index just past the closing quote of the string starting at `from`.
    fn end_of_string(&self, from: usize, end: usize) -> usize {
        let mut i = from + 1;
        while i < end {
            let c = self.bytes[i];
            if c == b'\\' {
                i += 2;
                continue;
            }
            if c == b'"' {
                return i + 1;
            }
            i += 1;
        }
        end
    }

    /// Index just past the value starting at `from`, whatever kind it is.
    fn end_of_value(&self, from: usize, end: usize) -> usize {
        match self.bytes[from] {
            b'"' => self.end_of_string(from, end),
            b'{' | b'[' => {
                let mut depth = 0i64;
                let mut i = from;
                while i < end {
                    let c = self.bytes[i];
                    if c == b'"' {
                        i = self.end_of_string(i, end);
                        continue;
                    }
                    if c == b'{' || c == b'[' {
                        depth += 1;
                    }
                    if c == b'}' || c == b']' {
                        depth -= 1;
                        if depth == 0 {
                            return i + 1;
                        }
                    }
                    i += 1;
                }
                end
            }
            _ => {
                let mut i = from;
                while i < end {
                    if matches!(self.bytes[i], b',' | b'}' | b']' | b' ' | b'\t' | b'\n' | b'\r') {
                        return i;
                    }
                    i += 1;
                }
                end
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn members(s: &str) -> Vec<(String, String)> {
        let scan = Scan { bytes: s.as_bytes() };
        let mut out = vec![];
        scan.for_each_member(0..s.len(), |k, v| out.push((s[k].to_string(), s[v].to_string())));
        out
    }

    #[test]
    fn walks_top_level_members_only() {
        assert_eq!(members(r#"{"a":1, "b":{"c":[1,"}"]},"d":"x\"y"}"#),
                   vec![("a".into(), "1".into()), ("b".into(), r#"{"c":[1,"}"]}"#.into()),
                        ("d".into(), r#""x\"y""#.into())]);
    }

    #[test]
    fn a_cut_key_stops_the_walk() {
        assert_eq!(members(r#"{"a":1,"b"#), vec![("a".into(), "1".into())]);
        assert_eq!(members(r#"{"a":1,"#), vec![("a".into(), "1".into())]);
    }

    #[test]
    fn member_takes_the_first_duplicate() {
        let s = r#"{"k":1,"k":2}"#;
        let scan = Scan { bytes: s.as_bytes() };
        assert_eq!(&s[scan.member(b"k", 0..s.len()).unwrap()], "1");
    }

    #[test]
    fn integers_and_overflow() {
        let s = "12 x 9223372036854775807 9223372036854775808";
        let scan = Scan { bytes: s.as_bytes() };
        assert_eq!(scan.int64(0..2), Some(12));
        assert_eq!(scan.int64(3..4), None);
        assert_eq!(scan.int64(2..2), None);
        assert_eq!(scan.int64(5..24), Some(i64::MAX));
        assert_eq!(scan.int64(25..44), None);
    }

    #[test]
    fn strings_unescape_like_swift() {
        let s = r#""a\nb\u00e9\/c\""#;
        let scan = Scan { bytes: s.as_bytes() };
        assert_eq!(scan.string(0..s.len()).unwrap(), "a\nbu00e9/c\\");
        let bad = b"\"a\xffb\"";
        assert_eq!(Scan { bytes: bad }.string(0..bad.len()).unwrap(), "a\u{fffd}b");
        assert_eq!(Scan { bytes: b"1" }.string(0..1), None);
    }
}

//! The subset of Swift `String` semantics the project map's rules were written in: equality under
//! canonical equivalence, Character (grapheme cluster) prefixes, counts and splits. ASCII input,
//! which is every path on most machines, takes a byte fast path with identical answers.

use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

fn nfc(s: &str) -> String {
    s.nfc().collect()
}

/// ASCII where every byte is its own Character: `"\r\n"` is the one ASCII cluster of two.
fn bytewise(s: &str) -> bool {
    s.is_ascii() && !s.contains('\r')
}

/// A key that hashes and compares the way a Swift `String` dictionary key does.
pub fn key(s: &str) -> String {
    if s.is_ascii() { s.to_string() } else { nfc(s) }
}

/// `a == b`.
pub fn eq(a: &str, b: &str) -> bool {
    if a.is_ascii() && b.is_ascii() { a == b } else { nfc(a) == nfc(b) }
}

/// `s.hasPrefix(p)`: Character by Character, each compared under canonical equivalence.
pub fn has_prefix(s: &str, p: &str) -> bool {
    if bytewise(s) && bytewise(p) {
        return s.as_bytes().starts_with(p.as_bytes());
    }
    let mut chars = s.graphemes(true);
    for want in p.graphemes(true) {
        match chars.next() {
            Some(got) if eq(got, want) => {}
            _ => return false,
        }
    }
    true
}

/// `s.count`: grapheme clusters.
pub fn char_count(s: &str) -> usize {
    if bytewise(s) { s.len() } else { s.graphemes(true).count() }
}

/// `s.split(separator: sep)`: on Characters equal to `sep`, empty pieces dropped. A `"\r\n"`
/// cluster is not a `"\n"`, and `"/"` followed by a combining mark is not a `"/"`.
pub fn split_nonempty(s: &str, sep: &str) -> Vec<String> {
    let mut out = vec![];
    let mut piece = String::new();
    for g in s.graphemes(true) {
        if eq(g, sep) {
            if !piece.is_empty() {
                out.push(std::mem::take(&mut piece));
            }
        } else {
            piece.push_str(g);
        }
    }
    if !piece.is_empty() {
        out.push(piece);
    }
    out
}

/// Claude Code's transcript-folder spelling of a path: every Character that is not a single ASCII
/// letter or digit, or a dash, becomes one dash.
pub fn munged(path: &str) -> String {
    path.graphemes(true)
        .map(|g| {
            let keep = g == "-" || (g.len() == 1 && g.as_bytes()[0].is_ascii_alphanumeric());
            if keep { g } else { "-" }
        })
        .collect()
}

/// `trimmingCharacters(in: .whitespaces)`: tab and the Unicode space separators (Zs); not newlines.
pub fn trim_whitespace(s: &str) -> &str {
    let ws = |c: char| {
        matches!(c, '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}')
    };
    s.trim_matches(ws)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_equivalence_and_clusters() {
        let (nfc_e, nfd_e) = ("caf\u{e9}", "cafe\u{301}");
        assert!(eq(nfc_e, nfd_e));
        assert_eq!(key(nfd_e), key(nfc_e));
        assert!(has_prefix(&format!("{nfd_e}/x"), &format!("{nfc_e}/")));
        // A combining mark after the prefix's last letter makes it a different Character.
        assert!(!has_prefix("cafe\u{301}", "cafe"));
        assert_eq!(char_count(nfd_e), 4);
        assert_eq!(char_count("x\r\n"), 2);
        assert!(!has_prefix("a\r\nb", "a\r"));
        assert_eq!(split_nonempty("/a//b/", "/"), vec!["a", "b"]);
        assert_eq!(split_nonempty("a\r\nb\nc", "\n"), vec!["a\r\nb", "c"]);
        assert_eq!(split_nonempty("a/\u{301}b", "/"), vec!["a/\u{301}b"]);
        assert_eq!(munged("/Users/a b/caf\u{e9}-x.y"), "-Users-a-b-caf--x-y");
        assert_eq!(trim_whitespace("\u{3000} a\t\n"), "a\t\n");
    }
}

//! One transcript file to per (day, project) token buckets. Ported from TokenStatsParser.swift:
//! each line is rejected by a substring test before any parsing, malformed lines are skipped in
//! silence, and nothing but the numeric fields, the cwd and the timestamp is ever converted.

use std::collections::HashMap;

use memchr::memmem::Finder;

use super::day::Stamper;
use super::json_scan::Scan;
use super::project_map::ProjectMap;
use super::{Bucket, Host, Totals, OTHER_KEY};

pub const CLAUDE: &str = "claude";
pub const CODEX: &str = "codex";

pub fn buckets(path: &str, provider: &str, map: &ProjectMap, host: &dyn Host) -> Vec<Bucket> {
    let Ok(raw) = std::fs::read(path) else { return vec![] };
    buckets_of(&raw, provider, map, host)
}

pub fn buckets_of(raw: &[u8], provider: &str, map: &ProjectMap, host: &dyn Host) -> Vec<Bucket> {
    if raw.is_empty() {
        return vec![];
    }
    let mut out = Accumulator::default();
    match provider {
        CLAUDE => read_claude(raw, map, host, &mut out),
        CODEX => read_codex(raw, map, host, &mut out),
        _ => {}
    }
    out.buckets()
}

/// Claude Code: usage on `message.usage`, cwd and timestamp at the top level. One turn is written
/// as several lines sharing a `message.id`, each restating the usage so far, so a turn counts as
/// the highest value each column reached (per file: see TokenStatsParser.swift for why).
fn read_claude(raw: &[u8], map: &ProjectMap, host: &dyn Host, out: &mut Accumulator) {
    let scan = Scan { bytes: raw };
    let usage_needle = Finder::new(b"\"usage\"");
    let mut stamper = Stamper::new(host);
    let mut counted: HashMap<u64, Totals> = HashMap::new();
    let mut projects = KeyMemo::new(map);

    for_each_line(raw, |line| {
        if !contains(&usage_needle, &raw[line.clone()]) {
            return;
        }
        let (mut cwd, mut timestamp, mut message) = (None, None, None);
        scan.for_each_member(line, |k, v| {
            if scan.key_is(&k, b"cwd") {
                cwd = Some(v);
            } else if scan.key_is(&k, b"timestamp") {
                timestamp = Some(v);
            } else if scan.key_is(&k, b"message") {
                message = Some(v);
            }
        });
        let (Some(message), Some(timestamp)) = (message, timestamp) else { return };
        let Some(day) = stamper.day_from_iso(raw, timestamp) else { return };

        let (mut usage, mut message_id) = (None, None);
        scan.for_each_member(message, |k, v| {
            if scan.key_is(&k, b"usage") {
                usage = Some(v);
            } else if scan.key_is(&k, b"id") {
                message_id = Some(v);
            }
        });
        let Some(usage) = usage else { return };

        let mut totals = Totals::default();
        scan.for_each_member(usage, |k, v| {
            if scan.key_is(&k, b"input_tokens") {
                totals.input = scan.int64(v).unwrap_or(0);
            } else if scan.key_is(&k, b"cache_creation_input_tokens") {
                totals.cache_write = scan.int64(v).unwrap_or(0);
            } else if scan.key_is(&k, b"cache_read_input_tokens") {
                totals.cache_read = scan.int64(v).unwrap_or(0);
            } else if scan.key_is(&k, b"output_tokens") {
                totals.output = scan.int64(v).unwrap_or(0);
            }
        });
        if totals.is_empty() {
            return;
        }
        // No id (older transcripts): counted whole, the safer error.
        if let Some(id) = message_id {
            let added = counted.entry(fingerprint(&raw[id])).or_default().raise(&totals);
            if added.is_empty() {
                return;
            }
            totals = added;
        }
        let project = projects.key(&scan, cwd);
        out.add(&totals, day, project);
    });
}

/// Codex: the cwd is on the `session_meta` line, and `total_token_usage` is cumulative for the
/// session, so consecutive differences are taken; a total that moved backwards is a fresh counter.
/// Codex counts cached tokens inside `input_tokens`, so they are subtracted out.
fn read_codex(raw: &[u8], map: &ProjectMap, host: &dyn Host, out: &mut Accumulator) {
    let scan = Scan { bytes: raw };
    let token_needle = Finder::new(b"token_count");
    let cwd_needle = Finder::new(b"\"cwd\"");
    let mut stamper = Stamper::new(host);
    let mut projects = KeyMemo::new(map);
    let mut project = OTHER_KEY.to_string();
    let mut previous: Option<Counters> = None;

    for_each_line(raw, |line| {
        let bytes = &raw[line.clone()];
        if !contains(&token_needle, bytes) && !contains(&cwd_needle, bytes) {
            return;
        }
        let (mut kind, mut timestamp, mut payload) = (None, None, None);
        scan.for_each_member(line, |k, v| {
            if scan.key_is(&k, b"type") {
                kind = Some(v);
            } else if scan.key_is(&k, b"timestamp") {
                timestamp = Some(v);
            } else if scan.key_is(&k, b"payload") {
                payload = Some(v);
            }
        });
        let Some(payload) = payload else { return };

        if let Some(kind) = kind {
            if &raw[kind] == b"\"session_meta\"" {
                project = projects.key(&scan, scan.member(b"cwd", payload)).to_string();
                return;
            }
        }

        let (mut payload_type, mut info) = (None, None);
        scan.for_each_member(payload, |k, v| {
            if scan.key_is(&k, b"type") {
                payload_type = Some(v);
            } else if scan.key_is(&k, b"info") {
                info = Some(v);
            }
        });
        let Some(payload_type) = payload_type else { return };
        if &raw[payload_type] != b"\"token_count\"" {
            return;
        }
        let Some(info) = info else { return };
        let Some(usage) = scan.member(b"total_token_usage", info) else { return };
        let Some(timestamp) = timestamp else { return };
        let Some(day) = stamper.day_from_iso(raw, timestamp) else { return };

        let mut current = Counters::default();
        scan.for_each_member(usage, |k, v| {
            if scan.key_is(&k, b"input_tokens") {
                current.input = scan.int64(v).unwrap_or(0);
            } else if scan.key_is(&k, b"cached_input_tokens") {
                current.cached = scan.int64(v).unwrap_or(0);
            } else if scan.key_is(&k, b"cache_write_input_tokens") {
                current.cache_write = scan.int64(v).unwrap_or(0);
            } else if scan.key_is(&k, b"output_tokens") {
                current.output = scan.int64(v).unwrap_or(0);
            }
        });
        let delta = current.delta(previous.as_ref());
        previous = Some(current);
        if delta.is_empty() {
            return;
        }
        out.add(&delta, day, &project);
    });
}

#[derive(Clone, Copy, Default)]
struct Counters {
    input: i64, // includes the cached part
    cached: i64,
    cache_write: i64,
    output: i64, // includes reasoning
}

impl Counters {
    fn delta(&self, previous: Option<&Counters>) -> Totals {
        match previous {
            Some(p) if self.input >= p.input && self.cached >= p.cached
                && self.cache_write >= p.cache_write && self.output >= p.output =>
            {
                let fresh = (self.input - p.input) - (self.cached - p.cached);
                Totals {
                    input: fresh.max(0),
                    cache_write: self.cache_write - p.cache_write,
                    cache_read: self.cached - p.cached,
                    output: self.output - p.output,
                }
            }
            _ => Totals {
                input: (self.input - self.cached).max(0),
                cache_write: self.cache_write,
                cache_read: self.cached,
                output: self.output,
            },
        }
    }
}

/// Splits on `\n` only; empty lines are skipped, a last line without a newline is read.
fn for_each_line(raw: &[u8], mut body: impl FnMut(std::ops::Range<usize>)) {
    let mut start = 0;
    while start < raw.len() {
        let end = memchr::memchr(b'\n', &raw[start..]).map_or(raw.len(), |i| start + i);
        if end > start {
            body(start..end);
        }
        start = end + 1;
    }
}

fn contains(needle: &Finder, hay: &[u8]) -> bool {
    needle.find(hay).is_some()
}

/// 64-bit FNV-1a over a value's raw bytes (quotes included): the dedupe key for `message.id`.
fn fingerprint(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// Remembers the last cwd's raw bytes so a file whose lines share one cwd converts it once.
struct KeyMemo<'m> {
    map: &'m ProjectMap,
    last_bytes: Vec<u8>,
    last_key: String,
}

impl<'m> KeyMemo<'m> {
    fn new(map: &'m ProjectMap) -> Self {
        KeyMemo { map, last_bytes: vec![], last_key: OTHER_KEY.to_string() }
    }

    fn key(&mut self, scan: &Scan, range: Option<std::ops::Range<usize>>) -> &str {
        let Some(range) = range else { return OTHER_KEY };
        let bytes = &scan.bytes[range.clone()];
        if self.last_bytes != bytes {
            self.last_bytes = bytes.to_vec();
            self.last_key = self.map.key_for_cwd(scan.string(range).as_deref());
        }
        &self.last_key
    }
}

#[derive(Default)]
struct Accumulator {
    cells: HashMap<(i64, String), Totals>,
}

impl Accumulator {
    fn add(&mut self, totals: &Totals, day: i64, project: &str) {
        self.cells.entry((day, project.to_string())).or_default().add(totals);
    }

    /// Sorted so a re-scan of an unchanged file produces an identical cache entry.
    fn buckets(self) -> Vec<Bucket> {
        let mut out: Vec<Bucket> =
            self.cells.into_iter().map(|((day, project), totals)| Bucket { day, project, totals }).collect();
        out.sort_by(|a, b| (a.day, &a.project).cmp(&(b.day, &b.project)));
        out
    }
}

#[cfg(test)]
#[path = "parser_tests.rs"]
mod tests;

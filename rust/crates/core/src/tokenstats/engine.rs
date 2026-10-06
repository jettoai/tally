//! Scans the transcripts and keeps a per-file cache (`~/.tally/token-stats.json`, written in the
//! shape the Swift engine wrote, so an upgrade starts warm): a file whose size and modification
//! time are unchanged is never opened again. Ported from TokenStatsEngine.swift.

use std::collections::{BTreeMap, HashMap};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use super::project_map::ProjectMap;
use super::{parser, sources, Bucket, Host, Sample, Totals};

/// Bumped whenever the parsing rules change in a way that makes existing entries wrong. A
/// mismatch discards the cache and rescans, which is slow exactly once.
/// 2: projects are attributed by allow-list rather than by raw cwd.
/// 3: a turn's usage is counted at its highest restated value rather than its first.
/// 4: a directory is attributed to the project whose claim on it is the deepest.
/// 5: a worktree is attributed to the repository it was cut from.
/// 6: that attribution reads the git directory a worktree actually belongs to, and remembers a
/// torn-down worktree's repository from the note teardown leaves.
/// 7: each cell also carries the model, the subagent flag, the turn count and the 1 hour cache
/// write, which the cost view prices.
pub const CURRENT_VERSION: i64 = 7;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Entry {
    pub provider: String,
    pub size: i64,
    pub modified: f64,
    pub buckets: Vec<Bucket>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Cache {
    pub version: i64,
    /// The zone the day numbers were cut in: a machine that moved zones rescans everything.
    pub zone: String,
    pub files: BTreeMap<String, Entry>,
}

impl Cache {
    fn current(zone: &str, files: BTreeMap<String, Entry>) -> Cache {
        Cache { version: CURRENT_VERSION, zone: zone.to_string(), files }
    }

    fn is_current(&self, zone: &str) -> bool {
        self.version == CURRENT_VERSION && self.zone == zone
    }
}

pub struct ScanInput {
    pub home: String,
    pub claude_homes: Vec<String>,
    pub codex_homes: Vec<String>,
    pub zone: String,
    pub cache_path: String,
}

pub struct ScanOutcome {
    pub samples: Vec<Sample>,
    pub files_seen: u32,
    pub files_reparsed: u32,
}

/// The in-memory cache between scans. Callers serialize scans (the Swift side's queue); the lock
/// only makes that safe to rely on.
#[derive(Default)]
pub struct Engine {
    cache: Mutex<Option<Cache>>,
}

impl Engine {
    pub fn scan(&self, input: &ScanInput, host: &dyn Host) -> ScanOutcome {
        let mut slot = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        let mut loaded = slot.take().unwrap_or_else(|| read(&input.cache_path, &input.zone));
        if !loaded.is_current(&input.zone) {
            loaded = Cache::current(&input.zone, BTreeMap::new());
        }

        // The allow-list is read once per scan, before the files are listed.
        let map = ProjectMap::build(&input.home, host);
        let mut next = BTreeMap::new();
        let (mut seen, mut reparsed) = (0u32, 0u32);
        for file in sources::list(&input.claude_homes, &input.codex_homes) {
            seen += 1;
            if let Some(known) = loaded.files.get(&file.path) {
                if known.size == file.size && (known.modified - file.modified).abs() < 0.001 {
                    next.insert(file.path, known.clone());
                    continue;
                }
            }
            reparsed += 1;
            let buckets = parser::buckets(&file.path, &file.provider, &map, host);
            next.insert(file.path, Entry { provider: file.provider, size: file.size, modified: file.modified, buckets });
        }

        // Replacing rather than merging drops files deleted since the last scan.
        let changed = reparsed > 0 || loaded.files.len() != next.len();
        let updated = Cache::current(&input.zone, next);
        if changed {
            write(&input.cache_path, &updated);
        }
        let samples = merge(&updated.files);
        *slot = Some(updated);
        ScanOutcome { samples, files_seen: seen, files_reparsed: reparsed }
    }
}

/// One cell per (day, project, provider, model, side), sorted (the Swift engine's order was
/// undefined).
pub fn merge(files: &BTreeMap<String, Entry>) -> Vec<Sample> {
    type Key<'a> = (i64, &'a str, &'a str, &'a str, bool);
    let mut cells: HashMap<Key, (Totals, i64)> = HashMap::new();
    for entry in files.values() {
        for b in &entry.buckets {
            let cell = cells.entry((b.day, &b.project, &entry.provider, &b.model, b.subagent)).or_default();
            cell.0.add(&b.totals);
            cell.1 += b.turns;
        }
    }
    let mut out: Vec<Sample> = cells.into_iter()
        .map(|((day, project, provider, model, subagent), (totals, turns))| Sample {
            day,
            project: project.to_string(),
            provider_id: provider.to_string(),
            totals,
            model: model.to_string(),
            subagent,
            turns,
        })
        .collect();
    out.sort_by(|a, b| (a.day, &a.project, &a.provider_id, &a.model, a.subagent)
        .cmp(&(b.day, &b.project, &b.provider_id, &b.model, b.subagent)));
    out
}

fn read(path: &str, zone: &str) -> Cache {
    std::fs::read(path).ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or_else(|| Cache::current(zone, BTreeMap::new()))
}

/// Atomic: written beside the cache and renamed over it. Failures are ignored, as before.
fn write(path: &str, cache: &Cache) {
    let Ok(data) = serde_json::to_vec(cache) else { return };
    let target = std::path::Path::new(path);
    if let Some(parent) = target.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let temp = format!("{path}.tmp-{}", std::process::id());
    if std::fs::write(&temp, data).is_ok() && std::fs::rename(&temp, target).is_err() {
        let _ = std::fs::remove_file(&temp);
    }
}

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;

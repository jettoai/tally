//! Every transcript file, both providers, with the identity (size, modification time) the
//! incremental cache compares against. Ported from TokenStatsSources.swift's walk.
//!
//! The config homes come from the host (the accounts the app already discovers, plus the default
//! home), never from a fresh `~/.claude*` glob, which would sweep in backup folders. Roots are
//! deduplicated by their resolved path because multi-account setups symlink one `projects/` into
//! every home. Symlinked files are not read and symlinked directories are not entered, matching
//! FileManager's enumerator.

use std::collections::HashSet;

use super::parser::{CLAUDE, CODEX};
use super::swift_str;
use tally_sys::fs::{is_hidden, resolve_like_foundation};

#[derive(Clone, Debug, PartialEq)]
pub struct SourceFile {
    pub path: String,
    pub provider: String,
    pub size: i64,
    pub modified: f64,
}

pub fn list(claude_homes: &[String], codex_homes: &[String]) -> Vec<SourceFile> {
    let claude_dirs: Vec<String> = claude_homes.iter().map(|h| format!("{h}/projects")).collect();
    // Archiving moves a Codex rollout from sessions/ into archived_sessions/; both are read.
    let codex_dirs: Vec<String> = codex_homes.iter()
        .flat_map(|h| [format!("{h}/sessions"), format!("{h}/archived_sessions")])
        .collect();
    let mut out = vec![];
    for root in roots(&claude_dirs) {
        walk(&root, CLAUDE, &mut out);
    }
    for root in roots(&codex_dirs) {
        walk(&root, CODEX, &mut out);
    }
    out
}

/// Existing directories, symlinks resolved, each only once, in order.
fn roots(candidates: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    candidates.iter().filter_map(|c| {
        let resolved = resolve_like_foundation(c);
        let is_dir = std::fs::metadata(&resolved).is_ok_and(|m| m.is_dir());
        (is_dir && seen.insert(swift_str::key(&resolved))).then_some(resolved)
    }).collect()
}

fn walk(dir: &str, provider: &str, out: &mut Vec<SourceFile>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Ok(meta) = entry.metadata() else { continue };
        if is_hidden(&name, &meta) {
            continue;
        }
        let name = name.to_string_lossy();
        let path = format!("{dir}/{name}");
        if meta.is_dir() {
            walk(&path, provider, out);
            continue;
        }
        let wanted = std::path::Path::new(&*name).extension().is_some_and(|e| e == "jsonl")
            && (provider != CODEX || name.starts_with("rollout-"));
        if wanted && meta.is_file() {
            out.push(SourceFile { path, provider: provider.to_string(), size: meta.len() as i64, modified: mtime(&meta) });
        }
    }
}

#[cfg(unix)]
fn mtime(meta: &std::fs::Metadata) -> f64 {
    use std::os::unix::fs::MetadataExt;
    meta.mtime() as f64 + meta.mtime_nsec() as f64 / 1e9
}

#[cfg(not(unix))]
fn mtime(meta: &std::fs::Metadata) -> f64 {
    meta.modified().ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0.0, |d| d.as_secs_f64())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn walks_both_providers_and_skips_links_and_hidden() {
        let root = std::env::temp_dir().join(format!("tally-sources-{}", std::process::id()));
        let base = root.to_string_lossy().into_owned();
        let p = format!("{base}/c/projects/-x/s/subagents");
        std::fs::create_dir_all(&p).unwrap();
        std::fs::create_dir_all(format!("{base}/x/sessions/2026/01/02")).unwrap();
        std::fs::write(format!("{base}/c/projects/-x/a.jsonl"), b"1").unwrap();
        std::fs::write(format!("{p}/agent.jsonl"), b"22").unwrap();
        std::fs::write(format!("{base}/c/projects/-x/.h.jsonl"), b"1").unwrap();
        std::fs::write(format!("{base}/c/projects/-x/a.txt"), b"1").unwrap();
        std::os::unix::fs::symlink(format!("{p}/agent.jsonl"), format!("{base}/c/projects/-x/l.jsonl")).unwrap();
        std::fs::write(format!("{base}/x/sessions/2026/01/02/rollout-1.jsonl"), b"333").unwrap();
        std::fs::write(format!("{base}/x/sessions/2026/01/02/other.jsonl"), b"1").unwrap();
        // The same home twice (and through a link) is read once.
        std::os::unix::fs::symlink(format!("{base}/c"), format!("{base}/c2")).unwrap();

        let homes = [format!("{base}/c"), format!("{base}/c2")];
        let mut got = list(&homes, &[format!("{base}/x")]);
        got.sort_by(|a, b| a.path.cmp(&b.path));
        let real = resolve_like_foundation(&base);
        let summary: Vec<_> = got.iter().map(|f| (f.path.replace(&real, ""), f.provider.as_str(), f.size)).collect();
        assert_eq!(summary, vec![
            ("/c/projects/-x/a.jsonl".to_string(), "claude", 1),
            ("/c/projects/-x/s/subagents/agent.jsonl".to_string(), "claude", 2),
            ("/x/sessions/2026/01/02/rollout-1.jsonl".to_string(), "codex", 3),
        ]);
        assert!(got[0].modified > 1.0e9);
        std::fs::remove_dir_all(&root).unwrap();
    }
}

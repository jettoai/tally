//! The signals other than file age: which sessions are live, which paths a process names, and
//! whether a git tree holds anything that exists nowhere else.
use super::scan::{self, Kind};
use super::{fsutil, Abstain, TRANSCRIPT_LIVE};
use crate::git;
use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

/// Session ids to treat as live: fresh in `tally status --json` or with a transcript written in
/// the last 3h. None when tally's view is unavailable (the caller treats every session as live).
pub fn live_sessions(status_text: &str, projects: &Path, now: f64, sids: &[String]) -> Option<HashSet<String>> {
    let cut = now - TRANSCRIPT_LIVE;
    let mut live = HashSet::new();
    let projs = fsutil::listdir(projects);
    for sid in sids {
        for proj in &projs {
            let base = projects.join(proj);
            let sub = base.join(sid);
            let main_recent = fsutil::mtime(&base.join(format!("{sid}.jsonl"))) > cut;
            let sub_recent = sub.is_dir() && scan::busy_since(&sub, cut);
            if main_recent || sub_recent {
                live.insert(sid.clone());
                break;
            }
        }
    }
    let d: serde_json::Value = serde_json::from_str(status_text).ok()?;
    let gen_raw = d.get("generatedAt")?.as_str()?;
    let head = gen_raw.split('.').next().unwrap_or("").trim_end_matches('Z');
    let (gen, _) = crate::iso::parse(format!("{head}Z").as_bytes())?;
    if truthy(d.get("stale")) || now - gen as f64 > 600.0 {
        return None;
    }
    for s in d.get("sessions")?.as_array()? {
        let obj = s.as_object()?; // a session that is not an object makes the whole view unreadable
        if let Some(id) = obj.get("transcriptSessionID").and_then(|v| v.as_str()).filter(|v| !v.is_empty()) {
            live.insert(id.to_string());
        }
    }
    Some(live)
}

/// Python truthiness of a JSON value.
fn truthy(v: Option<&serde_json::Value>) -> bool {
    use serde_json::Value::*;
    match v {
        None | Some(Null) => false,
        Some(Bool(b)) => *b,
        Some(Number(n)) => n.as_f64().is_none_or(|f| f != 0.0),
        Some(String(s)) => !s.is_empty(),
        Some(Array(a)) => !a.is_empty(),
        Some(Object(o)) => !o.is_empty(),
    }
}

/// One ps and one lsof snapshot: (every argv joined by newlines, every process cwd).
pub fn proc_snapshot(proc_file: Option<&str>) -> Result<(String, Vec<String>), Abstain> {
    let (args, cwds) = if let Some(f) = proc_file {
        let text = std::fs::read_to_string(f).map_err(|_| Abstain("process snapshot empty"))?;
        let lines: Vec<&str> = text.lines().collect();
        (
            lines.iter().filter_map(|l| l.strip_prefix("argv:")).collect::<Vec<_>>().join("\n"),
            lines.iter().filter_map(|l| l.strip_prefix("cwd:")).map(str::to_string).collect::<Vec<_>>(),
        )
    } else {
        let ps = std::process::Command::new("/bin/ps")
            .args(["-axww", "-o", "args="])
            .output()
            .map_err(|_| Abstain("ps failed"))?;
        if !ps.status.success() {
            return Err(Abstain("ps failed"));
        }
        let cwds = std::process::Command::new("/usr/sbin/lsof")
            .args(["-nP", "-d", "cwd", "-Fn"])
            .output()
            .map(|o| {
                String::from_utf8_lossy(&o.stdout).lines().filter_map(|l| l.strip_prefix('n')).map(str::to_string).collect()
            })
            .unwrap_or_default();
        (String::from_utf8_lossy(&ps.stdout).into_owned(), cwds)
    };
    if args.trim().is_empty() || cwds.is_empty() {
        return Err(Abstain("process snapshot empty"));
    }
    Ok((args, cwds))
}

/// The path and its /tmp spelling (the first `/private/tmp/` anywhere, as str.replace(.., 1) does).
pub fn aliases(p: &str) -> [String; 2] {
    [p.to_string(), p.replacen("/private/tmp/", "/tmp/", 1)]
}

/// Some process has its cwd at or below p, or (with `use_argv`) names p anywhere in its argv.
pub fn referenced(p: &str, args: &str, cwds: &[String], use_argv: bool) -> bool {
    aliases(p).iter().any(|a| {
        (use_argv && args.contains(a.as_str())) || cwds.iter().any(|c| c == a || c.starts_with(&format!("{a}/")))
    })
}

fn g(p: &Path, a: &[&str]) -> git::CommandResult {
    git::run(p, a, Duration::from_secs(60))
}

/// Why a worktree or clone must stay, or None when nothing in it exists only here.
pub fn tree_blocker(p: &Path, k: Kind) -> Option<&'static str> {
    let st = g(p, &["status", "--porcelain"]);
    if st.code != 0 {
        return Some("git-error");
    }
    if !st.out.trim().is_empty() {
        return Some("dirty");
    }
    let head = g(p, &["rev-parse", "HEAD"]);
    if head.code != 0 {
        return Some("git-error");
    }
    let refs = g(p, &["for-each-ref", "--count=1", "--contains", head.out.trim(), "refs/heads", "refs/remotes", "refs/tags"]);
    if refs.code != 0 || refs.out.trim().is_empty() {
        return Some("head-not-on-ref");
    }
    if k == Kind::Clone {
        let un = g(p, &["log", "--branches", "--not", "--remotes", "--oneline", "-1"]);
        if un.code != 0 || !un.out.trim().is_empty() {
            return Some("unpushed");
        }
        // C3: a commit kept only by a local tag, stash, note or detached HEAD is on no remote either.
        let local = g(p, &["log", "--all", "--not", "--remotes", "--oneline", "-1"]);
        if local.code != 0 || !local.out.trim().is_empty() {
            return Some("unpushed-local-ref");
        }
        // A worktree registered outside p uses p as its common dir; deleting p breaks it.
        let wl = g(p, &["worktree", "list", "--porcelain"]);
        if wl.code != 0 {
            return Some("git-error");
        }
        if wl.out.split("\n\n").skip(1).any(|e| e.starts_with("worktree ") && !e.lines().any(|l| l.starts_with("prunable"))) {
            return Some("linked-worktree");
        }
    }
    // An ignored repo nested inside goes with p and is never in p's status; each must be clean too.
    match nested_repos(p) {
        Err(()) => Some("git-error"),
        Ok(kids) => kids.iter().any(|(q, k)| tree_blocker(q, *k).is_some()).then_some("nested-repo"),
    }
}

/// Every directory below p holding a `.git` entry (not descended into), symlinks not followed.
/// Err when a directory cannot be read.
fn nested_repos(p: &Path) -> Result<Vec<(std::path::PathBuf, Kind)>, ()> {
    let (mut out, mut stack) = (Vec::new(), vec![p.to_path_buf()]);
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).map_err(|_| ())? {
            let e = e.map_err(|_| ())?;
            if e.file_name() == ".git" || !e.file_type().map_err(|_| ())?.is_dir() {
                continue;
            }
            let q = e.path();
            match std::fs::symlink_metadata(q.join(".git")) {
                Ok(m) => out.push((q, if m.is_dir() { Kind::Clone } else { Kind::Worktree })),
                Err(_) => stack.push(q),
            }
        }
    }
    Ok(out)
}

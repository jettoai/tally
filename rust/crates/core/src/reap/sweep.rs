//! One pass over the scratch root: DerivedData first (pure cache, smallest proof burden), then
//! worktrees and clones of sessions known to be offline, then the session directories themselves.
//! Conditions and their order follow the scratch reaper script; C1, C2 and C3 are the three keep
//! rules added on top of it, each evaluated only after every original condition has passed, so
//! anything this keeps that the script deleted carries one of their reasons in the output.
use super::fsutil::{born, du_kb, inside, listdir};
use super::record::{append_log, int_object, Rec, Val};
use super::scan::{busy_since, dd_root, git_dir_anywhere, last_accessed, targets, Kind};
use super::signals::{live_sessions, proc_snapshot, referenced, tree_blocker};
use super::{is_uuid, Abstain, Opts, DD_IDLE_DEAD, DD_IDLE_LIVE, SESSION_IDLE, TREE_IDLE};
use crate::git;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

enum Stop {
    Abstain(Abstain),
    Log(std::io::Error),
}

impl From<Abstain> for Stop {
    fn from(a: Abstain) -> Stop {
        Stop::Abstain(a)
    }
}

struct Ctx<'a> {
    o: &'a Opts,
    ts: i64,
    out: &'a mut dyn Write,
    deleted: i64,
    errors: i64,
    freed_kb: i64,
}

impl Ctx<'_> {
    /// Print the record, and log it (with `dry_run` appended) unless it is a dry-run delete.
    fn act(&mut self, action: &str, p: &str, kind: &str, reason: &str, kw: Vec<(&'static str, Val)>) -> Result<(), Stop> {
        let mut rec = Rec(vec![
            ("ts", Val::I(self.ts)),
            ("action", Val::S(action.into())),
            ("kind", Val::S(kind.into())),
            ("path", Val::S(p.into())),
            ("reason", Val::S(reason.into())),
        ]);
        let mut kb = 0;
        for (k, v) in kw {
            if let ("kb", Val::I(n)) = (k, &v) {
                kb = *n;
            }
            rec.0.push((k, v));
        }
        match action {
            "delete" => {
                self.deleted += 1;
                self.freed_kb += kb;
            }
            "error" => self.errors += 1,
            _ => {}
        }
        let line = rec.to_py_json();
        if !self.o.dry_run || action != "delete" {
            append_log(&self.o.log, &rec.with("dry_run", Val::B(self.o.dry_run))).map_err(Stop::Log)?;
        }
        let _ = writeln!(self.out, "{line}");
        Ok(())
    }

    /// Delete a directory tree (nothing in a dry run). A failure is an `error` record and false.
    fn remove(&mut self, p: &Path, kind: &str, sid: &str) -> Result<bool, Stop> {
        if self.o.dry_run {
            return Ok(true);
        }
        match std::fs::remove_dir_all(p) {
            Ok(()) => Ok(true),
            Err(e) => {
                let why = format!("{:?}: {e}", e.kind());
                self.act("error", &p.to_string_lossy(), kind, &why, vec![("session", Val::S(sid.into()))])?;
                Ok(false)
            }
        }
    }
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn session(sid: &str) -> (&'static str, Val) {
    ("session", Val::S(sid.into()))
}

/// Returns 0, or 1 when any single removal failed (the others are still processed).
pub fn sweep(o: &Opts, out: &mut dyn Write) -> Result<i32, Abstain> {
    match sweep_inner(o, out) {
        Ok(rc) => Ok(rc),
        Err(Stop::Abstain(a)) => Err(a),
        Err(Stop::Log(e)) => {
            eprintln!("tally reap: cannot write {}: {e}", o.log);
            Ok(1)
        }
    }
}

fn sweep_inner(o: &Opts, out: &mut dyn Write) -> Result<i32, Stop> {
    let now = o.now.unwrap_or_else(super::now_secs);
    let root = Path::new(&o.root);
    let mut sessions: Vec<(String, PathBuf)> = vec![];
    let mut projs = listdir(root);
    projs.sort();
    for proj in &projs {
        let mut sids = listdir(&root.join(proj));
        sids.sort();
        for sid in sids {
            let sd = root.join(proj).join(&sid);
            let real_dir = std::fs::symlink_metadata(&sd).map(|m| m.is_dir() && !m.file_type().is_symlink());
            if is_uuid(&sid) && real_dir.unwrap_or(false) {
                sessions.push((sid, sd));
            }
        }
    }
    let status_text = match &o.status_json {
        Some(f) if f.is_empty() => String::new(),
        Some(f) => std::fs::read_to_string(f).unwrap_or_default(),
        None => Command::new("/usr/local/bin/tally")
            .args(["status", "--json"])
            .output()
            .ok()
            .filter(|r| r.status.success())
            .map(|r| String::from_utf8_lossy(&r.stdout).into_owned())
            .unwrap_or_default(),
    };
    let sids: Vec<String> = sessions.iter().map(|x| x.0.clone()).collect();
    let live = live_sessions(&status_text, Path::new(&o.projects), now, &sids);
    let (args, cwds) = proc_snapshot(o.proc_file.as_deref())?;
    let mut c = Ctx { o, ts: now as i64, out, deleted: 0, errors: 0, freed_kb: 0 };

    for (sid, sd) in &sessions {
        let is_live = live.as_ref().is_none_or(|l| l.contains(sid));
        let scratch = sd.join("scratchpad");
        let found = if scratch.is_dir() { targets(&scratch) } else { vec![] };
        for (p, _) in found.iter().filter(|t| t.1 == Kind::Dd) {
            let idle = if is_live { DD_IDLE_LIVE } else { DD_IDLE_DEAD };
            let la = if dd_root(p) { last_accessed(p) } else { None };
            if !inside(&o.root, p, 4)
                || la.is_none_or(|la| la > now - idle)
                || busy_since(p, now - idle)
                || referenced(&s(p), &args, &cwds, true)
            {
                continue;
            }
            let (kb, b) = (du_kb(p), born(p));
            if c.remove(p, "dd", sid)? {
                let kw = vec![("kb", Val::I(kb)), ("born", Val::I(b)), session(sid), ("live", Val::B(is_live))];
                c.act("delete", &s(p), "dd", "idle", kw)?;
            }
        }
        if live.is_none() || is_live {
            continue;
        }
        for (p, k) in found.iter().filter(|t| t.1 != Kind::Dd) {
            if !p.is_dir() || !inside(&o.root, p, 4) {
                continue;
            }
            if busy_since(p, now - TREE_IDLE) || referenced(&s(p), &args, &cwds, true) {
                continue;
            }
            if let Some(why) = tree_blocker(p, *k) {
                c.act("skip", &s(p), k.as_str(), why, vec![session(sid)])?;
                continue;
            }
            let (kb, b) = (du_kb(p), born(p));
            if *k == Kind::Worktree {
                let common = git::run(p, &["rev-parse", "--path-format=absolute", "--git-common-dir"], Duration::from_secs(60));
                let main = if common.code == 0 { Path::new(common.out.trim()).parent().map(Path::to_path_buf) } else { None };
                let Some(main) = main.filter(|m| !m.as_os_str().is_empty() && m.is_dir()) else {
                    c.act("skip", &s(p), k.as_str(), "main-repo-unknown", vec![session(sid)])?;
                    continue;
                };
                if !o.dry_run && git::worktree_remove(&main, &s(p), false).code != 0 {
                    c.act("skip", &s(p), k.as_str(), "worktree-remove-refused", vec![session(sid)])?;
                    continue;
                }
            } else if !c.remove(p, k.as_str(), sid)? {
                continue;
            }
            let kw = vec![("kb", Val::I(kb)), ("born", Val::I(b)), session(sid)];
            c.act("delete", &s(p), k.as_str(), "idle-clean", kw)?;
        }
        if !sd.is_dir() || !inside(&o.root, sd, 2) {
            continue;
        }
        let left = if scratch.is_dir() { targets(&scratch) } else { vec![] };
        if left.iter().any(|(q, k)| *k != Kind::Dd && q.is_dir()) {
            continue;
        }
        let sds = s(sd);
        if busy_since(sd, now - SESSION_IDLE) || referenced(&sds, &args, &cwds, false) {
            continue;
        }
        // C1: the DerivedData tier kept anything an argv names; a session delete must not take it along.
        if referenced(&sds, &args, &cwds, true) {
            c.act("skip", &sds, "session", "session-argv-referenced", vec![session(sid)])?;
            continue;
        }
        // C2: targets() is depth-limited and scratchpad-only; prove there is no git tree anywhere.
        match git_dir_anywhere(sd) {
            Ok(false) => {}
            Ok(true) => {
                c.act("skip", &sds, "session", "session-git-tree", vec![session(sid)])?;
                continue;
            }
            Err(()) => {
                c.act("skip", &sds, "session", "session-scan-error", vec![session(sid)])?;
                continue;
            }
        }
        let (kb, b) = (du_kb(sd), born(sd));
        if c.remove(sd, "session", sid)? {
            c.act("delete", &sds, "session", "idle-72h", vec![("kb", Val::I(kb)), ("born", Val::I(b)), session(sid)])?;
        }
    }

    let sizes = sizes_kb(&o.root);
    let run = Rec(vec![
        ("ts", Val::I(c.ts)),
        ("action", Val::S("run".into())),
        ("dry_run", Val::B(o.dry_run)),
        ("live_known", Val::B(live.is_some())),
        ("deleted", Val::I(c.deleted)),
        ("errors", Val::I(c.errors)),
        ("freed_kb", Val::I(c.freed_kb)),
        ("sizes_kb", Val::Raw(int_object(&sizes))),
    ]);
    append_log(&o.log, &run).map_err(Stop::Log)?;
    Ok(if c.errors > 0 { 1 } else { 0 })
}

/// `du -k -d 1 <root>`: one entry per top-level name, the root itself as `_total`. A name seen
/// twice keeps its first position and its last value, like a Python dict.
fn sizes_kb(root: &str) -> Vec<(String, i64)> {
    let mut sizes: Vec<(String, i64)> = vec![];
    let Ok(r) = Command::new("/usr/bin/du").args(["-k", "-d", "1", root]).output() else { return sizes };
    for line in String::from_utf8_lossy(&r.stdout).lines() {
        let (kb, p) = line.split_once('\t').unwrap_or((line, ""));
        if kb.is_empty() || !kb.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let Ok(kb) = kb.parse::<i64>() else { continue };
        let key = if p == root { "_total".to_string() } else { p.rsplit('/').next().unwrap_or("").to_string() };
        match sizes.iter_mut().find(|e| e.0 == key) {
            Some(e) => e.1 = kb,
            None => sizes.push((key, kb)),
        }
    }
    sizes
}

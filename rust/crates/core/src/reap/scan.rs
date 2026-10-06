//! What a directory under the scratch root is, and whether anything in it moved recently.
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Dd,
    Worktree,
    Clone,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Dd => "dd",
            Kind::Worktree => "worktree",
            Kind::Clone => "clone",
        }
    }
}

fn plutil_raw(plist: &Path, key: &str, expect: Option<&str>) -> Option<String> {
    let mut c = Command::new("/usr/bin/plutil");
    c.args(["-extract", key, "raw"]);
    if let Some(t) = expect {
        c.args(["-expect", t]);
    }
    c.args(["-o", "-"]).arg(plist);
    let o = c.output().ok()?;
    if !o.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&o.stdout).trim_end().to_string())
}

/// A DerivedData root: Build/ is a directory AND info.plist is a dictionary with WorkspacePath.
/// Build/ is checked first only to spare a plutil spawn per ordinary directory; both are required.
pub fn dd_root(p: &Path) -> bool {
    if !p.join("Build").is_dir() {
        return false;
    }
    let plist = p.join("info.plist");
    if !plist.is_file() {
        return false;
    }
    plutil_raw(&plist, "WorkspacePath", None).is_some()
}

/// info.plist's LastAccessedDate as UTC seconds; None when absent or not a date.
pub fn last_accessed(p: &Path) -> Option<f64> {
    let raw = plutil_raw(&p.join("info.plist"), "LastAccessedDate", Some("date"))?;
    crate::iso::parse(raw.as_bytes()).map(|(s, ms)| s as f64 + f64::from(ms) / 1000.0)
}

pub fn kind(p: &Path) -> Option<Kind> {
    let m = fs::symlink_metadata(p).ok()?;
    if m.file_type().is_symlink() || !m.is_dir() {
        return None;
    }
    if dd_root(p) {
        return Some(Kind::Dd);
    }
    let gm = fs::symlink_metadata(p.join(".git")).ok()?;
    if gm.file_type().is_symlink() {
        return None;
    }
    if gm.is_file() {
        return Some(Kind::Worktree);
    }
    if gm.is_dir() {
        return Some(Kind::Clone);
    }
    None
}

/// Every DerivedData root, worktree and clone up to MAX_DEPTH below `scratch`. DerivedData roots
/// are leaves; worktrees and clones are searched too (in-tree build folders). LIFO like the
/// script, so the order things are removed in is the same when a clone contains a worktree.
pub fn targets(scratch: &Path) -> Vec<(PathBuf, Kind)> {
    let (mut out, mut stack) = (Vec::new(), vec![(scratch.to_path_buf(), 0usize)]);
    while let Some((d, depth)) = stack.pop() {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        let entries: Vec<_> = rd.filter_map(Result::ok).collect();
        for e in entries {
            let name = e.file_name();
            if name == ".git" || name == "node_modules" {
                continue;
            }
            let Ok(ft) = e.file_type() else { continue }; // does not follow symlinks
            if !ft.is_dir() {
                continue;
            }
            let p = e.path();
            let k = kind(&p);
            if let Some(k) = k {
                out.push((p.clone(), k));
            }
            if k != Some(Kind::Dd) && depth + 1 < super::MAX_DEPTH {
                stack.push((p, depth + 1));
            }
        }
    }
    out
}

/// True when any file under p (outside .git) was modified after `cutoff`, with os.walk's
/// semantics: a symlink to a directory is listed as a directory and neither descended nor
/// stat'ed; any other entry is a file judged by its lstat mtime; an unreadable directory anywhere
/// makes the answer true.
pub fn busy_since(p: &Path, cutoff: f64) -> bool {
    let mut stack = vec![p.to_path_buf()];
    let mut failed = false;
    while let Some(d) = stack.pop() {
        let rd = match fs::read_dir(&d) {
            Ok(r) => r,
            Err(_) => {
                failed = true;
                continue;
            }
        };
        for e in rd {
            let Ok(e) = e else {
                failed = true;
                continue;
            };
            let name = e.file_name();
            let path = e.path();
            let Ok(ft) = e.file_type() else {
                failed = true;
                continue;
            };
            if name == ".git" {
                continue;
            }
            let is_dir = if ft.is_symlink() {
                fs::metadata(&path).map(|m| m.is_dir()).unwrap_or(false)
            } else {
                ft.is_dir()
            };
            if is_dir {
                if !ft.is_symlink() {
                    stack.push(path);
                }
                continue;
            }
            match fs::symlink_metadata(&path) {
                Ok(m) => {
                    if super::fsutil::mtime_of(&m) > cutoff {
                        return true;
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(_) => return true,
            }
        }
    }
    failed
}

/// C2: any entry named `.git` (file, directory or symlink) anywhere under p, no depth limit,
/// symlinks not followed. Err when a directory cannot be read (absence cannot be proven).
pub fn git_dir_anywhere(p: &Path) -> Result<bool, ()> {
    let mut stack = vec![p.to_path_buf()];
    while let Some(d) = stack.pop() {
        let rd = fs::read_dir(&d).map_err(|_| ())?;
        for e in rd {
            let e = e.map_err(|_| ())?;
            if e.file_name() == ".git" {
                return Ok(true);
            }
            if e.file_type().map_err(|_| ())?.is_dir() {
                stack.push(e.path());
            }
        }
    }
    Ok(false)
}

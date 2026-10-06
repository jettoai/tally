//! Small filesystem helpers with the script's error behaviour (unreadable reads as empty or 0).
use std::fs::{self, Metadata};
use std::os::unix::fs::MetadataExt;
use std::path::Path;

pub fn mtime_of(m: &Metadata) -> f64 {
    m.mtime() as f64 + m.mtime_nsec() as f64 / 1e9
}

/// lstat mtime, 0 when unreadable.
pub fn mtime(p: &Path) -> f64 {
    fs::symlink_metadata(p).map(|m| mtime_of(&m)).unwrap_or(0.0)
}

/// Entry names, empty on error. Unsorted; callers sort where the order matters.
pub fn listdir(p: &Path) -> Vec<String> {
    fs::read_dir(p)
        .map(|rd| rd.filter_map(Result::ok).map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default()
}

/// p resolves to at least `min_extra` levels below the resolved root and is not itself a symlink.
pub fn inside(root: &str, p: &Path, min_extra: usize) -> bool {
    let rr = tally_sys::fs::realpath_or_same(root);
    let rp = tally_sys::fs::realpath_or_same(&p.to_string_lossy());
    let is_link = fs::symlink_metadata(p).map(|m| m.file_type().is_symlink()).unwrap_or(false);
    rp.starts_with(&format!("{rr}/"))
        && rp.matches('/').count().saturating_sub(rr.matches('/').count()) >= min_extra
        && !is_link
}

/// `du -sk`, -1 when its output does not parse.
pub fn du_kb(p: &Path) -> i64 {
    std::process::Command::new("/usr/bin/du")
        .arg("-sk")
        .arg(p)
        .output()
        .ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).split_whitespace().next().and_then(|s| s.parse().ok()))
        .unwrap_or(-1)
}

/// lstat birth time in whole seconds, 0 when unreadable.
pub fn born(p: &Path) -> i64 {
    fs::symlink_metadata(p)
        .ok()
        .and_then(|m| m.created().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

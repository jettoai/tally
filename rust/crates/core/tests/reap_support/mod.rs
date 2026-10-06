//! Fixtures for the `tally reap` tests: a fresh scratch root per case under /private/tmp (so the
//! /tmp alias of a path really differs from it), a projects folder, a status file and a process
//! snapshot standing in for tally, ps and lsof. Nothing outside the case directory is touched.
#![allow(dead_code)]

use serde_json::Value;
use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use tally_core::reap::{run, Opts};

static N: AtomicUsize = AtomicUsize::new(0);

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64()
}

/// `YYYY-MM-DDTHH:MM:SSZ` for a UTC epoch second (civil_from_days).
pub fn fmt_utc(epoch: i64) -> String {
    let (days, secs) = (epoch.div_euclid(86_400), epoch.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", secs / 3600, secs % 3600 / 60, secs % 60)
}

#[repr(C)]
struct Timespec {
    tv_sec: i64,
    tv_nsec: i64,
}

extern "C" {
    fn utimensat(fd: i32, path: *const std::ffi::c_char, times: *const Timespec, flag: i32) -> i32;
}

/// Set the mtime of p and everything under it to `hours` ago, symlinks not followed.
pub fn age(p: &Path, hours: f64) {
    let m = std::fs::symlink_metadata(p).unwrap();
    if m.is_dir() {
        for e in std::fs::read_dir(p).unwrap() {
            age(&e.unwrap().path(), hours);
        }
    }
    let t = now() - hours * 3600.0;
    let ts = || Timespec { tv_sec: t.floor() as i64, tv_nsec: ((t - t.floor()) * 1e9) as i64 };
    let c = CString::new(p.to_str().unwrap()).unwrap();
    // AT_FDCWD = -2, AT_SYMLINK_NOFOLLOW = 0x20 on macOS; atime and mtime both set to t.
    let both = [ts(), ts()];
    assert_eq!(unsafe { utimensat(-2, c.as_ptr(), both.as_ptr(), 0x20) }, 0, "utimensat {}", p.display());
}

pub fn git(cwd: &Path, a: &[&str]) {
    let mut args = vec![
        "-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main",
        "-c", "advice.detachedHead=false", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false",
    ];
    args.extend_from_slice(a);
    let o = Command::new("/usr/bin/git").args(&args).current_dir(cwd).output().unwrap();
    assert!(o.status.success(), "git {a:?}: {}", String::from_utf8_lossy(&o.stderr));
}

pub struct Case {
    pub dir: PathBuf,
    pub root: PathBuf,
    pub projects: PathBuf,
    pub log: PathBuf,
    pub status: PathBuf,
    pub proc_file: PathBuf,
    pub sid: String,
    pub sd: PathBuf,
    pub sp: PathBuf,
}

impl Drop for Case {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Case {
    pub fn new() -> Case {
        let (pid, n) = (std::process::id(), N.fetch_add(1, Ordering::SeqCst));
        let dir = PathBuf::from(format!("/private/tmp/tally-reap-test-{pid}-{n}"));
        let _ = std::fs::remove_dir_all(&dir);
        let root = dir.join("root");
        let sid = format!("{:08x}-0000-4000-8000-{:012x}", pid, n);
        let sd = root.join("-proj").join(&sid);
        let sp = sd.join("scratchpad");
        let projects = dir.join("projects");
        std::fs::create_dir_all(&sp).unwrap();
        std::fs::create_dir_all(projects.join("-proj")).unwrap();
        std::fs::create_dir_all(sd.join("tasks")).unwrap();
        std::fs::write(sd.join("tasks/fresh.output"), "").unwrap();
        let c = Case {
            log: dir.join("log.jsonl"),
            status: dir.join("status.json"),
            proc_file: dir.join("proc.txt"),
            dir, root, projects, sid, sd, sp,
        };
        c.set_status("", 0, false);
        c.set_proc("argv:/sbin/launchd\ncwd:/\n");
        c
    }

    /// tally's view: `live` online (or only "other" when empty), generated `age_secs` ago.
    pub fn set_status(&self, live: &str, age_secs: i64, stale: bool) {
        let gen = fmt_utc(now() as i64 - age_secs);
        let id = if live.is_empty() { "other" } else { live };
        let v = serde_json::json!({"generatedAt": gen, "stale": stale, "sessions": [{"transcriptSessionID": id}]});
        std::fs::write(&self.status, v.to_string()).unwrap();
    }

    pub fn tally_unavailable(&self) {
        std::fs::write(&self.status, "").unwrap();
    }

    pub fn set_proc(&self, text: &str) {
        std::fs::write(&self.proc_file, text).unwrap();
    }

    /// A DerivedData root at p: files idle `file_h` hours, LastAccessedDate `la_h` hours ago.
    pub fn dd(&self, p: &Path, file_h: f64, la_h: f64, with_workspace: bool) {
        std::fs::create_dir_all(p.join("Build/Products")).unwrap();
        std::fs::write(p.join("Build/Products/a.o"), "bin").unwrap();
        let la = fmt_utc((now() - la_h * 3600.0) as i64);
        let ws = if with_workspace { "<key>WorkspacePath</key><string>/x/Tally.xcodeproj</string>" } else { "" };
        let plist = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \
             \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>\
             <key>LastAccessedDate</key><date>{la}</date>{ws}</dict></plist>\n"
        );
        std::fs::write(p.join("info.plist"), plist).unwrap();
        age(p, file_h);
    }

    /// A worktree at `path`, detached on the one commit of `main` (created if missing).
    pub fn wt(&self, main: &Path, path: &Path) {
        if !main.join(".git").is_dir() {
            std::fs::create_dir_all(main).unwrap();
            git(main, &["init", "-q"]);
            git(main, &["commit", "-q", "--allow-empty", "-m", "x"]);
        }
        git(main, &["worktree", "add", "-q", "--detach", path.to_str().unwrap()]);
    }

    pub fn opts(&self, dry_run: bool) -> Opts {
        Opts {
            root: self.root.to_string_lossy().into_owned(),
            projects: self.projects.to_string_lossy().into_owned(),
            log: self.log.to_string_lossy().into_owned(),
            status_json: Some(self.status.to_string_lossy().into_owned()),
            proc_file: Some(self.proc_file.to_string_lossy().into_owned()),
            dry_run,
            report: false,
            project: None,
            now: None,
        }
    }

    /// (exit code, stdout).
    pub fn run(&self, dry_run: bool) -> (i32, String) {
        let mut buf = Vec::new();
        let rc = run(&self.opts(dry_run), &mut buf);
        (rc, String::from_utf8(buf).unwrap())
    }

    pub fn log_lines(&self) -> Vec<Value> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect()
    }

    fn has(&self, f: impl Fn(&Value) -> bool) -> bool {
        self.log_lines().iter().any(f)
    }

    pub fn assert_gone(&self, label: &str, rc: i32, p: &Path, kind: &str, reason: &str) {
        let ps = p.to_str().unwrap();
        let logged = self.has(|r| {
            r["action"] == "delete" && r["path"] == ps && r["kind"] == kind && r["reason"] == reason
                && r["dry_run"] == false && r["kb"].is_number()
        });
        assert!(rc == 0 && !p.exists() && logged, "{label}: rc={rc} exists={} log={:?}", p.exists(), self.log_lines());
    }

    pub fn assert_kept(&self, label: &str, rc: i32, p: &Path, skip: Option<&str>) {
        let ps = p.to_str().unwrap();
        let skip_ok = skip.is_none_or(|why| self.has(|r| r["action"] == "skip" && r["path"] == ps && r["reason"] == why));
        let ran = self.has(|r| r["action"] == "run");
        let deleted = self.has(|r| r["action"] == "delete" && r["path"] == ps);
        assert!(
            rc == 0 && p.exists() && skip_ok && ran && !deleted,
            "{label}: rc={rc} exists={} want-skip={skip:?} log={:?}",
            p.exists(),
            self.log_lines()
        );
    }

    /// The main repo no longer lists `wt` and has no prunable entry left.
    pub fn assert_wt_unlisted(&self, label: &str, main: &Path, wt: &Path) {
        let o = Command::new("/usr/bin/git").args(["worktree", "list", "--porcelain"]).current_dir(main).output().unwrap();
        let text = String::from_utf8_lossy(&o.stdout);
        let listed = text.contains(wt.to_str().unwrap());
        let prunable = text.lines().any(|l| l.starts_with("prunable"));
        assert!(!listed && !prunable, "{label}: worktree list: {text}");
    }
}

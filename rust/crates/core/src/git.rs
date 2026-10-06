//! Running git from Rust. One place for the subprocess rules both the scratch reaper and the
//! Swift worktree teardown (TallyCLI/WorktreeRemoveGit.swift) rely on.
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const GIT: &str = "/usr/bin/git";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandResult {
    /// stdout trimmed at both ends (what TallyCLI's runGit hands its callers).
    pub out: String,
    pub err: String,
    /// The exit code; 127 when git could not be started or `cwd` is not a directory, 124 on timeout.
    pub code: i32,
}

/// Run `git <args>` in `cwd`. Never panics, never returns Err: every caller already treats a
/// non-zero code as "do not proceed". GIT_OPTIONAL_LOCKS=0 so read-only queries do not rewrite
/// .git/index (the reaper's idle signal ignores .git, but other tools watching it do not).
pub fn run(cwd: &Path, args: &[&str], timeout: Duration) -> CommandResult {
    if !cwd.is_dir() {
        return CommandResult {
            out: String::new(),
            err: format!("cannot run git: no such directory `{}`", cwd.display()),
            code: 127,
        };
    }
    let spawned = Command::new(GIT)
        .args(args)
        .current_dir(cwd)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let mut child = match spawned {
        Ok(c) => c,
        Err(e) => {
            return CommandResult { out: String::new(), err: format!("cannot run git: {e}"), code: 127 }
        }
    };
    // Drain both pipes on threads so a chatty git cannot block on a full pipe while we wait.
    let to = drain(child.stdout.take());
    let te = drain(child.stderr.take());
    let start = Instant::now();
    let code = loop {
        match child.try_wait() {
            Ok(Some(st)) => break st.code().unwrap_or(128),
            Ok(None) if start.elapsed() >= timeout => {
                let _ = child.kill();
                let _ = child.wait();
                break 124;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(_) => break 127,
        }
    };
    let out = to.join().unwrap_or_default();
    let err = te.join().unwrap_or_default();
    CommandResult { out: out.trim().to_string(), err: err.trim().to_string(), code }
}

fn drain<R: Read + Send + 'static>(pipe: Option<R>) -> std::thread::JoinHandle<String> {
    std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(mut p) = pipe {
            let _ = p.read_to_string(&mut s);
        }
        s
    })
}

/// `git worktree remove [--force] <path>` run in `main_repo`. The single implementation behind
/// `tally reap` and `tally worktree remove`.
pub fn worktree_remove(main_repo: &Path, path: &str, force: bool) -> CommandResult {
    let mut args = vec!["worktree", "remove"];
    if force {
        args.push("--force");
    }
    args.push(path);
    run(main_repo, &args, Duration::from_secs(60))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static N: AtomicUsize = AtomicUsize::new(0);

    struct Repo {
        dir: PathBuf,
    }
    impl Drop for Repo {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    fn git(cwd: &Path, a: &[&str]) {
        let mut args = vec!["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"];
        args.extend_from_slice(a);
        let st = Command::new(GIT).args(&args).current_dir(cwd).output().unwrap();
        assert!(st.status.success(), "git {a:?}: {}", String::from_utf8_lossy(&st.stderr));
    }

    /// A main repo with one commit and a detached worktree next to it.
    fn repo() -> (Repo, PathBuf, PathBuf) {
        let dir = std::env::temp_dir()
            .join(format!("tally-git-test-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
        let main = dir.join("main");
        let wt = dir.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        git(&main, &["init", "-q"]);
        git(&main, &["commit", "-q", "--allow-empty", "-m", "x"]);
        git(&main, &["worktree", "add", "-q", "--detach", wt.to_str().unwrap()]);
        (Repo { dir }, main, wt)
    }

    fn listed(main: &Path, wt: &Path) -> bool {
        let wt = std::fs::canonicalize(wt).unwrap_or_else(|_| wt.to_path_buf());
        let o = run(main, &["worktree", "list", "--porcelain"], Duration::from_secs(10));
        o.out.contains(wt.to_str().unwrap())
    }

    #[test]
    fn missing_cwd_is_127() {
        let o = run(Path::new("/nonexistent/tally/git/cwd"), &["status"], Duration::from_secs(5));
        assert_eq!(o.code, 127);
        assert!(o.err.contains("no such directory"));
    }

    #[test]
    fn removes_a_clean_worktree() {
        let (_r, main, wt) = repo();
        assert!(listed(&main, &wt));
        let o = worktree_remove(&main, wt.to_str().unwrap(), false);
        assert_eq!(o.code, 0, "{}", o.err);
        assert!(!wt.exists());
        assert!(!listed(&main, &wt));
    }

    #[test]
    fn refuses_a_dirty_worktree_without_force() {
        let (_r, main, wt) = repo();
        std::fs::write(wt.join("untracked.txt"), "x").unwrap();
        let o = worktree_remove(&main, wt.to_str().unwrap(), false);
        assert_ne!(o.code, 0);
        assert!(!o.err.is_empty());
        assert!(wt.join("untracked.txt").exists());
    }

    #[test]
    fn force_removes_a_dirty_worktree() {
        let (_r, main, wt) = repo();
        std::fs::write(wt.join("untracked.txt"), "x").unwrap();
        let o = worktree_remove(&main, wt.to_str().unwrap(), true);
        assert_eq!(o.code, 0, "{}", o.err);
        assert!(!wt.exists());
    }
}

//! The three keep rules `tally reap` adds to the Python reaper (review of 67403b3). Each case is
//! one the Python version deletes; the assertion names the new skip reason itself, not just "the
//! path is still there".
mod reap_support;

use reap_support::{age, git, Case};

fn skipped(c: &Case, p: &std::path::Path, kind: &str, reason: &str) -> bool {
    let ps = p.to_str().unwrap();
    c.log_lines().iter().any(|r| r["action"] == "skip" && r["path"] == ps && r["kind"] == kind && r["reason"] == reason)
}

#[test]
fn c1_session_kept_when_argv_names_a_dd_inside() {
    let c = Case::new();
    std::fs::remove_file(c.sd.join("tasks/fresh.output")).unwrap();
    let dd = c.sp.join("old-dd");
    c.dd(&dd, 80.0, 80.0, true);
    age(&c.sd, 73.0);
    c.set_proc(&format!("argv:xcodebuild -derivedDataPath {}\ncwd:/\n", dd.display()));
    let (rc, out) = c.run(false);
    assert!(
        rc == 0 && dd.is_dir() && c.sd.is_dir() && skipped(&c, &c.sd, "session", "session-argv-referenced"),
        "C1: rc={rc} out={out}"
    );
}

/// A session idle 73h holding a dirty worktree at `rel` (relative to the session directory).
fn case2(rel: &str) -> (Case, std::path::PathBuf) {
    let c = Case::new();
    std::fs::remove_file(c.sd.join("tasks/fresh.output")).unwrap();
    let repo = c.sd.join(rel);
    std::fs::create_dir_all(repo.parent().unwrap()).unwrap();
    c.wt(&c.dir.join("main"), &repo);
    std::fs::write(repo.join("untracked.txt"), "work").unwrap();
    age(&c.sd, 73.0);
    (c, repo)
}

#[test]
fn c2_session_kept_when_git_tree_outside_scan() {
    for rel in ["elsewhere/repo", "scratchpad/a/b/c/d/e/repo"] {
        let (c, repo) = case2(rel);
        let (rc, out) = c.run(false);
        assert!(
            rc == 0 && c.sd.is_dir() && repo.join("untracked.txt").is_file()
                && skipped(&c, &c.sd, "session", "session-git-tree"),
            "C2 {rel}: rc={rc} out={out}"
        );
    }
}

#[test]
fn c3_clone_with_tag_only_commit_kept() {
    let c = Case::new();
    let (main, cl) = (c.dir.join("main3"), c.sp.join("c3"));
    std::fs::create_dir_all(&main).unwrap();
    git(&main, &["init", "-q"]);
    git(&main, &["commit", "-q", "--allow-empty", "-m", "x"]);
    git(&c.dir, &["clone", "-q", main.to_str().unwrap(), cl.to_str().unwrap()]);
    git(&cl, &["checkout", "-q", "--detach"]);
    git(&cl, &["commit", "-q", "--allow-empty", "-m", "local"]);
    git(&cl, &["tag", "keep"]);
    git(&cl, &["checkout", "-q", "main"]);
    age(&cl, 25.0);
    let (rc, out) = c.run(false);
    assert!(rc == 0 && cl.is_dir() && skipped(&c, &cl, "clone", "unpushed-local-ref"), "C3: rc={rc} out={out}");
}

/// A clean, pushed clone idle 25h (origin ignores `nested/`).
fn pushed_clone(c: &Case) -> std::path::PathBuf {
    let (origin, cl) = (c.dir.join("origin"), c.sp.join("clone"));
    std::fs::create_dir_all(&origin).unwrap();
    git(&origin, &["init", "-q"]);
    std::fs::write(origin.join(".gitignore"), "nested/\n").unwrap();
    git(&origin, &["add", "."]);
    git(&origin, &["commit", "-q", "-m", "base"]);
    git(&c.dir, &["clone", "-q", origin.to_str().unwrap(), cl.to_str().unwrap()]);
    cl
}

#[test]
fn c4_clone_with_ignored_nested_repo_kept() {
    let c = Case::new();
    let cl = pushed_clone(&c);
    let nested = cl.join("nested");
    std::fs::create_dir_all(&nested).unwrap();
    git(&nested, &["init", "-q"]);
    std::fs::write(nested.join("unique.txt"), "only copy").unwrap();
    git(&nested, &["add", "."]);
    git(&nested, &["commit", "-q", "-m", "unique"]);
    age(&cl, 25.0);
    let (rc, out) = c.run(false);
    assert!(
        rc == 0 && nested.join("unique.txt").is_file() && skipped(&c, &cl, "clone", "nested-repo"),
        "C4: rc={rc} out={out}"
    );
}

#[test]
fn c5_clone_backing_external_worktree_kept() {
    let c = Case::new();
    let cl = pushed_clone(&c);
    let ext = c.dir.join("external-wt");
    git(&cl, &["worktree", "add", "-q", "--detach", ext.to_str().unwrap()]);
    std::fs::write(ext.join("uncommitted.txt"), "active external work").unwrap();
    age(&cl, 25.0);
    c.set_proc(&format!("argv:/bin/zsh\ncwd:{}\n", ext.display()));
    let (rc, out) = c.run(false);
    assert!(rc == 0 && cl.is_dir() && skipped(&c, &cl, "clone", "linked-worktree"), "C5: rc={rc} out={out}");
}

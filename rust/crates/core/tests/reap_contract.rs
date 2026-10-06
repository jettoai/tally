//! The scratch reaper's contract (B-5700): the 29 labels of the Python version's section 110,
//! one test each, against `tally_core::reap`. Every "kept" case also asserts that the run wrote
//! its `run` record and no `delete` for the path, so a reaper that does nothing cannot pass it.
mod reap_support;

use reap_support::{age, git, Case};
use std::path::Path;

#[test]
fn t00_entry_runs_and_writes_run_record() {
    let c = Case::new();
    let (rc, _) = c.run(false);
    assert_eq!(rc, 0);
    assert!(c.log_lines().iter().any(|r| r["action"] == "run"), "sr:script-missing: {:?}", c.log_lines());
}

#[test]
fn t01_offline_idle_dd_deleted() {
    let c = Case::new();
    let p = c.sp.join("pk1-dd");
    c.dd(&p, 4.0, 4.0, true);
    let (rc, _) = c.run(false);
    c.assert_gone("sr:1-offline-idle-dd-deleted", rc, &p, "dd", "idle");
}

#[test]
fn t02_recent_file_kept() {
    let c = Case::new();
    let p = c.sp.join("pk2-dd");
    c.dd(&p, 4.0, 4.0, true);
    age(&p.join("Build/Products/a.o"), 600.0 / 3600.0);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:2-recent-file-kept", rc, &p, None);
}

fn tmp_alias(p: &Path) -> String {
    let s = p.to_str().unwrap();
    format!("/tmp/{}", s.strip_prefix("/private/tmp/").unwrap())
}

#[test]
fn t03a_fixture_alias_differs() {
    let c = Case::new();
    let p = c.sp.join("pk3-dd");
    assert_ne!(tmp_alias(&p), p.to_str().unwrap(), "sr:3-fixture-alias-not-different");
}

#[test]
fn t03b_argv_tmp_alias_kept() {
    let c = Case::new();
    let p = c.sp.join("pk3-dd");
    c.dd(&p, 4.0, 4.0, true);
    c.set_proc(&format!("argv:xcodebuild build -derivedDataPath {} -quiet\ncwd:/\n", tmp_alias(&p)));
    let (rc, _) = c.run(false);
    c.assert_kept("sr:3-argv-tmp-alias-kept", rc, &p, None);
}

#[test]
fn t04_lastaccessed_recent_kept() {
    let c = Case::new();
    let p = c.sp.join("pk4-dd");
    c.dd(&p, 4.0, 0.17, true);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:4-lastaccessed-recent-kept", rc, &p, None);
}

#[test]
fn t05a_live_4h_kept() {
    let c = Case::new();
    c.set_status(&c.sid, 0, false);
    let p = c.sp.join("pk5-dd");
    c.dd(&p, 4.0, 4.0, true);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:5a-live-4h-kept", rc, &p, None);
}

#[test]
fn t05b_live_7h_deleted() {
    let c = Case::new();
    c.set_status(&c.sid, 0, false);
    let p = c.sp.join("pk5b-dd");
    c.dd(&p, 7.0, 7.0, true);
    let (rc, _) = c.run(false);
    c.assert_gone("sr:5b-live-7h-deleted", rc, &p, "dd", "idle");
}

#[test]
fn t06a_clean_worktree_removed() {
    let c = Case::new();
    let (main, w) = (c.dir.join("main6"), c.sp.join("w6-pub"));
    c.wt(&main, &w);
    age(&w, 25.0);
    let (rc, _) = c.run(false);
    c.assert_gone("sr:6-clean-worktree-removed", rc, &w, "worktree", "idle-clean");
}

#[test]
fn t06b_main_repo_unlisted() {
    let c = Case::new();
    let (main, w) = (c.dir.join("main6"), c.sp.join("w6-pub"));
    c.wt(&main, &w);
    age(&w, 25.0);
    let (rc, _) = c.run(false);
    assert_eq!(rc, 0);
    c.assert_wt_unlisted("sr:6-main-unlisted", &main, &w);
}

#[test]
fn t07_dirty_skipped() {
    let c = Case::new();
    let w = c.sp.join("w7");
    c.wt(&c.dir.join("main7"), &w);
    std::fs::write(w.join("untracked.txt"), "x").unwrap();
    age(&w, 25.0);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:7-dirty-skipped", rc, &w, Some("dirty"));
}

#[test]
fn t08_head_not_on_ref_skipped() {
    let c = Case::new();
    let w = c.sp.join("w8");
    c.wt(&c.dir.join("main8"), &w);
    git(&w, &["commit", "-q", "--allow-empty", "-m", "orphan"]);
    age(&w, 25.0);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:8-head-not-on-ref-skipped", rc, &w, Some("head-not-on-ref"));
}

/// A worktree and a clone idle 25h whose .git internals were just refreshed.
fn case9() -> (Case, std::path::PathBuf, std::path::PathBuf) {
    let c = Case::new();
    let (main, w, cl) = (c.dir.join("main9"), c.sp.join("w9"), c.sp.join("c9"));
    c.wt(&main, &w);
    git(&c.dir, &["clone", "-q", main.to_str().unwrap(), cl.to_str().unwrap()]);
    age(&w, 25.0);
    age(&cl, 25.0);
    age(&w.join(".git"), 0.0);
    age(&cl.join(".git/index"), 0.0);
    (c, w, cl)
}

#[test]
fn t09a_worktree_gitfile_fresh_removed() {
    let (c, w, _) = case9();
    let (rc, _) = c.run(false);
    c.assert_gone("sr:9a-worktree-gitfile-fresh-removed", rc, &w, "worktree", "idle-clean");
}

#[test]
fn t09b_clone_gitindex_fresh_removed() {
    let (c, _, cl) = case9();
    let (rc, _) = c.run(false);
    c.assert_gone("sr:9b-clone-gitindex-fresh-removed", rc, &cl, "clone", "idle-clean");
}

/// tally unavailable: a 25h-idle worktree, a 4h dd and a 7h dd.
fn case10() -> (Case, std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
    let c = Case::new();
    c.tally_unavailable();
    let (w, a, b) = (c.sp.join("w10"), c.sp.join("a10-dd"), c.sp.join("b10-dd"));
    c.wt(&c.dir.join("main10"), &w);
    age(&w, 25.0);
    c.dd(&a, 4.0, 4.0, true);
    c.dd(&b, 7.0, 7.0, true);
    (c, w, a, b)
}

#[test]
fn t10a_no_tally_worktree_kept() {
    let (c, w, _, _) = case10();
    let (rc, _) = c.run(false);
    c.assert_kept("sr:10a-no-tally-worktree-kept", rc, &w, None);
}

#[test]
fn t10b_no_tally_dd4h_kept() {
    let (c, _, a, _) = case10();
    let (rc, _) = c.run(false);
    c.assert_kept("sr:10b-no-tally-dd4h-kept", rc, &a, None);
}

#[test]
fn t10c_no_tally_dd7h_deleted() {
    let (c, _, _, b) = case10();
    let (rc, _) = c.run(false);
    c.assert_gone("sr:10c-no-tally-dd7h-deleted", rc, &b, "dd", "idle");
}

/// A status that must not be trusted (stale, or generated `age_secs` ago).
fn case11(age_secs: i64, stale: bool) -> (Case, std::path::PathBuf, std::path::PathBuf) {
    let c = Case::new();
    c.set_status("", age_secs, stale);
    let (w, d) = (c.sp.join("w11"), c.sp.join("a11-dd"));
    c.wt(&c.dir.join("main11"), &w);
    age(&w, 25.0);
    c.dd(&d, 4.0, 4.0, true);
    (c, w, d)
}

#[test]
fn t11a_stale_worktree_kept() {
    let (c, w, _) = case11(0, true);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:11a-stale-worktree-kept", rc, &w, None);
}

#[test]
fn t11b_stale_dd4h_kept() {
    let (c, _, d) = case11(0, true);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:11b-stale-dd4h-kept", rc, &d, None);
}

#[test]
fn t11c_old_status_worktree_kept() {
    let (c, w, _) = case11(1200, false);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:11c-old-status-worktree-kept", rc, &w, None);
}

#[test]
fn t11d_old_status_dd4h_kept() {
    let (c, _, d) = case11(1200, false);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:11d-old-status-dd4h-kept", rc, &d, None);
}

#[test]
fn t12_empty_proc_abstains() {
    let c = Case::new();
    let p = c.sp.join("pk12-dd");
    c.dd(&p, 4.0, 4.0, true);
    c.set_proc("argv:/sbin/launchd\n");
    let (rc, _) = c.run(false);
    let last = c.log_lines().pop().unwrap_or_default();
    assert!(
        rc == 3 && p.is_dir() && last["action"] == "abstain" && last["reason"] == "process snapshot empty",
        "sr:12-empty-proc-abstain: rc={rc} last={last}"
    );
}

/// The dd is a symlink in the scratchpad pointing at a real DerivedData outside the root.
fn case13() -> (Case, std::path::PathBuf, std::path::PathBuf) {
    let c = Case::new();
    let (target, link) = (c.dir.join("outside13-dd"), c.sp.join("link13-dd"));
    c.dd(&target, 4.0, 4.0, true);
    std::os::unix::fs::symlink(&target, &link).unwrap();
    (c, target, link)
}

#[test]
fn t13a_symlink_target_intact() {
    let (c, target, link) = case13();
    let (rc, _) = c.run(false);
    assert!(
        rc == 0 && target.join("Build").is_dir() && link.symlink_metadata().unwrap().file_type().is_symlink(),
        "sr:13a-symlink-target-intact"
    );
}

#[test]
fn t13b_symlink_kept() {
    let (c, _, link) = case13();
    let (rc, _) = c.run(false);
    c.assert_kept("sr:13b-symlink-kept", rc, &link, None);
}

#[test]
fn t14_no_workspacepath_kept() {
    let c = Case::new();
    let p = c.sp.join("nows14");
    c.dd(&p, 4.0, 4.0, false);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:14-no-workspacepath-kept", rc, &p, None);
}

/// An offline session with nothing in it but one log file, everything idle `hours`.
fn case15(hours: f64) -> Case {
    let c = Case::new();
    std::fs::remove_file(c.sd.join("tasks/fresh.output")).unwrap();
    std::fs::write(c.sp.join("run.log"), "l").unwrap();
    age(&c.sd, hours);
    c
}

#[test]
fn t15a_session_73h_deleted() {
    let c = case15(73.0);
    let (rc, _) = c.run(false);
    c.assert_gone("sr:15a-session-73h-deleted", rc, &c.sd, "session", "idle-72h");
}

#[test]
fn t15b_session_71h_kept() {
    let c = case15(71.0);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:15b-session-71h-kept", rc, &c.sd, None);
}

#[test]
fn t16_subagent_transcript_live_kept() {
    let c = Case::new();
    let w = c.sp.join("w16");
    c.wt(&c.dir.join("main16"), &w);
    age(&w, 25.0);
    let sub = c.projects.join("-proj").join(&c.sid).join("subagents");
    std::fs::create_dir_all(&sub).unwrap();
    std::fs::write(sub.join("agent-x.jsonl"), "").unwrap();
    age(&sub.join("agent-x.jsonl"), 0.5);
    let (rc, _) = c.run(false);
    c.assert_kept("sr:16-subagent-transcript-live-kept", rc, &w, None);
}

#[test]
fn t17_dry_run_no_delete() {
    let c = Case::new();
    let p = c.sp.join("pk17-dd");
    c.dd(&p, 4.0, 4.0, true);
    let (rc, out) = c.run(true);
    let ps = p.to_str().unwrap();
    let printed = out.lines().filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok()).any(|r| {
        r["path"] == ps && r["action"] == "delete" && r["kind"] == "dd"
    });
    let log = c.log_lines();
    let dry_run_line = log.iter().any(|r| r["action"] == "run" && r["dry_run"] == true);
    let any_delete = log.iter().any(|r| r["action"] == "delete");
    assert!(
        rc == 0 && p.is_dir() && printed && dry_run_line && !any_delete,
        "sr:17-dry-run-no-delete: rc={rc} out={out}"
    );
}

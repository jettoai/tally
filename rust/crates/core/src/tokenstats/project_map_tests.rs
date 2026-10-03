use super::*;
use crate::tokenstats::{Origin, TestHost};

fn root(relative: &str, paths: &[&str]) -> Root {
    let paths: Vec<String> = paths.iter().map(|p| p.to_string()).collect();
    let munged = paths.iter().map(|p| swift_str::munged(p)).collect();
    Root { relative: relative.into(), paths, munged }
}

fn map(roots: Vec<Root>) -> ProjectMap {
    ProjectMap { home: "/Users/u".into(), home_components: vec!["Users".into(), "u".into()],
                 workspace: "/Users/u/workspace".into(), roots }
}

#[test]
fn an_equal_claim_goes_to_the_first_root() {
    // Two workspace entries linked onto one directory claim it equally; the first one listed wins.
    let m = map(vec![root("x", &["/Users/u/workspace/x", "/V/t"]), root("y", &["/Users/u/workspace/y", "/V/t"])]);
    assert_eq!(m.key_for_cwd(Some("/V/t/src")), "/Users/u/workspace/x");
}

#[test]
fn the_deepest_claim_wins_and_rules_place_the_rest() {
    let m = map(vec![root("mono", &["/Users/u/workspace/mono", "/V/work"]),
                     root("app", &["/Users/u/workspace/app", "/V/work/app"]),
                     root("specai", &["/Users/u/workspace/specai"])]);
    let k = |c: &str| m.key_for_cwd(Some(c));
    assert_eq!(k("/V/work/app/x"), "/Users/u/workspace/app");
    assert_eq!(k("/V/work/other"), "/Users/u/workspace/mono");
    assert_eq!(k("/V/workapp"), "");
    assert_eq!(k("/Users/u/workspace/app/scratchpad/x"), "");
    assert_eq!(k("/Users/u/.claude3/projects/-Users-u-workspace-specai/s/subagents"), "/Users/u/workspace/specai");
    assert_eq!(k("/Users/u/.claude/projects/-Users-u-workspace-specai-e2e/s"), "/Users/u/workspace/specai");
    assert_eq!(k("/Users/u/.claude/skills"), "/Users/u/.claude");
    assert_eq!(k("/Users/u/.codex2/x"), "/Users/u/.codex");
    assert_eq!(k("/Users/u/elsewhere"), "");
    assert_eq!(k("/tmp/x"), "");
    assert_eq!(m.key_for_cwd(None), "");
    assert_eq!(k(""), "");
    assert_eq!(map(vec![]).key_for_cwd(Some("/tmp/x")), "/tmp/x");
}

#[test]
fn builds_from_the_workspace_folding_worktrees() {
    let home = std::env::temp_dir().join(format!("tally-map-{}", std::process::id()));
    let h = home.to_string_lossy().into_owned();
    let w = format!("{h}/workspace");
    std::fs::create_dir_all(format!("{w}/main/.git/worktrees/wt")).unwrap();
    std::fs::create_dir_all(format!("{w}/wt")).unwrap();
    std::fs::write(format!("{w}/wt/.git"), format!("gitdir: {w}/main/.git/worktrees/wt\n")).unwrap();
    std::fs::create_dir_all(format!("{w}/org/app/.git")).unwrap();
    std::fs::create_dir_all(format!("{w}/org/notes")).unwrap();
    std::fs::create_dir_all(format!("{w}/.hidden/.git")).unwrap();

    let mut host = TestHost::at(0);
    host.origins = vec![
        Origin { repository: format!("{w}/main"), paths: vec!["/gone/wt".into()], purged: false },
        Origin { repository: format!("{w}/main"), paths: vec!["/gone/purged".into()], purged: true },
        Origin { repository: "/no/such/repo".into(), paths: vec!["/gone/other".into()], purged: false },
    ];
    let m = ProjectMap::build(&h, &host);
    let real_w = realpath_or_same(&w);
    let main = format!("{w}/main");
    assert_eq!(m.key_for_cwd(Some(&format!("{real_w}/wt/src"))), main);
    assert_eq!(m.key_for_cwd(Some("/gone/wt/x")), main);
    assert_eq!(m.key_for_cwd(Some("/gone/purged")), "");
    assert_eq!(m.key_for_cwd(Some("/gone/other")), "");
    assert_eq!(m.key_for_cwd(Some(&format!("{w}/org/app"))), format!("{w}/org/app"));
    assert_eq!(m.key_for_cwd(Some(&format!("{w}/org/notes"))), format!("{w}/org"));
    assert_eq!(m.key_for_cwd(Some(&format!("{w}/.hidden"))), "");
    assert_eq!(*host.recorded.borrow(), vec![LiveFold { worktree: format!("{w}/wt"), repository: main.clone() }]);
    std::fs::remove_dir_all(&home).unwrap();
}

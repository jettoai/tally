//! Which repository a checkout belongs to, read off the filesystem (never by running git): a
//! `.git` directory is its own identity; a `.git` file naming `<common>/worktrees/<id>` is a
//! linked worktree of `<common>`; a `.git` file naming anything else (a submodule, a
//! `--separate-git-dir` repository) is a main checkout identified by that directory.
//! See TokenProjectMap.swift `checkoutGit` for the reasoning behind each layout.

use super::swift_str;
use tally_sys::fs::realpath_or_same;

pub struct CheckoutGit {
    /// The repository's common git directory, resolved.
    pub common: String,
    pub is_linked_worktree: bool,
}

/// `nil` when the directory is not a checkout or says nothing understood (fail-open: the
/// directory stays a project of its own).
pub fn checkout_git(directory: &str) -> Option<CheckoutGit> {
    let dot_git = format!("{directory}/.git");
    let meta = std::fs::metadata(&dot_git).ok()?;
    if meta.is_dir() {
        return Some(CheckoutGit { common: realpath_or_same(&dot_git), is_linked_worktree: false });
    }
    let contents = String::from_utf8(std::fs::read(&dot_git).ok()?).ok()?;
    let marker = "gitdir:";
    let line = swift_str::split_nonempty(&contents, "\n")
        .into_iter()
        .find(|l| swift_str::has_prefix(l, marker))?;
    let recorded = swift_str::trim_whitespace(&line[marker.len()..]).to_string();
    if recorded.is_empty() {
        return None;
    }
    let git_dir = if swift_str::has_prefix(&recorded, "/") { recorded } else { format!("{directory}/{recorded}") };

    let parts = swift_str::split_nonempty(&git_dir, "/");
    if parts.len() >= 3 && swift_str::eq(&parts[parts.len() - 2], "worktrees") {
        let common = format!("/{}", parts[..parts.len() - 2].join("/"));
        return Some(CheckoutGit { common: realpath_or_same(&common), is_linked_worktree: true });
    }
    Some(CheckoutGit { common: realpath_or_same(&git_dir), is_linked_worktree: false })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_three_layouts() {
        let root = std::env::temp_dir().join(format!("tally-git-{}", std::process::id()));
        let base = root.to_string_lossy().into_owned();
        std::fs::create_dir_all(format!("{base}/main/.git/worktrees/wt")).unwrap();
        std::fs::create_dir_all(format!("{base}/wt")).unwrap();
        std::fs::create_dir_all(format!("{base}/sub")).unwrap();
        std::fs::create_dir_all(format!("{base}/crlf")).unwrap();
        std::fs::write(format!("{base}/wt/.git"), format!("gitdir: {base}/main/.git/worktrees/wt\n")).unwrap();
        std::fs::write(format!("{base}/sub/.git"), "gitdir: ../main/.git\n").unwrap();
        // CRLF is one Character, so the whole file is one line; the path keeps a trailing "\r\n" on
        // its last component and still reads as a linked worktree.
        std::fs::write(format!("{base}/crlf/.git"), format!("gitdir: {base}/main/.git/worktrees/wt\r\n")).unwrap();

        let real = realpath_or_same(&base);
        let main = checkout_git(&format!("{base}/main")).unwrap();
        assert_eq!((main.common.as_str(), main.is_linked_worktree), (format!("{real}/main/.git").as_str(), false));
        let wt = checkout_git(&format!("{base}/wt")).unwrap();
        assert_eq!((wt.common.as_str(), wt.is_linked_worktree), (format!("{real}/main/.git").as_str(), true));
        let sub = checkout_git(&format!("{base}/sub")).unwrap();
        assert_eq!((sub.common.as_str(), sub.is_linked_worktree), (format!("{real}/main/.git").as_str(), false));
        let crlf = checkout_git(&format!("{base}/crlf")).unwrap();
        assert_eq!((crlf.common.as_str(), crlf.is_linked_worktree), (format!("{real}/main/.git").as_str(), true));
        assert!(checkout_git(&base).is_none());
        std::fs::remove_dir_all(&root).unwrap();
    }
}

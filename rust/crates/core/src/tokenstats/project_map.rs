//! Which project row a session's working directory belongs to. Ported from TokenProjectMap.swift,
//! whose header explains the rules; in short:
//!
//! Attribution is an allow-list read from `~/workspace` once per scan: a folder there is a project
//! when it is a checkout, and a container's checkouts are projects of their own. A git worktree is
//! folded into the repository it was cut from, live ones by their `.git` file and torn-down ones by
//! the note left in the worktree ledger (`Host::load_worktree_origins`), and the scan writes a note
//! for every live worktree it folds (`Host::record_live_worktrees`), because a worktree removed by
//! hand never runs the teardown that would have written one. Everything else pools into Other.
//!
//! Any change to which project owns a directory has to bump the cache version (engine.rs).
//! Paths are compared with Swift `String` semantics (swift_str.rs) so non-ASCII directories land on
//! the rows the Swift engine gave them.

use std::collections::{HashMap, HashSet};

use super::project_git::checkout_git;
use super::swift_str::{self, char_count, has_prefix, split_nonempty};
use super::{Host, LiveFold, OTHER_KEY};
use tally_sys::fs::{is_hidden, realpath_or_same};

const WORKSPACE_FOLDER: &str = "workspace";
const CLAUDE_FOLDER: &str = ".claude";
const CODEX_FOLDER: &str = ".codex";

struct Root {
    relative: String,
    /// Every absolute path the project answers to (its own, its resolved one, its worktrees').
    paths: Vec<String>,
    /// The same paths in Claude Code's transcript-folder spelling.
    munged: Vec<String>,
}

impl Root {
    /// The length of the longest of this project's paths that contains `cwd`.
    fn claim(&self, cwd: &str) -> Option<usize> {
        self.paths.iter()
            .filter(|p| swift_str::eq(cwd, p) || has_prefix(cwd, &format!("{p}/")))
            .map(|p| char_count(p))
            .max()
    }

    /// The same for an agent's own transcript folder, where separators were flattened to dashes.
    fn claim_folder(&self, folder: &str) -> Option<usize> {
        self.munged.iter()
            .filter(|m| swift_str::eq(folder, m) || has_prefix(folder, &format!("{m}-")))
            .map(|m| char_count(m))
            .max()
    }
}

pub struct ProjectMap {
    home: String,
    home_components: Vec<String>,
    workspace: String,
    roots: Vec<Root>,
}

impl ProjectMap {
    pub fn build(home: &str, host: &dyn Host) -> ProjectMap {
        let workspace = format!("{home}/{WORKSPACE_FOLDER}");

        let mut relatives = vec![];
        for child in directories(&workspace) {
            relatives.push(child.clone());
            let child_path = format!("{workspace}/{child}");
            if is_checkout(&child_path) {
                continue;
            }
            for grandchild in directories(&child_path) {
                if is_checkout(&format!("{child_path}/{grandchild}")) {
                    relatives.push(format!("{child}/{grandchild}"));
                }
            }
        }

        let mut candidates: Vec<(String, Vec<String>)> = relatives.into_iter().map(|relative| {
            let absolute = format!("{workspace}/{relative}");
            let resolved = realpath_or_same(&absolute);
            let paths = if swift_str::eq(&resolved, &absolute) { vec![absolute] } else { vec![absolute, resolved] };
            (relative, paths)
        }).collect();
        // Later candidates overwrite earlier ones, as Swift's dictionary assignment did.
        let mut candidate_of_path: HashMap<String, usize> = HashMap::new();
        for (index, (_, paths)) in candidates.iter().enumerate() {
            for path in paths {
                candidate_of_path.insert(swift_str::key(path), index);
            }
        }

        // Fold every live worktree into the main checkout sharing its common git directory.
        let gits: Vec<_> = candidates.iter().map(|(_, paths)| checkout_git(&paths[0])).collect();
        let mut main_of_common: HashMap<String, usize> = HashMap::new();
        for (index, git) in gits.iter().enumerate() {
            if let Some(git) = git {
                if !git.is_linked_worktree {
                    main_of_common.entry(swift_str::key(&git.common)).or_insert(index);
                }
            }
        }
        let mut folded = HashSet::new();
        let mut live = vec![];
        for (index, git) in gits.iter().enumerate() {
            let Some(git) = git else { continue };
            if !git.is_linked_worktree {
                continue;
            }
            let Some(&target) = main_of_common.get(&swift_str::key(&git.common)) else { continue };
            if target == index {
                continue;
            }
            live.push(LiveFold { worktree: candidates[index].1[0].clone(), repository: candidates[target].1[0].clone() });
            let moved = candidates[index].1.clone();
            candidates[target].1.extend(moved);
            folded.insert(index);
        }

        // Torn-down worktrees, from the ledger. Read after the filesystem, as the Swift scan did.
        for origin in host.load_worktree_origins() {
            if origin.purged {
                continue;
            }
            let target = candidate_of_path.get(&swift_str::key(&origin.repository))
                .or_else(|| candidate_of_path.get(&swift_str::key(&realpath_or_same(&origin.repository))));
            let Some(&target) = target else { continue };
            if folded.contains(&target) {
                continue;
            }
            let known: HashSet<String> = candidates[target].1.iter().map(|p| swift_str::key(p)).collect();
            let added: Vec<String> = origin.paths.into_iter().filter(|p| !known.contains(&swift_str::key(p))).collect();
            candidates[target].1.extend(added);
        }

        host.record_live_worktrees(live);

        let roots = candidates.into_iter().enumerate()
            .filter(|(index, _)| !folded.contains(index))
            .map(|(_, (relative, paths))| {
                let munged = paths.iter().map(|p| swift_str::munged(p)).collect();
                Root { relative, paths, munged }
            })
            .collect();
        ProjectMap { home: home.to_string(), home_components: split_nonempty(home, "/"), workspace, roots }
    }

    /// The project key for a working directory: a project's root spelled through the workspace
    /// folder, a config-home row, or `OTHER_KEY`.
    pub fn key_for_cwd(&self, cwd: Option<&str>) -> String {
        let Some(cwd) = cwd else { return OTHER_KEY.to_string() };
        // Scratch directories are throwaway wherever they sit.
        if cwd.is_empty() || cwd.contains("scratchpad") {
            return OTHER_KEY.to_string();
        }
        if let Some(root) = self.best_root(|r| r.claim(cwd)) {
            return self.key_of(root);
        }

        let parts = split_nonempty(cwd, "/");
        let n = self.home_components.len();
        if !(parts.len() > n && parts[..n].iter().zip(&self.home_components).all(|(a, b)| swift_str::eq(a, b))) {
            return self.unplaced(cwd);
        }
        let rest = &parts[n..];
        let head = &rest[0];
        if has_prefix(head, CLAUDE_FOLDER) {
            // Agents run inside the transcript tree of the project they serve.
            if rest.len() > 2 && swift_str::eq(&rest[1], "projects") {
                if let Some(root) = self.best_root(|r| r.claim_folder(&rest[2])) {
                    return self.key_of(root);
                }
            }
            return format!("{}/{CLAUDE_FOLDER}", self.home);
        }
        if has_prefix(head, CODEX_FOLDER) {
            return format!("{}/{CODEX_FOLDER}", self.home);
        }
        self.unplaced(cwd)
    }

    /// The most specific claim; on a tie the FIRST root wins (Swift's `max(by:)` only replaces
    /// on strictly greater, unlike `Iterator::max_by_key`).
    fn best_root(&self, claim: impl Fn(&Root) -> Option<usize>) -> Option<&Root> {
        let mut best: Option<(&Root, usize)> = None;
        for root in &self.roots {
            if let Some(length) = claim(root) {
                if best.is_none_or(|(_, b)| length > b) {
                    best = Some((root, length));
                }
            }
        }
        best.map(|(root, _)| root)
    }

    fn key_of(&self, root: &Root) -> String {
        format!("{}/{}", self.workspace, root.relative)
    }

    /// With no workspace folder at all, a directory stays its own project.
    fn unplaced(&self, cwd: &str) -> String {
        if self.roots.is_empty() { cwd.to_string() } else { OTHER_KEY.to_string() }
    }
}

/// Non-hidden entries that are directories, following symlinks, in readdir order.
fn directories(path: &str) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(path) else { return vec![] };
    entries.filter_map(|e| {
        let e = e.ok()?;
        let name = e.file_name();
        if is_hidden(&name, &e.metadata().ok()?) || !std::fs::metadata(e.path()).ok()?.is_dir() {
            return None;
        }
        Some(name.to_string_lossy().into_owned())
    }).collect()
}

fn is_checkout(path: &str) -> bool {
    std::path::Path::new(&format!("{path}/.git")).exists()
}

#[cfg(test)]
#[path = "project_map_tests.rs"]
mod tests;

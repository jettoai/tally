//! Token usage statistics: reads the local Claude and Codex transcripts into per (day, project,
//! provider) token totals, with a per-file cache so only what changed is read twice. Ported from
//! the Swift engine (Tally/Core/TokenStats) rule for rule; the Swift side keeps only the types the
//! UI draws and a host for the three things that stay native (`Host`).
//!
//! Integer overflow is the one deliberate difference: Swift traps (the app dies) where this
//! parses an over-long number as absent and adds with wrapping.

pub mod day;
pub mod engine;
pub mod heatmap;
pub mod json_scan;
pub mod parser;
pub mod project_map;
mod project_git;
pub mod sources;
pub mod summary;
pub mod swift_str;

use serde::{Deserialize, Serialize};

/// The pooled project row: directories that are not projects, and sessions with no directory.
pub const OTHER_KEY: &str = "";

/// The four token classes, kept apart (see Tally/Core/TokenStats/TokenTotals.swift).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Totals {
    pub input: i64,
    pub cache_write: i64,
    pub cache_read: i64,
    pub output: i64,
}

impl Totals {
    pub fn total(&self) -> i64 {
        self.input.wrapping_add(self.cache_write).wrapping_add(self.cache_read).wrapping_add(self.output)
    }

    pub fn is_empty(&self) -> bool {
        self.total() == 0
    }

    pub fn add(&mut self, other: &Totals) {
        self.input = self.input.wrapping_add(other.input);
        self.cache_write = self.cache_write.wrapping_add(other.cache_write);
        self.cache_read = self.cache_read.wrapping_add(other.cache_read);
        self.output = self.output.wrapping_add(other.output);
    }

    /// Raises every column to the higher of the two values and reports what that added: a turn
    /// restated while it streams counts as the highest value each column reached.
    pub fn raise(&mut self, peak: &Totals) -> Totals {
        let added = Totals {
            input: (peak.input - self.input).max(0),
            cache_write: (peak.cache_write - self.cache_write).max(0),
            cache_read: (peak.cache_read - self.cache_read).max(0),
            output: (peak.output - self.output).max(0),
        };
        self.add(&added);
        added
    }
}

/// One file's cell: a local day and one project. The grain the cache is written at.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Bucket {
    pub day: i64,
    pub project: String,
    pub totals: Totals,
}

/// A merged cell, with the provider that produced it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sample {
    pub day: i64,
    pub project: String,
    pub provider_id: String,
    pub totals: Totals,
}

/// A torn-down worktree's note (Tally/Core/WorktreeOrigins.swift): the repository it was cut
/// from and every spelling of its directory.
#[derive(Clone, Debug)]
pub struct Origin {
    pub repository: String,
    pub paths: Vec<String>,
    pub purged: bool,
}

/// A live worktree the project map folded into its repository, to be written down.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LiveFold {
    pub worktree: String,
    pub repository: String,
}

/// What the platform provides: the zone offset (so day boundaries agree with the platform's own
/// time zone database), and the worktree ledger the CLI shares with the app.
pub trait Host {
    fn seconds_from_gmt(&self, epoch_seconds: i64) -> i32;
    fn load_worktree_origins(&self) -> Vec<Origin>;
    fn record_live_worktrees(&self, folds: Vec<LiveFold>);
}

/// A fixed-offset host for the unit tests, with a ledger to read and a record of what was written.
#[cfg(test)]
pub(crate) struct TestHost {
    pub offset: i32,
    pub origins: Vec<Origin>,
    pub recorded: std::cell::RefCell<Vec<LiveFold>>,
}

#[cfg(test)]
impl TestHost {
    pub fn at(offset: i32) -> Self {
        TestHost { offset, origins: vec![], recorded: Default::default() }
    }
}

#[cfg(test)]
impl Host for TestHost {
    fn seconds_from_gmt(&self, _: i64) -> i32 {
        self.offset
    }
    fn load_worktree_origins(&self) -> Vec<Origin> {
        self.origins.clone()
    }
    fn record_live_worktrees(&self, folds: Vec<LiveFold>) {
        self.recorded.borrow_mut().extend(folds);
    }
}

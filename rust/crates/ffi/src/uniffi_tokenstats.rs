//! UniFFI surface of the token statistics (tally_core::tokenstats) for the app's Tokens tab.
//! The Swift side (Tally/Core/TokenStats) keeps its types and calls these; the bindings are
//! generated into rust/generated/swift by scripts/gen-uniffi.sh.
//!
//! `token_stats_file_buckets`, `files_seen`/`files_reparsed` and `token_stats_swift_str_probe`
//! have no app caller: they exist for tests/run-tokenstats-tests.sh and the per-file
//! reconciliation against the Swift engine this replaced.

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

use tally_core::tokenstats::{
    cost, engine, heatmap, parser, pricing::CostParts, project_map::ProjectMap, sources, summary,
    swift_str, Host, LiveFold, Origin, Sample, Totals,
};

#[derive(uniffi::Record)]
pub struct FfiTotals {
    pub input: i64,
    pub cache_write: i64,
    pub cache_read: i64,
    pub output: i64,
    pub cache_write_1h: i64,
}

#[derive(uniffi::Record)]
pub struct FfiSample {
    pub day: i64,
    pub project: String,
    pub provider_id: String,
    pub totals: FfiTotals,
    pub model: String,
    pub subagent: bool,
    pub turns: i64,
}

#[derive(uniffi::Record)]
pub struct FfiCostParts {
    pub input: f64,
    pub cache_write: f64,
    pub cache_read: f64,
    pub output: f64,
}

#[derive(uniffi::Record)]
pub struct FfiModelCost {
    pub model: String,
    pub cost: f64,
}

#[derive(uniffi::Record)]
pub struct FfiCostProject {
    pub key: String,
    pub name: String,
    pub is_other: bool,
    pub cost: f64,
    pub share: f64,
    pub tokens: FfiTotals,
    pub main_cost: f64,
    pub subagent_cost: f64,
    pub previous_cost: Option<f64>,
    pub by_model: Vec<FfiModelCost>,
    pub series: Vec<f64>,
}

#[derive(uniffi::Record)]
pub struct FfiCostProvider {
    pub provider_id: String,
    pub cost: Option<f64>,
    pub tokens: FfiTotals,
}

#[derive(uniffi::Record)]
pub struct FfiCostSummary {
    pub parts: FfiCostParts,
    pub subagent_cost: f64,
    pub unpriced_turns: i64,
    pub providers: Vec<FfiCostProvider>,
    pub projects: Vec<FfiCostProject>,
    pub bar_days: i64,
}

#[derive(uniffi::Record)]
pub struct FfiBucket {
    pub day: i64,
    pub project: String,
    pub totals: FfiTotals,
}

#[derive(uniffi::Record)]
pub struct FfiSourceFile {
    pub path: String,
    pub provider: String,
    pub size: i64,
    pub modified: f64,
}

#[derive(uniffi::Record)]
pub struct FfiOrigin {
    pub repository: String,
    pub paths: Vec<String>,
    pub purged: bool,
}

#[derive(uniffi::Record)]
pub struct FfiLiveFold {
    pub worktree: String,
    pub repository: String,
}

#[derive(uniffi::Record)]
pub struct FfiScanInput {
    pub home: String,
    pub claude_homes: Vec<String>,
    pub codex_homes: Vec<String>,
    pub zone: String,
    pub cache_path: String,
}

#[derive(uniffi::Record)]
pub struct FfiScanOutcome {
    pub samples: Vec<FfiSample>,
    pub files_seen: u32,
    pub files_reparsed: u32,
}

#[derive(uniffi::Record)]
pub struct FfiProviderRow {
    pub provider_id: String,
    pub totals: FfiTotals,
    pub share: f64,
}

#[derive(uniffi::Record)]
pub struct FfiProjectRow {
    pub key: String,
    pub name: String,
    pub is_other: bool,
    pub totals: FfiTotals,
    pub share: f64,
}

#[derive(uniffi::Record)]
pub struct FfiSummary {
    pub totals: FfiTotals,
    pub providers: Vec<FfiProviderRow>,
    pub projects: Vec<FfiProjectRow>,
}

#[derive(uniffi::Record)]
pub struct FfiHeatmapCell {
    pub day: i64,
    pub column: i64,
    pub row: i64,
    pub total: i64,
    pub level: i64,
}

#[derive(Debug, uniffi::Error)]
pub enum TokenStatsError {
    Internal { message: String },
}

impl std::fmt::Display for TokenStatsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let TokenStatsError::Internal { message } = self;
        write!(f, "token stats scan failed: {message}")
    }
}

impl std::error::Error for TokenStatsError {}

/// What the app provides: its own time zone database, and the worktree ledger it shares with the
/// CLI (Tally/Core/WorktreeOrigins.swift).
#[uniffi::export(foreign)]
pub trait TokenStatsHost: Send + Sync {
    fn seconds_from_gmt(&self, epoch_seconds: i64) -> i32;
    fn load_worktree_origins(&self) -> Vec<FfiOrigin>;
    fn record_live_worktrees(&self, folds: Vec<FfiLiveFold>);
}

struct Bridge(Arc<dyn TokenStatsHost>);

impl Host for Bridge {
    fn seconds_from_gmt(&self, epoch_seconds: i64) -> i32 {
        self.0.seconds_from_gmt(epoch_seconds)
    }
    fn load_worktree_origins(&self) -> Vec<Origin> {
        self.0.load_worktree_origins().into_iter()
            .map(|o| Origin { repository: o.repository, paths: o.paths, purged: o.purged })
            .collect()
    }
    fn record_live_worktrees(&self, folds: Vec<LiveFold>) {
        self.0.record_live_worktrees(folds.into_iter()
            .map(|f| FfiLiveFold { worktree: f.worktree, repository: f.repository })
            .collect());
    }
}

/// The scanning engine with its in-memory cache; the app keeps one for its lifetime.
#[derive(uniffi::Object)]
pub struct TokenStatsCore {
    engine: engine::Engine,
}

#[uniffi::export]
impl TokenStatsCore {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(TokenStatsCore { engine: engine::Engine::default() })
    }

    pub fn scan(&self, input: FfiScanInput, host: Arc<dyn TokenStatsHost>) -> Result<FfiScanOutcome, TokenStatsError> {
        let input = engine::ScanInput {
            home: input.home,
            claude_homes: input.claude_homes,
            codex_homes: input.codex_homes,
            zone: input.zone,
            cache_path: input.cache_path,
        };
        let bridge = Bridge(host);
        let outcome = catch_unwind(AssertUnwindSafe(|| self.engine.scan(&input, &bridge)))
            .map_err(|_| TokenStatsError::Internal { message: "panic".into() })?;
        Ok(FfiScanOutcome {
            samples: outcome.samples.into_iter().map(sample_out).collect(),
            files_seen: outcome.files_seen,
            files_reparsed: outcome.files_reparsed,
        })
    }
}

/// One scan's project allow-list (immutable once built).
#[derive(uniffi::Object)]
pub struct TokenProjectMapCore {
    map: ProjectMap,
}

#[uniffi::export]
impl TokenProjectMapCore {
    #[uniffi::constructor]
    pub fn build(home: String, host: Arc<dyn TokenStatsHost>) -> Arc<Self> {
        Arc::new(TokenProjectMapCore { map: ProjectMap::build(&home, &Bridge(host)) })
    }

    pub fn key_for_cwd(&self, cwd: Option<String>) -> String {
        self.map.key_for_cwd(cwd.as_deref())
    }
}

fn totals_out(t: Totals) -> FfiTotals {
    FfiTotals { input: t.input, cache_write: t.cache_write, cache_read: t.cache_read, output: t.output,
                cache_write_1h: t.cache_write_1h }
}

fn totals_in(t: &FfiTotals) -> Totals {
    Totals { input: t.input, cache_write: t.cache_write, cache_read: t.cache_read, output: t.output,
             cache_write_1h: t.cache_write_1h }
}

fn sample_out(s: Sample) -> FfiSample {
    FfiSample { day: s.day, project: s.project, provider_id: s.provider_id, totals: totals_out(s.totals),
                model: s.model, subagent: s.subagent, turns: s.turns }
}

fn samples_in(samples: Vec<FfiSample>) -> Vec<Sample> {
    samples.into_iter()
        .map(|s| Sample { day: s.day, totals: totals_in(&s.totals), project: s.project, provider_id: s.provider_id,
                          model: s.model, subagent: s.subagent, turns: s.turns })
        .collect()
}

fn parts_out(p: CostParts) -> FfiCostParts {
    FfiCostParts { input: p.input, cache_write: p.cache_write, cache_read: p.cache_read, output: p.output }
}

#[uniffi::export]
pub fn token_stats_sources(claude_homes: Vec<String>, codex_homes: Vec<String>) -> Vec<FfiSourceFile> {
    sources::list(&claude_homes, &codex_homes).into_iter()
        .map(|f| FfiSourceFile { path: f.path, provider: f.provider, size: f.size, modified: f.modified })
        .collect()
}

#[uniffi::export]
pub fn token_stats_file_buckets(path: String, provider: String, map: Arc<TokenProjectMapCore>,
                                host: Arc<dyn TokenStatsHost>) -> Vec<FfiBucket> {
    parser::buckets(&path, &provider, &map.map, &Bridge(host)).into_iter()
        .map(|b| FfiBucket { day: b.day, project: b.project, totals: totals_out(b.totals) })
        .collect()
}

#[uniffi::export]
pub fn token_stats_summarize(samples: Vec<FfiSample>, day_count: Option<u32>, today: i64,
                             provider_order: Vec<String>) -> FfiSummary {
    let s = summary::summarize(&samples_in(samples), day_count, today, &provider_order);
    FfiSummary {
        totals: totals_out(s.totals),
        providers: s.providers.into_iter()
            .map(|p| FfiProviderRow { provider_id: p.provider_id, totals: totals_out(p.totals), share: p.share })
            .collect(),
        projects: s.projects.into_iter()
            .map(|p| FfiProjectRow { key: p.key, name: p.name, is_other: p.is_other, totals: totals_out(p.totals), share: p.share })
            .collect(),
    }
}

/// The cost view's render input (tally_core::tokenstats::cost).
#[uniffi::export]
pub fn token_stats_summarize_cost(samples: Vec<FfiSample>, day_count: Option<u32>, today: i64,
                                  provider_order: Vec<String>) -> FfiCostSummary {
    let s = cost::summarize_cost(&samples_in(samples), day_count, today, &provider_order);
    FfiCostSummary {
        parts: parts_out(s.parts),
        subagent_cost: s.subagent_cost,
        unpriced_turns: s.unpriced_turns,
        providers: s.providers.into_iter()
            .map(|p| FfiCostProvider { provider_id: p.provider_id, cost: p.cost, tokens: totals_out(p.tokens) })
            .collect(),
        projects: s.projects.into_iter().map(|p| FfiCostProject {
            key: p.key, name: p.name, is_other: p.is_other, cost: p.cost, share: p.share,
            tokens: totals_out(p.tokens), main_cost: p.main_cost, subagent_cost: p.subagent_cost,
            previous_cost: p.previous_cost,
            by_model: p.by_model.into_iter().map(|m| FfiModelCost { model: m.model, cost: m.cost }).collect(),
            series: p.series,
        }).collect(),
        bar_days: s.bar_days,
    }
}

#[derive(uniffi::Record)]
pub struct FfiCostCell {
    pub day: i64,
    pub project: String,
    pub provider_id: String,
    pub model: String,
    pub subagent: bool,
    pub cost: Option<f64>,
    pub tokens: FfiTotals,
}

/// Every sample priced at the grain `~/.tally/project-cost.json` is written at (cost::cost_cells).
#[uniffi::export]
pub fn token_stats_cost_cells(samples: Vec<FfiSample>) -> Vec<FfiCostCell> {
    cost::cost_cells(&samples_in(samples)).into_iter()
        .map(|c| FfiCostCell { day: c.day, project: c.project, provider_id: c.provider_id, model: c.model,
                               subagent: c.subagent, cost: c.cost, tokens: totals_out(c.tokens) })
        .collect()
}

/// The row label each project key gets in the Tokens tab (summary::row_names), for a set of keys.
#[uniffi::export]
pub fn token_project_names(keys: Vec<String>) -> Vec<String> {
    summary::row_names(&keys.iter().map(String::as_str).collect::<Vec<_>>())
}

#[uniffi::export]
pub fn token_daily_totals(samples: Vec<FfiSample>, project: String) -> HashMap<i64, i64> {
    heatmap::daily_totals(&samples_in(samples), &project)
}

#[uniffi::export]
pub fn token_local_day(epoch_seconds: i64, offset_seconds: i32) -> i64 {
    tally_core::tokenstats::day::local_day(epoch_seconds, i64::from(offset_seconds))
}

#[uniffi::export]
pub fn heatmap_week_columns() -> i64 {
    heatmap::WEEK_COLUMNS
}

#[uniffi::export]
pub fn heatmap_weekdays() -> i64 {
    heatmap::WEEKDAYS
}

#[uniffi::export]
pub fn heatmap_weekday_index(day: i64) -> i64 {
    heatmap::weekday_index(day)
}

#[uniffi::export]
pub fn heatmap_window_start(today: i64) -> i64 {
    heatmap::window_start(today)
}

#[uniffi::export]
pub fn heatmap_cells(daily_totals: HashMap<i64, i64>, today: i64) -> Vec<FfiHeatmapCell> {
    heatmap::cells(&daily_totals, today).into_iter()
        .map(|c| FfiHeatmapCell { day: c.day, column: c.column, row: c.row, total: c.total, level: c.level })
        .collect()
}

#[uniffi::export]
pub fn heatmap_thresholds(values: Vec<i64>) -> Vec<i64> {
    heatmap::thresholds(values)
}

#[uniffi::export]
pub fn heatmap_level(total: i64, thresholds: Vec<i64>) -> i64 {
    heatmap::level(total, &thresholds)
}

#[uniffi::export]
pub fn heatmap_window_total(daily_totals: HashMap<i64, i64>, today: i64) -> i64 {
    heatmap::window_total(&daily_totals, today)
}

/// The Swift `String` rules the project map relies on, one at a time, so the suite can compare
/// them with Swift's own answers (eq, has_prefix, count, split, trim, munged).
#[uniffi::export]
pub fn token_stats_swift_str_probe(op: String, a: String, b: String) -> String {
    match op.as_str() {
        "eq" => swift_str::eq(&a, &b).to_string(),
        "has_prefix" => swift_str::has_prefix(&a, &b).to_string(),
        "count" => swift_str::char_count(&a).to_string(),
        "split" => swift_str::split_nonempty(&a, &b).join("\u{1}"),
        "trim" => swift_str::trim_whitespace(&a).to_string(),
        "munged" => swift_str::munged(&a),
        _ => String::new(),
    }
}

//! The cost view's render input for one range: what each project's tokens cost at list prices
//! (pricing.rs), split by model, by main loop against subagents, and over time. Projects are keyed
//! in NFC like the Tokens tab, ranked by cost, then tokens, then key; the tail past
//! `PROJECT_ROW_LIMIT` and the unattributed sessions pool into Other. Only priced tokens reach the
//! project rows: a provider with no price (Codex) keeps its own row with no cost, and turns on a
//! model the table does not know are counted rather than silently treated as free.

use std::collections::HashMap;

use super::pricing::{self, CostParts};
use super::summary::{nfc, row_names, PROJECT_ROW_LIMIT};
use super::{Sample, Totals, OTHER_KEY};

/// How many weekly bars the whole-history range draws.
pub const ALL_RANGE_WEEKS: i64 = 12;

pub struct ModelCost {
    /// The price table key, e.g. `claude-opus-5-5`.
    pub model: String,
    pub cost: f64,
}

pub struct CostProject {
    pub key: String,
    /// Empty for the Other row, whose label is localized by the caller.
    pub name: String,
    pub is_other: bool,
    pub cost: f64,
    /// Share of the range's total cost, 0...1.
    pub share: f64,
    /// The priced tokens behind `cost`.
    pub tokens: Totals,
    pub main_cost: f64,
    pub subagent_cost: f64,
    /// The same project over the window of equal length just before this one; None for the whole
    /// history and the Other row.
    pub previous_cost: Option<f64>,
    /// Most expensive first.
    pub by_model: Vec<ModelCost>,
    /// Cost per bar, oldest first: one bar a day, or a week for the whole history.
    pub series: Vec<f64>,
}

pub struct CostProvider {
    pub provider_id: String,
    /// None: this provider's models have no price.
    pub cost: Option<f64>,
    pub tokens: Totals,
}

pub struct CostSummary {
    pub parts: CostParts,
    pub subagent_cost: f64,
    /// Turns on a model of a priced provider that the price table does not know.
    pub unpriced_turns: i64,
    pub providers: Vec<CostProvider>,
    pub projects: Vec<CostProject>,
    /// Days per bar of every row's `series`.
    pub bar_days: i64,
}

impl CostSummary {
    pub fn total(&self) -> f64 {
        self.parts.total()
    }
}

#[derive(Default)]
struct Acc {
    cost: f64,
    tokens: Totals,
    main: f64,
    sub: f64,
    models: HashMap<&'static str, f64>,
    series: Vec<f64>,
}

impl Acc {
    fn add(&mut self, model: &'static str, cost: f64, tokens: &Totals, subagent: bool, bar: Option<usize>, bars: usize) {
        self.cost += cost;
        self.tokens.add(tokens);
        if subagent { self.sub += cost } else { self.main += cost }
        *self.models.entry(model).or_default() += cost;
        if self.series.len() != bars {
            self.series = vec![0.0; bars];
        }
        if let Some(i) = bar {
            self.series[i] += cost;
        }
    }

    fn merge(&mut self, o: &Acc) {
        self.cost += o.cost;
        self.tokens.add(&o.tokens);
        self.main += o.main;
        self.sub += o.sub;
        for (m, c) in &o.models {
            *self.models.entry(m).or_default() += c;
        }
        if self.series.len() < o.series.len() {
            self.series.resize(o.series.len(), 0.0);
        }
        for (a, b) in self.series.iter_mut().zip(&o.series) {
            *a += b;
        }
    }
}

/// `day_count` None is the whole history; otherwise the window ending on `today`.
pub fn summarize_cost(samples: &[Sample], day_count: Option<u32>, today: i64, provider_order: &[String]) -> CostSummary {
    let (first_bar_day, bar_days, bars) = match day_count {
        Some(n) => (today - (i64::from(n) - 1), 1, n as usize),
        None => (today - (ALL_RANGE_WEEKS * 7 - 1), 7, ALL_RANGE_WEEKS as usize),
    };
    let earliest = day_count.map(|n| today - (i64::from(n) - 1));
    let previous = day_count.map(|n| (today - (2 * i64::from(n) - 1), today - i64::from(n)));

    let mut parts = CostParts::default();
    let (mut subagent_cost, mut unpriced_turns) = (0.0, 0i64);
    let mut providers: HashMap<&str, (Option<f64>, Totals)> = HashMap::new();
    let mut by_project: HashMap<String, Acc> = HashMap::new();
    let mut before: HashMap<String, f64> = HashMap::new();
    for s in samples {
        let priced = pricing::canon(&s.model).zip(pricing::cost(&s.model, &s.totals));
        if let (Some((lo, hi)), Some((_, c))) = (previous, priced) {
            if (lo..=hi).contains(&s.day) {
                *before.entry(nfc(&s.project)).or_default() += c.total();
            }
        }
        if earliest.is_some_and(|e| s.day < e) {
            continue;
        }
        let row = providers.entry(&s.provider_id).or_default();
        row.1.add(&s.totals);
        let Some((model, c)) = priced else {
            if s.provider_id == super::parser::CLAUDE {
                unpriced_turns += s.turns;
            }
            continue;
        };
        *row.0.get_or_insert(0.0) += c.total();
        parts.add(&c);
        if s.subagent {
            subagent_cost += c.total();
        }
        let bar = (s.day >= first_bar_day).then(|| ((s.day - first_bar_day) / bar_days) as usize);
        by_project.entry(nfc(&s.project)).or_default().add(model, c.total(), &s.totals, s.subagent, bar, bars);
    }
    let denominator = parts.total().max(f64::MIN_POSITIVE);

    let providers = provider_order.iter().filter_map(|p| {
        let (cost, tokens) = providers.get(p.as_str())?;
        Some(CostProvider { provider_id: p.clone(), cost: *cost, tokens: *tokens })
    }).collect();

    let mut pooled = by_project.remove(OTHER_KEY).unwrap_or_default();
    let mut ranked: Vec<(String, Acc)> = by_project.into_iter().collect();
    ranked.sort_by(|a, b| b.1.cost.total_cmp(&a.1.cost)
        .then(b.1.tokens.total().cmp(&a.1.tokens.total()))
        .then(a.0.cmp(&b.0)));
    for (_, acc) in ranked.iter().skip(PROJECT_ROW_LIMIT) {
        pooled.merge(acc);
    }
    ranked.truncate(PROJECT_ROW_LIMIT);

    let row = |key: String, name: String, is_other: bool, acc: &Acc, previous_cost: Option<f64>| {
        let mut by_model: Vec<ModelCost> = acc.models.iter()
            .map(|(m, c)| ModelCost { model: m.to_string(), cost: *c }).collect();
        by_model.sort_by(|a, b| b.cost.total_cmp(&a.cost).then(a.model.cmp(&b.model)));
        let mut series = acc.series.clone();
        series.resize(bars, 0.0);
        CostProject { key, name, is_other, cost: acc.cost, share: acc.cost / denominator, tokens: acc.tokens,
                      main_cost: acc.main, subagent_cost: acc.sub, previous_cost, by_model, series }
    };
    let names = row_names(&ranked.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>());
    let mut projects: Vec<CostProject> = ranked.iter().zip(names).map(|((key, acc), name)| {
        let prev = previous.map(|_| before.get(key).copied().unwrap_or(0.0));
        row(key.clone(), name, false, acc, prev)
    }).collect();
    if pooled.cost > 0.0 {
        projects.push(row(OTHER_KEY.to_string(), String::new(), true, &pooled, None));
    }
    CostSummary { parts, subagent_cost, unpriced_turns, providers, projects, bar_days }
}

/// One priced cell of `~/.tally/project-cost.json`: a local day, an NFC project key, a provider, a
/// model and a side. `model` is the price table key when the model is priced, otherwise the id as
/// the transcript wrote it; `cost` is None for an unpriced model (never 0).
pub struct CostCell {
    pub day: i64,
    pub project: String,
    pub provider_id: String,
    pub model: String,
    pub subagent: bool,
    pub cost: Option<f64>,
    pub tokens: Totals,
}

/// Every sample priced and merged per (day, NFC project, provider, model, side), in that order.
/// Pricing is linear in the tokens, so a merged cell costs what its parts did.
pub fn cost_cells(samples: &[Sample]) -> Vec<CostCell> {
    let mut cells: HashMap<(i64, String, String, String, bool), Totals> = HashMap::new();
    for s in samples {
        let model = pricing::canon(&s.model).map_or_else(|| s.model.clone(), str::to_string);
        cells.entry((s.day, nfc(&s.project), s.provider_id.clone(), model, s.subagent))
            .or_default().add(&s.totals);
    }
    let mut out: Vec<CostCell> = cells.into_iter()
        .map(|((day, project, provider_id, model, subagent), tokens)| CostCell {
            cost: pricing::cost(&model, &tokens).map(|c| c.total()),
            day, project, provider_id, model, subagent, tokens,
        })
        .collect();
    out.sort_by(|a, b| (a.day, &a.project, &a.provider_id, &a.model, a.subagent)
        .cmp(&(b.day, &b.project, &b.provider_id, &b.model, b.subagent)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(day: i64, project: &str, provider: &str, model: &str, output: i64, subagent: bool) -> Sample {
        Sample { day, project: project.into(), provider_id: provider.into(), model: model.into(), subagent,
                 turns: 1, totals: Totals { output, ..Default::default() } }
    }

    #[test]
    fn ranks_by_cost_not_tokens_and_splits_sides_models_and_days() {
        let order = vec!["claude".to_string(), "codex".to_string()];
        let samples = vec![
            // /w/cheap has more tokens but on the cheaper model.
            s(10, "/w/cheap", "claude", "claude-haiku-4-5", 1_000_000, false),   // $5
            s(10, "/w/dear", "claude", "claude-opus-5-5", 400_000, false),       // $8
            s(9, "/w/dear", "claude", "claude-fable-5-1", 100_000, true),        // $5
            s(3, "/w/dear", "claude", "claude-opus-5-5", 100_000, false),        // $2, previous window
            s(10, "/w/cheap", "codex", "gpt-6-astra", 9_000_000, false),         // unpriced provider
            s(10, "/w/dear", "claude", "claude-mystery-9", 5, false),            // unpriced model
            s(10, "", "claude", "claude-sonnet-5", 100_000, false),              // $1, Other
        ];
        let m = summarize_cost(&samples, Some(7), 10, &order);
        assert!((m.total() - 19.0).abs() < 1e-9);
        assert!((m.subagent_cost - 5.0).abs() < 1e-9);
        assert_eq!(m.unpriced_turns, 1);
        assert_eq!(m.providers.iter().map(|p| (p.provider_id.as_str(), p.cost.is_some())).collect::<Vec<_>>(),
                   [("claude", true), ("codex", false)]);
        let dear = &m.projects[0];
        assert_eq!((dear.name.as_str(), dear.by_model[0].model.as_str()), ("dear", "claude-opus-5-5"));
        assert!((dear.cost - 13.0).abs() < 1e-9 && (dear.subagent_cost - 5.0).abs() < 1e-9);
        assert_eq!(dear.previous_cost.map(|c| (c * 100.0).round()), Some(200.0));
        assert_eq!(dear.series.len(), 7);
        assert!((dear.series[5] - 5.0).abs() < 1e-9 && (dear.series[6] - 8.0).abs() < 1e-9);
        assert_eq!(m.projects[1].tokens.output, 1_000_000); // Codex tokens are not in the row
        assert!(m.projects[2].is_other);

        let all = summarize_cost(&samples, None, 10, &order);
        assert_eq!((all.bar_days, all.projects[0].series.len()), (7, ALL_RANGE_WEEKS as usize));
        assert!(all.projects[0].previous_cost.is_none());
    }

    #[test]
    fn cells_merge_in_nfc_and_price_like_the_summary() {
        let mut a = s(10, "/w/caf\u{e9}", "claude", "claude-opus-5-5-20260901", 400_000, false);
        let b = s(10, "/w/cafe\u{301}", "claude", "claude-opus-5-5", 100_000, false);
        a.turns = 2;
        let samples = vec![a, b, s(10, "/w/x", "codex", "gpt-6-astra", 9, false),
                           s(9, "/w/x", "claude", "claude-opus-5-5", 50_000, true)];
        let cells = cost_cells(&samples);
        assert_eq!(cells.len(), 3);
        assert_eq!((cells[0].day, cells[0].subagent, cells[0].cost.map(|c| (c * 100.0).round())), (9, true, Some(100.0)));
        let merged = &cells[1];
        assert_eq!((merged.project.as_str(), merged.model.as_str(), merged.tokens.output),
                   ("/w/caf\u{e9}", "claude-opus-5-5", 500_000));
        assert!((merged.cost.unwrap() - 10.0).abs() < 1e-9);
        assert_eq!((cells[2].model.as_str(), cells[2].cost), ("gpt-6-astra", None));
        let priced: f64 = cells.iter().filter_map(|c| c.cost).sum();
        assert!((priced - summarize_cost(&samples, None, 10, &[]).total()).abs() < 1e-9);
    }
}

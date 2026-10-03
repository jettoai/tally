//! The Tokens tab's render input for one range: totals, a row per provider, the top projects.
//! Ported from TokenStatsSummary.swift. Ranking is by total, then output, then (new: Swift left
//! exact ties in dictionary order, which differs per process) the key.

use std::collections::{HashMap, HashSet};

use super::{swift_str, Sample, Totals, OTHER_KEY};

/// How many projects get their own row before the tail is pooled into Other.
pub const PROJECT_ROW_LIMIT: usize = 15;

pub struct ProviderRow {
    pub provider_id: String,
    pub totals: Totals,
    pub share: f64,
}

pub struct ProjectRow {
    pub key: String,
    /// Empty for the Other row, whose label is localized by the caller.
    pub name: String,
    pub is_other: bool,
    pub totals: Totals,
    pub share: f64,
}

pub struct Summary {
    pub totals: Totals,
    pub providers: Vec<ProviderRow>,
    pub projects: Vec<ProjectRow>,
}

/// `day_count` None is the whole history; otherwise the window ending on `today`.
pub fn summarize(samples: &[Sample], day_count: Option<u32>, today: i64, provider_order: &[String]) -> Summary {
    let earliest = day_count.map(|n| today - (i64::from(n) - 1));
    let mut totals = Totals::default();
    let mut by_provider: HashMap<&str, Totals> = HashMap::new();
    let mut by_project: HashMap<&str, Totals> = HashMap::new();
    let mut ever_seen: HashSet<&str> = HashSet::new();
    for s in samples {
        ever_seen.insert(&s.provider_id);
        if earliest.is_some_and(|e| s.day < e) {
            continue;
        }
        totals.add(&s.totals);
        by_provider.entry(&s.provider_id).or_default().add(&s.totals);
        by_project.entry(&s.project).or_default().add(&s.totals);
    }
    let denominator = totals.total().max(1) as f64;

    // Catalog order; a provider that ever recorded anything keeps its row in an empty window.
    let providers = provider_order.iter().filter(|p| ever_seen.contains(p.as_str())).map(|p| {
        let t = by_provider.get(p.as_str()).copied().unwrap_or_default();
        ProviderRow { provider_id: p.clone(), totals: t, share: t.total() as f64 / denominator }
    }).collect();

    let mut pooled = by_project.remove(OTHER_KEY).unwrap_or_default();
    let mut ranked: Vec<(&str, Totals)> = by_project.into_iter().collect();
    ranked.sort_by(|a, b| (b.1.total(), b.1.output).cmp(&(a.1.total(), a.1.output)).then(a.0.cmp(b.0)));
    for (_, t) in ranked.iter().skip(PROJECT_ROW_LIMIT) {
        pooled.add(t);
    }
    ranked.truncate(PROJECT_ROW_LIMIT);

    // Names that repeat are widened to two components.
    let names: Vec<String> = ranked.iter().map(|(k, _)| display_name(k, 1)).collect();
    let mut counts: HashMap<&str, usize> = HashMap::new();
    for n in &names {
        *counts.entry(n).or_default() += 1;
    }
    let mut projects: Vec<ProjectRow> = ranked.iter().zip(&names).map(|((key, t), name)| ProjectRow {
        key: key.to_string(),
        name: if counts[name.as_str()] > 1 { display_name(key, 2) } else { name.clone() },
        is_other: false,
        totals: *t,
        share: t.total() as f64 / denominator,
    }).collect();
    if !pooled.is_empty() {
        projects.push(ProjectRow {
            key: OTHER_KEY.to_string(),
            name: String::new(),
            is_other: true,
            totals: pooled,
            share: pooled.total() as f64 / denominator,
        });
    }
    Summary { totals, providers, projects }
}

/// The trailing `components` path components of a project key.
pub fn display_name(key: &str, components: usize) -> String {
    let parts = swift_str::split_nonempty(key, "/");
    let keep = components.max(1).min(parts.len());
    parts[parts.len() - keep..].join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(day: i64, project: &str, provider: &str, output: i64) -> Sample {
        Sample { day, project: project.into(), provider_id: provider.into(),
                 totals: Totals { output, ..Default::default() } }
    }

    #[test]
    fn ranks_pools_and_widens() {
        let order = vec!["claude".to_string(), "codex".to_string(), "gemini".to_string()];
        let mut samples: Vec<Sample> = (0..17).map(|i| s(10, &format!("/w/p{i:02}"), "claude", 100 + i)).collect();
        samples.push(s(10, "/w/a/src", "codex", 1000));
        samples.push(s(10, "/w/b/src", "codex", 999));
        samples.push(s(10, "", "codex", 5));
        samples.push(s(1, "/w/old", "codex", 7));
        let m = summarize(&samples, Some(7), 10, &order);
        assert_eq!(m.providers.iter().map(|p| p.provider_id.as_str()).collect::<Vec<_>>(), ["claude", "codex"]);
        assert_eq!(m.projects.len(), 16);
        assert_eq!((m.projects[0].name.as_str(), m.projects[1].name.as_str()), ("a/src", "b/src"));
        assert_eq!(m.projects[2].name, "p16");
        let other = m.projects.last().unwrap();
        // p00 to p03 fall off the top 15, plus the unattributed 5.
        assert!(other.is_other);
        assert_eq!(other.totals.output, 100 + 101 + 102 + 103 + 5);
        assert_eq!(m.totals.output, samples.iter().filter(|x| x.day >= 4).map(|x| x.totals.output).sum::<i64>());

        let empty = summarize(&samples, Some(1), 30, &order);
        assert_eq!(empty.providers.len(), 2);
        assert!(empty.projects.is_empty());
        assert_eq!(empty.providers[0].share, 0.0);
    }

    #[test]
    fn exact_ties_break_on_the_key() {
        let order = vec!["claude".to_string()];
        let samples = vec![s(1, "/w/b", "claude", 5), s(1, "/w/a", "claude", 5)];
        let m = summarize(&samples, None, 1, &order);
        assert_eq!(m.projects[0].key, "/w/a");
    }
}

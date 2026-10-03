//! A project's activity heatmap: which local day lands in which square, and how dark it is.
//! Ported from TokenActivityHeatmap.swift (the opacity table and date conversion stay in Swift).

use std::collections::HashMap;

use super::Sample;

/// Week columns drawn, the current week last (a year is 52 weeks and a day or two).
pub const WEEK_COLUMNS: i64 = 53;
pub const WEEKDAYS: i64 = 7;
/// Steps above the empty square.
const LEVELS: i64 = 4;

pub struct Cell {
    pub day: i64,
    pub column: i64,
    pub row: i64,
    pub total: i64,
    pub level: i64,
}

/// Monday-first (0 = Monday); day 0 was a Thursday. Safe for negative days.
pub fn weekday_index(day: i64) -> i64 {
    ((day + 3) % 7 + 7) % 7
}

/// The Monday of the leftmost column.
pub fn window_start(today: i64) -> i64 {
    today - weekday_index(today) - (WEEK_COLUMNS - 1) * WEEKDAYS
}

/// Every square, column-major; days after today are left out.
pub fn cells(daily_totals: &HashMap<i64, i64>, today: i64) -> Vec<Cell> {
    let start = window_start(today);
    // The scale comes from the days on screen only.
    let bounds = thresholds(daily_totals.iter()
        .filter(|(&d, &v)| d >= start && d <= today && v > 0)
        .map(|(_, &v)| v)
        .collect());
    let mut out = Vec::with_capacity((WEEK_COLUMNS * WEEKDAYS) as usize);
    for column in 0..WEEK_COLUMNS {
        let monday = start + column * WEEKDAYS;
        for row in 0..WEEKDAYS {
            let day = monday + row;
            if day > today {
                continue;
            }
            let total = daily_totals.get(&day).copied().unwrap_or(0);
            out.push(Cell { day, column, row, total, level: level(total, &bounds) });
        }
    }
    out
}

/// The p25 / p50 / p75 cuts of the active days (index rounded half away from zero, as Swift's
/// `.rounded()`).
pub fn thresholds(mut values: Vec<i64>) -> Vec<i64> {
    if values.is_empty() {
        return vec![0, 0, 0];
    }
    values.sort_unstable();
    let last = values.len() - 1;
    [0.25, 0.5, 0.75].iter().map(|q| {
        let index = ((last as f64) * q).round() as i64;
        values[index.clamp(0, last as i64) as usize]
    }).collect()
}

/// 0 for an empty day, else 1...4 by the cuts.
pub fn level(total: i64, thresholds: &[i64]) -> i64 {
    if total <= 0 {
        return 0;
    }
    if thresholds.len() != 3 {
        return LEVELS;
    }
    if total <= thresholds[0] {
        1
    } else if total <= thresholds[1] {
        2
    } else if total <= thresholds[2] {
        3
    } else {
        4
    }
}

/// The tokens inside the drawn window.
pub fn window_total(daily_totals: &HashMap<i64, i64>, today: i64) -> i64 {
    let start = window_start(today);
    daily_totals.iter().filter(|(&d, _)| d >= start && d <= today).fold(0i64, |s, (_, &v)| s.wrapping_add(v))
}

/// One project's tokens per local day, every provider merged.
pub fn daily_totals(samples: &[Sample], project: &str) -> HashMap<i64, i64> {
    let mut out = HashMap::new();
    for s in samples.iter().filter(|s| s.project == project) {
        let t = out.entry(s.day).or_insert(0i64);
        *t = t.wrapping_add(s.totals.total());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grid_arithmetic() {
        assert_eq!(weekday_index(0), 3);
        assert_eq!(weekday_index(4), 0);
        assert_eq!(weekday_index(-1), 2);
        assert_eq!(window_start(4), 4 - 52 * 7);
        assert_eq!(thresholds(vec![]), vec![0, 0, 0]);
        assert_eq!(thresholds(vec![4, 1, 3, 2]), vec![2, 3, 3]);
        assert_eq!(level(0, &[1, 2, 3]), 0);
        assert_eq!(level(5, &[1, 2, 3]), 4);
        assert_eq!(level(5, &[]), 4);
        let today = 20_000;
        let d: HashMap<i64, i64> = [(today, 10), (today - 400, 99), (today + 1, 7)].into();
        let c = cells(&d, today);
        assert_eq!(c.len() as i64, 52 * 7 + weekday_index(today) + 1);
        assert_eq!(c.last().unwrap().total, 10);
        assert_eq!(window_total(&d, today), 10);
    }
}

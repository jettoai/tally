//! What a cell of tokens cost, at Anthropic's list prices. The table, the per-model cache read
//! multipliers and the cache write multipliers are a copy of `PRICE`, `CACHE_READ_MULT_BY_MODEL`
//! and `CACHE_CREATE_*_MULT` in the maintainer's era-compare.py (lines 587-609 there); that file is
//! the source of truth and the two are changed together. A model not in the table (every Codex
//! model among them: no local price list is trusted for those) has no price, which callers count
//! and show rather than treat as free.

use super::Totals;

/// (model id prefix, input $/M, output $/M, cache read multiplier of input).
const PRICES: &[(&str, f64, f64, f64)] = &[
    ("claude-fable-5", 10.0, 50.0, 0.1),
    ("claude-fable-5-1", 10.0, 50.0, 0.025),
    ("claude-opus-5", 5.0, 25.0, 0.1),
    ("claude-opus-5-5", 4.0, 20.0, 0.05),
    ("claude-opus-4-8", 5.0, 25.0, 0.1),
    ("claude-sonnet-5", 2.0, 10.0, 0.1),
    ("claude-haiku-4-5", 1.0, 5.0, 0.1),
];
const CACHE_WRITE_5M_MULT: f64 = 1.25;
const CACHE_WRITE_1H_MULT: f64 = 2.0;

/// The table key a model id prices as: the LONGEST key it starts with, because two keys are
/// prefixes of each other (claude-fable-5 and claude-fable-5-1 differ fourfold on cache reads),
/// and dated ids (`claude-opus-5-5-20260901`) must still find theirs.
pub fn canon(model: &str) -> Option<&'static str> {
    PRICES.iter().map(|p| p.0).filter(|k| model.starts_with(k)).max_by_key(|k| k.len())
}

/// A cost split by token class, in US dollars.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CostParts {
    pub input: f64,
    pub cache_write: f64,
    pub cache_read: f64,
    pub output: f64,
}

impl CostParts {
    pub fn total(&self) -> f64 {
        self.input + self.cache_write + self.cache_read + self.output
    }

    pub fn add(&mut self, o: &CostParts) {
        self.input += o.input;
        self.cache_write += o.cache_write;
        self.cache_read += o.cache_read;
        self.output += o.output;
    }
}

/// The cost of `t` on `model`, or None when the model has no price. The 1 hour part of the cache
/// write is priced at 2x input and the rest at 1.25x (era-compare's `msg_cost`).
pub fn cost(model: &str, t: &Totals) -> Option<CostParts> {
    let key = canon(model)?;
    let &(_, input, output, read_mult) = PRICES.iter().find(|p| p.0 == key)?;
    let one_hour = t.cache_write_1h.min(t.cache_write);
    let five_min = t.cache_write - one_hour;
    let per = |tokens: f64, rate: f64| tokens * rate / 1e6;
    Some(CostParts {
        input: per(t.input as f64, input),
        cache_write: per(five_min as f64 * CACHE_WRITE_5M_MULT + one_hour as f64 * CACHE_WRITE_1H_MULT, input),
        cache_read: per(t.cache_read as f64 * read_mult, input),
        output: per(t.output as f64, output),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(input: i64, cw: i64, cw1h: i64, cr: i64, output: i64) -> Totals {
        Totals { input, cache_write: cw, cache_read: cr, output, cache_write_1h: cw1h }
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    /// Expected values worked by hand from era-compare's `msg_cost` formula.
    #[test]
    fn matches_era_compare_msg_cost() {
        // Opus 5.5: 1000*4 + (100*1.25 + 200*2)*4 + 10000*4*0.05 + 500*20 = 18100 / 1e6.
        let c = cost("claude-opus-5-5", &t(1000, 300, 200, 10_000, 500)).unwrap();
        assert!(close(c.total(), 0.0181), "{c:?}");
        // Fable 5.1 dated id, cache read at 0.025x: 1e6*10*0.025 = 0.25.
        assert!(close(cost("claude-fable-5-1-20260901", &t(0, 0, 0, 1_000_000, 0)).unwrap().total(), 0.25));
        // Fable 5 (the shorter key) at 0.1x: 1.0.
        assert!(close(cost("claude-fable-5", &t(0, 0, 0, 1_000_000, 0)).unwrap().total(), 1.0));
        // Sonnet 5, flat cache write only (no nested split): 1e6*1.25*2 + 1e6*10 = 12.5.
        assert!(close(cost("claude-sonnet-5", &t(0, 1_000_000, 0, 0, 1_000_000)).unwrap().total(), 12.5));
        // Haiku 4.5: 2e6*1 + 1e6*5 = 7.
        let h = cost("claude-haiku-4-5-20251001", &t(2_000_000, 0, 0, 0, 1_000_000)).unwrap();
        assert!(close(h.input, 2.0) && close(h.output, 5.0));
    }

    #[test]
    fn unknown_models_have_no_price() {
        assert_eq!(canon("claude-opus-5-5-x"), Some("claude-opus-5-5"));
        assert_eq!(canon("claude-opus-5"), Some("claude-opus-5"));
        assert!(cost("gpt-6-astra", &Totals::default()).is_none());
        assert!(cost("<synthetic>", &Totals::default()).is_none());
        assert!(cost("", &Totals::default()).is_none());
    }
}

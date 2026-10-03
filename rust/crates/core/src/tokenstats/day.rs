//! UTC transcript timestamps to local calendar days (days since 1970-01-01), without a date
//! library: the zone offset is asked of the host once per distinct UTC hour per file.
//! Ported from `LocalDayStamper` (JSONScan.swift), including what it does not check.

use super::Host;

/// Seconds since the epoch for a `"yyyy-MM-ddTHH:mm:ss…Z"` value, quotes included. Only the
/// fixed-width prefix is read; separators are not checked, and only month and day are
/// range-checked (Feb 31 rolls into March, as in the Swift reader).
pub fn epoch_seconds(bytes: &[u8], range: std::ops::Range<usize>) -> Option<i64> {
    if range.len() < 21 {
        return None;
    }
    let start = range.start + 1;
    let digits = |offset: usize, count: usize| -> Option<i64> {
        let mut value = 0i64;
        for &c in &bytes[start + offset..start + offset + count] {
            if !c.is_ascii_digit() {
                return None;
            }
            value = value * 10 + i64::from(c - b'0');
        }
        Some(value)
    };
    let (year, month, day) = (digits(0, 4)?, digits(5, 2)?, digits(8, 2)?);
    let (hour, minute, second) = (digits(11, 2)?, digits(14, 2)?, digits(17, 2)?);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    Some(days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second)
}

/// Howard Hinnant's `days_from_civil`; `/` truncates like Swift's.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = year - i64::from(month <= 2);
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The local day for an epoch second at a known offset.
pub fn local_day(epoch_seconds: i64, offset_seconds: i64) -> i64 {
    ((epoch_seconds + offset_seconds) as f64 / 86_400.0).floor() as i64
}

/// One per file, like the Swift reader's: the cached offset is the one asked for the FIRST
/// timestamp seen in each UTC hour, which only differs from a fresh lookup in zones whose
/// transitions fall off the hour.
pub struct Stamper<'a> {
    host: &'a dyn Host,
    cached_hour: i64,
    cached_offset: i64,
}

impl<'a> Stamper<'a> {
    pub fn new(host: &'a dyn Host) -> Self {
        Stamper { host, cached_hour: i64::MIN, cached_offset: 0 }
    }

    pub fn day_from_iso(&mut self, bytes: &[u8], range: std::ops::Range<usize>) -> Option<i64> {
        epoch_seconds(bytes, range).map(|s| self.day_from_epoch(s))
    }

    pub fn day_from_epoch(&mut self, seconds: i64) -> i64 {
        let hour = (seconds as f64 / 3600.0).floor() as i64;
        if hour != self.cached_hour {
            self.cached_hour = hour;
            self.cached_offset = i64::from(self.host.seconds_from_gmt(seconds));
        }
        local_day(seconds, self.cached_offset)
    }
}

#[cfg(test)]
mod tests {
    use super::super::{LiveFold, Origin};
    use super::*;
    use std::cell::Cell;

    /// +08:00 before epoch 1000, +05:30 from it on; counts lookups.
    struct Zone {
        calls: Cell<u32>,
    }
    impl Host for Zone {
        fn seconds_from_gmt(&self, epoch: i64) -> i32 {
            self.calls.set(self.calls.get() + 1);
            if epoch < 1000 { 8 * 3600 } else { 5 * 3600 + 1800 }
        }
        fn load_worktree_origins(&self) -> Vec<Origin> { vec![] }
        fn record_live_worktrees(&self, _: Vec<LiveFold>) {}
    }

    fn q(s: &str) -> Option<i64> {
        let v = format!("\"{s}\"");
        epoch_seconds(v.as_bytes(), 0..v.len())
    }

    #[test]
    fn parses_the_fixed_prefix_only() {
        assert_eq!(q("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(q("2026-07-17T11:52:33.310Z"), Some(1_784_289_153));
        assert_eq!(q("1970-01-01X00:00:00Z"), Some(0));
        assert_eq!(q("2026-02-31T00:00:00Z"), q("2026-03-03T00:00:00Z"));
        assert_eq!(q("2026-13-01T00:00:00Z"), None);
        assert_eq!(q("2026-01-00T00:00:00Z"), None);
        assert_eq!(q("2026-01-01T0a:00:00Z"), None);
        assert_eq!(q("2026-01-01T00:00:0"), None);
        assert_eq!(q("0000-03-01T00:00:00Z"), Some(-719_468 * 86_400));
    }

    #[test]
    fn one_lookup_per_utc_hour_and_the_first_one_sticks() {
        let zone = Zone { calls: Cell::new(0) };
        let mut s = Stamper::new(&zone);
        // 999 and 1001 share UTC hour 0: the offset asked at 999 (+8h) is kept for 1001.
        assert_eq!(s.day_from_epoch(999), 0);
        assert_eq!(s.day_from_epoch(1001), local_day(1001, 8 * 3600));
        assert_eq!(zone.calls.get(), 1);
        assert_eq!(s.day_from_epoch(3600 * 20), local_day(3600 * 20, 5 * 3600 + 1800));
        assert_eq!(zone.calls.get(), 2);
        assert_eq!(local_day(-1, 0), -1);
    }
}

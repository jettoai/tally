//! The one stamp shape Claude Code writes, `YYYY-MM-DDTHH:MM:SS(.d{1,3})?Z`, parsed without a
//! formatter. Anything else (an offset, more fraction digits, a lower-case z, second 60, a day the
//! month does not have) is not answered here: the line reports the raw text and Swift parses it
//! with the same formatters it always used (`transcriptParseISO`).

/// Whole seconds since 1970 (UTC) and milliseconds, or None when the shape is not the strict one.
pub fn parse(s: &[u8]) -> Option<(i64, i32)> {
    if s.len() < 20 || s[s.len() - 1] != b'Z' {
        return None;
    }
    let num = |range: std::ops::Range<usize>| -> Option<i64> {
        let mut value = 0i64;
        for &b in &s[range] {
            if !b.is_ascii_digit() {
                return None;
            }
            value = value * 10 + i64::from(b - b'0');
        }
        Some(value)
    };
    if s[4] != b'-' || s[7] != b'-' || s[10] != b'T' || s[13] != b':' || s[16] != b':' {
        return None;
    }
    let (year, month, day) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (hour, minute, second) = (num(11..13)?, num(14..16)?, num(17..19)?);
    let millis = match s.len() {
        20 => 0,
        22..=24 if s[19] == b'.' => {
            let digits = s.len() - 21;
            num(20..20 + digits)? * [100, 10, 1][digits - 1]
        }
        _ => return None,
    };
    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
        return None;
    }
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let days = days_from_civil(year, month, day);
    Some((days * 86_400 + hour * 3_600 + minute * 60 + second, millis as i32))
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Days from 1970-01-01 (Howard Hinnant's days_from_civil).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn strict_shapes() {
        assert_eq!(parse(b"1970-01-01T00:00:00Z"), Some((0, 0)));
        assert_eq!(parse(b"2026-10-03T08:15:30Z"), Some((1_791_015_330, 0)));
        assert_eq!(parse(b"2026-10-03T08:15:30.5Z"), Some((1_791_015_330, 500)));
        assert_eq!(parse(b"2026-10-03T08:15:30.05Z"), Some((1_791_015_330, 50)));
        assert_eq!(parse(b"2026-10-03T08:15:30.123Z"), Some((1_791_015_330, 123)));
        assert_eq!(parse(b"2024-02-29T00:00:00Z"), Some((1_709_164_800, 0)));
        assert_eq!(parse(b"2000-03-01T00:00:00Z"), Some((951_868_800, 0)));
    }

    #[test]
    fn everything_else_is_raw() {
        for s in [
            &b"2025-02-29T00:00:00Z"[..],
            b"2024-02-30T00:00:00Z",
            b"1900-02-29T00:00:00Z",
            b"2026-13-01T00:00:00Z",
            b"2026-00-01T00:00:00Z",
            b"2026-01-00T00:00:00Z",
            b"2026-04-31T00:00:00Z",
            b"2026-01-01T24:00:00Z",
            b"2026-01-01T00:60:00Z",
            b"2026-01-01T00:00:60Z",
            b"2026-01-01T00:00:00.1234Z",
            b"2026-01-01T00:00:00.Z",
            b"2026-01-01T00:00:00+08:00",
            b"2026-01-01T00:00:00z",
            b"2026-01-01 00:00:00Z",
            b"2026-1-01T00:00:00Z",
            b"2026-01-01T00:00:0aZ",
            b"",
        ] {
            assert_eq!(parse(s), None, "{}", String::from_utf8_lossy(s));
        }
    }
}

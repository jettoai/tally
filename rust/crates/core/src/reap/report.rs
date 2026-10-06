//! `tally reap --report`: per day and project, the size at the first run of the day, the change
//! from the previous day, what was reaped that day, and gross new = change + reaped. Days are in
//! local time. Dry-run lines are ignored.
use super::{truthy, Opts};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::ffi::{c_char, c_int, c_long};
use std::io::Write;

#[repr(C)]
struct Tm {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: *const c_char,
}

extern "C" {
    fn localtime_r(t: *const i64, tm: *mut Tm) -> *mut Tm;
}

/// `time.strftime("%Y-%m-%d", time.localtime(ts))`.
fn local_day(ts: i64) -> String {
    // All-zero is a valid Tm: integers and a null tm_zone.
    let mut tm: Tm = unsafe { std::mem::zeroed() };
    if unsafe { localtime_r(&ts, &mut tm) }.is_null() {
        return String::new();
    }
    format!("{:04}-{:02}-{:02}", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday)
}

pub fn report(o: &Opts, out: &mut dyn Write) -> i32 {
    let text = match std::fs::read_to_string(&o.log) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("tally reap: cannot read {}: {e}", o.log);
            return 1;
        }
    };
    let mut first: BTreeMap<String, HashMap<String, i64>> = BTreeMap::new();
    let mut reaped: HashMap<(String, String), i64> = HashMap::new();
    for line in text.lines() {
        let Ok(r) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        if truthy(r.get("dry_run")) {
            continue;
        }
        let Some(ts) = r.get("ts").and_then(|v| v.as_i64()) else { continue };
        let day = local_day(ts);
        match r.get("action").and_then(|v| v.as_str()) {
            Some("run") if !first.contains_key(&day) => {
                let sizes = r
                    .get("sizes_kb")
                    .and_then(|v| v.as_object())
                    .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_i64().unwrap_or(0))).collect())
                    .unwrap_or_default();
                first.insert(day, sizes);
            }
            Some("delete") => {
                let path = r.get("path").and_then(|v| v.as_str()).unwrap_or("");
                let proj = path.get(o.root.len() + 1..).unwrap_or("").split('/').next().unwrap_or("").to_string();
                let kb = r.get("kb").and_then(|v| v.as_i64()).unwrap_or(0).max(0);
                *reaped.entry((day, proj)).or_insert(0) += kb;
            }
            _ => {}
        }
    }
    let days: Vec<&String> = first.keys().collect();
    let mut projs: Vec<String> = first
        .values()
        .flat_map(|m| m.keys().cloned())
        .filter(|p| p != "_total")
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if let Some(want) = &o.project {
        projs.retain(|p| p.contains(want.as_str()));
    }
    let _ = writeln!(out, "day\tproject\tsize_gib\tnet_gib\treaped_gib\tgross_new_gib");
    let g = 1_048_576.0;
    for i in 1..days.len() {
        let (d, prev) = (days[i], days[i - 1]);
        for p in &projs {
            let size = *first[d].get(p).unwrap_or(&0) as f64;
            let size0 = *first[prev].get(p).unwrap_or(&0) as f64;
            let rp = *reaped.get(&(prev.clone(), p.clone())).unwrap_or(&0) as f64;
            let _ = writeln!(
                out,
                "{d}\t{p}\t{:.1}\t{:+.1}\t{:.1}\t{:.1}",
                size / g,
                (size - size0) / g,
                rp / g,
                (size - size0 + rp) / g
            );
        }
    }
    0
}

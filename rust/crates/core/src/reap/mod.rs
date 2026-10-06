//! `tally reap`: reclaim what Claude Code work packages leave under /private/tmp/claude-<uid>.
//! Port of the scratch reaper script (B-5700): same four tiers, flags, log lines and exit codes,
//! plus three extra keep rules the script lacked (sweep.rs: C1, C2, C3). Every tier needs two or
//! more independent signals; a signal that cannot be read means keep.
//!
//!   dd       Xcode DerivedData root (info.plist has WorkspacePath, Build/ exists). Pure cache.
//!            Deleted when no file outside .git is newer than the idle cutoff, info.plist's
//!            LastAccessedDate is older than it, and no process argv or cwd names it. Cutoff 3h,
//!            or 6h while its session is live.
//!   worktree A directory whose .git is a file. Removed with `git worktree remove` (never rm) when
//!            its session is not live, it is idle 24h, clean, HEAD is on some ref, unreferenced.
//!   clone    A directory whose .git is a directory. Removed like a worktree, plus nothing unpushed.
//!   session  <root>/<project>/<uuid>: not live, idle 72h, no worktree or clone left, no process
//!            cwd or argv inside, and no git tree anywhere below it.
mod fsutil;
mod record;
mod report;
mod scan;
mod signals;
mod sweep;

pub(crate) const H: f64 = 3600.0;
pub(crate) const DD_IDLE_DEAD: f64 = 3.0 * H;
pub(crate) const DD_IDLE_LIVE: f64 = 6.0 * H;
pub(crate) const TREE_IDLE: f64 = 24.0 * H;
pub(crate) const SESSION_IDLE: f64 = 72.0 * H;
pub(crate) const TRANSCRIPT_LIVE: f64 = 3.0 * H;
pub(crate) const MAX_DEPTH: usize = 5;

/// A reason to stop the whole run without deleting anything (exit code 3).
#[derive(Debug)]
pub struct Abstain(pub &'static str);

#[derive(Debug, Clone)]
pub struct Opts {
    pub root: String,
    pub projects: String,
    pub log: String,
    /// Read `tally status --json` from this file instead; Some("") means tally is unavailable.
    pub status_json: Option<String>,
    /// `argv:` and `cwd:` lines instead of running ps and lsof.
    pub proc_file: Option<String>,
    pub dry_run: bool,
    pub report: bool,
    pub project: Option<String>,
    /// Tests only; None is the wall clock. Not a command line flag.
    pub now: Option<f64>,
}

extern "C" {
    fn getuid() -> u32;
}

impl Opts {
    pub fn defaults() -> Opts {
        let home = std::env::var("HOME").unwrap_or_default();
        Opts {
            root: format!("/private/tmp/claude-{}", unsafe { getuid() }),
            projects: format!("{home}/.claude/projects"),
            log: format!("{home}/.tally/logs/reap.jsonl"),
            status_json: None,
            proc_file: None,
            dry_run: false,
            report: false,
            project: None,
            now: None,
        }
    }
}

/// `--flag value` and `--flag=value` for the flags the reaper defines. An unknown flag or a
/// missing value prints usage on stderr and is Err(2).
pub fn parse_args(args: &[String]) -> Result<Opts, i32> {
    let mut o = Opts::defaults();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let (key, inline) = match a.split_once('=') {
            Some((k, v)) if k.starts_with("--") => (k, Some(v.to_string())),
            _ => (a.as_str(), None),
        };
        let mut val = || -> Result<String, i32> {
            inline.clone().or_else(|| it.next().cloned()).ok_or_else(|| usage(&format!("{key} needs a value")))
        };
        match key {
            "--dry-run" => o.dry_run = true,
            "--report" => o.report = true,
            "--root" => o.root = val()?,
            "--projects" => o.projects = val()?,
            "--log" => o.log = val()?,
            "--status-json" => o.status_json = Some(val()?),
            "--proc-file" => o.proc_file = Some(val()?),
            "--project" => o.project = Some(val()?),
            _ => return Err(usage(&format!("unknown argument {a}"))),
        }
    }
    Ok(o)
}

fn usage(msg: &str) -> i32 {
    eprintln!(
        "tally reap: {msg}\nusage: tally reap [--dry-run] [--report] [--project P] [--root DIR] [--projects DIR] [--log FILE]"
    );
    2
}

pub fn main(args: &[String], out: &mut dyn std::io::Write) -> i32 {
    let o = match parse_args(args) {
        Ok(o) => o,
        Err(rc) => return rc,
    };
    run(&o, out)
}

/// Entry with already-parsed options (tests call this).
pub fn run(o: &Opts, out: &mut dyn std::io::Write) -> i32 {
    if o.report {
        return report::report(o, out);
    }
    match sweep::sweep(o, out) {
        Ok(rc) => rc,
        Err(Abstain(reason)) => {
            let ts = o.now.unwrap_or_else(now_secs) as i64;
            if let Err(e) = record::append_log(&o.log, &record::abstain(ts, reason)) {
                eprintln!("tally reap: cannot write {}: {e}", o.log);
            }
            eprintln!("abstain: {reason}");
            3
        }
    }
}

pub(crate) fn now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Python truthiness of a JSON value.
pub(crate) fn truthy(v: Option<&serde_json::Value>) -> bool {
    use serde_json::Value::*;
    match v {
        None | Some(Null) => false,
        Some(Bool(b)) => *b,
        Some(Number(n)) => n.as_f64().is_none_or(|f| f != 0.0),
        Some(String(s)) => !s.is_empty(),
        Some(Array(a)) => !a.is_empty(),
        Some(Object(o)) => !o.is_empty(),
    }
}

/// Lower-case 8-4-4-4-12 hex, the shape of a Claude Code session id.
pub(crate) fn is_uuid(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, &c)| match i {
            8 | 13 | 18 | 23 => c == b'-',
            _ => c.is_ascii_digit() || (b'a'..=b'f').contains(&c),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_shape() {
        assert!(is_uuid("23cf560d-1fcc-4e9f-8988-838b26148ab1"));
        assert!(!is_uuid("23CF560D-1fcc-4e9f-8988-838b26148ab1"));
        assert!(!is_uuid("23cf560d-1fcc-4e9f-8988-838b26148ab"));
        assert!(!is_uuid("23cf560d_1fcc-4e9f-8988-838b26148ab1"));
    }

    #[test]
    fn args_both_spellings_and_errors() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        let o = parse_args(&s(&["--dry-run", "--root", "/r", "--log=/l"])).unwrap();
        assert!(o.dry_run && o.root == "/r" && o.log == "/l");
        assert_eq!(parse_args(&s(&["--bogus"])).unwrap_err(), 2);
        assert_eq!(parse_args(&s(&["--root"])).unwrap_err(), 2);
        assert!(Opts::defaults().log.ends_with("/.tally/logs/reap.jsonl"));
    }
}

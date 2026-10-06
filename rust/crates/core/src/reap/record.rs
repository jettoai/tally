//! The reaper's output and log lines, spelled exactly as Python's `json.dumps(rec,
//! ensure_ascii=False)`: `", "` and `": "` separators, keys in insertion order, non-ASCII as is.
//! The log and the printed lines are read by scripts that compared runs of the Python version.
use std::io::Write;

pub enum Val {
    I(i64),
    S(String),
    B(bool),
    /// Already-encoded JSON (the `sizes_kb` object).
    Raw(String),
}

pub struct Rec(pub Vec<(&'static str, Val)>);

fn quote(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

impl Rec {
    pub fn to_py_json(&self) -> String {
        let body: Vec<String> = self
            .0
            .iter()
            .map(|(k, v)| {
                let v = match v {
                    Val::I(n) => n.to_string(),
                    Val::S(s) => quote(s),
                    Val::B(b) => b.to_string(),
                    Val::Raw(r) => r.clone(),
                };
                format!("{}: {v}", quote(k))
            })
            .collect();
        format!("{{{}}}", body.join(", "))
    }

    pub fn with(mut self, k: &'static str, v: Val) -> Rec {
        self.0.push((k, v));
        self
    }
}

/// An object of integers in the given order, encoded the same way.
pub fn int_object(pairs: &[(String, i64)]) -> String {
    let body: Vec<String> = pairs.iter().map(|(k, v)| format!("{}: {v}", quote(k))).collect();
    format!("{{{}}}", body.join(", "))
}

/// Append one line, creating the log's directory first.
pub fn append_log(path: &str, rec: &Rec) -> std::io::Result<()> {
    if let Some(dir) = std::path::Path::new(path).parent() {
        if !dir.as_os_str().is_empty() {
            std::fs::create_dir_all(dir)?;
        }
    }
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(f, "{}", rec.to_py_json())
}

pub fn abstain(ts: i64, reason: &str) -> Rec {
    Rec(vec![("ts", Val::I(ts)), ("action", Val::S("abstain".into())), ("reason", Val::S(reason.into()))])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spelled_like_python_json_dumps() {
        let r = Rec(vec![("ts", Val::I(5)), ("path", Val::S("/a/é \"q\"\n".into())), ("dry_run", Val::B(true))])
            .with("sizes_kb", Val::Raw(int_object(&[("x".into(), 1), ("_total".into(), 2)])));
        assert_eq!(
            r.to_py_json(),
            "{\"ts\": 5, \"path\": \"/a/é \\\"q\\\"\\n\", \"dry_run\": true, \"sizes_kb\": {\"x\": 1, \"_total\": 2}}"
        );
        assert_eq!(int_object(&[]), "{}");
    }
}

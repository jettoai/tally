use super::*;
use crate::tokenstats::TestHost;

const JAN1: i64 = 20_454; // 2026-01-01

fn read(provider: &str, text: &str) -> Vec<(i64, String, Totals)> {
    let host = TestHost::at(8 * 3600);
    // No workspace folder: every cwd is its own project.
    let map = ProjectMap::build("/nonexistent-tally-home", &host);
    buckets_of(text.as_bytes(), provider, &map, &host).into_iter().map(|b| (b.day, b.project, b.totals)).collect()
}

fn t(input: i64, cache_write: i64, cache_read: i64, output: i64) -> Totals {
    Totals { input, cache_write, cache_read, output }
}

#[test]
fn restated_turn_counts_peak() {
    let text = r#"{"cwd":"/p","timestamp":"2026-01-01T15:00:00Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":1}}}
{"cwd":"/p","timestamp":"2026-01-01T15:00:01Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}
{"cwd":"/p","timestamp":"2026-01-01T15:00:02Z","message":{"id":"m1","usage":{"input_tokens":10,"cache_read_input_tokens":3,"output_tokens":4}}}
{"cwd":"/p","timestamp":"2026-01-01T15:00:03Z","message":{"id":"m2","usage":{"output_tokens":2}}}
"#;
    assert_eq!(read(CLAUDE, text), vec![(JAN1, "/p".into(), t(10, 0, 3, 7))]);
}

#[test]
fn lines_without_an_id_count_whole_and_split_at_local_midnight() {
    // 16:30Z is 00:30 the next day at +08:00. The cut last line has no `message`.
    let text = "{\"cwd\":\"/p\",\"timestamp\":\"2026-01-01T15:59:59Z\",\"message\":{\"usage\":{\"input_tokens\":2,\"output_tokens\":2}}}\n\
                \n\
                {\"cwd\":\"/p\",\"timestamp\":\"2026-01-01T16:30:00Z\",\"message\":{\"usage\":{\"input_tokens\":2,\"output_tokens\":2}}}\r\n\
                {\"cwd\":\"/p\",\"timestamp\":\"2026-01-01T16:31:00Z\",\"message\":{\"usage\":{\"cache_creation_input_tokens\":9}}}\n\
                {\"cwd\":\"/p\",\"timestamp\":\"2026-01-01T16:40:00Z\",\"mess";
    assert_eq!(read(CLAUDE, text), vec![
        (JAN1, "/p".into(), t(2, 0, 0, 2)),
        (JAN1 + 1, "/p".into(), t(2, 9, 0, 2)),
    ]);
}

#[test]
fn codex_takes_differences_and_restarts_on_a_backwards_total() {
    let line = |ts: &str, i: i64, c: i64, o: i64| format!(
        r#"{{"timestamp":"{ts}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":{i},"cached_input_tokens":{c},"output_tokens":{o}}}}}}}}}"#);
    let text = [
        line("2026-01-02T01:00:00Z", 100, 40, 10), // before the cwd is known: Other
        r#"{"timestamp":"2026-01-02T01:30:00Z","type":"session_meta","payload":{"cwd":"/q","id":"x"}}"#.to_string(),
        line("2026-01-02T02:00:00Z", 150, 60, 15),
        line("2026-01-02T02:30:00Z", 150, 60, 15), // no change: nothing
        line("2026-01-02T03:00:00Z", 20, 5, 3),    // backwards: a fresh counter
    ].join("\n");
    assert_eq!(read(CODEX, &text), vec![
        (JAN1 + 1, "".into(), t(60, 0, 40, 10)),
        (JAN1 + 1, "/q".into(), t(30 + 15, 0, 20 + 5, 5 + 3)),
    ]);
}

#[test]
fn unknown_providers_and_empty_input_read_nothing() {
    assert!(read("gemini", r#"{"usage":1}"#).is_empty());
    assert!(read(CLAUDE, "").is_empty());
}

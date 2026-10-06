use super::*;
use crate::tokenstats::TestHost;

/// Written by the Swift engine's own `JSONEncoder` (the cache shape every installed app has).
const SWIFT_CACHE: &str = include_str!("../../tests/fixtures/token-stats-swift-v6.json");

#[test]
fn reads_the_cache_the_swift_engine_wrote() {
    let mut cache: Cache = serde_json::from_str(SWIFT_CACHE).unwrap();
    // A version 6 cache predates the model columns: it reads (they default) and is then rescanned.
    assert_eq!(cache.version, 6);
    assert!(!cache.is_current("Asia/Taipei"));
    cache.version = CURRENT_VERSION;
    assert!(cache.is_current("Asia/Taipei"));
    assert_eq!(cache.files.len(), 3);
    let s1 = &cache.files["/h/.claude/projects/-w-a/s1.jsonl"];
    assert_eq!((s1.provider.as_str(), s1.size, s1.modified), ("claude", 1234, 1759494000.123456));
    assert_eq!(s1.buckets[0], Bucket { day: 20454, project: "/w/a".into(),
                                       totals: Totals { input: 10, cache_write: 1, cache_read: 2, output: 5, cache_write_1h: 0 },
                                       ..Default::default() });
    let samples = merge(&cache.files);
    assert_eq!(samples.len(), 3);
    assert_eq!(samples[2].totals.output, 8 + 0);
    // And what this writes reads back the same.
    let again: Cache = serde_json::from_slice(&serde_json::to_vec(&cache).unwrap()).unwrap();
    assert_eq!(again.files["/h/.claude/projects/-w-a/s1.jsonl"].buckets, s1.buckets);
}

struct Home {
    root: String,
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn usage(ts: &str, out: i64) -> String {
    format!("{{\"cwd\":\"/p\",\"timestamp\":\"{ts}\",\"message\":{{\"usage\":{{\"output_tokens\":{out}}}}}}}\n")
}

#[test]
fn rescans_only_what_changed() {
    let root = std::env::temp_dir().join(format!("tally-engine-{}", std::process::id())).to_string_lossy().into_owned();
    let home = Home { root: root.clone() };
    std::fs::create_dir_all(format!("{root}/.claude/projects/-p")).unwrap();
    std::fs::create_dir_all(format!("{root}/.codex/sessions/2026/01/02")).unwrap();
    let a = format!("{root}/.claude/projects/-p/a.jsonl");
    let b = format!("{root}/.claude/projects/-p/b.jsonl");
    std::fs::write(&a, usage("2026-01-01T00:00:00Z", 5)).unwrap();
    std::fs::write(&b, usage("2026-01-02T00:00:00Z", 7)).unwrap();
    std::fs::write(format!("{root}/.codex/sessions/2026/01/02/rollout-1.jsonl"), "").unwrap();

    let input = |zone: &str| ScanInput {
        home: root.clone(),
        claude_homes: vec![format!("{root}/.claude")],
        codex_homes: vec![format!("{root}/.codex")],
        zone: zone.into(),
        cache_path: format!("{root}/.tally/token-stats.json"),
    };
    let host = TestHost::at(0);
    let engine = Engine::default();
    let first = engine.scan(&input("UTC"), &host);
    assert_eq!((first.files_seen, first.files_reparsed), (3, 3));
    assert_eq!(first.samples.iter().map(|s| (s.day, s.totals.output)).collect::<Vec<_>>(), vec![(20454, 5), (20455, 7)]);
    assert_eq!(engine.scan(&input("UTC"), &host).files_reparsed, 0);
    // A fresh engine starts from the disk cache.
    assert_eq!(Engine::default().scan(&input("UTC"), &host).files_reparsed, 0);

    std::fs::write(&a, usage("2026-01-01T00:00:00Z", 50)).unwrap();
    let changed = engine.scan(&input("UTC"), &host);
    assert_eq!(changed.files_reparsed, 1);
    assert_eq!(changed.samples[0].totals.output, 50);

    std::fs::remove_file(&b).unwrap();
    let removed = engine.scan(&input("UTC"), &host);
    assert_eq!((removed.files_seen, removed.samples.len()), (2, 1));

    // Another zone discards every entry.
    assert_eq!(engine.scan(&input("Asia/Taipei"), &host).files_reparsed, 2);
    drop(home);
}

#[test]
fn an_old_version_is_discarded() {
    let mut cache: Cache = serde_json::from_str(SWIFT_CACHE).unwrap();
    cache.version = 5;
    assert!(!cache.is_current("Asia/Taipei"));
    assert!(!Cache::current("UTC", BTreeMap::new()).is_current("Asia/Taipei"));
}

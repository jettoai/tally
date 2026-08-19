import Darwin
import Foundation

// THE SUPERVISOR'S OWN FOOTPRINT, which every other suite here is blind to: they all assert what a
// tick DECIDES, and this one asserts what a tick COSTS.
//
// A supervisor is a `while` loop that never returns, and Swift wraps only `main` in an autorelease
// pool - drained when the process exits, which for this process is days later or never. So every
// Foundation temporary a tick made stood for the life of the session. The heaviest of them are the
// `NSURL`s of the transcript-directory pass the idle gates run (TranscriptFork.swift): 979 bytes per
// directory entry, about 3.3 passes per tick, 30 ticks a minute. Measured on a live supervisor
// 2026-08-19: 16.5 MB/min against a 169-file project directory, and 47 GB on the process that had
// gone longest without a self-update exec - the one event that gave any of it back, because it
// replaces the process image. Six such processes took a 128 GB machine down.
//
// It stood for 25 versions because nothing could see it. `leaks(1)` reports zero: every one of those
// objects is reachable from the pool's own pages, so none of them is leaked in the sense that tool
// means. Type-check, lint and 4,100 behaviour assertions were all green throughout. THE ORACLE IS
// THE SLOPE, and that is what this file measures.
//
// The measurement is written to be self-validating rather than absolute. It runs the real scan path
// twice - once unpooled, once with the pool the supervisor now puts around its tick - and asserts
// BOTH that the unpooled arm grows measurably and that the pooled arm is a small fraction of it. The
// first half is what stops the check passing vacuously on a machine or a runtime where the
// instrument sees nothing: "the pool worked" and "nothing was measured" are the same green
// otherwise, which is exactly the shape of failure that let the leak through in the first place.

/// This process's resident size, the figure that grew 16.5 MB/min on the live supervisor.
private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
        / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.resident_size : 0
}

/// A project directory shaped like a real one: mostly transcripts older than this launch, one
/// subdirectory per session (62 of the 169 entries on the machine that was measured), and the bound
/// file silent long enough that the scan's one cost gate lets every pass through - which is the
/// state an idle session sits in for hours.
private struct FootprintFixture {
    let dir: URL
    let launchedAt = Date().addingTimeInterval(-600)
    let boundID = "b0000000-0000-0000-0000-000000000000"

    init(transcripts: Int, sessionDirs: Int) {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-footprint-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        write(boundID, age: 60)
        for index in 0 ..< transcripts {
            write(String(format: "a%07d-0000-0000-0000-000000000000", index), age: 3600)
        }
        for index in 0 ..< sessionDirs {
            try! FileManager.default.createDirectory(
                at: dir.appendingPathComponent(String(format: "s%07d", index))
                    .appendingPathComponent("subagents"),
                withIntermediateDirectories: true)
        }
    }

    /// `age` in seconds before this launch, applied to both dates: the scan drops anything born
    /// before the launch, which is what the great majority of a real directory is.
    private func write(_ id: String, age: TimeInterval) {
        let url = dir.appendingPathComponent("\(id).jsonl")
        try! "{}\n".write(to: url, atomically: true, encoding: .utf8)
        let when = launchedAt.addingTimeInterval(-age)
        try! FileManager.default.setAttributes([.creationDate: when, .modificationDate: when],
                                               ofItemAtPath: url.path)
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

/// The resident growth over `passes` runs of the real path, with and without the pool around each
/// one. One watcher for the whole run, as the supervisor has one for the life of a child.
private func residentGrowth(passes: Int, pooled: Bool, fixture: FootprintFixture) -> UInt64 {
    var watcher = TranscriptWatcher(projectDir: fixture.dir, since: fixture.launchedAt,
                                    resumeID: fixture.boundID)
    watcher.locateFile()   // bind first, so the measurement below is the steady state
    let before = residentBytes()
    for _ in 0 ..< passes {
        if pooled {
            autoreleasepool { watcher.locateFile() }
        } else {
            watcher.locateFile()
        }
    }
    let after = residentBytes()
    return after > before ? after - before : 0
}

func runFootprintChecks() {
    let fixture = FootprintFixture(transcripts: 200, sessionDirs: 60)
    defer { fixture.remove() }
    let passes = 400
    // Warm the allocator on the pooled arm first: a cold first run pays for pages this process
    // keeps, and charging those to whichever arm ran first would read as growth that is not the
    // leak. Both arms are then measured over an allocator that has already grown.
    _ = residentGrowth(passes: 20, pooled: true, fixture: fixture)
    let pooled = residentGrowth(passes: passes, pooled: true, fixture: fixture)
    let unpooled = residentGrowth(passes: passes, pooled: false, fixture: fixture)

    // THE INSTRUMENT FIRST. Without this the check below passes on a machine that measured nothing,
    // which is the same green as a working pool.
    let measured = unpooled > 4 << 20
    let reclaimed = pooled * 4 < unpooled
    check("an unpooled directory pass leaves its Foundation temporaries resident", measured)
    check("...and the pool the supervisor's tick runs in gives them back", reclaimed)
    if !measured || !reclaimed {
        print("  (measured over \(passes) passes: unpooled \(unpooled / 1024) KB, "
            + "pooled \(pooled / 1024) KB)")
    }

    // AND THAT THE LOOP ACTUALLY HAS ONE. The measurement above proves the pool reclaims these
    // objects; only the source says the resident loop puts one round its tick, because `runSupervised`
    // spawns a real child and never returns, so no assertion here can call it.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    let pollLoop = String((loop.components(separatedBy: "while child.isRunning {").last ?? "")
        .prefix(600))
    check("the resident poll loop runs each tick inside an autoreleasepool",
          !loop.isEmpty && pollLoop.contains("autoreleasepool") && loop.contains("func tick()"))

    // And that neither directory pass hangs a prefetched `_FileCache` (320 of the 979 bytes an entry
    // cost) onto entries it is about to discard: a project directory is transcripts mixed with one
    // subdirectory per session, and the dates are asked for below the extension filter instead.
    let fork = (try? String(contentsOfFile: "TallyCLI/TranscriptFork.swift", encoding: .utf8)) ?? ""
    let watcher = (try? String(contentsOfFile: "TallyCLI/TranscriptWatcher.swift",
                               encoding: .utf8)) ?? ""
    check("neither transcript-directory pass prefetches resource values it will throw away",
          fork.contains("at: projectDir, includingPropertiesForKeys: nil)")
          && watcher.contains("at: projectDir, includingPropertiesForKeys: nil)"))
}

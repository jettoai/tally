import Foundation

// G1, the speed gate: the same corpus, the same process, three readers interleaved.
//   A  the watcher on the substring readers (what ships without the Rust core)
//   B  the best plain-Swift line reader this work could be measured against: every needle by libc
//      memmem over the whole line, and every line's stamp parsed with the cached formatters. Only
//      the reading, none of the decisions, so it flatters B.
//   C  the watcher on the Rust core
// Pass: C's median CPU <= 0.85 x B's.

private func cpuNanos() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let t = { (v: timeval) in UInt64(v.tv_sec) * 1_000_000_000 + UInt64(v.tv_usec) * 1_000 }
    return t(usage.ru_utime) + t(usage.ru_stime)
}

private let stampKey = Array("\"timestamp\":\"".utf8)

/// B: per line, all needles and the stamp.
private func bestSwiftPass(_ files: [URL]) -> Int {
    var sink = 0
    for file in files {
        guard let data = try? Data(contentsOf: file) else { continue }
        data.withUnsafeBytes { (all: UnsafeRawBufferPointer) in
            var start = 0
            while start < all.count {
                let end = transcriptByteIndex(of: 0x0A, in: all, from: start) ?? all.count
                defer { start = end + 1 }
                guard end > start else { continue }
                let line = UnsafeRawBufferPointer(rebasing: all[start..<end])
                for needle in LineNeedle.table where transcriptBytesContain(line, needle) { sink &+= 1 }
                if let key = transcriptBytesIndex(of: stampKey, in: line),
                   let close = transcriptByteIndex(of: 0x22, in: line, from: key + stampKey.count) {
                    let raw = String(decoding: UnsafeRawBufferPointer(
                        rebasing: line[(key + stampKey.count)..<close]), as: UTF8.self)
                    if transcriptParseISO(raw) != nil { sink &+= 1 }
                }
            }
        }
    }
    return sink
}

private func watcherPass(_ files: [URL], forceString: Bool, budget: Int? = nil) -> Int {
    var sink = 0
    for file in files {
        var w = watcher(file, since: Date(timeIntervalSince1970: 0), forceString: forceString,
                        budget: budget)
        sink &+= ctxScan(&w) &+ w.fullPathLines
    }
    return sink
}

private func stats(_ xs: [UInt64]) -> (median: Double, p90: Double) {
    let s = xs.sorted()
    let at = { (q: Double) in Double(s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]) }
    return (at(0.5) / 1e6, at(0.9) / 1e6)
}

func runBench(corpusList: String) {
    let files = ((try? String(contentsOfFile: corpusList, encoding: .utf8)) ?? "")
        .split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    let bytes = files.reduce(0) {
        $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0)
    }
    let runs = Int(ProcessInfo.processInfo.environment["CTXRUST_BENCH_RUNS"] ?? "") ?? 10
    let variants: [(String, () -> Int)] = [
        ("A StringLineView (current)", { watcherPass(files, forceString: true) }),
        ("B best Swift (memmem x\(LineNeedle.table.count) + cached ISO)", { bestSwiftPass(files) }),
        ("C RustLineView", { watcherPass(files, forceString: false) }),
    ]
    print("corpus: \(files.count) files, \(String(format: "%.1f", Double(bytes) / 1e6)) MB; "
          + "1 warm-up, then \(runs) interleaved runs")
    for v in variants { _ = v.1() }
    var cpu = [[UInt64]](repeating: [], count: 3), wall = cpu
    var sinks = [Set<Int>](repeating: [], count: 3)
    for run in 0..<runs {
        for (i, v) in variants.enumerated() {
            let c0 = cpuNanos(), w0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            sinks[i].insert(v.1())
            cpu[i].append(cpuNanos() - c0)
            wall[i].append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - w0)
        }
        print("run \(run + 1)/\(runs) done", to: &standardError)
    }
    print("| reader | CPU median ms | CPU p90 ms | wall median ms |")
    print("|---|---|---|---|")
    for (i, v) in variants.enumerated() {
        let c = stats(cpu[i]), w = stats(wall[i])
        print(String(format: "| %@ | %.0f | %.0f | %.0f |", v.0, c.median, c.p90, w.median))
    }
    let a = stats(cpu[0]).median, b = stats(cpu[1]).median, c = stats(cpu[2]).median
    print(String(format: "C/B = %.3f (gate <= 0.85: %@), C/A = %.3f; C is %.1f%% faster than B",
                 c / b, c / b <= 0.85 ? "PASS" : "FAIL", c / a, (1 - c / b) * 100))
    print("result stable across runs: \(sinks.allSatisfy { $0.count == 1 })")
    // Incremental poll: the same corpus fed 64 KB per call.
    for (name, force) in [("string", true), ("rust", false)] {
        let c0 = cpuNanos()
        _ = watcherPass(files, forceString: force, budget: 65536)
        let us = Double(cpuNanos() - c0) / 1e3 / (Double(bytes) / 65536)
        print(String(format: "64 KB poll, %@: %.1f us CPU per 64 KB", name, us))
    }
}

nonisolated(unsafe) var standardError = FileHandle.standardError
extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) { write(Data(string.utf8)) }
}

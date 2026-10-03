import Foundation

// One line describing everything a transcript scan leaves in a watcher. Shared by the ctxrust
// suite (substring readers vs the Rust core, same tree) and by the parent-vs-child corpus
// reconciliation, so it uses only API the tree before the Rust core already had.

func ctxHex(_ date: Date?) -> String {
    date.map { String(format: "%a", $0.timeIntervalSinceReferenceDate) } ?? "nil"
}

func ctxFlag(_ f: SafeguardFlag?) -> String {
    guard let f else { return "nil" }
    return [ctxHex(f.at), f.from, f.to, f.category, f.refusedUUID ?? "nil", f.uuid ?? "nil"]
        .joined(separator: ",")
}

/// FNV-1a over a string, so a 64-entry FIFO fits one column.
func ctxFNV(_ s: String) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return String(h, radix: 16)
}

/// Drives `sawCapHit` to the end of the file; the number of calls that reported a cap hit.
func ctxScan(_ watcher: inout TranscriptWatcher) -> Int {
    var hits = 0
    var guardCalls = 0
    repeat {
        if watcher.sawCapHit() { hits += 1 }
        guardCalls += 1
    } while !watcher.caughtUp && guardCalls < 1_000_000
    return hits
}

func ctxDump(_ w: TranscriptWatcher, hits: Int) -> String {
    let excerpts = w.recentUserExcerpts.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1}")
    let stopped = w.lastStoppedTasks.map {
        "\(ctxHex($0.at)),\($0.uuid),\($0.ids.sorted().joined(separator: "+"))"
    } ?? "nil"
    let reset = w.lastLimitReset.map { "\(String(describing: $0.outcome)),\(ctxHex($0.at))" } ?? "nil"
    let pending = w.pendingConfirmation.map {
        "\($0.model),\(ctxHex($0.at)),\(ctxHex($0.root.at)),\($0.root.seq)"
    } ?? "nil"
    let confirmed = w.modelConfirmation.map { "\($0.model),\(ctxHex($0.at))" } ?? "nil"
    let fields: [String] = [
        "hits=\(hits)", "offset=\(w.offset)", "fullPathLines=\(w.fullPathLines)",
        "ctx=\(w.lastContextTokens.map(String.init) ?? "nil")", "model=\(w.lastModel ?? "nil")",
        "mainChain=\(ctxHex(w.lastMainChainEventAt))",
        "conversation=\(ctxHex(w.lastConversationEventAt))",
        "person=\(ctxHex(w.lastPersonInputAt))", "userTurn=\(ctxHex(w.lastUserTurnAt))",
        "modelCommand=\(ctxHex(w.lastModelCommandAt))",
        "effort=\(w.lastModelCommandEffort ?? "nil")",
        "commandSeq=\(w.commandSeq.map(String.init) ?? "nil")", "scanSeq=\(w.scanSeq)",
        "flag=\(ctxFlag(w.lastFlag))", "flagsSinceCommand=\(w.flagsSinceCommand.count)",
        "pending=\(pending)", "confirmed=\(confirmed)", "unanchored=\(w.unanchoredServed)",
        "stopped=\(stopped)", "limitReset=\(reset)", "capHitAt=\(ctxHex(w.capHitAt))",
        "capScope=\(w.capHitScope.map { $0.rawValue } ?? "nil")",
        "loginRequired=\(ctxHex(w.loginSignals.requiredAt))",
        "excerpts=\(w.recentUserExcerpts.count):\(ctxFNV(excerpts))",
    ]
    return fields.joined(separator: "\t")
}

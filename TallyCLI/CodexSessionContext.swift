import Foundation

/// The board's optional identity fields, without a fabricated context-token measurement.
/// `runningEffort` carries the native turn reading when available, then the launch override
/// before the first turn. It is not a Tally session pin.
private struct CodexSessionContext: Codable, Equatable {
    var accountID: String
    var runningModel: String?
    var runningEffort: String?
    var updatedAt: Date
}

struct CodexSessionContextWriter {
    private var current: CodexSessionContext?

    mutating func sync(accountID: String, launchModel: String?, launchEffort: String?,
                       observer: CodexSessionObserver?, pid: String,
                       dir: URL = supervisorStateDir, now: Date = Date(),
                       notify: (String) -> Void = postSessionStateChanged) {
        let next = CodexSessionContext(accountID: accountID,
            runningModel: observer?.model ?? launchModel,
            runningEffort: observer?.hasTurnContext == true ? observer?.effort : launchEffort,
            updatedAt: now)
        if var unchanged = current {
            unchanged.updatedAt = now
            if unchanged == next { return }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encoder.encode(next).write(to: dir.appendingPathComponent(pid + ".session"), options: .atomic)
        } catch { return }
        current = next
        notify(pid)
    }
}

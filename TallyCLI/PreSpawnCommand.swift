import Foundation

// `tally prespawn set|show|clear`: the only writer of ~/.tally/prespawn.json (PreSpawnHook.swift).
// Claude only for now; the file is keyed by provider so Codex can join without a format change.

private let preSpawnProvider = "claude"

private let preSpawnUsage = """
usage:
  tally prespawn set '<command>' [--timeout <seconds>]
                            run <command> (with /bin/sh -c) before every supervised claude start
                            or restart; nonzero stops that start. Timeout 1 to 30, default 5
  tally prespawn show       the command set on this Mac, if any
  tally prespawn clear      remove it
"""

func runPreSpawn(args: [String]) -> Int32 {
    switch args.first {
    case "set": return runPreSpawnSet(Array(args.dropFirst()))
    case "show", nil: return runPreSpawnShow()
    case "clear": return runPreSpawnClear()
    default:
        warn(preSpawnUsage)
        return 2
    }
}

private func runPreSpawnSet(_ args: [String]) -> Int32 {
    var command: String?
    var timeout = preSpawnDefaultTimeout
    var rest = args[...]
    while let word = rest.popFirst() {
        if word == "--timeout" {
            guard let value = rest.popFirst().flatMap({ Int($0) }), preSpawnTimeoutRange.contains(value)
            else {
                warn("--timeout takes whole seconds from \(preSpawnTimeoutRange.lowerBound) to \(preSpawnTimeoutRange.upperBound)")
                return 2
            }
            timeout = value
        } else if command == nil {
            command = word
        } else {
            warn("quote the whole command as one argument\n\(preSpawnUsage)")
            return 2
        }
    }
    guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        warn(preSpawnUsage)
        return 2
    }
    guard var file = loadPreSpawnFile() else {
        warn("\(preSpawnConfigURL.path) exists but cannot be read; fix or remove it first")
        return 1
    }
    file[preSpawnProvider] = PreSpawnEntry(command: command, timeoutSeconds: timeout)
    do { try savePreSpawn(file) } catch {
        warn("could not write \(preSpawnConfigURL.path): \(error.localizedDescription)")
        return 1
    }
    warn("pre-spawn check set: \(command) (timeout \(timeout)s)")
    return 0
}

private func runPreSpawnShow() -> Int32 {
    switch readPreSpawn(provider: preSpawnProvider) {
    case .unset:
        print("no pre-spawn command set")
    case .unreadable:
        warn("\(preSpawnConfigURL.path) exists but cannot be read")
        return 1
    case .entry(let entry):
        print("command: \(entry.command)")
        print("timeout: \(entry.timeoutSeconds ?? preSpawnDefaultTimeout)s")
        print("file:    \(preSpawnConfigURL.path)")
    }
    return 0
}

private func runPreSpawnClear() -> Int32 {
    guard var file = loadPreSpawnFile() else {
        warn("\(preSpawnConfigURL.path) exists but cannot be read; fix or remove it first")
        return 1
    }
    file[preSpawnProvider] = nil
    do { try savePreSpawn(file) } catch {
        warn("could not write \(preSpawnConfigURL.path): \(error.localizedDescription)")
        return 1
    }
    warn("pre-spawn check cleared")
    return 0
}

import Foundation

// `tally events` - plan §5.6/§6.7. Three unrelated jobs share this one entry point because they
// share one directory (`~/.tally/events/`, plan §5.1): reading the spool from a cursor
// (`--since`/`--latest-seq`, the consumer's catch-up path), kicking a delivery pass by hand
// (`--deliver-once`, what the supervisor's detached spawn also runs), and managing the one
// configured destination (`sink set`/`show`/`clear`).
//
// A LOCAL STDERR HELPER RATHER THAN THE REPO'S OWN `warn` (Snapshot.swift): that function lives in
// the same ~14-file quota/account closure `tests/run-waitevents-tests.sh`'s own comment says this
// package deliberately does not pull in (P2's `tests/waitevents/support.swift` stands in for
// `parseISO` for exactly this reason). Naming it differently also sidesteps ever having two
// declarations named `warn` visible to the same file once this compiles into the full `tally`
// binary alongside Snapshot.swift.
private func eventsWarn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private let eventsUsage = "usage: tally events --since <n> [--limit n] | --latest-seq | "
    + "--deliver-once [--replay-dead-letter] | sink set <url> --secret-stdin | sink show | sink clear"

/// The spool's own `seq` counter (SessionWaitSpool.swift) minus one: that file holds the NEXT seq an
/// append will hand out, so the highest seq actually written is one less than it, or 0 when nothing
/// has been appended yet. A local read rather than a call into `SessionWaitSpool.swift`, which keeps
/// that file private to itself the same way `EventDelivery.swift`'s header explains for `cursor`.
private func latestWrittenSeq(dir: URL = tallyEventsDir) -> Int {
    guard let raw = try? String(contentsOf: dir.appendingPathComponent("seq"), encoding: .utf8),
          let next = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
    return max(next - 1, 0)
}

func runEvents(args: [String]) -> Int32 {
    if args.contains("--latest-seq") {
        print(latestWrittenSeq())
        return 0
    }

    if let sinceIndex = args.firstIndex(of: "--since") {
        guard sinceIndex + 1 < args.count, let since = Int(args[sinceIndex + 1]) else {
            eventsWarn("--since requires an integer: \(eventsUsage)")
            return 2
        }
        var limit = 500
        if let limitIndex = args.firstIndex(of: "--limit"), limitIndex + 1 < args.count,
           let parsedLimit = Int(args[limitIndex + 1]) {
            limit = parsedLimit
        }
        let encoder = sessionWaitEventEncoder()
        for event in readSessionWaitEvents(since: since, limit: limit) {
            guard let data = try? encoder.encode(event), let line = String(data: data, encoding: .utf8)
            else { continue }
            print(line)
        }
        return 0
    }

    if args.contains("--deliver-once") {
        return deliverPendingEvents(replayDeadLetter: args.contains("--replay-dead-letter"))
    }

    if args.first == "sink" {
        return runEventsSink(Array(args.dropFirst()))
    }

    eventsWarn(eventsUsage)
    return 2
}

/// A scheme and a non-empty host, nothing more: this is a webhook destination the supervisor's own
/// child process will POST to unattended, not a URL a person is about to open, so path/query/
/// fragment are all left alone.
private func isValidSinkURL(_ raw: String) -> Bool {
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
        return false
    }
    return true
}

/// What `sink show` prints - pulled out as its own pure function (rather than folded into
/// `runEventsSink`'s `print` calls) so `tests/waitevents/main.swift` (T13) can assert the secrets
/// rule directly against the strings this command would actually emit, without spawning the
/// compiled binary or capturing stdout.
func eventsSinkShowLines(dir: URL = tallyEventsDir) -> [String] {
    guard let config = readEventSinkConfig(dir: dir) else {
        return ["url: (unset)", "secret: unset"]
    }
    return ["url: \(config.url)", "secret: set"]
}

private func runEventsSink(_ args: [String]) -> Int32 {
    guard let action = args.first else {
        eventsWarn("usage: tally events sink set <url> --secret-stdin | sink show | sink clear")
        return 2
    }
    switch action {
    case "set":
        guard args.count > 1 else {
            eventsWarn("usage: tally events sink set <url> --secret-stdin")
            return 2
        }
        let url = args[1]
        // Argv is visible to every other process on the machine via `ps`; a secret typed as
        // `--secret <value>` would sit there in the clear for as long as the process runs. Only
        // stdin is accepted (§5.4).
        guard args.contains("--secret-stdin") else {
            eventsWarn("sink set requires --secret-stdin - a literal --secret value would show up in `ps`")
            return 2
        }
        guard isValidSinkURL(url) else {
            eventsWarn("sink url must be http:// or https:// with a non-empty host")
            return 2
        }
        guard let secretLine = readLine(strippingNewline: true), !secretLine.isEmpty else {
            eventsWarn("no secret read from stdin")
            return 2
        }
        let config = EventSinkConfig(url: url, secret: secretLine, createdAt: Date())
        guard writeEventSinkConfig(config) else {
            eventsWarn("failed to write sink config")
            return 1
        }
        return 0
    case "show":
        eventsSinkShowLines().forEach { print($0) }
        return 0
    case "clear":
        clearEventSinkConfig()
        return 0
    default:
        eventsWarn("unknown sink subcommand: \(action)")
        return 2
    }
}

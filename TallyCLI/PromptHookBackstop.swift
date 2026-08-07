import Foundation

// The second hook beside the tool call, and the one judgement it makes.
//
// Each slash command is registered as TWO hooks on one event (IntegrationsPromptHook.swift): an
// `mcp_tool` hook that raises the native picker, and a command hook running `tally hook-<x>
// --backstop`. Claude Code runs every hook that matches, in parallel, and the FIRST decision wins.
//
// SO THE BACKSTOP MUST BE CONDITIONAL, and that is a measured requirement rather than a caution
// (probe C2, 2026-08-07): an unconditional backstop wins the race every time - it is a process
// exiting in milliseconds against a dialog waiting on a human - and the picker becomes an orphan
// drawn over a prompt that has already been answered. So it answers only when the picker cannot.
//
// WHAT "CAN THE PICKER ANSWER" MEANS HERE: is the MCP server running for THIS session. It is a
// child of Claude Code, spawned when the session starts, so the question is answerable from the
// process table alone - no heartbeat file, no state of ours to go stale, and precise to the session
// rather than to the machine. It also covers, for free, the window this design would otherwise have
// to reason about specially: a session started BEFORE the server was ever registered has no such
// child, and is answered as text exactly as it is today.
//
// THE FAILURE DIRECTIONS ARE NOT SYMMETRIC, which is what the search below is shaped by.
//
//   - Saying "not serving" when it is: the backstop blocks, and the picker that was about to open
//     is orphaned. The user sees a list where they expected a dialog, and worse, a dialog appears
//     over an answered prompt.
//   - Saying "serving" when it is not: nothing blocks the expansion, so the prompt reaches a model
//     and costs one short turn - whose content is the command file, written to spend that turn
//     saying one useful sentence (IntegrationsModelCommand.swift).
//
// The second is the cheaper mistake, so the search is generous: it accepts a server under the
// hook's parent OR under its grandparent, because whether a shell sits between Claude Code and this
// process is a property of how the hook was spawned rather than of anything measured.

/// Whether the process table shows a `tally mcp-serve` belonging to the Claude Code that ran this
/// hook. Pure over the table, so the shapes that matter can be asserted without spawning anything.
///
/// `parent` is this hook's own parent, which the probe measured to be the Claude Code process
/// itself (2026-08-07: the hook's `$PPID` and `ps -o ppid=` both named it). The grandparent is
/// accepted as well for the reason the header gives.
func processTableCarriesPicker(_ table: String, parent: pid_t,
                               command: String = mcpServeCommand) -> Bool {
    var parents: [pid_t: pid_t] = [:]
    var servers: [pid_t] = []      // the ppid of every mcp-serve in the table
    for line in table.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2, let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]) else {
            continue
        }
        parents[pid] = ppid
        // As a WORD, never as a substring: a path that happens to contain the subcommand's spelling
        // is not a running server, and the argument is always its own token.
        let arguments = fields.count > 2 ? String(fields[2]) : ""
        if arguments.split(whereSeparator: \.isWhitespace).contains(where: { $0 == command }) {
            servers.append(ppid)
        }
    }
    let eligible = [parent, parents[parent]].compactMap { $0 }
    return servers.contains { eligible.contains($0) }
}

/// The same question, asked of this machine.
///
/// `ps` rather than `pgrep` because one invocation answers the whole question: the pids, their
/// parents and their arguments in one table, so the ancestry above is decided here rather than in
/// two or three more spawns. Anything that goes wrong reads as "not serving", which is the
/// conservative direction for a fallback: it prints the listing this command has always printed.
func nativePickerIsServing(parent: pid_t = getppid(),
                           table: () -> String? = readProcessTable) -> Bool {
    guard let table = table() else { return false }
    return processTableCarriesPicker(table, parent: parent)
}

/// Every process on this machine as `pid ppid arguments`, or nil when it cannot be read.
func readProcessTable() -> String? {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-Ao", "pid=,ppid=,args="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    ps.standardError = FileHandle.nullDevice
    guard (try? ps.run()) != nil else { return nil }
    // Read before waiting: the table is far larger than a pipe buffer, and waiting first is the
    // deadlock this repo has already paid for once (CLIRunner.swift states the same rule).
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

/// What a backstop invocation does. Pure, so the rule is one sentence with a test on it rather than
/// a condition buried in two command entries.
enum PromptHookBackstopAction: Equatable {
    /// The picker is up: exit 0, silently, and let the dialog have the prompt.
    case standDown
    /// Nothing else will answer: do what this hook has always done.
    case answer
}

func promptHookBackstopAction(pickerIsServing: Bool) -> PromptHookBackstopAction {
    pickerIsServing ? .standDown : .answer
}

/// Whether a hook invocation is the backstop one, read off its own arguments.
func promptHookIsBackstop(_ arguments: [String]) -> Bool {
    arguments.contains(promptHookBackstopFlag)
}

// MARK: - How a prompt hook says its piece

/// One prompt hook's answer, decided before any of it is written, so the SHAPE is testable without
/// capturing a process's file descriptors.
struct PromptHookOutput: Equatable {
    /// A hook decision for stdout, or nil when the answer belongs on stderr.
    var decision: String?
    /// Lines for stderr, one `warn` each, or empty.
    var warnings: [String] = []
    var exitCode: Int32
}

/// Where a hook's answer goes, which is not the same question for the two shapes it is registered
/// in.
///
/// THE PLAIN HOOK IS UNCHANGED: stderr, exit 2. That is the only channel a blocked expansion has
/// when there is nothing else answering, and every machine without the native picker keeps exactly
/// the behaviour it has today.
///
/// THE BACKSTOP ANSWERS THE WAY THE TOOL BESIDE IT DOES: a `{"decision":"block","reason":...}` on
/// stdout, exit 0. Not cosmetics - Claude Code prints the whole command line in front of a hook
/// that blocks by exiting 2, so the fleet listing arrived under
/// `["/Applications/Tally.app/Contents/Helpers/tally" hook-model --backstop]:` and a `[tally]` tag,
/// while the tool path's identical listing arrived clean (measured Q1/Q2/Q4, 2026-08-07). One
/// command, registered twice, must not read as two different features depending on which half
/// happened to answer.
///
/// The risk it takes is stated rather than hidden: a decision Claude Code fails to parse is an
/// exit 0 with no decision at all, which lets the expansion through and costs one short turn on the
/// command file. That is the same cost the whole backstop design already accepts for the race it
/// cannot close, and it buys the shared wording.
func promptHookOutput(_ lines: [String], backstop: Bool) -> PromptHookOutput {
    guard backstop else {
        return PromptHookOutput(warnings: lines, exitCode: 2)
    }
    return PromptHookOutput(decision: mcpBlockDecision(lines.joined(separator: "\n")), exitCode: 0)
}

/// Write it, and hand back the exit code.
func emitPromptHookOutput(_ output: PromptHookOutput) -> Int32 {
    if let decision = output.decision { print(decision) }
    for line in output.warnings { warn(line) }
    return output.exitCode
}

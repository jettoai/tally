import Foundation

// The conditional backstop (PromptHookBackstop.swift): the second hook beside the tool call, and
// the one question it asks before it answers anything.
//
// The failure it exists to avoid is measured (probe C2, 2026-08-07): hooks run in parallel and the
// first decision wins, so a backstop that always answered would beat a dialog waiting on a human
// every time, leaving the picker drawn over a prompt that had already been answered.

func runBackstopChecks() {
    // A table shaped exactly as `ps -Ao pid=,ppid=,args=` prints one: right-aligned columns, the
    // arguments running to the end of the line.
    let helper = "/Applications/Tally.app/Contents/Helpers/tally"
    func table(_ rows: [(pid: Int, ppid: Int, args: String)]) -> String {
        rows.map { String(format: "%6d %6d %@", $0.pid, $0.ppid, $0.args) }
            .joined(separator: "\n")
    }

    // The measured layout: Claude Code (500) starts the server as a direct child, and runs this
    // hook as another one.
    let live = table([
        (pid: 500, ppid: 400, args: "/Users/u/.local/bin/claude"),
        (pid: 501, ppid: 500, args: "\(helper) \(mcpServeCommand)"),
        (pid: 502, ppid: 500, args: "\(helper) hook-model \(promptHookBackstopFlag)"),
    ])
    check("a server running under this hook's parent is the picker being up",
          processTableCarriesPicker(live, parent: 500))
    check("…and the hook's own command line is not mistaken for one",
          !processTableCarriesPicker(table([
              (pid: 502, ppid: 500, args: "\(helper) hook-model \(promptHookBackstopFlag)"),
          ]), parent: 500))

    // A shell between Claude Code and the hook is a property of how the hook was spawned rather
    // than of anything measured, so the grandparent counts too. The mistake this leans towards is
    // the cheap one: a prompt that reaches a model costs one short turn, while a backstop that
    // answers over a live dialog leaves the picker orphaned.
    let throughShell = table([
        (pid: 500, ppid: 400, args: "/Users/u/.local/bin/claude"),
        (pid: 501, ppid: 500, args: "\(helper) \(mcpServeCommand)"),
        (pid: 600, ppid: 500, args: "/bin/sh -c \(helper) hook-model"),
    ])
    check("a shell between the hook and Claude Code does not hide the server",
          processTableCarriesPicker(throughShell, parent: 600))

    // Somebody else's session. The server is real, and it is not this conversation's, so this hook
    // must answer as text rather than standing down for a dialog nobody will see.
    let otherSession = table([
        (pid: 500, ppid: 400, args: "/Users/u/.local/bin/claude"),
        (pid: 700, ppid: 400, args: "/Users/u/.local/bin/claude"),
        (pid: 701, ppid: 700, args: "\(helper) \(mcpServeCommand)"),
    ])
    check("another session's server is not this session's picker",
          !processTableCarriesPicker(otherSession, parent: 500))

    // As a WORD, never as a substring: a path that happens to spell the subcommand is not a server.
    check("a path that merely contains the subcommand is not a running server",
          !processTableCarriesPicker(table([
              (pid: 500, ppid: 400, args: "/Users/u/.local/bin/claude"),
              (pid: 501, ppid: 500, args: "/Users/u/src/mcp-server/build.sh"),
          ]), parent: 500))
    check("…nor is one whose name merely starts the same way",
          !processTableCarriesPicker(table([
              (pid: 501, ppid: 500, args: "\(helper) mcp-serve-old"),
          ]), parent: 500))

    // Nothing at all, which is the ordinary state of a machine that never installed the pickers and
    // of every session started before they were registered.
    check("no server anywhere reads as not serving",
          !processTableCarriesPicker(table([
              (pid: 500, ppid: 400, args: "/Users/u/.local/bin/claude"),
          ]), parent: 500))
    check("an empty table is not serving", !processTableCarriesPicker("", parent: 500))
    // A header line, a truncated line, a process with no arguments: skipped rather than crashed on.
    check("lines that are not three fields are skipped",
          processTableCarriesPicker("  PID  PPID ARGS\n\nbroken\n   501    500 \(helper) "
              + "\(mcpServeCommand)", parent: 500))

    // The live reading, with the table injected: the failure path answers "not serving", which is
    // the conservative direction because it prints the listing this command has always printed.
    check("a table that cannot be read reads as not serving",
          !nativePickerIsServing(parent: 500, table: { nil }))
    check("…and one that can is answered from it",
          nativePickerIsServing(parent: 500, table: { live }))

    // The decision itself, and the flag that selects it.
    check("a live picker stands the backstop down",
          promptHookBackstopAction(pickerIsServing: true) == .standDown)
    check("…and nothing else answering means this hook does",
          promptHookBackstopAction(pickerIsServing: false) == .answer)
    check("the flag is read off the arguments the app registered",
          promptHookIsBackstop([promptHookBackstopFlag])
              && !promptHookIsBackstop([]) && !promptHookIsBackstop(["--backstopped"]))

    // MARK: - Where the answer goes
    //
    // ONE COMMAND REGISTERED TWICE MUST NOT READ AS TWO FEATURES. Claude Code prints the whole
    // command line in front of a hook that blocks by exiting 2, so the same fleet listing arrived
    // under `["/Applications/.../tally" hook-model --backstop]:` from the backstop and completely
    // clean from the tool beside it (measured Q1/Q2/Q4, 2026-08-07). The backstop therefore answers
    // in the tool's own shape.
    let listing = ["this session's last response was served by claude-fable-5", "efforts: low, high"]
    let asBackstop = promptHookOutput(listing, backstop: true)
    check("the backstop answers on stdout, as a decision, and exits 0",
          asBackstop.warnings.isEmpty && asBackstop.exitCode == 0 && asBackstop.decision != nil)
    // The SAME encoder the tool path uses, so the two cannot drift into different wire shapes.
    check("…in exactly the shape the tool path returns",
          asBackstop.decision == mcpBlockDecision(listing.joined(separator: "\n")))
    let decoded = (asBackstop.decision?.data(using: .utf8))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]
    check("…carrying the whole listing as the one reason a user reads",
          decoded?["decision"] == "block"
              && decoded?["reason"] == listing.joined(separator: "\n"))
    // AND THE PLAIN HOOK IS UNTOUCHED: every machine without the native picker keeps the channel,
    // the exit code and the line-per-warn shape it has had since the hooks shipped.
    let asPlain = promptHookOutput(listing, backstop: false)
    check("the plain hook still answers on stderr and exits 2",
          asPlain.decision == nil && asPlain.warnings == listing && asPlain.exitCode == 2)
}

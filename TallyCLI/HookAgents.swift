import Foundation

// The `tally hook-agents <event>` subcommand: Claude Code's `SubagentStart`, `SubagentStop` and
// `Stop` hooks, registered by the app's Integrations pane. Reads the event JSON on stdin and leaves
// this session's subagent roster for its supervisor to publish (AgentRoster.swift holds the record
// and every rule; this file is the plumbing around them).
//
// THE SAME HARD CONSTRAINTS AS THE OTHER HOOKS, and for the same reason: this runs inside somebody's
// session, several times a turn, on events they did not ask for. It never throws, never prints,
// never blocks, and answers 0 whatever happens - a hook that failed loudly would put its complaint
// on the terminal the child is drawing into for a number nobody in that terminal is looking at.

/// `tally hook-agents <event>` - one of Claude Code's three subagent-facing hooks.
///
/// A SESSION THIS TOOL DID NOT LAUNCH IS NOT OURS TO REPORT ON: without the supervisor marker in the
/// environment there is nobody to leave the roster for, so it returns before reading anything.
func runHookAgents(args: [String]) -> Int32 {
    guard let supervisor = ProcessInfo.processInfo.environment["TALLY_SUPERVISOR_PID"],
          let pid = pid_t(supervisor), supervisorAlive(pid) else { return 0 }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
    guard let event = agentRosterEvent(payload, registered: args.first) else { return 0 }
    // WHOSE EVENT IS THIS. The marker above is inherited by every descendant of a supervised
    // session, a `claude` launched from inside one included, so a nested session's fan-out would
    // otherwise be counted against the conversation its parent is having - the defect family
    // `SupervisedSession.transcriptSessionID` was added to close. Both ends have to be able to say
    // who they are for this to decide anything, so an event with no id, or a supervisor too old to
    // publish which conversation it watches, reads as "cannot say" and is recorded: the same
    // fail-open every other witness on this track takes.
    let session = (payload?["session_id"] as? String).flatMap {
        isTranscriptSessionID($0) ? $0 : nil
    }
    if let session, let watching = readSessionContext(pid: supervisor)?.transcriptSessionID,
       watching != session {
        return 0
    }
    // THE TURN BOUNDARY IS A FACT WORTH LEAVING ON ITS OWN, beside the roster this event is folded
    // into: `Stop` is the moment `tally session send` has always been waiting for and had to infer
    // from 30 seconds of silence (SessionTurnEnd.swift carries the whole reasoning, the fail-open
    // included). Written FIRST, so the instant recorded is as close to the boundary as this process
    // can make it: the fold below may queue on the roster lock for up to a quarter of a second.
    if let ended = turnEndEvent(event, sessionID: session) {
        writeSessionTurnEnd(ended, pid: supervisor)
    }
    let claudeCode = ProcessInfo.processInfo.environment[claudeCodeExecPathVariable]
    // THE READ AND THE WRITE ARE ONE ACT (`recordAgentEvent`), never two here. A fan-out starts its
    // subagents at once and Claude Code runs this hook per subagent, so these processes race each
    // other over one document: done as two halves, a fan-out ends with a roster naming whichever
    // agent happened to write last.
    recordAgentEvent(event, declared: claudeCodeReportsAgents(executablePath: claudeCode),
                     pid: supervisor)
    return 0
}

/// Where Claude Code says which build is running, exported to everything it spawns
/// (`claudeCodeVersion` states what is read out of it and why this rather than a version variable).
let claudeCodeExecPathVariable = "CLAUDE_CODE_EXECPATH"

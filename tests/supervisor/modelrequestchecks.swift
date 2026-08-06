import Foundation

// The addressing and the grammar of `tally model`: the request file's format, what a fresh
// supervisor starts out having served, what the command makes of a typed line, and what crosses the
// self-update exec. The tick's own decision is next door in modeltickchecks.swift, the surfaces that
// print in modelsurfacechecks.swift.
//
// The file format carries a rule the switch's does not: BOTH AXES ARE VALIDATED HERE. A model name
// only has to have the shape of a launch axis, because model names are open text; an effort has to
// be in the enumeration, because `claude --effort nonsense` exits immediately - so a request naming
// one would kill the child and respawn it into the same failure on every tick, for ever.

func runModelRequestChecks() {
    // MARK: - 32a. The request format

    check("a request parses into stamp, model and effort",
          parseModelRequest("1800000000123\nopus\nxhigh\n")
              == ModelRequest(epoch: 1_800_000_000_123, model: "opus", effort: "xhigh"))
    check("an empty effort line means the effort is left alone",
          parseModelRequest("1800000000123\nopus\n\n")
              == ModelRequest(epoch: 1_800_000_000_123, model: "opus", effort: nil))
    check("…and so does no effort line at all",
          parseModelRequest("1800000000123\nopus")
              == ModelRequest(epoch: 1_800_000_000_123, model: "opus", effort: nil))
    check("surrounding whitespace is tolerated",
          parseModelRequest(" 1800000000123 \n opus \n xhigh ")
              == ModelRequest(epoch: 1_800_000_000_123, model: "opus", effort: "xhigh"))
    check("the reserved model reads as a release",
          parseModelRequest("1\n\(modelAutoRequest)\n")?.isRelease == true)
    check("…and a real model does not",
          parseModelRequest("1\nopus\n")?.isRelease == false)
    // A half-written file must never read as an instruction nobody gave.
    check("an empty body is no request", parseModelRequest("") == nil)
    check("a stamp with no model is no request", parseModelRequest("1800000000123\n") == nil)
    check("a model with no stamp is no request", parseModelRequest("\nopus\n") == nil)
    check("a garbage stamp is no request", parseModelRequest("soon\nopus\n") == nil)
    // The validation the switch's format has no need of.
    check("a model that is not a launch-axis value is no request",
          parseModelRequest("1\nopus; touch /tmp/x\n") == nil
              && parseModelRequest("1\n--account\n") == nil)
    check("an effort outside the enumeration is no request",
          parseModelRequest("1\nopus\nnonsense\n") == nil)
    check("…including one that has the right shape but is not a level",
          parseModelRequest("1\nopus\nextreme\n") == nil)
    check("every documented level IS accepted, and so is the undocumented alias",
          claudeEffortNames().allSatisfy { parseModelRequest("1\nopus\n\($0)\n")?.effort == $0 })
    check("an effort is matched case-insensitively",
          parseModelRequest("1\nopus\nXHIGH\n")?.effort == "XHIGH")
    // A release carrying an effort is a contradiction rather than half an instruction: `auto` hands
    // both axes back at once.
    check("a release naming an effort is refused outright",
          parseModelRequest("1\n\(modelAutoRequest)\nxhigh\n") == nil)
    check("the release token cannot be spelled by a real model name",
          modelAutoRequest.hasPrefix("-") && !isLaunchAxisValue(modelAutoRequest))

    // MARK: - 32b. The file, and the stamp a supervisor starts with

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-model-file-\(UUID().uuidString)")
    check("a session with no request reads as nil",
          readModelRequest(sessionKey: "4242", dir: dir) == nil)
    try! writeModelRequest(model: "opus", effort: "xhigh", sessionKey: "4242",
                           now: Date(timeIntervalSince1970: 1_800_000_000.5), dir: dir)
    check("a written request round-trips",
          readModelRequest(sessionKey: "4242", dir: dir)
              == ModelRequest(epoch: 1_800_000_000_500, model: "opus", effort: "xhigh"))
    // Milliseconds, like the switch stamp: "opus xhigh" then, on second thoughts, "opus high" a
    // moment later is a real sequence, and at second resolution the second one would read as
    // already served and vanish without a word.
    try! writeModelRequest(model: "opus", effort: "high", sessionKey: "4242",
                           now: Date(timeIntervalSince1970: 1_800_000_000.9), dir: dir)
    check("two requests inside one second are distinguishable",
          readModelRequest(sessionKey: "4242", dir: dir)?.epoch == 1_800_000_000_900)
    check("a request is addressed to one session only",
          readModelRequest(sessionKey: "9999", dir: dir) == nil)
    check("a request with no effort writes an empty line, not the word nil",
          { try! writeModelRequest(model: "opus", effort: nil, sessionKey: "7", dir: dir)
            return readModelRequest(sessionKey: "7", dir: dir)?.effort == nil }())
    // A fresh supervisor seeds itself from whatever is addressed to its pid, because pids come
    // round: the request it finds at startup belongs to whoever held the pid before.
    check("a new supervisor treats a request it did not ask for as served",
          SessionModelState(sessionKey: "4242", dir: dir).servedEpoch == 1_800_000_000_900)
    check("…and the self-update exec, which IS the same session, does not",
          SessionModelState(sessionKey: "4242", servedEpoch: 0, dir: dir).servedEpoch == 0)
    check("a session with nothing pending starts at zero",
          SessionModelState(sessionKey: "nobody", dir: dir).servedEpoch == 0)
    check("a state with no pin is not pinned",
          !SessionModelState(sessionKey: "x", servedEpoch: 0, dir: dir).isPinned)
    check("…and one with either axis is",
          SessionModelState(sessionKey: "x", servedEpoch: 0,
                            pin: SessionModelPin(effort: "xhigh"), dir: dir).isPinned)

    // MARK: - 32c. Consuming a served request

    var consuming = SessionModelState(sessionKey: "4242", servedEpoch: 0, dir: dir)
    PendingModelConsumption(epoch: 1_800_000_000_900,
                            pin: SessionModelPin(model: "opus", effort: "high"),
                            dir: dir).commit(&consuming)
    check("committing records the stamp and the pin",
          consuming.servedEpoch == 1_800_000_000_900
              && consuming.pin == SessionModelPin(model: "opus", effort: "high"))
    check("…and unlinks the request it served",
          readModelRequest(sessionKey: "4242", dir: dir) == nil)
    // A newer request written while the child was being torn down is NOT deleted: the millisecond
    // stamps exist so two changes in quick succession are two changes.
    try! writeModelRequest(model: "haiku", effort: nil, sessionKey: "4242",
                           now: Date(timeIntervalSince1970: 1_800_000_001), dir: dir)
    PendingModelConsumption(epoch: 1_800_000_000_900, pin: SessionModelPin(), dir: dir)
        .commit(&consuming)
    check("a newer request left on disk survives an older consumption",
          readModelRequest(sessionKey: "4242", dir: dir)?.model == "haiku")

    // The model directory sweeps through the SAME loop the switch directory does: one answer to
    // "is that pid still alive", not two. Last, because it removes every file not named for a live
    // pid - which is every fixture above.
    try! writeModelRequest(model: "opus", effort: nil, sessionKey: String(getpid()), dir: dir)
    sweepDeadSessionRequests(dir: dir)
    check("a request for a dead session is swept",
          readModelRequest(sessionKey: "4242", dir: dir) == nil)
    check("a live session's request survives it",
          readModelRequest(sessionKey: String(getpid()), dir: dir) != nil)
    try? FileManager.default.removeItem(at: dir)

    // MARK: - 32d. What a typed line asks for

    check("one word is a model, with the effort left alone",
          modelIntent(["opus"]) == .pin(model: "opus", effort: nil))
    check("two words are a model and an effort",
          modelIntent(["opus", "xhigh"]) == .pin(model: "opus", effort: "xhigh"))
    check("the release is accepted in both spellings",
          modelIntent(["auto"]) == .auto && modelIntent([modelAutoRequest]) == .auto)
    check("…case-insensitively for the bare word", modelIntent(["AUTO"]) == .auto)
    check("nothing at all is not an instruction", modelIntent([]) == nil)
    check("…and neither are three words", modelIntent(["a", "b", "c"]) == nil)
    // `auto` beside a model is one instruction under either reading and the two readings are
    // opposites, so it is refused rather than guessed at - the rule `switchIntent` states.
    check("a release beside a model is refused",
          modelIntent(["auto", "opus"]) == nil)

    // MARK: - 32e. What may be written, and how a refusal reads

    check("a plain model with no effort is writable",
          modelIntentProblem(.pin(model: "opus", effort: nil)) == nil)
    check("…so is a fully qualified one",
          modelIntentProblem(.pin(model: "us.anthropic.claude-opus-4:1", effort: "high")) == nil)
    check("a release is always writable", modelIntentProblem(.auto) == nil)
    check("a model carrying a shell separator is not",
          modelIntentProblem(.pin(model: "opus; touch /tmp/x", effort: nil))?
              .contains("is not a model name") == true)
    // A flag offered as a value gets its own sentence: the general one ends in "and dash" and reads
    // as a contradiction to the one person who most needs to act on it.
    check("a flag offered as a model says so in its own words",
          modelIntentProblem(.pin(model: "--effort", effort: nil))
              == "\"--effort\" is a flag, not a model name; nothing was queued")
    // The effort refusal LISTS the levels, the shape the account matcher's ambiguity refusal uses:
    // a closed set is refused by naming the set, so the next attempt cannot miss again.
    check("an effort outside the enumeration is refused, with the levels named",
          modelIntentProblem(.pin(model: "opus", effort: "nonsense"), efforts: ["low", "high"])
              == "\"nonsense\" is not an effort level - pick one of low, high; nothing was queued")
    check("every level the enumeration holds is accepted",
          claudeEffortNames().allSatisfy {
              modelIntentProblem(.pin(model: "opus", effort: $0)) == nil
          })
    check("the model is checked before the effort, so the first fault is the one reported",
          modelIntentProblem(.pin(model: "-", effort: "nonsense"))?.contains("model") == true)

    // MARK: - 32f. Which surface an invocation lands on

    check("a named pair acts, whatever the terminal is",
          modelEntry(["opus"], interactive: true) == .act(.pin(model: "opus", effort: nil))
              && modelEntry(["opus"], interactive: false)
                  == .act(.pin(model: "opus", effort: nil)))
    check("bare in a terminal offers the menu", modelEntry([], interactive: true) == .menu)
    check("bare in a pipe prints the usage text", modelEntry([], interactive: false) == .usage)
    check("a line this command cannot act on is refused rather than turned into a menu",
          modelEntry(["a", "b", "c"], interactive: true) == .usage)

    // MARK: - 32g. Across the self-update exec

    // The pin is a promise about the user's SESSION, and it lives in memory only: without the flag
    // the first quiet tick after an upgrade would put the session back on the fleet default, undoing
    // by itself an instruction the user gave by hand.
    let pinned = SessionModelPin(model: "opus", effort: "xhigh")
    let argv = selfUpdateArgv(binary: "/usr/local/bin/tally", id: "a", label: "A", home: "/h",
                              follow: true, sessionModel: pinned, args: ["--resume", "abc"])
    let ridden = parseResuperviseArgs(Array(argv.dropFirst(2)))
    check("a pinned pair rides the exec intact", ridden.sessionModel == pinned)
    check("…and the child args ride with it", ridden.childArgs == ["--resume", "abc"])
    check("a pin on the model alone survives as exactly that",
          parseResuperviseArgs(Array(selfUpdateArgv(
              binary: "/t", id: "a", label: "A", home: "/h", follow: true,
              sessionModel: SessionModelPin(model: "opus"), args: []).dropFirst(2))).sessionModel
              == SessionModelPin(model: "opus"))
    // Optional by construction: an unpinned session writes no flag, which is also what every build
    // predating it wrote, and an absent flag has to mean "not pinned".
    check("an unpinned session writes no flag at all",
          !selfUpdateArgv(binary: "/t", id: "a", label: "A", home: "/h", follow: true,
                          sessionModel: SessionModelPin(), args: [])
              .contains(resuperviseSessionModelFlag))
    check("…and an absent flag parses as no pin",
          parseResuperviseArgs(["--home", "/h"]).sessionModel == nil)
    check("the same pin always spells the same argv",
          encodeSessionModel(pinned) == encodeSessionModel(pinned)
              && encodeSessionModel(pinned) == #"{"effort":"xhigh","model":"opus"}"#)
    // A value from a DIFFERENT build that we cannot fully parse is a disagreement about the format,
    // and half a pin is a session running one axis its user chose and one they did not.
    check("a value that is not JSON is no pin", decodeSessionModel("not-json") == nil)
    check("an empty object is no pin", decodeSessionModel("{}") == nil)
    check("an axis of the wrong type discards the whole pin",
          decodeSessionModel(#"{"model":7}"#) == nil)
    check("…and so does one that is not a launch-axis value",
          decodeSessionModel(#"{"model":"opus; touch /tmp/x"}"#) == nil)
    check("keys a later build adds are ignored",
          decodeSessionModel(#"{"model":"opus","reasoning":"deep"}"#)
              == SessionModelPin(model: "opus"))
    check("a dangling flag is no pin rather than a crash",
          parseResuperviseArgs(["--home", "/h", resuperviseSessionModelFlag]).sessionModel == nil)
    check("an unreadable value does not swallow the flags after it",
          parseResuperviseArgs([resuperviseSessionModelFlag, "{", "--home", "/h"]).home == "/h")
}

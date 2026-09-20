import Darwin
import Foundation

func codexSessionInputProblem(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("!") else {
        return "Codex direct send requires a nonempty prompt, not a slash command, shell command, or an empty Return. Use the native Codex session for those actions."
    }
    if text.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 || $0.value == 127 }) {
        return "Codex direct prompts cannot contain terminal control characters. Nothing was typed."
    }
    return nil
}

/// A single input stamp can be a pasted draft. Hold it until a user turn accounts for it.
/// Unlike the Claude stash, this does not remove or expire a possibly unsent Codex draft.
func codexInputDraftSuspected(lastInput: Date?, userTurnAt: Date?, launchedAt: Date) -> Bool {
    guard let lastInput else { return true }
    return lastInput > max(userTurnAt ?? launchedAt, launchedAt)
}

@discardableResult
func applyCodexSessionInput(_ input: inout SessionInputState, observer: CodexSessionObserver?,
                           keyboard: KeyboardActivity, launchedAt: Date,
                           terminalReady: Bool, dir: URL = sessionInputDir,
                           log: URL = sessionInputLog, now: Date = Date(),
                           inject: (String) -> SessionInputInjection,
                           confirm: () -> Bool) -> SessionInputAction {
    let ready = observer?.canAcceptInput == true && observer?.inputReceiptsAvailable == true
    let suspected = codexInputDraftSuspected(lastInput: keyboard.lastStamp,
        userTurnAt: observer?.lastUserTurnAt, launchedAt: launchedAt)
    // Reuse the existing queue, expiry, keyboard gate, receipt and audit writer. Unknown and
    // permission-wait readings stay closed; no Claude-specific account or draft action runs.
    return applySessionInput(&input, session: ready ? .idle : (observer?.state == .working ? .working : .unknown),
        quiet: ready ? .quiet : .busy, turnEnded: { false },
        keyboardIdle: terminalReady && keyboard.lastStamp != nil
            && keyboard.idle(sessionInputKeyboardQuietSeconds, now: now),
        relaunchPlanned: false, draftSuspected: suspected, waitingOnPerson: false,
        stashComposer: false,
        inputRefusal: { request in codexSessionInputProblem(request.text)
            ?? (suspected ? "Cannot verify that the Codex composer has no unsent input. "
            + "Submit an actual prompt in that "
            + "Codex session, wait for its turn to finish, then retry." : nil) },
        confirmInput: confirm, dir: dir, log: log, now: now, agents: { _ in nil },
        inject: { text, _ in inject(text) })
}

/// A tty write is not a native prompt receipt. Bound the wait and never repeat the injection.
func awaitCodexInputConfirmation(timeout: TimeInterval = 3,
                                 poll: () -> Bool, sleep: (TimeInterval) -> Void = {
                                     usleep(useconds_t($0 * 1_000_000))
                                 }, clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Bool {
    let deadline = clock() + timeout
    repeat {
        if poll() { return true }
        sleep(0.05)
    } while clock() < deadline
    return false
}

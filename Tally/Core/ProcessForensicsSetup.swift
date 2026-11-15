import Foundation

/// Installing and removing the evidence helper (ProcessForensicsPrivilege.swift says what it is). The
/// password window is injected so a suite never raises one; the disk, not the window's exit code, says
/// whether it worked (the rule IntegrationsCLITool's link install follows).
enum ProcessForensicsSetup {
    enum Outcome: Equatable { case succeeded, cancelled, failed }

    typealias Elevate = (_ script: String, _ arguments: [String], _ prompt: String) -> AdminShell.Result

    private static func outcome(_ result: AdminShell.Result, then settled: () -> Bool) -> Outcome {
        switch result {
        case .cancelled: return .cancelled
        case .foreignFile, .failed: return .failed
        case .done: return settled() ? .succeeded : .failed
        }
    }

    /// Asks for the password once. A user name that is not a plain account name never gets that far.
    static func install(user: String = NSUserName(), prompt: String, elevate: Elevate,
                        state: () -> ProcessForensicsPrivilege.State = { ProcessForensicsPrivilege.state() }) -> Outcome {
        guard let rule = ProcessForensicsPrivilege.sudoersRule(user: user) else { return .failed }
        let result = elevate(ProcessForensicsPrivilege.installScript(),
                             [ProcessForensicsPrivilege.wrapperScript(), rule], prompt)
        return outcome(result) { state() == .installed }
    }

    /// The rule's own removal first (no window); the password window only when that is refused.
    static func remove(prompt: String, elevate: Elevate,
                       sudoRemove: () -> Bool = ProcessForensicsPrivilege.sudoRemove,
                       state: () -> ProcessForensicsPrivilege.State = { ProcessForensicsPrivilege.state() }) -> Outcome {
        if state() == .notInstalled { return .succeeded }
        if sudoRemove(), state() == .notInstalled { return .succeeded }
        return outcome(elevate(ProcessForensicsPrivilege.removeScript, [], prompt)) { state() == .notInstalled }
    }
}

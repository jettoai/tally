import Foundation
import Observation

/// The app's half of the automatic Codex redeem: the switch, the persisted memory, and the one
/// place an automatic redeem is started. The decision is `CodexAutoRedeemLogic`; the redeem itself
/// is `RedeemAction.redeem`, the same call the card's button makes, so there is still exactly one
/// way Tally spends a credit.
///
/// Driven by the usage refresh through `ResetHintNotifier.evaluate`, which the refresh only calls in
/// the installed app (`BuildVariant.isUnshipped`): a dev build and the release app must never both
/// spend a credit for one wall. The gate is repeated in the decision so it cannot be lost by moving
/// the call.
@MainActor
@Observable
final class CodexAutoRedeemStore {
    static let shared = CodexAutoRedeemStore()

    private(set) var enabled: Bool

    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let enabledKey = "ai.jetto.tally.codexAutoRedeem.enabled"
    @ObservationIgnored private let stateKey = "ai.jetto.tally.codexAutoRedeem.state"

    private init() {
        // ON by default: the user asked for this outcome, and it only ever acts on a weekly window
        // that is already empty, where the alternative is waiting days with a credit in the bank.
        enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled, !DemoUsage.isActive else { return }
        UserDefaults.standard.set(on, forKey: enabledKey)
        enabled = on
    }

    /// Feed one refresh. Returns the accounts this round started a redeem for, so the reminder can
    /// stay quiet about them.
    @discardableResult
    func evaluate(accounts: [AccountUsage]) -> Set<String> {
        let (next, due) = CodexAutoRedeemLogic.decide(
            state: loadState(), accounts: accounts, enabled: enabled,
            isUnshipped: BuildVariant.isUnshipped, isDemo: DemoUsage.isActive,
            inFlight: inFlight, now: Date())
        // MARKED BEFORE THE WRITE: past this line a redeem may be on the wire, and a refresh that
        // lands while it is must find the window already answered.
        saveState(next)
        for id in due {
            guard let usage = accounts.first(where: { $0.id == id }) else { continue }
            Task { @MainActor in
                // `redeem` brackets the call with `beginRedeem`/`endRedeem`, like a manual redeem.
                let outcome = await RedeemAction.redeem(usage: usage)
                await announce(outcome, usage: usage)
                await RedeemAction.followThrough(outcome: outcome, usage: usage)
            }
        }
        return Set(due)
    }

    /// Every redeem, from any control, runs between this and `endRedeem` (`RedeemAction.redeem`), so
    /// a refresh landing while a manual redeem is on the wire cannot start an automatic one.
    func beginRedeem(accountID: String) {
        inFlight.insert(accountID)
    }

    /// Record what a redeem came to (`CodexAutoRedeemLogic.settle`) and clear it from in flight.
    func endRedeem(_ outcome: CodexAppServerClient.RedeemOutcome?, usage: AccountUsage) {
        saveState(CodexAutoRedeemLogic.settle(outcome: Self.name(outcome), usage: usage,
                                              in: loadState(), now: Date()))
        inFlight.remove(usage.id)
    }

    private static func name(_ outcome: CodexAppServerClient.RedeemOutcome?) -> String {
        switch outcome {
        case .redeemed: return "redeemed"
        case .alreadyUsed: return "alreadyUsed"
        case .noCredit: return "noCredit"
        case .failed: return "failed"
        case nil: return "noHome"
        }
    }

    /// One notification per attempt that did something worth knowing: a credit spent, or one that
    /// could not be. A credit that turned out to be gone already spent nothing and says nothing.
    private func announce(_ outcome: CodexAppServerClient.RedeemOutcome?, usage: AccountUsage) async {
        switch outcome {
        case .redeemed:
            _ = await SystemAlert.post(
                title: String(format: L("%@: reset redeemed automatically"), usage.accountLabel),
                body: L("Its weekly quota ran out, so Tally redeemed the banked reset that expires soonest. The counters clear within a minute."))
        case .failed:
            // The reminder's category, so the notification carries the same "Use a reset" button,
            // which opens the card's confirmation rather than retrying on its own.
            NotificationRouter.shared.refreshCategories()
            _ = await SystemAlert.post(
                title: String(format: L("%@: automatic reset failed"), usage.accountLabel),
                body: L("Its weekly quota ran out and Tally could not redeem a banked reset. It will not try again until the quota comes back and runs out again; you can still use a reset yourself."),
                categoryID: ResetHintNotifier.categoryID,
                userInfo: [ResetHintNotifier.accountKey: usage.id])
        case .alreadyUsed, .noCredit, nil:
            break
        }
    }

    private func loadState() -> CodexAutoRedeemState {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(CodexAutoRedeemState.self, from: data)
        else { return CodexAutoRedeemState() }
        return state
    }

    private func saveState(_ state: CodexAutoRedeemState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }
}

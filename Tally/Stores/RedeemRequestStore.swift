import Foundation

/// The app's half of `tally redeem` (TallyCLI/RedeemRequest.swift): claim a request, spend through
/// RedeemAction.redeem (the panel button's own call, so the manual and automatic redeems share one
/// dedupe), answer at once, then run the usual follow-through so the snapshot catches up. Every file
/// touch runs detached; only the account lookup and the redeem itself stay on the main actor.
///
/// Installed app only, like the automatic redeem: a dev build and the release app must never both
/// claim one request, and a dev build does not write ~/.tally, so `tally status` could not see what
/// it spent.
@MainActor
final class RedeemRequestStore: NSObject {
    static let shared = RedeemRequestStore()

    private var handles: Bool { !BuildVariant.isUnshipped && !DemoUsage.isActive }

    func install() {
        guard handles else { return }
        Task {
            // Leftovers first, so the sweep can never delete a claim or an answer made this run.
            await Task.detached(priority: .utility) { sweepRedeemLeftovers() }.value
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(requested),
                name: Notification.Name(redeemRequestedNotification), object: nil)
            await drain()
        }
    }

    @objc nonisolated private func requested(_ note: Notification) {
        Task { @MainActor in await self.drain() }
    }

    /// Two drains racing each other is safe: the claim is a rename only one of them can win.
    private func drain() async {
        let claimed = await Task.detached(priority: .utility) { claimPendingRedeemRequests() }.value
        for request in claimed { Task { await self.handle(request) } }
    }

    private func handle(_ request: RedeemRequest) async {
        let store = UsageStore.shared
        guard !store.accounts.isEmpty else { return answer(request, .notReady) }
        guard let usage = store.accounts.first(where: { $0.id == request.accountID }) else {
            return answer(request, .notFound)
        }
        guard usage.providerID == CodexAutoRedeemLogic.providerID else {
            return answer(request, .notSupported)
        }
        // The same lookup RedeemAction.redeem makes, with no await between the two, so a nil from
        // redeem below can only mean the shared dedupe held it back.
        guard store.discoveredAccounts.first(where: { $0.id == usage.id })?.launchableHome != nil
        else { return answer(request, .signedOut) }

        let outcome = await RedeemAction.redeem(usage: usage)
        switch outcome {
        case .redeemed?: answer(request, .redeemed)
        case .noCredit?: answer(request, .noCredit)
        case .alreadyUsed?: answer(request, .alreadyUsed)
        case .failed(let why)?: answer(request, .failed, detail: why)
        case nil: return answer(request, .busy)   // the redeem that holds it owns the refresh
        }
        await RedeemAction.followThrough(outcome: outcome, usage: usage)
    }

    private func answer(_ request: RedeemRequest, _ code: RedeemResultCode, detail: String? = nil) {
        let result = RedeemResult(id: request.id, code: code.rawValue, detail: detail)
        Task.detached(priority: .userInitiated) { answerRedeemRequest(result) }
    }
}

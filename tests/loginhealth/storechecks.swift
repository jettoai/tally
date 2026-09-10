import Foundation

/// The real LoginStatusStore with external services replaced by inert test dependencies.
@main
struct LoginStoreChecks {
    @MainActor
    static func main() {
        var failures = 0
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            if condition { passed += 1; print("PASS: " + name) }
            else { failures += 1; print("FAIL: " + name) }
        }
        let store = LoginStatusStore.shared
        let account = ProviderAccount(id: "claude:login-store-a", providerID: "claude", label: "A", locator: [:])
        let sibling = ProviderAccount(id: "claude:login-store-b", providerID: "claude", label: "B", locator: [:])
        func reject(_ account: ProviderAccount, since mark: Int? = nil) {
            store.usageAuthentication(account: account, authenticated: false,
                                      since: mark ?? store.beginUsageAuthentication())
        }
        reject(account)
        reject(sibling)
        check(store.isExpired(account.id) && store.isExpired(sibling.id),
              "real usage callbacks mark both fixture accounts rejected")
        let beforeLanding = store.beginUsageAuthentication()
        let beforeLandingInvalidations = LoginHealthStore.shared.invalidated.count
        store.loginLanded([account.id])
        check(LoginHealthStore.shared.invalidated.count == beforeLandingInvalidations + 1,
              "loginLanded invalidates credential metadata")
        check(!store.isExpired(account.id), "loginLanded clears the real store's usage rejection")
        check(store.isExpired(sibling.id), "loginLanded preserves a sibling's rejection")
        reject(account, since: beforeLanding)
        check(!store.isExpired(account.id), "a callback from before loginLanded cannot restore the rejection")
        reject(account)
        check(store.isExpired(account.id), "a new callback after loginLanded can report a fresh failure")
        let beforeRenewalInvalidations = LoginHealthStore.shared.invalidated.count
        store.loginRenewed(account.id)
        check(LoginHealthStore.shared.invalidated.count == beforeRenewalInvalidations + 1,
              "loginRenewed invalidates credential metadata")
        check(!store.isExpired(account.id), "the existing renewal path still clears usage rejection")
        reject(account)
        let beforeRemoval = store.beginUsageAuthentication()
        let beforeRemovalInvalidations = LoginHealthStore.shared.invalidated.count
        store.forgetIdentity(accountID: account.id)
        check(LoginHealthStore.shared.invalidated.count == beforeRemovalInvalidations + 1,
              "forgetIdentity invalidates credential metadata")
        check(!store.isExpired(account.id), "the existing removal path still clears usage rejection")
        reject(account, since: beforeRemoval)
        check(!store.isExpired(account.id), "a pre-removal callback still cannot revive the account")
        print("login store: \(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

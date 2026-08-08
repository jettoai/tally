import Foundation

/// What macOS says about Tally's own login item, and everything the Settings row draws from it.
///
/// A decision table with no system call in it, next to the call itself in
/// LaunchAtLoginService.swift, the way DryPoolLogic sits beside DryPoolNotifier. This is the half
/// where the mistakes live, and none of it needs a login item to exercise
/// (tests/run-launchatlogin-tests.sh registers nothing).
///
/// FOUR states, not two, and the reason is the whole point of the file. A login item that EXISTS
/// is not a login item that will RUN: the user can deny or revoke it under System Settings >
/// General > Login Items, and nothing tells the app when they do. So a switch rendered from a
/// preference of our own goes on saying "on" for an app that will never start, and the only
/// gesture the row offers (flipping the switch) is the one gesture that cannot fix it. That case
/// is `requiresApproval` and it has to say so in words.
enum LaunchAtLoginState: Equatable {
    /// Registered and eligible to run at the next login.
    case enabled
    /// No login item: nothing will start Tally when the user logs in.
    case notRegistered
    /// Registered, but consent is missing or was withdrawn in System Settings. It will not run.
    case requiresApproval
    /// macOS found no such service at all.
    case notFound
    /// A status this build does not know. `SMAppServiceStatus` is an open NS_ENUM, so a future
    /// macOS may answer with a fifth value; it gets a state of its own rather than being folded
    /// into "off", which would be a guess presented as a reading.
    case unknown
}

extension LaunchAtLoginState {
    /// Where the switch sits. `requiresApproval` counts as registered because it is: the
    /// registration went through, and it is the user's consent that is missing. Drawing it as
    /// "off" would invite them to flip it on, which re-registers something already registered and
    /// changes nothing they can see.
    var isRegistered: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound, .unknown: return false
        }
    }

    /// The localization key of the line under the row, or nil when the switch alone says it all.
    ///
    /// A key rather than a localized string, so this file stays clear of the app's locale plumbing
    /// and the assertions can name the sentence they expect. The view resolves it through `L`.
    var noticeKey: String? {
        switch self {
        case .enabled, .notRegistered:
            return nil
        case .requiresApproval:
            return "macOS is holding this back. Allow Tally under Login Items in System Settings; switching this off and on again cannot grant it."
        case .notFound:
            return "macOS found no login item for this copy of Tally. Move Tally to your Applications folder, then turn this on again."
        case .unknown:
            return "macOS reported a login item state this version of Tally does not recognize."
        }
    }

    /// Whether THIS STATE is one that gets settled in System Settings > Login Items. Every state
    /// carrying a notice is, because each of them is settled there and nowhere in this window.
    ///
    /// Named for the state rather than for the button, because it is not the whole rule for the
    /// button and reading it as one produced a row that said "that failed" with nothing to press
    /// (see `offersSystemSettings(for:failure:)`).
    var needsSystemSettings: Bool { noticeKey != nil }

    /// Whether a thrown register/unregister error still needs a line of its own, given the state
    /// macOS reports beside it.
    ///
    /// This is not a `try?`. An error is dropped only where something truthful already stands in
    /// its place: asking for "on" and landing on `.enabled` throws `kSMErrorAlreadyRegistered`
    /// when a registration was already there, asking for "off" while unregistered throws
    /// `kSMErrorJobNotFound`, and both name a state the user asked for and now has. The third is
    /// the denial, where `register()` fails because consent was withheld and `requiresApproval`
    /// explains it in words the raw error does not. Everything else, a refused code signature
    /// included, reaches the user verbatim, and so does a denial they were trying to switch OFF
    /// (there the state on screen is not the one they asked for either).
    ///
    /// Phrased against the STATE rather than against the error, and that is what lets it be asked
    /// twice: once the moment the attempt returns, and again on every later re-read. See
    /// `surviving(_:beside:)`.
    static func surfacesFailure(after state: LaunchAtLoginState, wanted: Bool) -> Bool {
        switch (state, wanted) {
        case (.enabled, true), (.notRegistered, false), (.requiresApproval, true): return false
        default: return true
        }
    }

    /// Whether the row offers its way into System Settings, given everything that is on screen.
    ///
    /// Two lines can be showing and either of them is reason enough. The state's own notice is one,
    /// and it was the only one for a while, which left the other case mute: a failure can be on
    /// screen while the state has nothing to say at all. The likeliest such case is also the worst
    /// one to be mute in, a registration macOS refused for a signature it did not accept, where
    /// `register()` never took and the state is therefore a perfectly ordinary `.notRegistered`.
    /// The user was told something went wrong and given nowhere to go with it, at the one moment a
    /// way out is worth most.
    ///
    /// A rule over both inputs rather than a widened `needsSystemSettings`, because that property
    /// is a true statement about states and `.notRegistered` is genuinely not settled in System
    /// Settings. What changed is not the state; it is that the row is now saying more than the
    /// state does.
    static func offersSystemSettings(for state: LaunchAtLoginState,
                                     failure: LaunchAtLoginFailure?) -> Bool {
        state.needsSystemSettings || failure != nil
    }

    /// The recorded failure still worth a line beside `state`, or nil once the world has moved
    /// past it.
    ///
    /// A failure is the answer to a gesture, not a fact about the machine, so it cannot be re-read
    /// the way the state is. It can be re-JUDGED, which is what this does: the message stays only
    /// while the state still contradicts what was asked for. Without it, a user who is told the
    /// switch did not take, goes and settles it under Login Items, and comes back, reads "on,
    /// enabled" with "that failed" still sitting under it, the older of the two being the wrong
    /// one.
    ///
    /// The row runs this on BOTH paths, right after an attempt and on every refresh, so the two
    /// cannot drift into two answers. That is also why the row remembers `wanted` next to the
    /// message: it is the one part of a failure that no re-read can recover, because it is not
    /// something the world knows. Everything the world knows is still read, never stored.
    static func surviving(_ failure: LaunchAtLoginFailure?,
                          beside state: LaunchAtLoginState) -> LaunchAtLoginFailure? {
        guard let failure, surfacesFailure(after: state, wanted: failure.wanted) else { return nil }
        return failure
    }
}

/// A register/unregister attempt that threw, kept exactly as long as it still explains what is on
/// screen. `wanted` is what the user asked for, and it is here because the filter above needs it
/// long after the call that produced the message has returned.
struct LaunchAtLoginFailure: Equatable {
    let wanted: Bool
    let message: String
}

import Foundation

// WHO MAY ANSWER THIS MACHINE'S PICKS, split out of PickContract.swift because it is not part of
// the contract: that file is the WIRE two processes speak over (the request, the claim, the answer),
// and both targets compile it for exactly that reason. This is a judgement only the app makes, about
// the build it is running as, and it is the app that stands down when the answer is no.

/// WHETHER THIS BUILD MAY CLAIM AT ALL, which is a question about the machine rather than about the
/// request, and the one thing the exclusive claim itself cannot answer (`takePickClaim`, over in
/// the contract: it guarantees one winner, never which).
///
/// THE INCIDENT (2026-08-09). A dev build left running since the previous night heard the same knock
/// as the installed 0.42.0 beside it. It had been built before the panel's self-cancelling defect
/// was fixed, so it claimed each request and wrote an empty answer 147ms later, and every
/// `/tally-account` and `/tally-model` on that machine died with "nothing was changed" while a
/// healthy app sat right there. Exclusivity guarantees the race has exactly one winner; it says
/// nothing about WHICH, and a stale build is the likelier winner precisely because it does less
/// before it claims.
///
/// So a build nobody installed stands down. Same predicate and same reason as the login item's one
/// uninvited registration (`LaunchAtLoginDefault.plan`), one axis over: answering a pick IS acting
/// for the machine, because the reply pins somebody's conversation to an account, and a build that
/// is about to stop existing must not be the one that answers.
///
/// NOT THE CAPTURE FAMILY'S GATE, which deliberately asks something else and answers differently
/// (`LoginItemPreview.previewable`). That one decides whether a build may show a reviewer FICTION;
/// this one decides whether a build may ACT for the machine. The dev build is exactly where they
/// part, and them disagreeing there is them working: it may invent a login-item row all day, and
/// must not answer one real pick. An invented state costs the person who asked for it nothing; an
/// answered pick moves somebody's conversation to another account.
///
/// THE OVERRIDE is for the one person this costs anything: the developer testing the picker end to
/// end. `-TallyPickClaim YES` hands the capability back for that launch and nothing else
/// (`CaptureLaunch.pickClaimOverride`), and for `CaptureLaunch.pickClaimOverrideLifetime` rather
/// than forever: an override left switched on is the incident above arriving through the escape
/// hatch instead of around it, which is what it did twice on 2026-08-10.
///
/// WHAT IT COSTS OTHERWISE, so it is weighed rather than discovered: a copy run straight out of a
/// downloaded disk image reads as unshipped (translocation, `BuildVariant.isBuildProductsPath`), so
/// nobody claims and the CLI draws the elicitation form a second and a half later. That is the
/// fallback doing its job, and it is the same surface those users get when Tally is not running at
/// all.
func pickMayBeClaimed(isUnshipped: Bool, overridden: Bool, overrideAge: TimeInterval) -> Bool {
    !isUnshipped || (overridden && overrideAge <= CaptureLaunch.pickClaimOverrideLifetime)
}

import Foundation

// THE ONE THING ABOUT THE SKILL THAT NO OTHER CHECK CAN SEE: whether an edit to its text travels.
//
// Every other assertion in this suite reads the markdown THIS BUILD holds, so all of them stay
// green when the text is rewritten. What decides whether a machine that already has the skill ever
// sees that rewrite is `skillVersion` alone: `autoUpdateSkills` rewrites a file only when its
// marker differs from the current number, and `detectSkill` calls anything else current. Text
// edited without a bump therefore reaches fresh installs and nobody else, and the installs left
// behind are the oldest ones - the users who have had the skill the longest keep instructions that
// name commands the app has since deleted (found in review of the `/tally` merge, 1455ccb, which
// rewrote the skill's command guidance and left the version at 15).
//
// So the text and the number are pinned TOGETHER. Change the markdown and this suite goes red; the
// only way back to green is to bump the version and re-pin the digest, which is the pair of edits
// that had to happen anyway.

/// A stable digest of a text, for pinning content whose CHANGES must be noticed rather than whose
/// wording must be asserted. FNV-1a over the UTF-8 bytes: no import, no platform variance, and the
/// same number on every machine and every run, which is what a pinned constant needs.
func textFingerprint(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in Array(text.utf8) {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
}

/// The digest of the skill markdown that version carries. Re-pin it in the same edit that bumps
/// `skillVersion`, never on its own: a digest updated while the version stands still is this
/// check's one blind spot, and the failing run prints the number to paste so that reaching for it
/// is a deliberate act rather than a convenient one.
let pinnedSkillDigest = "67501669180a7883"

func runSkillVersionChecks() {
    check("skill is at version 21", IntegrationsStore.skillVersion == 21)
    let digest = textFingerprint(IntegrationsStore.skillMarkdown())
    check("…and the text that version stands for is the text this build ships",
          digest == pinnedSkillDigest)
    if digest != pinnedSkillDigest {
        print("  the skill text changed: bump skillVersion, then pin \(digest)")
    }
}

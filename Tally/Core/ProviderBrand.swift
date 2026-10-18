import Foundation

/// The colour a provider's mark wears where Tally draws it in its brand colour: today the menu bar
/// rings (B-2045), whose ring carries the severity colour and so leaves the mark free to be the brand.
/// The single table for it, so no view types a brand hex of its own.
///
/// `nil` means the mark is drawn in the surface's ink (white on a dark bar, black on a light one),
/// either because the provider's own guideline is a single-colour mark or because it is unknown.
///
/// Sources (checked 2026-10-18):
/// - claude: Claude's own site draws its logo with `fill="#D97757"` (https://claude.com/product/overview)
///   and Anthropic's brand-guidelines skill names `#d97757` "Primary accent"
///   (https://github.com/anthropics/skills/blob/main/skills/brand-guidelines/SKILL.md).
/// - codex (the OpenAI Blossom): OpenAI's design guidelines list "don't add any colors to the
///   Blossom" (https://openai.com/brand/), so it stays ink.
enum ProviderBrand {
    /// 0xRRGGBB, or nil for ink.
    static func markHex(for providerID: String) -> UInt32? {
        switch providerID {
        case "claude": return 0xD97757
        default: return nil
        }
    }
}

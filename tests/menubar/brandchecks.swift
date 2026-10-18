import Foundation

// The menu bar mark's brand colour (B-2045): the single table, and that the strip reads it.
func brandChecks() {
    expect(ProviderBrand.markHex(for: "claude") == 0xD97757, "claude mark is Claude's #D97757")
    expect(ProviderBrand.markHex(for: "codex") == nil,
           "codex (OpenAI Blossom) has no brand colour: OpenAI says add no colours, so it is ink")
    expect(ProviderBrand.markHex(for: "unknown-provider") == nil, "an unknown provider is ink")

    let strip = (try? String(contentsOfFile: "Tally/MenuBar/MenuBarStrip.swift", encoding: .utf8)) ?? ""
    expect(strip.contains("ProviderBrand.markHex(for: segment.providerID)"),
           "the strip takes the mark colour from ProviderBrand, not from the severity")
}

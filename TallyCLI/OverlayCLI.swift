// Commands a private build adds to the CLI. The public build adds none: no dispatch, no help
// lines, no completion entries.
#if !TALLY_OVERLAY
enum OverlayCLI {
    static func handles(_ command: String) -> Bool { false }
    static func run(_ command: String, args: [String]) -> Int32 { 64 }
    /// Help lines, each ending in "\n", inserted between the core commands and `tally update`.
    static let usage = ""
    /// zsh `_describe` lines, each ending in "\n".
    static let completionLines = ""
}
#endif

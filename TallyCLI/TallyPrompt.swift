import Foundation

// `/tally` - ONE slash command for both axes, and what a typed line after it means.
//
// WHY ONE COMMAND. The panel already holds both axes side by side (PickPalette.swift), so two
// commands in front of one surface were two doors into the same room: a person had to decide which
// axis they wanted BEFORE they could look at either. `/tally` opens the room.
//
// AND THE DIRECT PATH SURVIVES, which is the half that must not be lost. `/tally opus high` and
// `/tally Claude 2` are answered by the hook with no model turn at all, which is the whole reason
// these commands exist: the commonest moment to reach for one is when the model this session runs
// has nothing left to answer with. A picker that has to be looked at would be a worse answer than
// the one it replaced.
//
// SO THE LINE HAS TO BE READ WITHOUT GUESSING, and that is what this file is. The two axes take
// different vocabularies - a model is a short name from a known list, an account is whatever
// somebody called it in Settings - so the reading is decided by what the words ARE rather than by
// which command was typed.

/// What a `/tally` line asks for.
enum TallyPromptIntent: Equatable {
    /// Nothing was named: open the palette.
    case palette
    /// A model, and possibly a depth.
    case model(ModelIntent)
    /// An account, named as written: labels contain spaces, so the line is not re-tokenised.
    case account(String)
    /// `auto` on its own. BOTH axes have a release, so this names two opposite instructions and is
    /// refused rather than resolved (`tallyPromptReleaseRefusal`).
    case release
}

/// Either spelling of the release, in the one position it can appear on this command.
func tallyPromptIsRelease(_ word: String) -> Bool {
    word == modelAutoRequest || word == switchAutoRequest || word.lowercased() == "auto"
}

/// Whether a word names a model rather than an account.
///
/// THE LIST IS THE PALETTE'S OWN (`mcpModelOptions`), which is what makes this decidable instead of
/// a guess: the direct path recognises exactly the models the panel would have offered, so a name
/// that is a row up there is a model down here, and anything else is a label.
func tallyPromptNamesModel(_ word: String, among models: [String]) -> Bool {
    models.contains { $0 != mcpModelAutoValue && modelsAgree($0, word) }
}

/// The model reading of a typed line, or nil when this line is not one.
///
/// TWO SHAPES COUNT AS A MODEL, and the difference between them is the whole of the disambiguation:
///
///   - A PAIR whose second word is an effort level. Unmistakable, and it is why `/tally opus high`
///     works for a model nobody has heard of yet.
///   - A SINGLE word that NAMES a model. This is the case the obvious reading gets wrong: the
///     underlying grammar accepts any single word as a model name (`modelIntent` deliberately
///     leaves the axis open), so reading it that way would send every one-word ACCOUNT down the
///     model path - and on the machine this was written on the first account is called "Claude".
private func tallyPromptModelIntent(_ words: [String], models: [String],
                                    efforts: [String]) -> ModelIntent? {
    guard case .pin(let model, let effort)? = modelIntent(words) else { return nil }
    // A NAME THE PANEL WOULD OFFER is a model whatever follows it, so a mistyped depth is answered
    // with "that is not an effort level" rather than with "no account called opus 2".
    if tallyPromptNamesModel(model, among: models) { return .pin(model: model, effort: effort) }
    // Otherwise only the pair form counts, which is what keeps a model too new for the alias table
    // typeable. A second word that is not a depth makes this a two-word label ("Claude 2").
    guard let effort, isClaudeEffortName(effort, in: efforts) else { return nil }
    return .pin(model: model, effort: effort)
}

/// What a `/tally` line asks for. Pure and total, so every reading can be asserted without a
/// session, a snapshot or a hook.
///
/// - Parameter models: the models this session would be offered, which is what a single word is
///   recognised against. Defaulted to the documented aliases so a caller without a session reading
///   still gets the common answers right.
func tallyPromptIntent(_ arguments: String, models: [String] = claudeModelAliases,
                       efforts: [String] = claudeEffortNames()) -> TallyPromptIntent {
    // VERBATIM, then trimmed at the ends only: an account label may contain spaces and is passed on
    // as written, under the same rule the account command has always applied to its own line.
    let line = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return .palette }
    let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
    if words.count == 1, tallyPromptIsRelease(words[0]) { return .release }
    if let intent = tallyPromptModelIntent(words, models: models, efforts: efforts) {
        return .model(intent)
    }
    return .account(line)
}

/// What the one refused line is answered with.
///
/// THE ONLY TYPED FORM THAT LOST SOMETHING IN THE MERGE, said plainly rather than resolved: `auto`
/// meant "release the model pin" on one command and "release the account pin" on the other, and the
/// merged command cannot tell which was meant. Both are still one click away in the panel (each
/// column pins its own release row) and both are still typeable in a terminal, so the sentence names
/// all three ways out rather than only refusing.
let tallyPromptReleaseRefusal =
    "`auto` releases a pin and `/tally` sets two of them, so nothing was queued. Open `/tally` and "
        + "take the release row in the column you mean, or name the axis in a terminal: "
        + "`tally model auto` or `tally account --auto`"

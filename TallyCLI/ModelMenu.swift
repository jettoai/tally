import Foundation

// The arrow-key picker behind a bare `tally model`, drawn with the same menu component the worktree
// and account pickers use (WorktreeMenu.swift, which draws on /dev/tty rather than stdout).
//
// TWO MENUS, IN SEQUENCE, because the instruction has two axes and one list cannot hold their
// product: four models times six efforts is twenty-four rows to arrow through for a choice a person
// makes as two. So the model is chosen first, then the effort - with "leave it as it is" as the
// first effort row, because that is the shape of the command itself (`tally model opus` names one
// axis on purpose) and the commonest thing to want.
//
// The release is the ACTION LINE of the first menu rather than a row of it, which is what that line
// is for: it is not one more model to run, it is the instruction to stop naming one.
//
// The models offered are the documented aliases (LaunchAxisNames.swift, shared with the app's own
// picker). They are suggestions, never a gate: the command takes any name the provider accepts, and
// a menu that refused an unlisted one would be a menu that goes stale the week a model ships.

/// What a bare `tally model` came to.
enum ModelMenuOutcome: Equatable {
    case picked(ModelIntent)
    /// Esc, q, or Ctrl-C at either stage: nothing happens and nothing is printed.
    case cancelled
    /// No menu was possible (no tty, a dumb terminal). The caller falls back to the usage text,
    /// which still says what to type.
    case unavailable
}

/// The first menu: one row per model alias, plus the release. Pure, so the mapping is asserted
/// without a terminal - the label leads, and the dim column says which layer that model is already
/// coming from, so a person can see what picking it would and would not change.
func modelMenuFrame(models: [String], status: ModelStatus) -> (rows: [MenuRow], action: String?) {
    let rows = models.map { model -> MenuRow in
        let name = model.lowercased()
        var note = ""
        if name == status.pair.model?.lowercased() {
            note = "running now, from \(status.modelSource)"
        } else if name == status.fleet.model?.lowercased() {
            note = modelLayerFleet
        } else if name == status.project.model?.lowercased() {
            note = modelLayerProject
        }
        return MenuRow(branch: model, age: note, dirty: false, subject: "")
    }
    return (rows, "follow the project profile and the fleet default (auto)")
}

/// The second menu: the effort levels, with "leave it as it is" first. Pure for the same reason.
///
/// The current level is marked rather than pre-selected as the only sensible answer, because the
/// commonest reason to be here is to CHANGE it - the highlight starts on the keep row, which is the
/// one choice that is always safe to press Enter on.
func effortMenuFrame(levels: [String], current: String?) -> (rows: [MenuRow], action: String?) {
    let keep = MenuRow(branch: effortMenuKeepRow, age: current.map { "still \($0)" } ?? "none set",
                       dirty: false, subject: "")
    return ([keep] + levels.map {
        MenuRow(branch: $0, age: $0.lowercased() == current?.lowercased() ? "running now" : "",
                dirty: false, subject: "")
    }, nil)
}

/// The first row of the effort menu, which means "name no effort at all". A constant because the
/// row's text and the branch that reads the chosen index have to agree about which row it is.
let effortMenuKeepRow = "leave the effort as it is"

/// What the two chosen indices mean. Pure, so the composition - including the off-by-one the keep
/// row introduces - is asserted without a terminal.
func modelMenuPick(models: [String], modelIndex: Int, levels: [String],
                   effortIndex: Int) -> ModelIntent? {
    guard models.indices.contains(modelIndex) else { return nil }
    // Row 0 is the keep row, so the levels start at 1; anything outside that is no effort rather
    // than a guess at one.
    let effort = effortIndex >= 1 && effortIndex - 1 < levels.count ? levels[effortIndex - 1] : nil
    return .pin(model: models[modelIndex], effort: effort)
}

/// Draw both menus and report what the user chose.
func pickSessionModel(models: [String] = claudeModelAliases,
                      levels: [String] = claudeEffortNames()) -> ModelMenuOutcome {
    let status = liveModelStatus()
    let frame = modelMenuFrame(models: models, status: status)
    guard let picked = selectMenuRow(rows: frame.rows, action: frame.action) else {
        return .unavailable
    }
    switch picked {
    case .newWorktree:
        // The action line: "stop naming a model". Named for the menu component's own vocabulary,
        // which is the worktree menu's; what it MEANS is decided here.
        return .picked(.auto)
    case .cancelled:
        return .cancelled
    case .existing(let modelIndex):
        let effortFrame = effortMenuFrame(levels: levels, current: status.pair.effort)
        guard let chosenEffort = selectMenuRow(rows: effortFrame.rows,
                                               action: effortFrame.action) else {
            return .unavailable
        }
        switch chosenEffort {
        case .cancelled:
            // Cancelling the SECOND menu abandons the whole thing rather than falling back to
            // "model only": the user is halfway through one instruction, and quietly committing
            // half of it is the surprise this menu exists to avoid.
            return .cancelled
        case .newWorktree:
            return .unavailable   // unreachable without an action line; never a silent wrong move
        case .existing(let effortIndex):
            guard let intent = modelMenuPick(models: models, modelIndex: modelIndex,
                                             levels: levels, effortIndex: effortIndex) else {
                return .unavailable
            }
            return .picked(intent)
        }
    }
}

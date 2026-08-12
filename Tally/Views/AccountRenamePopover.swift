import SwiftUI

/// Rename UI in a popover so the field lives outside the row layout entirely. Clearing (or typing
/// the default name back) removes the override.
///
/// A file of its own because its host is at the repo's size cap, not because anything else uses it:
/// this is the Settings account row's rename field and nothing more (SettingsAccountsView).
struct AccountRenamePopover: View {
    let defaultLabel: String
    @Binding var override: String?
    let dismiss: () -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text, prompt: Text(defaultLabel))
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .padding(12)
            .onAppear { text = override ?? "" }
            .onSubmit { commit() }
            .onDisappear { commit() }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        override = (trimmed.isEmpty || trimmed == defaultLabel) ? nil : trimmed
        dismiss()
    }
}

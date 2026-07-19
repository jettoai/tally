import SwiftUI
import AppKit

/// A monospaced command that copies itself on click, flashing a green check as the receipt.
/// Shared by the launch-help popover and the Settings add-account guidance.
struct CopyCommandChip: View {
    let command: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: command).font(.caption.monospaced())
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Copy"))
    }
}

import SwiftUI

/// The window a copy running from a disk image shows instead of starting. The width is fixed and
/// the height follows the content (prompt and error differ, and so does every language), so the
/// controller's `sizingOptions = [.preferredContentSize]` is the one size authority.
struct MoveToApplicationsView: View {
    let model: MoveToApplicationsModel
    let onQuit: () -> Void
    let onMove: () -> Void

    private var failure: MoveFailure? {
        if case .failed(let reason) = model.phase { return reason }
        return nil
    }

    private var title: String {
        failure == nil ? L("Move Tally to Applications first") : L("Tally couldn't be moved to Applications")
    }

    private var lines: [String] {
        guard let failure else {
            return [L("Tally is running from the disk image. Moved to Applications, it can start at login and keep itself up to date.")]
        }
        let reason: String
        switch failure {
        case .notWritable: reason = L("This Mac doesn't let Tally write to the Applications folder.")
        case .notEnoughSpace: reason = L("There isn't enough free space on this Mac to copy Tally.")
        case .trashFailed: reason = L("The older copy of Tally in Applications couldn't be moved to the Trash.")
        case .copyFailed: reason = L("Copying Tally didn't finish, so nothing was left in Applications.")
        case .launchFailed: reason = L("Tally is in Applications now, but it didn't open from there.")
        }
        let hint = failure == .launchFailed
            ? L("Open Tally from your Applications folder.")
            : L("Drag Tally into Applications yourself, then open it there.")
        return [reason, hint]
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 84, height: 84)
                .padding(.bottom, 12)
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                buttons
            }
            .padding(.top, 24)
        }
        .padding(EdgeInsets(top: 8, leading: 36, bottom: 28, trailing: 36))
        .frame(width: 500)
    }

    @ViewBuilder private var buttons: some View {
        let moving = model.phase == .moving
        Button(action: onQuit) { Text(L("Quit")).frame(minWidth: 64) }
            .controlSize(.large)
            // Alone on the failure screen, Quit is the default button.
            .keyboardShortcut(failure == nil ? .cancelAction : .defaultAction)
            .disabled(moving)
        if failure == nil {
            Button(action: onMove) {
                // The label keeps the idle text's width underneath the spinner so the button does
                // not change size when the copy starts.
                ZStack {
                    Text(L("Move to Applications")).opacity(moving ? 0 : 1)
                    if moving { ProgressView().controlSize(.small) }
                }
                .frame(minWidth: 64)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(moving)
        }
    }
}

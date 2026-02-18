import SwiftUI

/// Shows a list of recent file operations during backup.
/// Simple design showing file names with status text.
struct FileActivityListView: View {
    @EnvironmentObject var appState: AppState

    /// Maximum height as fraction of screen height
    private let maxHeightFraction: CGFloat = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.recentFileActivities.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .frame(maxHeight: maxHeight)
    }

    /// Calculate max height based on screen size
    private var maxHeight: CGFloat {
        if let screen = NSScreen.main {
            return screen.visibleFrame.height * maxHeightFraction
        }
        return 400 // Fallback
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            Text("Scanning files…")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(appState.recentFileActivities) { activity in
                    FileActivityRow(activity: activity)
                    if activity.id != appState.recentFileActivities.last?.id {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }
}

/// A single row in the file activity list - simple design with file name and status.
struct FileActivityRow: View {
    let activity: FileActivity

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Status indicator
            statusIndicator
                .frame(width: 20, height: 20)

            // File info
            VStack(alignment: .leading, spacing: 2) {
                // File name
                Text(activity.fileName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Status text with size and folder
                HStack(spacing: 4) {
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor)

                    if let size = activity.formattedSize {
                        Text("|")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text(size)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            openDestinationInFinder()
        }
    }

    // MARK: - Status

    private var statusText: String {
        switch activity.status {
        case .copying:
            return "Copying…"
        case .copied:
            return activity.folderName
        case .skipped:
            return "Skipped"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    private var statusColor: Color {
        switch activity.status {
        case .copying:
            return .protonPurple
        case .copied:
            return .secondary
        case .skipped:
            return .secondary
        case .error:
            return .statusRed
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch activity.status {
        case .copying:
            ProgressView()
                .scaleEffect(0.6)
                .progressViewStyle(CircularProgressViewStyle(tint: .protonPurple))
        case .copied:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.statusGreen)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.statusRed)
        }
    }

    // MARK: - Actions

    private func openDestinationInFinder() {
        let folderURL = URL(fileURLWithPath: activity.destinationFolder)
        let fileURL = URL(fileURLWithPath: activity.fullPath)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: folderURL.path)
        } else {
            NSWorkspace.shared.open(folderURL)
        }
    }
}

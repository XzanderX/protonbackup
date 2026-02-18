import SwiftUI

/// Shows a list of recent file operations during backup.
struct FileActivityListView: View {
    @EnvironmentObject var appState: AppState

    /// Maximum height as fraction of screen height
    private let maxHeightFraction: CGFloat = 0.4

    var body: some View {
        Group {
            if appState.recentFileActivities.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .frame(minHeight: 100, maxHeight: maxHeight)
    }

    /// Calculate max height based on screen size
    private var maxHeight: CGFloat {
        if let screen = NSScreen.main {
            return screen.visibleFrame.height * maxHeightFraction
        }
        return 300
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if appState.backupState.isRunning {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Scanning files…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else if !appState.isDestinationConnected {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("Connect your backup drive")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 24))
                    .foregroundColor(.statusGreen.opacity(0.5))
                Text("All files backed up")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(appState.recentFileActivities) { activity in
                    FileActivityRow(activity: activity)
                }
            }
        }
    }
}

/// A single row in the file activity list.
struct FileActivityRow: View {
    let activity: FileActivity

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // File type icon
            fileIcon
                .frame(width: 32, height: 32)

            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 0) {
                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundColor(statusColor)

                    if let size = activity.formattedSize {
                        Text(" | ")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text(size)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Status indicator
            statusIndicator
                .frame(width: 20, height: 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            openDestinationInFinder()
        }
    }

    // MARK: - File Icon

    @ViewBuilder
    private var fileIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.1))

            Image(systemName: "doc.fill")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Status

    private var statusText: String {
        switch activity.status {
        case .copying:
            return "Copying…"
        case .copied:
            return "Copied"
        case .skipped:
            return "Skipped"
        case .error(let msg):
            return msg
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
                .scaleEffect(0.5)
                .progressViewStyle(CircularProgressViewStyle(tint: .protonPurple))
        case .copied:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
        case .skipped:
            Image(systemName: "minus")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        case .error:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .semibold))
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

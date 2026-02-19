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
/// Shows: file name on first line, status with destination folder on second line.
struct FileActivityRow: View {
    let activity: FileActivity

    /// Last path component of the destination folder for display
    private var shortFolderName: String {
        let folder = activity.destinationFolder as NSString
        return folder.lastPathComponent
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // File name
                Text(activity.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Status - Folder name
                HStack(spacing: 0) {
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text(" - ")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.5))

                    Button {
                        openFolderInFinder()
                    } label: {
                        Text(shortFolderName)
                            .font(.system(size: 11))
                            .foregroundColor(.protonPurple)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            statusIndicator
                .frame(width: 20, height: 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Status

    private var statusText: String {
        activity.status.displayText
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch activity.status {
        case .indexing:
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
        case .downloading(let progress):
            CircularProgressView(progress: progress)
                .frame(width: 16, height: 16)
        case .copying(let progress):
            if let p = progress {
                CircularProgressView(progress: p)
                    .frame(width: 16, height: 16)
            } else {
                ProgressView()
                    .scaleEffect(0.5)
                    .progressViewStyle(CircularProgressViewStyle(tint: .protonPurple))
            }
        case .copied:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
        case .skipped:
            EmptyView()
        case .error:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.statusRed)
        }
    }

    // MARK: - Actions

    private func openFolderInFinder() {
        let folderURL = URL(fileURLWithPath: activity.destinationFolder)
        NSWorkspace.shared.open(folderURL)
    }
}

/// Circular progress indicator showing percentage complete.
struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 2)

            // Progress arc
            Circle()
                .trim(from: 0, to: CGFloat(min(progress, 1.0)))
                .stroke(Color.protonPurple, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

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

/// A single row in the file activity list - Proton Drive style.
/// Shows: file name on first line, status - folder link on second line.
struct FileActivityRow: View {
    let activity: FileActivity

    /// Last path component of the destination folder for display
    private var shortFolderName: String {
        (activity.destinationFolder as NSString).lastPathComponent
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // File name
                Text(activity.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Status - Folder link
                HStack(spacing: 4) {
                    Text(activity.status.displayText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("-")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Button {
                        openFolderInFinder()
                    } label: {
                        Text(shortFolderName)
                            .font(.system(size: 11))
                            .foregroundColor(.protonPurple)
                            .underline()
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            statusIndicator
                .frame(width: 20, height: 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func openFolderInFinder() {
        let folderURL = URL(fileURLWithPath: activity.destinationFolder)
        NSWorkspace.shared.open(folderURL)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch activity.status {
        case .indexing:
            // Empty circle for indexing
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
        case .waitingToDownload:
            // Empty circle for waiting
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
        case .downloading(let progress):
            CircularProgressView(progress: progress)
        case .copying(let progress):
            if let p = progress {
                CircularProgressView(progress: p)
            } else {
                // Indeterminate - show partial circle
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        case .copied:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
        case .offloading:
            // Indeterminate upload indicator
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        case .offloaded:
            Image(systemName: "cloud.fill")
                .font(.system(size: 12))
                .foregroundColor(.blue)
        case .skipped:
            EmptyView()
        case .error:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundColor(.statusRed)
        }
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

import SwiftUI

/// Shows a list of recent file operations during backup.
/// Design inspired by Proton Drive's file activity view.
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
            VStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.title3)
                    .foregroundColor(.secondary.opacity(0.5))
                Text("No recent activity")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 12)
            Spacer()
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(appState.recentFileActivities) { activity in
                    FileActivityRow(activity: activity, destinationPath: appState.destinationPath)
                    if activity.id != appState.recentFileActivities.last?.id {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
        }
    }
}

/// A single row in the file activity list - Proton Drive style.
struct FileActivityRow: View {
    let activity: FileActivity
    let destinationPath: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // File type icon
            fileIcon
                .frame(width: 40, height: 40)

            // File info
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Status and size
                HStack(spacing: 0) {
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor)

                    if let size = activity.formattedSize {
                        Text(" | ")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(size)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Progress indicator or status icon
            statusIndicator
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            openDestinationInFinder()
        }
    }

    // MARK: - File Icon

    @ViewBuilder
    private var fileIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(iconBackgroundColor)

            Image(systemName: iconName)
                .font(.system(size: 18))
                .foregroundColor(iconForegroundColor)
        }
    }

    private var iconName: String {
        let ext = activity.fileExtension
        switch ext {
        case "pdf":
            return "doc.fill"
        case "doc", "docx":
            return "doc.text.fill"
        case "xls", "xlsx":
            return "tablecells.fill"
        case "ppt", "pptx", "key":
            return "play.rectangle.fill"
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            return "photo.fill"
        case "mp4", "mov", "avi", "mkv":
            return "video.fill"
        case "mp3", "wav", "aac", "m4a":
            return "music.note"
        case "zip", "rar", "7z", "tar", "gz":
            return "doc.zipper"
        case "txt", "md", "rtf":
            return "doc.plaintext.fill"
        case "html", "css", "js", "ts", "swift", "py", "json":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc.fill"
        }
    }

    private var iconBackgroundColor: Color {
        let ext = activity.fileExtension
        switch ext {
        case "pdf":
            return Color.red.opacity(0.15)
        case "doc", "docx":
            return Color.blue.opacity(0.15)
        case "xls", "xlsx":
            return Color.green.opacity(0.15)
        case "ppt", "pptx", "key":
            return Color.orange.opacity(0.15)
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            return Color.purple.opacity(0.15)
        case "mp4", "mov", "avi", "mkv":
            return Color.pink.opacity(0.15)
        case "mp3", "wav", "aac", "m4a":
            return Color.indigo.opacity(0.15)
        default:
            return Color.gray.opacity(0.15)
        }
    }

    private var iconForegroundColor: Color {
        let ext = activity.fileExtension
        switch ext {
        case "pdf":
            return .red
        case "doc", "docx":
            return .blue
        case "xls", "xlsx":
            return .green
        case "ppt", "pptx", "key":
            return .orange
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            return .purple
        case "mp4", "mov", "avi", "mkv":
            return .pink
        case "mp3", "wav", "aac", "m4a":
            return .indigo
        default:
            return .gray
        }
    }

    // MARK: - Status

    private var statusText: String {
        switch activity.status {
        case .copying:
            return "Copying…"
        case .copied:
            return "Copied to \(activity.folderName)"
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
            // Spinning progress ring
            ProgressView()
                .scaleEffect(0.7)
                .progressViewStyle(CircularProgressViewStyle(tint: .protonPurple))
        case .copied:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.statusGreen)
        case .skipped:
            Image(systemName: "arrow.uturn.right.circle")
                .font(.system(size: 18))
                .foregroundColor(.secondary)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.statusRed)
        }
    }

    // MARK: - Actions

    private func openDestinationInFinder() {
        // Open the destination folder containing this file
        let folderURL = URL(fileURLWithPath: activity.destinationFolder)
        let fileURL = URL(fileURLWithPath: activity.fullPath)

        // Try to select the file in Finder, or just open the folder
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: folderURL.path)
        } else {
            NSWorkspace.shared.open(folderURL)
        }
    }
}

#Preview {
    FileActivityListView()
        .environmentObject({
            let state = AppState()
            return state
        }())
        .frame(width: 350)
}

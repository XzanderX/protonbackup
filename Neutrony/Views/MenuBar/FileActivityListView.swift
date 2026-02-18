import SwiftUI

/// Shows a list of recent file operations during backup.
/// Similar to Finder's file activity display - shows file name, folder, and status.
struct FileActivityListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.recentFileActivities.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
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
        VStack(spacing: 0) {
            ForEach(appState.recentFileActivities) { activity in
                FileActivityRow(activity: activity)
                if activity.id != appState.recentFileActivities.last?.id {
                    Divider()
                        .padding(.leading, 40)
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
            // Status icon
            Image(systemName: activity.status.iconName)
                .font(.system(size: 16))
                .foregroundColor(statusColor)
                .frame(width: 20)

            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.fileName)
                    .font(.system(.caption, design: .default))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    Text(activity.relativeTime)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.5))

                    // Clickable folder link
                    Button {
                        openInFinder()
                    } label: {
                        Text(activity.folderName)
                            .font(.caption2)
                            .foregroundColor(.protonPurple)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .help("Open folder in Finder")
                }
            }

            Spacer()

            // Status text for copying
            if case .copying = activity.status {
                Text("Copying…")
                    .font(.caption2)
                    .foregroundColor(.protonPurple)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch activity.status {
        case .copying: return .protonPurple
        case .copied: return .statusGreen
        case .skipped: return .secondary
        case .error: return .statusRed
        }
    }

    private func openInFinder() {
        let url = URL(fileURLWithPath: activity.folderPath)
        NSWorkspace.shared.selectFile(activity.fullPath, inFileViewerRootedAtPath: url.path)
    }
}

#Preview {
    FileActivityListView()
        .environmentObject({
            let state = AppState()
            // Add some sample activities for preview
            return state
        }())
        .frame(width: 300)
}

import SwiftUI

/// Help screen explaining how to restore files from backup.
struct RestoreHelpView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 32))
                        .foregroundColor(.protonPurple)

                    VStack(alignment: .leading) {
                        Text("How to Restore Files")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Find and recover your backed-up files")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // Quick actions
                HStack(spacing: 12) {
                    ActionButton(
                        title: "Open Backup",
                        icon: "folder",
                        action: openBackupFolder
                    )

                    ActionButton(
                        title: "Open Mirror",
                        icon: "internaldrive",
                        action: openMirrorFolder
                    )

                    if appState.config.keepVersions {
                        ActionButton(
                            title: "Open Versions",
                            icon: "clock.arrow.circlepath",
                            action: openVersionsFolder
                        )
                    }
                }

                Divider()

                // Explanation sections
                RestoreSection(
                    number: 1,
                    title: "Finding Your Files",
                    content: """
                    Your backup is stored directly on your external drive. \
                    The folder structure mirrors your Proton Drive exactly.

                    **Backup location:** \(appState.config.destinationDisplayName ?? "Not configured")

                    Simply navigate to the file you need and copy it to where you want it.
                    """
                )

                RestoreSection(
                    number: 2,
                    title: "Restoring from Versions",
                    content: """
                    If you have **Keep Versions** enabled, previously overwritten or deleted files \
                    are saved in a **_versions** folder, organized by date.

                    **Structure:**
                    ```
                    [Backup Drive]/
                    ├── _versions/
                    │   ├── 2025-01-15/
                    │   │   └── Documents/report.pdf
                    │   └── 2025-01-16/
                    │       └── Photos/vacation.jpg
                    ├── Documents/
                    │   └── report.pdf (current)
                    └── Photos/
                        └── vacation.jpg (current)
                    ```

                    To restore a previous version, navigate to `_versions/[date]/` and find the file.
                    """
                )

                RestoreSection(
                    number: 3,
                    title: "Restoring to Proton Drive",
                    content: """
                    To put files back on Proton Drive:

                    1. Find the file in your backup folder
                    2. Upload it to Proton Drive through the web interface or desktop app
                    3. The file will sync back down on the next check

                    **Note:** Do not copy files directly into the local mirror folder, as they may \
                    be overwritten on the next sync.
                    """
                )

                RestoreSection(
                    number: 4,
                    title: "Full Restore",
                    content: """
                    For a complete restore (e.g., after data loss):

                    1. Sign into Proton Drive on the web
                    2. Upload the contents of your backup drive
                    3. The app will detect the changes on the next sync

                    Your backup is a plain folder of files — no special tools needed to read it.
                    """
                )

                // Version info
                if appState.config.keepVersions,
                   let destPath = appState.destinationPath {
                    let backupRoot = destPath
                    let dates = appState.versionManager.listVersionDates(backupRoot: backupRoot)
                    if !dates.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Available Versions")
                                .font(.headline)

                            ForEach(dates, id: \.self) { date in
                                HStack {
                                    Image(systemName: "clock")
                                        .foregroundColor(.secondary)
                                    Text(date)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func openBackupFolder() {
        guard let destPath = appState.destinationPath else { return }
        let backupPath = destPath
        NSWorkspace.shared.open(URL(fileURLWithPath: backupPath))
    }

    private func openMirrorFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: appState.config.localMirrorPath))
    }

    private func openVersionsFolder() {
        guard let destPath = appState.destinationPath else { return }
        let versionsPath = (destPath as NSString)
            .appending("/_versions")
        NSWorkspace.shared.open(URL(fileURLWithPath: versionsPath))
    }
}

// MARK: - Subviews

struct ActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.protonPurple)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct RestoreSection: View {
    let number: Int
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(number)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.protonPurple)
                    .cornerRadius(10)

                Text(title)
                    .font(.headline)
            }

            Text(LocalizedStringKey(content))
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

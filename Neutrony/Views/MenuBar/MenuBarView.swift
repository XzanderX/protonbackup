import SwiftUI

/// Proton Drive-style menu bar dropdown.
/// Minimal design: header with settings, file list, status bar, action toolbar.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header with destination info and settings gear
            HeaderView()
                .environmentObject(appState)

            Divider()

            // File activity list
            FileActivityListView()
                .environmentObject(appState)

            // Status bar
            StatusBarView()
                .environmentObject(appState)

            Divider()

            // Bottom toolbar
            ToolbarView()
                .environmentObject(appState)
        }
        .frame(width: 340)
    }
}

// MARK: - Header View

struct HeaderView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingMenu = false

    var body: some View {
        HStack(spacing: 12) {
            // Destination icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.protonPurple)
                    .frame(width: 44, height: 44)

                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
            }

            // Destination info
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.config.destinationDisplayName ?? "Backup Drive")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                if appState.isDestinationConnected {
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    Text("Drive not connected")
                        .font(.system(size: 12))
                        .foregroundColor(.statusYellow)
                }
            }

            Spacer()

            // Settings gear menu
            Menu {
                if appState.backupState.isRunning {
                    Button {
                        appState.pauseBackup()
                    } label: {
                        Label("Pause Backup", systemImage: "pause")
                    }
                } else if appState.backupState.isPaused {
                    Button {
                        appState.resumeBackup()
                    } label: {
                        Label("Resume Backup", systemImage: "play")
                    }
                }

                Button {
                    WindowManager.shared.showSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }

                Divider()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30, height: 30)
        }
        .padding(12)
    }

    private var statusText: String {
        if case .backing(let progress) = appState.backupState {
            return "Backing up \(progress.completedFiles)/\(progress.totalFiles)"
        } else if case .syncing(let progress) = appState.backupState {
            return "Syncing \(progress.completedFiles)/\(progress.totalFiles)"
        } else if let lastBackup = appState.config.lastSuccessfulBackup {
            return "Last backup \(lastBackup.relativeString)"
        }
        return "Ready"
    }
}

// MARK: - Status Bar View

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .font(.system(size: 14))
                .foregroundColor(statusColor)

            Text(statusText)
                .font(.system(size: 12))
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private var statusIcon: String {
        switch appState.backupState {
        case .upToDate:
            return "checkmark.circle.fill"
        case .backing, .syncing:
            return "arrow.triangle.2.circlepath"
        case .paused:
            return "pause.circle.fill"
        case .error:
            return "exclamationmark.circle.fill"
        case .destinationDisconnected:
            return "externaldrive.badge.xmark"
        default:
            return "circle"
        }
    }

    private var statusColor: Color {
        switch appState.backupState {
        case .upToDate:
            return .statusGreen
        case .backing, .syncing:
            return .protonPurple
        case .paused:
            return .statusYellow
        case .error:
            return .statusRed
        case .destinationDisconnected:
            return .statusYellow
        default:
            return .secondary
        }
    }

    private var statusText: String {
        switch appState.backupState {
        case .upToDate:
            if let lastBackup = appState.config.lastSuccessfulBackup {
                return "Backed up \(lastBackup.relativeString)"
            }
            return "Up to date"
        case .backing(let progress):
            return "Backing up… \(progress.summary)"
        case .syncing(let progress):
            return "Syncing… \(progress.summary)"
        case .paused(let progress):
            return "Paused - \(progress.summary)"
        case .error(let message):
            return "Error: \(message)"
        case .destinationDisconnected:
            return "Connect drive to back up"
        case .idle:
            return "Ready"
        case .notConfigured:
            return "Setup required"
        }
    }
}

// MARK: - Toolbar View

struct ToolbarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Open folder button
            ToolbarButton(
                icon: "folder",
                label: "Open folder",
                action: openDestinationFolder
            )
            .disabled(!appState.isDestinationConnected)

            Divider()
                .frame(height: 30)

            // Back up now button
            ToolbarButton(
                icon: backupButtonIcon,
                label: backupButtonLabel,
                action: handleBackupAction
            )
            .disabled(!appState.config.setupCompleted || !appState.isDestinationConnected)

            Divider()
                .frame(height: 30)

            // View log button
            ToolbarButton(
                icon: "doc.text",
                label: "View log",
                action: { WindowManager.shared.showLogViewer() }
            )
        }
        .padding(.vertical, 8)
    }

    private var backupButtonIcon: String {
        if appState.backupState.isRunning {
            return "pause"
        } else if appState.backupState.isPaused {
            return "play"
        } else {
            return "arrow.clockwise"
        }
    }

    private var backupButtonLabel: String {
        if appState.backupState.isRunning {
            return "Pause"
        } else if appState.backupState.isPaused {
            return "Resume"
        } else {
            return "Back up"
        }
    }

    private func handleBackupAction() {
        if appState.backupState.isRunning {
            appState.pauseBackup()
        } else if appState.backupState.isPaused {
            appState.resumeBackup()
        } else {
            appState.runNow()
        }
    }

    private func openDestinationFolder() {
        if let path = appState.destinationPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Toolbar Button

struct ToolbarButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundColor(isEnabled ? .primary : .secondary.opacity(0.5))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

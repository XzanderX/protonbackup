import SwiftUI

/// Proton Drive-style menu bar dropdown.
/// Minimal design: header with settings gear, file list, status bar.
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
        }
        .frame(width: 340)
    }
}

// MARK: - Header View

struct HeaderView: View {
    @EnvironmentObject var appState: AppState

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
                        .font(.system(size: 12).monospacedDigit())
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
                // Backup actions
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
                } else if appState.config.setupCompleted && appState.isDestinationConnected {
                    Button {
                        appState.runNow()
                    } label: {
                        Label("Back Up Now", systemImage: "arrow.clockwise")
                    }
                }

                Divider()

                // Open destination folder
                Button {
                    openDestinationFolder()
                } label: {
                    Label("Open Backup Folder", systemImage: "folder")
                }
                .disabled(!appState.isDestinationConnected)

                // View log
                Button {
                    WindowManager.shared.showLogViewer()
                } label: {
                    Label("View Log", systemImage: "doc.text")
                }

                // Settings
                Button {
                    WindowManager.shared.showSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }

                Divider()

                // Quit
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit Neutrony", systemImage: "power")
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
        if appState.backupState.isRunning || appState.backupState.isPaused {
            return volumeUsageText ?? "Backing up…"
        } else if let lastBackup = appState.config.lastSuccessfulBackup {
            return "Last backup \(lastBackup.relativeString)"
        }
        return "Ready"
    }

    private var volumeUsageText: String? {
        guard let path = appState.destinationPath,
              let values = try? URL(fileURLWithPath: path).resourceValues(
                  forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else { return nil }
        let used = Int64(total - available)
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return "Using \(fmt.string(fromByteCount: used)) of \(fmt.string(fromByteCount: Int64(total)))"
    }

    private func openDestinationFolder() {
        if let path = appState.destinationPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
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
                .font(.system(size: 12).monospacedDigit())
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
            if progress.totalFiles > 0 {
                return "Backing up… \(progress.summary) (\(progress.percentage)%)"
            }
            return "Scanning files…"
        case .syncing(let progress):
            if progress.totalFiles > 0 {
                return "Downloading from Proton Drive… \(progress.summary) (\(progress.percentage)%)"
            }
            return "Scanning Proton Drive…"
        case .paused(let progress):
            return "Paused — \(progress.summary) (\(progress.percentage)%)"
        case .error(let message):
            return "Error: \(message)"
        case .destinationDisconnected:
            return "Connect drive to back up"
        case .idle:
            return "Waiting for next backup"
        case .notConfigured:
            return "Setup required"
        }
    }
}

import SwiftUI

/// The content of the menu bar dropdown.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Status section
            StatusHeaderView()
                .environmentObject(appState)

            Divider()

            // Quick actions
            if appState.backupState.isRunning {
                Button {
                    appState.pauseBackup()
                } label: {
                    Label("Pause Backup", systemImage: "pause.fill")
                }
            } else if appState.backupState.isPaused {
                Button {
                    appState.resumeBackup()
                } label: {
                    Label("Resume Backup", systemImage: "play.fill")
                }
            } else {
                Button {
                    appState.runNow()
                } label: {
                    Label("Back Up Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!appState.config.setupCompleted)
            }

            Divider()

            // Windows
            Button {
                WindowManager.shared.showSetupWizard()
            } label: {
                Label("Setup Wizard…", systemImage: "wand.and.stars")
            }

            Button {
                WindowManager.shared.showSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            Button {
                WindowManager.shared.showLogViewer()
            } label: {
                Label("View Log…", systemImage: "doc.text")
            }

            Button {
                WindowManager.shared.showRestoreHelp()
            } label: {
                Label("Restore Help…", systemImage: "arrow.uturn.backward")
            }

            Divider()

            // Destination info
            if appState.config.setupCompleted {
                DestinationInfoRow()
                    .environmentObject(appState)
                Divider()
            }

            // Quit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Proton Backup", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
    }
}

// MARK: - Status Header

struct StatusHeaderView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: appState.backupState.menuBarIconName)
                    .foregroundColor(statusColor)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.backupState.statusText)
                        .font(.body)
                        .fontWeight(.medium)

                    if let lastBackup = appState.config.lastSuccessfulBackup {
                        Text("Last backup: \(lastBackup.relativeString)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }

            // Progress bar for running operations
            if case .syncing(let progress) = appState.backupState {
                ProgressView(value: progress.fraction)
                    .tint(.protonPurple)
                if let fileName = progress.currentFileName {
                    Text(fileName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if case .backing(let progress) = appState.backupState {
                ProgressView(value: progress.fraction)
                    .tint(.protonPurple)
                if let fileName = progress.currentFileName {
                    Text(fileName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if case .paused(let progress) = appState.backupState {
                ProgressView(value: progress.fraction)
                    .tint(.statusYellow)
                Text("Paused - \(progress.summary)")
                    .font(.caption2)
                    .foregroundColor(.statusYellow)
            }

            // Last summary
            if let summary = appState.lastSummary, !appState.backupState.isRunning {
                Text(summary.displayText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
    }

    private var statusColor: Color {
        switch appState.backupState {
        case .upToDate: return .statusGreen
        case .error: return .statusRed
        case .destinationDisconnected: return .statusYellow
        case .syncing, .backing: return .protonPurple
        case .paused: return .statusYellow
        default: return .secondary
        }
    }
}

// MARK: - Destination Info Row

struct DestinationInfoRow: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            Image(systemName: appState.isDestinationConnected ? "externaldrive.fill" : "externaldrive.badge.xmark")
                .foregroundColor(appState.isDestinationConnected ? .statusGreen : .statusYellow)

            VStack(alignment: .leading, spacing: 1) {
                Text(appState.config.destinationDisplayName ?? "No destination")
                    .font(.caption)
                Text(appState.isDestinationConnected ? "Connected" : "Not connected")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

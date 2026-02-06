import SwiftUI

/// Final wizard step: run the initial backup.
struct InitialBackupStepView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: WizardState

    @State private var isRunning = false
    @State private var progress: BackupProgress?
    @State private var backupSummary: BackupSummary?
    @State private var errorMessage: String?
    @State private var currentPhase: BackupPhase = .notStarted

    private enum BackupPhase {
        case notStarted
        case backingUp
        case complete
        case failed
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: phaseIcon)
                .font(.system(size: 40))
                .foregroundColor(phaseColor)

            Text("Initial Backup")
                .font(.title2)
                .fontWeight(.semibold)

            Text(phaseDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            // Progress
            if isRunning, let progress {
                VStack(spacing: 8) {
                    ProgressView(value: progress.fraction)
                        .tint(.protonPurple)
                        .frame(maxWidth: 300)

                    Text(progress.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let fileName = progress.currentFileName {
                        Text(fileName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 300)
                    }
                }
            }

            // Summary
            if let backupSummary {
                SummaryCard(title: "Backup Complete", summary: backupSummary)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.statusRed)
                    .frame(maxWidth: 400)
            }

            // Action button
            if !isRunning && currentPhase == .notStarted {
                Button {
                    runInitialBackup()
                } label: {
                    Label("Run Initial Backup", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.protonPurple)
                .controlSize(.large)
            }

            if currentPhase == .complete {
                Label("Initial backup complete!", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.statusGreen)
                    .font(.headline)
            }

            Spacer()

            if currentPhase == .notStarted {
                Text("You can also skip this step and run the backup later.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var phaseIcon: String {
        switch currentPhase {
        case .notStarted: return "arrow.triangle.2.circlepath"
        case .backingUp: return "externaldrive.fill.badge.plus"
        case .complete: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var phaseColor: Color {
        switch currentPhase {
        case .notStarted, .backingUp: return .protonPurple
        case .complete: return .statusGreen
        case .failed: return .statusRed
        }
    }

    private var phaseDescription: String {
        switch currentPhase {
        case .notStarted:
            return "This will copy all your Proton Drive files to your external backup drive."
        case .backingUp:
            return "Copying files from Proton Drive folder to your external backup drive…"
        case .complete:
            return "All files have been backed up. The app will now keep your backup in sync automatically."
        case .failed:
            return "The backup encountered an error. You can retry or finish setup and run it later."
        }
    }

    private func runInitialBackup() {
        guard let sourcePath = wizardState.sourcePath else {
            errorMessage = "No source folder selected"
            return
        }

        isRunning = true
        errorMessage = nil
        currentPhase = .backingUp

        Task {
            do {
                // Backup from source (Proton Drive folder) to destination
                if let destBookmark = wizardState.destinationBookmark,
                   let destURL = BookmarkManager.startAccessing(bookmark: destBookmark) {
                    defer { BookmarkManager.stopAccessing(url: destURL) }

                    let backupResult = try await appState.backupEngine.performBackup(
                        sourcePath: sourcePath,
                        destinationPath: destURL.path,
                        deletionPolicy: wizardState.deletionPolicy,
                        keepVersions: wizardState.keepVersions
                    ) { prog in
                        Task { @MainActor in
                            self.progress = prog
                        }
                    }

                    backupSummary = backupResult
                }

                currentPhase = .complete
                wizardState.initialBackupComplete = true
                isRunning = false

            } catch {
                errorMessage = error.localizedDescription
                currentPhase = .failed
                isRunning = false
            }
        }
    }
}

// MARK: - Summary Card

struct SummaryCard: View {
    let title: String
    let summary: BackupSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)

                Spacer()

                Image(systemName: summary.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundColor(summary.succeeded ? .statusGreen : .statusYellow)
            }

            Text(summary.displayText)
                .font(.caption2)
                .foregroundColor(.secondary)

            if !summary.errors.isEmpty {
                Text("\(summary.errors.count) errors occurred")
                    .font(.caption2)
                    .foregroundColor(.statusRed)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .frame(maxWidth: 400)
    }
}

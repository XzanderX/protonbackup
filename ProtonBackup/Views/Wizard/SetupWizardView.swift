import SwiftUI

/// The main setup wizard container that manages step navigation.
struct SetupWizardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var wizardState = WizardState()

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            ProgressStepsView(currentStep: wizardState.currentStep, totalSteps: WizardStep.allCases.count)
                .padding(.top, 20)
                .padding(.horizontal, 40)

            Divider()
                .padding(.top, 12)

            // Current step content
            Group {
                switch wizardState.currentStep {
                case .welcome:
                    WelcomeStepView()
                case .sourceFolder:
                    LoginStepView()
                case .destination:
                    DestinationStepView()
                case .deletionPolicy:
                    DeletionPolicyStepView()
                case .initialBackup:
                    InitialBackupStepView()
                }
            }
            .environmentObject(wizardState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.vertical, 20)

            Divider()

            // Navigation buttons
            HStack {
                if wizardState.currentStep != .welcome {
                    Button("Back") {
                        wizardState.goBack()
                    }
                }

                Spacer()

                if wizardState.currentStep == .initialBackup {
                    Button("Finish Setup") {
                        finishSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.protonPurple)
                    .disabled(!wizardState.canFinish)
                } else {
                    Button("Continue") {
                        wizardState.goForward()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.protonPurple)
                    .disabled(!wizardState.canContinue)
                }
            }
            .padding(20)
        }
        .frame(width: 600, height: 700)
    }

    private func finishSetup() {
        var config = appState.config
        config.sourcePath = wizardState.sourcePath
        config.destinationBookmark = wizardState.destinationBookmark
        config.destinationDisplayName = wizardState.destinationName
        config.deletionPolicy = wizardState.deletionPolicy
        config.keepVersions = wizardState.keepVersions
        config.useRclone = wizardState.useRclone
        config.rcloneConfigured = wizardState.rcloneConfigured
        appState.completeSetup(config: config)
    }
}

// MARK: - Wizard State

enum WizardStep: Int, CaseIterable {
    case welcome = 0
    case sourceFolder
    case destination
    case deletionPolicy
    case initialBackup
}

@MainActor
class WizardState: ObservableObject {
    @Published var currentStep: WizardStep = .welcome

    // Source (Proton Drive folder) state
    @Published var isAuthenticated = false
    @Published var username = ""
    @Published var sourcePath: String?

    // Rclone state
    @Published var useRclone = false
    @Published var rcloneConfigured = false

    // Destination state
    @Published var destinationBookmark: Data?
    @Published var destinationName: String?
    @Published var destinationPath: String?

    // Deletion policy state
    @Published var deletionPolicy: DeletionPolicy = .mirrorWithVersions
    @Published var keepVersions = true

    // Initial backup state
    @Published var initialBackupComplete = false
    @Published var initialBackupRunning = false

    var canContinue: Bool {
        switch currentStep {
        case .welcome: return true
        case .sourceFolder: return isAuthenticated
        case .destination: return destinationBookmark != nil
        case .deletionPolicy: return true
        case .initialBackup: return true
        }
    }

    var canFinish: Bool {
        // For rclone mode, sourcePath will be "protondrive:"
        let hasSource = useRclone ? rcloneConfigured : (sourcePath != nil)
        return hasSource && destinationBookmark != nil
    }

    func goForward() {
        guard let nextStep = WizardStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = nextStep
    }

    func goBack() {
        guard let prevStep = WizardStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prevStep
    }
}

// MARK: - Progress Steps View

struct ProgressStepsView: View {
    let currentStep: WizardStep
    let totalSteps: Int

    private let stepLabels = ["Welcome", "Source", "Destination", "Policy", "Backup"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<totalSteps, id: \.self) { index in
                HStack(spacing: 4) {
                    Circle()
                        .fill(index <= currentStep.rawValue ? Color.protonPurple : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)

                    if index < totalSteps - 1 {
                        Rectangle()
                            .fill(index < currentStep.rawValue ? Color.protonPurple : Color.secondary.opacity(0.3))
                            .frame(height: 2)
                    }
                }
            }
        }
        .frame(height: 8)
    }
}

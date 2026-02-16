import SwiftUI

/// Setup wizard step for enabling the FinderSync extension.
struct FinderExtensionStepView: View {
    @EnvironmentObject var wizardState: WizardState

    @State private var extensionEnabled = false
    @State private var checkingStatus = false

    private let finderSyncHelper = FinderSyncHelper.shared

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .padding(.top, 20)

            // Title
            Text("Finder Progress Badges")
                .font(.title)
                .fontWeight(.semibold)

            // Description
            Text("See backup progress directly in Finder with badge icons on your files and folders.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            // Badge preview
            HStack(spacing: 32) {
                BadgePreviewItem(
                    icon: "arrow.triangle.2.circlepath",
                    color: .blue,
                    label: "Syncing"
                )
                BadgePreviewItem(
                    icon: "arrow.down.circle.fill",
                    color: .blue,
                    label: "Downloading"
                )
                BadgePreviewItem(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    label: "Complete"
                )
            }
            .padding(.vertical, 20)

            Divider()
                .frame(maxWidth: 400)

            // Status and action
            if !finderSyncHelper.isExtensionAvailable() {
                // Extension not bundled (dev build)
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)

                    Text("Finder extension not available")
                        .font(.headline)

                    Text("This feature requires the full app bundle.\nUse `make package` to build with the extension.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else if extensionEnabled {
                // Extension is enabled
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.green)

                    Text("Finder extension enabled!")
                        .font(.headline)
                        .foregroundStyle(.green)

                    Text("You'll see progress badges on your backup destination.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                // Extension needs to be enabled
                VStack(spacing: 16) {
                    Text("Enable the extension to see badges in Finder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button(action: enableExtension) {
                        HStack {
                            Image(systemName: "gearshape")
                            Text("Open System Settings")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.protonPurple)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("In System Settings:")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("1. Go to Privacy & Security → Extensions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("2. Click 'Added Extensions' → 'Finder'")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("3. Enable 'Proton Backup Finder Extension'")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                    .padding(.top, 8)

                    Button("Check Status") {
                        checkExtensionStatus()
                    }
                    .buttonStyle(.bordered)
                    .disabled(checkingStatus)
                }
                .padding()
            }

            Spacer()

            // Skip option
            if !extensionEnabled && finderSyncHelper.isExtensionAvailable() {
                Text("You can enable this later in Settings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            checkExtensionStatus()
        }
    }

    private func enableExtension() {
        _ = finderSyncHelper.requestEnableExtension()
    }

    private func checkExtensionStatus() {
        checkingStatus = true
        // Small delay to allow the extension to start after being enabled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            extensionEnabled = finderSyncHelper.isExtensionEnabled()
            wizardState.finderExtensionEnabled = extensionEnabled
            checkingStatus = false
        }
    }
}

// MARK: - Badge Preview Item

struct BadgePreviewItem: View {
    let icon: String
    let color: Color
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 48, height: 48)

                Image(systemName: "doc.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)

                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(color)
                    .offset(x: 14, y: 14)
            }

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    FinderExtensionStepView()
        .environmentObject(WizardState())
        .frame(width: 500, height: 600)
}

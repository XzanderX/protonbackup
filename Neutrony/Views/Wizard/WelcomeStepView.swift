import SwiftUI

/// First step of the setup wizard: explains what the app does.
struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "externaldrive.badge.icloud")
                .font(.system(size: 56))
                .foregroundColor(.protonPurple)

            Text("Welcome to Neutrony")
                .font(.title)
                .fontWeight(.semibold)

            Text("Automatically back up your Proton Drive files to an external drive.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 16) {
                StepExplanationRow(
                    icon: "folder.fill.badge.gearshape",
                    title: "Proton Drive Folder",
                    description: "Synced by the official Proton Drive app"
                )

                Image(systemName: "arrow.down")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)

                StepExplanationRow(
                    icon: "externaldrive.fill",
                    title: "External Backup",
                    description: "Your selected external drive for safe keeping"
                )
            }
            .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 8) {
                Text("Requires the Proton Drive macOS app to be installed.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Link("Download Proton Drive", destination: URL(string: "https://proton.me/drive/download")!)
                    .font(.caption)
            }
        }
    }
}

struct StepExplanationRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.protonPurple)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

import SwiftUI

/// First step of the setup wizard: explains what the app does.
struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "externaldrive.badge.icloud")
                .font(.system(size: 56))
                .foregroundColor(.protonPurple)

            Text("Welcome to Proton Backup")
                .font(.title)
                .fontWeight(.semibold)

            Text("Automatically back up your Proton Drive files to an external drive.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 16) {
                StepExplanationRow(
                    icon: "cloud.fill",
                    title: "Proton Drive",
                    description: "Your encrypted files in the cloud"
                )

                Image(systemName: "arrow.down")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)

                StepExplanationRow(
                    icon: "internaldrive",
                    title: "Local Mirror",
                    description: "A local copy on your Mac for fast access"
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

            Text("This wizard will guide you through the setup in a few steps.")
                .font(.caption)
                .foregroundColor(.secondary)
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

import SwiftUI

/// Final wizard step: ready to start backup.
struct InitialBackupStepView: View {
    @EnvironmentObject var wizardState: WizardState

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.statusGreen)

            Text("Ready to Back Up")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Click \"Finish Setup\" to complete configuration and start your first backup automatically.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer()

            // Summary of settings
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(icon: "folder.fill", label: "Source", value: wizardState.sourcePath?.components(separatedBy: "/").last ?? "Proton Drive")

                SettingRow(icon: "externaldrive.fill", label: "Destination", value: wizardState.destinationName ?? "External Drive")

                SettingRow(icon: "doc.on.doc.fill", label: "Deletion Policy", value: wizardState.deletionPolicy.displayName)

                SettingRow(icon: "clock.arrow.circlepath", label: "Keep Versions", value: wizardState.keepVersions ? "Yes" : "No")
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .frame(maxWidth: 400)

            Spacer()
        }
    }
}

/// A row showing a setting summary.
private struct SettingRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.protonPurple)
                .frame(width: 20)

            Text(label)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .fontWeight(.medium)
        }
        .font(.caption)
    }
}

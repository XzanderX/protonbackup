import SwiftUI

/// Mirror location step: configure where the local mirror of Proton Drive is stored.
struct MirrorLocationStepView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: WizardState

    @State private var availableSpace: String?
    @State private var mirrorSize: String = "Empty"
    @State private var spaceWarning: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "internaldrive")
                .font(.system(size: 40))
                .foregroundColor(.protonPurple)

            Text("Local Mirror Location")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Proton Backup keeps a local copy of your Proton Drive files on this Mac. This allows fast incremental backups to your external drive.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            // Current path display
            VStack(alignment: .leading, spacing: 8) {
                Text("Mirror folder:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.protonPurple)

                    Text(wizardState.mirrorPath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Change…") {
                        chooseFolder()
                    }
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            .frame(maxWidth: 400)

            // Space info
            VStack(spacing: 4) {
                if let availableSpace {
                    Label("Available: \(availableSpace)", systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Label("Mirror size: \(mirrorSize)", systemImage: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let warning = spaceWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.statusYellow)
                    .frame(maxWidth: 400)
            }

            Button("Reset to Default") {
                wizardState.mirrorPath = BackupConfiguration.defaultMirrorPath
                checkSpace()
            }
            .font(.caption)

            Spacer()
        }
        .onAppear {
            checkSpace()
        }
    }

    private func chooseFolder() {
        guard let url = BookmarkManager.selectFolder(
            title: "Choose Mirror Location",
            message: "Select where the local mirror of your Proton Drive will be stored."
        ) else { return }

        wizardState.mirrorPath = url.path
        checkSpace()
    }

    private func checkSpace() {
        let path = wizardState.mirrorPath

        // Check available space
        if let space = DiskSpaceUtility.availableSpace(atPath: (path as NSString).deletingLastPathComponent) {
            availableSpace = DiskSpaceUtility.formatBytes(space)
        }

        // Check existing mirror size
        let size = DiskSpaceUtility.directorySize(atPath: path)
        mirrorSize = size > 0 ? DiskSpaceUtility.formatBytes(size) : "Empty"

        // Space warning
        spaceWarning = DiskSpaceUtility.checkSpaceWarning(
            atPath: (path as NSString).deletingLastPathComponent,
            requiredBytes: 0
        )
    }
}

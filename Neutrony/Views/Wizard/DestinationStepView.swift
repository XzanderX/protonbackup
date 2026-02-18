import SwiftUI

/// Destination step: choose external drive/folder for backups.
struct DestinationStepView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: WizardState

    @State private var availableVolumes: [VolumeInfo] = []
    @State private var selectedPath: String?
    @State private var spaceWarning: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "externaldrive.fill.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(.protonPurple)

            Text("Choose Backup Destination")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select the external drive or folder where your backups will be stored. The app remembers this location even if the drive letter changes.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            // Available external volumes
            if !availableVolumes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connected external drives:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(availableVolumes) { volume in
                        VolumeRow(volume: volume, isSelected: selectedPath == volume.mountPath)
                            .onTapGesture {
                                selectVolume(volume)
                            }
                    }
                }
                .frame(maxWidth: 400)
            } else {
                Label("No external drives detected", systemImage: "externaldrive.badge.xmark")
                    .foregroundColor(.secondary)
            }

            // Manual folder picker
            Button("Choose Folder…") {
                chooseFolder()
            }

            // Selected destination info
            if let path = wizardState.destinationPath {
                VStack(spacing: 4) {
                    Label(wizardState.destinationName ?? "Selected", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.statusGreen)

                    Text(path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 400)
            }

            if let warning = spaceWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.statusYellow)
                    .frame(maxWidth: 400)
            }

            Spacer()
        }
        .onAppear {
            refreshVolumes()
        }
    }

    private func refreshVolumes() {
        availableVolumes = appState.driveMonitor.getExternalVolumes()
    }

    private func selectVolume(_ volume: VolumeInfo) {
        let url = URL(fileURLWithPath: volume.mountPath)
        do {
            let bookmark = try BookmarkManager.createReadWriteBookmark(for: url)
            wizardState.destinationBookmark = bookmark
            wizardState.destinationName = volume.name
            wizardState.destinationPath = volume.mountPath
            selectedPath = volume.mountPath

            checkSpace(atPath: volume.mountPath)
        } catch {
            appState.logService.log(.error, category: .config,
                                     message: "Failed to create bookmark: \(error.localizedDescription)")
        }
    }

    private func chooseFolder() {
        guard let url = BookmarkManager.selectFolder(
            title: "Choose Backup Destination",
            message: "Select the folder where Neutrony will store your backup files."
        ) else { return }

        do {
            let bookmark = try BookmarkManager.createReadWriteBookmark(for: url)
            wizardState.destinationBookmark = bookmark
            wizardState.destinationName = url.lastPathComponent
            wizardState.destinationPath = url.path
            selectedPath = url.path

            checkSpace(atPath: url.path)
        } catch {
            appState.logService.log(.error, category: .config,
                                     message: "Failed to create bookmark: \(error.localizedDescription)")
        }
    }

    private func checkSpace(atPath path: String) {
        spaceWarning = DiskSpaceUtility.checkSpaceWarning(atPath: path, requiredBytes: 0)
    }
}

// MARK: - Volume Row

struct VolumeRow: View {
    let volume: VolumeInfo
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: volume.isEjectable ? "externaldrive.fill" : "internaldrive.fill")
                .foregroundColor(.protonPurple)

            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.body)
                Text("\(volume.formattedAvailableSpace) available of \(volume.formattedTotalSpace)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.statusGreen)
            }
        }
        .padding(8)
        .background(isSelected ? Color.protonPurple.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.protonPurple : Color.clear, lineWidth: 1)
        )
    }
}

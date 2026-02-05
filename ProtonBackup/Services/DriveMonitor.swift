import Foundation
import DiskArbitration

/// Monitors external drive connections and disconnections.
/// Notifies the app when the configured backup destination becomes available.
final class DriveMonitor {

    private let logService: LogService
    private var session: DASession?
    private var runLoop: CFRunLoop?

    /// Called when the configured destination volume becomes available.
    var onDestinationConnected: ((VolumeInfo) -> Void)?

    /// Called when the configured destination volume is disconnected.
    var onDestinationDisconnected: (() -> Void)?

    /// Called when any external volume is mounted (for UI display).
    var onExternalVolumeAppeared: ((VolumeInfo) -> Void)?

    init(logService: LogService) {
        self.logService = logService
    }

    // MARK: - Public API

    /// Start monitoring disk mount/unmount events.
    func startMonitoring() {
        guard session == nil else { return }

        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else {
            logService.log(.error, category: .driveMonitor, message: "Failed to create DiskArbitration session")
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()

        // Register for disk appeared events
        DARegisterDiskAppearedCallback(session, nil, diskAppearedCallback, context)

        // Register for disk disappeared events
        DARegisterDiskDisappearedCallback(session, nil, diskDisappearedCallback, context)

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        logService.log(.info, category: .driveMonitor, message: "Drive monitoring started")
    }

    /// Stop monitoring.
    func stopMonitoring() {
        guard let session else { return }

        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.session = nil

        logService.log(.info, category: .driveMonitor, message: "Drive monitoring stopped")
    }

    /// Get information about currently mounted external volumes.
    func getExternalVolumes() -> [VolumeInfo] {
        let fm = FileManager.default
        guard let volumeURLs = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeNameKey,
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeUUIDStringKey,
                .volumeIsInternalKey
            ],
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        return volumeURLs.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                .volumeUUIDStringKey, .volumeIsInternalKey
            ]) else { return nil }

            let isInternal = values.volumeIsInternal ?? true
            let isRemovable = values.volumeIsRemovable ?? false
            let isEjectable = values.volumeIsEjectable ?? false

            // Only return external/removable volumes
            guard !isInternal || isRemovable || isEjectable else { return nil }

            return VolumeInfo(
                id: values.volumeUUIDString ?? url.path,
                name: values.volumeName ?? url.lastPathComponent,
                mountPath: url.path,
                totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
                availableCapacity: Int64(values.volumeAvailableCapacity ?? 0),
                isExternal: !isInternal,
                isEjectable: isEjectable
            )
        }
    }

    /// Check if a specific destination path is currently available.
    func isDestinationAvailable(bookmark: Data?) -> (available: Bool, path: String?) {
        guard let bookmark else { return (false, nil) }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return (false, nil)
        }

        let available = FileManager.default.fileExists(atPath: url.path)
        return (available, url.path)
    }

    // MARK: - Callbacks

    private func handleDiskAppeared(disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return }

        let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String ?? "Unknown"
        let mountPath = (description[kDADiskDescriptionVolumePathKey as String] as? URL)?.path ?? ""
        let isInternal = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true
        let isEjectable = description[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false

        guard !isInternal || isEjectable else { return }

        logService.log(.info, category: .driveMonitor, message: "External volume appeared: \(volumeName) at \(mountPath)")

        let volumeURL = URL(fileURLWithPath: mountPath)
        let values = try? volumeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeUUIDStringKey
        ])

        let info = VolumeInfo(
            id: values?.volumeUUIDString ?? mountPath,
            name: volumeName,
            mountPath: mountPath,
            totalCapacity: Int64(values?.volumeTotalCapacity ?? 0),
            availableCapacity: Int64(values?.volumeAvailableCapacity ?? 0),
            isExternal: !isInternal,
            isEjectable: isEjectable
        )

        DispatchQueue.main.async { [weak self] in
            self?.onExternalVolumeAppeared?(info)
            self?.onDestinationConnected?(info)
        }
    }

    private func handleDiskDisappeared(disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return }

        let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String ?? "Unknown"
        let isInternal = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true

        guard !isInternal else { return }

        logService.log(.info, category: .driveMonitor, message: "External volume disappeared: \(volumeName)")

        DispatchQueue.main.async { [weak self] in
            self?.onDestinationDisconnected?()
        }
    }
}

// MARK: - C Callbacks

private func diskAppearedCallback(disk: DADisk, context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handleDiskAppeared(disk: disk)
}

private func diskDisappearedCallback(disk: DADisk, context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handleDiskDisappeared(disk: disk)
}

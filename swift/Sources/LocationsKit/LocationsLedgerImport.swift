import Foundation

public enum LocationsLedgerImportError: Error {
    case existingData
    case noPersistentStore
    case emptyLedger
    case invalidPendingCapture
}

@MainActor
extension BlipTimelineStore {
    public var hasCapturedData: Bool {
        !days.isEmpty || !ledger.observations.isEmpty || !ledger.visits.isEmpty
    }

    /// Imports the complete Blip on-device ledger. The input files are copied
    /// unchanged before any new Locations state is written.
    public func importLegacyLedger(
        from ledgerURL: URL,
        pendingCaptureURL: URL? = nil
    ) throws {
        guard !hasCapturedData, !trackingEnabled else {
            throw LocationsLedgerImportError.existingData
        }
        guard let fileURL = persistence.fileURL else {
            throw LocationsLedgerImportError.noPersistentStore
        }

        let ledgerData = try Data(contentsOf: ledgerURL)
        var imported = try BlipTimelinePersistence.decoder.decode(
            BlipTimelineLedger.self,
            from: ledgerData
        )
        guard !imported.days.isEmpty || !imported.observations.isEmpty || !imported.visits.isEmpty else {
            throw LocationsLedgerImportError.emptyLedger
        }

        let pendingData = try pendingCaptureURL.map { try Data(contentsOf: $0) }
        let pending: BlipTimelinePendingCapturePayload
        if let pendingData {
            pending = try BlipTimelinePersistence.decoder.decode(
                BlipTimelinePendingCapturePayload.self,
                from: pendingData
            )
        } else {
            pending = .empty
        }

        let backupDirectory = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        try ledgerData.write(
            to: backupDirectory.appendingPathComponent("blip-timeline-v1.json"),
            options: .atomic
        )
        if let pendingData {
            try pendingData.write(
                to: backupDirectory.appendingPathComponent("blip-pending-capture-v1.json"),
                options: .atomic
            )
        }

        // Old deletion intent applies to Blip's mirror, never to the new server.
        imported.trackingEnabled = false
        imported.backgroundCaptureStatus = .unavailable
        imported.pendingDeleteAll = false
        imported.pendingDeletionDateKeys = []
        imported.pendingDateKeys.formUnion(imported.days.map(\.dateKey))
        try persistence.save(imported)

        ledger = imported
        days = imported.days.sorted { $0.date < $1.date }
        trackingEnabled = false
        trackingState = .stopped
        backgroundCaptureStatus = .unavailable
        for observation in pending.observations {
            ingest(observation)
        }
        for visit in pending.visits {
            _ = ingest(visit)
        }
    }
}

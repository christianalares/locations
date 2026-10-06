import Foundation
#if os(iOS)
import UIKit
#endif

struct LocationsTimelineUpload: Codable, Sendable {
    let sourceDeviceID: String
    let generation: Int
    let revision: Int
    let updatedAt: Date
    var days: [BlipTimelineDay]
    let deletedDateKeys: [String]
    let deleteAll: Bool
    let ledger: BlipTimelineLedger
    var serverURL: String? = nil
}

struct LocationsTimelineRestore: Decodable {
    let generation: Int
    let updatedAt: Date?
    let days: [BlipTimelineDay]
    let ledger: BlipTimelineLedger?
}

private struct LocationsDeviceRegistration: Codable {
    let sourceDeviceID: String
}

private struct LocationsGeneration: Decodable {
    let generation: Int
}

private struct LocationsUploadReceipt: Decodable {
    let accepted: Bool
}

@MainActor
extension BlipTimelineStore {
    var hasPendingCloudBackup: Bool {
        ledger.syncRevision > ledger.syncedRevision || pendingSyncCount > 0
    }

    // An empty installation restores before attempting any upload. An existing
    // phone registers without claiming another phone's recording authority.
    func prepareCloudBackup(using session: BlipCloudSession) async throws {
        guard let serverURL = session.baseURL?.absoluteString else {
            throw LocationsSyncError.unauthorized
        }

        if ledger.syncServerURL != serverURL {
            ledger.syncGeneration = nil
        }
        guard ledger.syncGeneration == nil else { return }
        let body = try BlipTimelinePersistence.encoder.encode(
            LocationsDeviceRegistration(sourceDeviceID: sourceDeviceID)
        )
        let isEmpty = !hasCapturedData && !trackingEnabled && ledger.savedPlaces.isEmpty
            && !ledger.pendingDeleteAll && ledger.pendingDeletionDateKeys.isEmpty
        if isEmpty {
            let data = try await session.authorizedData(
                path: "native/v1/timeline/restore", method: "POST", body: body
            )
            let restored = try BlipTimelinePersistence.decoder.decode(
                LocationsTimelineRestore.self, from: data
            )
            try installCloudBackup(restored, serverURL: serverURL)
        } else {
            let data = try await session.authorizedData(
                path: "native/v1/timeline/register", method: "POST", body: body
            )
            let generation = try BlipTimelinePersistence.decoder.decode(
                LocationsGeneration.self, from: data
            ).generation
            ledger.syncGeneration = generation
            ledger.syncServerURL = serverURL
            ledger.pendingDateKeys.formUnion(days.map(\.dateKey))
            persistLedger()
        }
    }

    func installCloudBackup(_ backup: LocationsTimelineRestore, serverURL: String) throws {
        guard !hasCapturedData, ledger.savedPlaces.isEmpty,
              !trackingEnabled, !ledger.pendingDeleteAll,
              ledger.pendingDeletionDateKeys.isEmpty else {
            throw LocationsLedgerImportError.existingData
        }

        var restored = backup.ledger ?? .empty
        restored.days = backup.days.sorted { $0.date < $1.date }
        restored.trackingEnabled = false
        restored.backgroundCaptureStatus = .unavailable
        restored.pendingDateKeys = []
        restored.pendingDeletionDateKeys = []
        restored.pendingDeleteAll = false
        restored.pendingDeleteAllRevision = nil
        restored.syncGeneration = backup.generation
        restored.syncServerURL = serverURL
        restored.syncRevision = 0
        restored.syncedRevision = 0
        restored.lastBackupAt = backup.updatedAt
        if backup.ledger == nil {
            // Legacy cloud days have no raw ledger or edit intent. Keep their
            // captured representation rather than rebuilding from new fixes.
            restored.manuallyEditedDateKeys.formUnion(backup.days.map(\.dateKey))
        }
        // A replacement phone cannot observe what happened during the gap.
        // Bound an unfinished visit at the last backup, never at today's date.
        if let boundary = backup.updatedAt {
            restored.visits = restored.visits.map { visit in
                guard visit.departureDate == nil else { return visit }
                let end = max(visit.arrivalDate, boundary)
                return visit.ending(at: end, inferredUpperBound: end)
            }
        }
        try persistence.save(restored)

        ledger = restored
        days = restored.days
        trackingEnabled = false
        trackingState = .stopped
        backgroundCaptureStatus = .unavailable
        lastSyncAt = backup.updatedAt
    }

    func makeCloudUpload(now: Date = Date()) throws -> LocationsTimelineUpload {
        guard let generation = ledger.syncGeneration else {
            throw LocationsSyncError.invalidResponse
        }

        var backup = ledger
        backup.days = []
        backup.pendingDateKeys = []
        backup.pendingDeletionDateKeys = []
        backup.pendingDeleteAll = false
        backup.pendingDeleteAllRevision = nil
        backup.trackingEnabled = false
        backup.backgroundCaptureStatus = nil
        backup.syncGeneration = nil
        backup.syncServerURL = nil
        backup.syncRevision = 0
        backup.syncedRevision = 0
        backup.lastBackupAt = nil
        backup.savedPlaces = backup.savedPlaces.map(\.cloudReference)
        backup.visitPlaceAssignments = backup.visitPlaceAssignments.mapValues { assignment in
            .init(place: assignment.place.cloudReference, remembersPlace: assignment.remembersPlace)
        }
        var upload = LocationsTimelineUpload(
            sourceDeviceID: sourceDeviceID,
            generation: generation,
            revision: max(1, ledger.syncRevision),
            updatedAt: now,
            days: [],
            deletedDateKeys: ledger.pendingDeletionDateKeys.sorted(),
            deleteAll: ledger.pendingDeleteAll,
            ledger: backup
        )
        upload.serverURL = ledger.syncServerURL
        // Historical imports can be large. Bound each batch while retaining
        // every day's route, and leave the remaining days queued durably.
        var byteCount = try BlipTimelinePersistence.encoder.encode(upload).count
        for day in days.filter({ ledger.pendingDateKeys.contains($0.dateKey) })
            .sorted(by: { $0.dateKey > $1.dateKey }) {
            let safe = cloudSafeDay(day)
            let dayBytes = try BlipTimelinePersistence.encoder.encode(safe).count
            if !upload.days.isEmpty && (upload.days.count >= 10 || byteCount + dayBytes > 28_000_000) {
                break
            }
            upload.days.append(safe)
            byteCount += dayBytes
        }

        return upload
    }

    func acknowledgeCloudUpload(_ upload: LocationsTimelineUpload) {
        guard upload.sourceDeviceID == sourceDeviceID,
              upload.generation == ledger.syncGeneration,
              upload.serverURL == ledger.syncServerURL else { return }

        for day in upload.days {
            if let local = days.first(where: { $0.dateKey == day.dateKey }),
               cloudSafeDay(local) == day {
                ledger.pendingDateKeys.remove(day.dateKey)
            }
        }
        for dateKey in upload.deletedDateKeys where !days.contains(where: { $0.dateKey == dateKey }) {
            ledger.pendingDeletionDateKeys.remove(dateKey)
        }
        if upload.deleteAll && (ledger.pendingDeleteAllRevision ?? 0) <= upload.revision {
            ledger.pendingDeleteAll = false
            ledger.pendingDeleteAllRevision = nil
        }
        ledger.syncedRevision = max(ledger.syncedRevision, upload.revision)
        ledger.lastBackupAt = max(ledger.lastBackupAt ?? .distantPast, upload.updatedAt)
        lastSyncAt = ledger.lastBackupAt
        syncError = nil
        syncRetryDelay = 15
        persistLedger(scheduleSync: false)
        // Further batches need a new revision even if capture did not change.
        if pendingSyncCount > 0 && ledger.syncRevision <= ledger.syncedRevision {
            ledger.syncRevision = ledger.syncedRevision + 1
            persistLedger(scheduleSync: false)
        }
#if os(iOS)
        scheduleAutomaticSync()
#endif
    }

    func uploadCloudBackup(using session: BlipCloudSession) async throws {
        // Establish a revision for upgrading a ledger that has no queued days.
        if ledger.syncRevision == 0 {
            ledger.syncRevision = 1
            persistLedger(scheduleSync: false)
        }
        guard hasPendingCloudBackup else { return }

        ledger.pendingDateKeys.formIntersection(days.map(\.dateKey))
        persistLedger(scheduleSync: false)

        let upload = try makeCloudUpload()
        let body = try BlipTimelinePersistence.encoder.encode(upload)
        let data = try await session.uploadBackup(body: body)
        guard try BlipTimelinePersistence.decoder.decode(
            LocationsUploadReceipt.self, from: data
        ).accepted else {
            throw LocationsSyncError.server(409)
        }

        acknowledgeCloudUpload(upload)
    }

#if os(iOS)
    func scheduleAutomaticSync(immediate: Bool = false) {
        guard !usesDemoData, !isSyncing, cloudSession?.isConnected == true,
              hasPendingCloudBackup, automaticSyncTask == nil else { return }

        let backgroundChange = UIApplication.shared.applicationState != .active && syncRetryDelay == 15
        let delay = immediate || backgroundChange ? 0 : syncRetryDelay
        let syncID = UUID()
        automaticSyncID = syncID
        automaticSyncTask = Task { [weak self] in
            do {
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                guard let self, !Task.isCancelled, automaticSyncID == syncID else { return }
                automaticSyncTask = nil
                automaticSyncID = nil
                await automaticallyUploadCloudBackup()
            } catch {
                if self?.automaticSyncID == syncID {
                    self?.automaticSyncTask = nil
                    self?.automaticSyncID = nil
                }
            }
        }
    }

    private func automaticallyUploadCloudBackup() async {
        guard !isSyncing, let cloudSession, cloudSession.isConnected else {
            scheduleAutomaticSync()
            return
        }

        isSyncing = true
        do {
            try await prepareCloudBackup(using: cloudSession)
            try await uploadCloudBackup(using: cloudSession)
            syncRetryDelay = 15
        } catch {
            syncError = error.localizedDescription
            syncRetryDelay = min(syncRetryDelay * 2, 300)
        }
        isSyncing = false
        scheduleAutomaticSync()
    }

    public func flushPendingCloudBackup() {
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        automaticSyncID = nil
        scheduleAutomaticSync(immediate: true)
    }
#endif
}

extension BlipTimelineSavedPlace {
    var cloudReference: Self {
        updating(residentContacts: residentContacts.map(\.cloudReference))
    }
}

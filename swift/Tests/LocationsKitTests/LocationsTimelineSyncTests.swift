// Fictional Null Island fixtures; dates and identities are synthetic.
import Foundation
import Testing
import Synchronization
@testable import LocationsKit

@MainActor
struct LocationsTimelineSyncTests {
    private func store() -> BlipTimelineStore {
        BlipTimelineStore(arguments: [], calendar: .autoupdatingCurrent, cloudSession: nil, persistence: .inMemory)
    }

    private func day(at date: Date, title: String = "Home") -> BlipTimelineDay {
        BlipTimelineDay(
            date: date, timeZoneIdentifier: "UTC", coverage: .partial,
            entries: [.init(id: "visit-one", kind: .visit, title: title, startDate: date,
                coordinate: .init(latitude: 0, longitude: 0), confidence: .observed)],
            metrics: nil, updatedAt: date, sourceDeviceID: "phone"
        )
    }

    @Test
    func acknowledgmentKeepsEditsMadeWhileUploadingAndPersistsRemainingBackup() throws {
        let store = store()
        let date = Date(timeIntervalSince1970: 969_545_600)
        store.replaceDays([day(at: date)])
        store.ledger.syncGeneration = 1
        store.ledger.pendingDateKeys.insert(store.days[0].dateKey)
        let upload = try store.makeCloudUpload(now: date)

        store.replaceDays([day(at: date.addingTimeInterval(1), title: "Edited home")])
        store.acknowledgeCloudUpload(upload)

        #expect(store.ledger.pendingDateKeys.contains(store.days[0].dateKey))
        #expect(store.hasPendingCloudBackup)
        #expect(store.days[0].entries[0].title == "Edited home")
        let latest = try store.makeCloudUpload(now: date.addingTimeInterval(2))
        store.acknowledgeCloudUpload(latest)
        #expect(store.ledger.pendingDateKeys.isEmpty)
        #expect(!store.hasPendingCloudBackup)
    }

    @Test
    func backupCarriesEvidenceAndPlaceEditsWithoutContactIdentifiers() throws {
        let store = store()
        let date = Date(timeIntervalSince1970: 969_545_600)
        let visit = BlipTimelineVisitObservation(id: UUID(), arrivalDate: date, departureDate: nil,
            coordinate: .init(latitude: 0, longitude: 0), horizontalAccuracy: 10, timeZoneIdentifier: "UTC")
        let place = BlipTimelineSavedPlace(id: "home", title: "Home", subtitle: nil,
            coordinate: visit.coordinate, isHome: true, residentContacts: [
                .init(id: "alice", contactIdentifier: "device-alice", displayName: "Alice"),
                .init(id: "bob", contactIdentifier: "device-bob", displayName: "Bob"),
            ])
        store.ledger.visits = [visit]
        store.ledger.savedPlaces = [place]
        store.ledger.visitPlaceAssignments[visit.id.uuidString.lowercased()] = .init(place: place, remembersPlace: true)
        store.ledger.manuallyEditedDateKeys = ["2000-10-05"]
        store.ledger.syncGeneration = 1
        store.ledger.syncRevision = 1
        let upload = try store.makeCloudUpload(now: date)
        let data = try BlipTimelinePersistence.encoder.encode(upload)
        let decoded = try BlipTimelinePersistence.decoder.decode(LocationsTimelineUpload.self, from: data)

        #expect(decoded.ledger.visits[0].id == visit.id)
        #expect(decoded.ledger.savedPlaces[0].residentContacts.count == 2)
        #expect(decoded.ledger.manuallyEditedDateKeys == ["2000-10-05"])
        #expect(!String(decoding: data, as: UTF8.self).contains("device-alice"))
        #expect(!String(decoding: data, as: UTF8.self).contains("device-bob"))
        #expect(decoded.ledger.days.isEmpty)
    }

    @Test
    func restorationKeepsHistoryAndBoundsAnOpenVisitAtLastBackup() throws {
        let store = store()
        let date = Date(timeIntervalSince1970: 969_545_600)
        var ledger = BlipTimelineLedger.empty
        ledger.visits = [.init(id: UUID(), arrivalDate: date, departureDate: nil,
            coordinate: .init(latitude: 0, longitude: 0), horizontalAccuracy: 10, timeZoneIdentifier: "UTC")]
        ledger.manuallyEditedDateKeys = [day(at: date).dateKey]
        ledger.trackingEnabled = true
        let backup = LocationsTimelineRestore(generation: 2, updatedAt: date.addingTimeInterval(60),
            days: [day(at: date)], ledger: ledger)

        try store.installCloudBackup(backup, serverURL: "https://example.test")

        #expect(store.days == backup.days)
        #expect(!store.trackingEnabled)
        #expect(store.ledger.visits[0].departureDate == backup.updatedAt)
        #expect(store.ledger.visits[0].departureWasReported == false)
        #expect(store.ledger.observations.isEmpty)
        #expect(store.ledger.syncGeneration == 2)
        #expect(throws: LocationsLedgerImportError.existingData) {
            try store.installCloudBackup(backup, serverURL: "https://example.test")
        }
    }

    @Test
    func legacyCloudRestoreDoesNotInventRawObservationsAndKeepsDaysFromRebuilding() throws {
        let store = store()
        let date = Date(timeIntervalSince1970: 969_545_600)
        let backup = LocationsTimelineRestore(generation: 1, updatedAt: nil, days: [day(at: date)], ledger: nil)

        try store.installCloudBackup(backup, serverURL: "https://example.test")
        store.materializeStationaryDays(now: date.addingTimeInterval(86_400))

        #expect(store.days[0].entries == backup.days[0].entries)
        #expect(store.ledger.observations.isEmpty)
        #expect(store.ledger.visits.isEmpty)
        #expect(store.ledger.manuallyEditedDateKeys.contains(backup.days[0].dateKey))
    }

    @Test
    func historicalBatchesAdvanceRevisionAndAnOldPhoneCannotAcknowledgeAfterTakeover() throws {
        let store = store()
        let date = Date(timeIntervalSince1970: 969_545_600)
        store.replaceDays((0..<12).map { day(at: date.addingTimeInterval(Double($0) * 86_400)) })
        store.ledger.pendingDateKeys.formUnion(store.days.map(\.dateKey))
        store.ledger.syncGeneration = 1
        let first = try store.makeCloudUpload(now: date)
        #expect(first.days.count == 10)
        store.acknowledgeCloudUpload(first)
        #expect(store.ledger.pendingDateKeys.count == 2)
        let second = try store.makeCloudUpload(now: date)
        #expect(second.revision > first.revision)
        store.ledger.syncGeneration = 2
        store.acknowledgeCloudUpload(second)
        #expect(store.ledger.pendingDateKeys.count == 2)
    }

    @Test
    func failedUploadRemainsDurableAndRetryUploadsTheLatestEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BlipTimelinePersistence(fileURL: directory.appendingPathComponent("timeline.json"))
        let store = BlipTimelineStore(arguments: [], calendar: .autoupdatingCurrent, cloudSession: nil, persistence: persistence)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncTestURLProtocol.self]
        let session = BlipCloudSession(session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://locations.test")!, token: "test-device-token")
        let date = Date(timeIntervalSince1970: 969_545_600)
        store.replaceDays([day(at: date)])
        try await store.prepareCloudBackup(using: session)

        do {
            try await store.uploadCloudBackup(using: session)
            Issue.record("The first upload should fail")
        } catch {
            #expect(store.hasPendingCloudBackup)
            #expect(persistence.load().pendingDateKeys.contains(store.days[0].dateKey))
        }
        store.replaceDays([day(at: date.addingTimeInterval(1), title: "Edited offline")])
        try await store.uploadCloudBackup(using: session)

        #expect(!store.hasPendingCloudBackup)
        #expect(persistence.load().pendingDateKeys.isEmpty)
        let payloads = SyncTestURLProtocol.state.withLock { $0.payloads }
        let latest = try BlipTimelinePersistence.decoder.decode(LocationsTimelineUpload.self, from: #require(payloads.last))
        #expect(latest.days[0].entries[0].title == "Edited offline")
    }

    @Test
    func backupCompressionRoundTripsAndRejectsCorruption() throws {
        let original = Data(String(repeating: "GPS capture and place metadata ", count: 1000).utf8)
        let compressed = try original.locationsGzipped()

        #expect(compressed.count < original.count / 10)
        #expect(try compressed.locationsGunzip() == original)
        #expect(throws: LocationsCompressionError.self) {
            try Data("not gzip".utf8).locationsGunzip()
        }
    }
}

private final class SyncTestURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var payloads: [Data] = []
    }
    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isUpload = request.url?.path.hasSuffix("/sync") == true
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        if request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" {
            data = (try? data.locationsGunzip()) ?? Data()
        }
        let status = isUpload ? Self.state.withLock { state in
            state.payloads.append(data)
            return state.payloads.count == 1 ? 500 : 200
        } : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((isUpload ? "{\"accepted\":true}" : "{\"generation\":1}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

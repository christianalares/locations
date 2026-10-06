// Fictional Null Island fixtures; dates and identities are synthetic.
import Foundation
import Testing
@testable import LocationsKit

@MainActor
struct BlipTimelineDepartureRecoveryTests {
    private let start = ISO8601DateFormatter().date(from: "2000-10-05T14:30:00Z")!
    private var end: Date { start.addingTimeInterval(1_800) }
    private var origin: BlipTimelineVisitObservation {
        BlipTimelineVisitObservation(
            id: UUID(), arrivalDate: start.addingTimeInterval(-86_400), departureDate: nil,
            coordinate: .init(latitude: 0, longitude: 0), horizontalAccuracy: 5,
            timeZoneIdentifier: "Europe/Stockholm"
        )
    }
    private var destination: BlipTimelineVisitObservation {
        BlipTimelineVisitObservation(
            id: UUID(), arrivalDate: end, departureDate: nil,
            coordinate: .init(latitude: 0.12, longitude: 0.06), horizontalAccuracy: 5,
            timeZoneIdentifier: "Europe/Stockholm"
        )
    }
    private var samples: [BlipTimelineLocationObservation] {
        (0...30).map { index in
            BlipTimelineLocationObservation(
                id: UUID(), timestamp: start.addingTimeInterval(Double(index) * 60),
                coordinate: .init(
                    latitude: Double(index) * 0.004,
                    longitude: Double(max(0, index - 15)) * 0.004
                ),
                horizontalAccuracy: 5, speedMetersPerSecond: 15,
                timeZoneIdentifier: "Europe/Stockholm", motion: .automotive
            )
        }
    }
    private func store() -> BlipTimelineStore {
        BlipTimelineStore(
            arguments: [], calendar: .autoupdatingCurrent,
            cloudSession: nil, persistence: .inMemory
        )
    }
    private func journey(in store: BlipTimelineStore) throws -> BlipTimelineEntry {
        let day = try #require(store.days.first { $0.dateKey == "2000-10-05" })
        return try #require(day.entries.first { $0.kind == .journey })
    }

    @Test(arguments: ["beforeArrival", "afterArrival", "legacyBoundary"])
    func recordedMovementRecoversMissingDeparture(delivery: String) throws {
        let store = store()
        let source = origin
        let readings = samples
        store.ledger.visits = [source]
        if delivery == "beforeArrival" {
            store.ingest(readings, now: end)
        } else if delivery == "legacyBoundary" {
            store.ledger.visits = [BlipTimelineVisitObservation(
                id: source.id, arrivalDate: source.arrivalDate, departureDate: end,
                coordinate: source.coordinate, horizontalAccuracy: 5,
                timeZoneIdentifier: source.timeZoneIdentifier, departureWasReported: false
            )]
        }
        store.ingest(destination, now: end.addingTimeInterval(60))
        if delivery != "beforeArrival" {
            #expect(try journey(in: store).startDate == end)
            store.ingest(readings, now: end.addingTimeInterval(120))
        }

        let drive = try journey(in: store)
        #expect(store.ledger.observations.count == readings.count)
        #expect(store.ledger.visits[0].id == source.id)
        #expect(store.ledger.visits[0].departureDate == start)
        #expect(store.ledger.visits[0].inferredDepartureUpperBound == end)
        #expect(drive.startDate == start)
        #expect(drive.endDate == end)
        #expect(drive.route.count >= 31)
        #expect(drive.route.contains(readings[15].coordinate))
        #expect(drive.confidence == .inferred)
        #expect((drive.distanceMeters ?? 0) > BlipTimelineGeometry.distanceMeters(
            source.coordinate, destination.coordinate
        ))
    }

    @Test(arguments: ["none", "stationary", "noise", "inaccurate", "invalid", "gap", "jump", "tooFew"])
    func insufficientMovementKeepsExistingFallback(reason: String) throws {
        let store = store()
        store.ledger.visits = [origin]
        let readings: [BlipTimelineLocationObservation]
        switch reason {
        case "none": readings = []
        case "gap": readings = samples.filter {
            $0.timestamp < start.addingTimeInterval(300) || $0.timestamp > end.addingTimeInterval(-300)
        }
        case "tooFew": readings = [samples[0], samples[30]]
        default:
            readings = samples.enumerated().map { index, point in
                BlipTimelineLocationObservation(
                    id: point.id,
                    timestamp: reason == "jump" ? start.addingTimeInterval(Double(index)) : point.timestamp,
                    coordinate: reason == "noise"
                        ? .init(latitude: Double(index % 3) * 0.0001, longitude: 0)
                        : reason == "invalid"
                            ? .init(latitude: point.coordinate.latitude + 180, longitude: 0)
                            : point.coordinate,
                    horizontalAccuracy: reason == "inaccurate" ? 1_000 : 5,
                    speedMetersPerSecond: reason == "stationary" ? 0 : point.speedMetersPerSecond,
                    timeZoneIdentifier: point.timeZoneIdentifier,
                    motion: reason == "stationary" ? .stationary : .automotive
                )
            }
        }
        store.ingest(readings, now: end)
        store.ingest(destination, now: end.addingTimeInterval(60))

        let drive = try journey(in: store)
        #expect(drive.startDate == end)
        #expect(drive.endDate == end)
        #expect(drive.confidence == .inferred)
        #expect(store.ledger.visits[0].inferredDepartureUpperBound == end)
    }

    @Test
    func earlierOutingDoesNotExtendTheFinalDeparture() throws {
        let store = store()
        store.ledger.visits = [origin]
        let earlier = samples.map { point in
            BlipTimelineLocationObservation(
                id: UUID(), timestamp: point.timestamp.addingTimeInterval(-7_200),
                coordinate: point.coordinate, horizontalAccuracy: 5,
                speedMetersPerSecond: 15, timeZoneIdentifier: point.timeZoneIdentifier,
                motion: .automotive
            )
        }

        store.ingest(earlier + samples, now: end)
        store.ingest(destination, now: end.addingTimeInterval(60))

        #expect(try journey(in: store).startDate == start)
    }

    @Test
    func delayedReturnToOriginCanRefineTheFinalExitForward() throws {
        let store = store()
        store.ledger.visits = [origin]
        let earlier = samples.enumerated().map { index, point in
            BlipTimelineLocationObservation(
                id: UUID(), timestamp: start.addingTimeInterval(Double(index) * 40),
                coordinate: point.coordinate, horizontalAccuracy: 5,
                speedMetersPerSecond: 20, timeZoneIdentifier: point.timeZoneIdentifier,
                motion: .automotive
            )
        }
        store.ingest(earlier, now: end)
        store.ingest(destination, now: end.addingTimeInterval(60))
        #expect(try journey(in: store).startDate == start)
        let finalExit = end.addingTimeInterval(-300)
        let delayed = samples.enumerated().map { index, point in
            BlipTimelineLocationObservation(
                id: UUID(), timestamp: finalExit.addingTimeInterval(Double(index) * 10),
                coordinate: point.coordinate, horizontalAccuracy: 5,
                speedMetersPerSecond: 50, timeZoneIdentifier: point.timeZoneIdentifier,
                motion: .automotive
            )
        }

        store.ingest(delayed, now: end.addingTimeInterval(120))

        #expect(try journey(in: store).startDate == finalExit)
        #expect(store.ledger.visits[0].inferredDepartureUpperBound == end)
    }

    @Test
    func inferredRepairPreservesAnExplicitlyEditedDay() throws {
        let store = store()
        store.ledger.visits = [origin]
        store.ingest(destination, now: end.addingTimeInterval(60))
        let edited = try #require(store.days.first { $0.dateKey == "2000-10-05" })
        store.ledger.manuallyEditedDateKeys.insert(edited.dateKey)

        store.ingest(samples, now: end.addingTimeInterval(120))
        store.materializeStationaryDays(now: end.addingTimeInterval(180))

        #expect(store.ledger.visits[0].departureDate == start)
        #expect(store.days.first { $0.dateKey == edited.dateKey }?.entries == edited.entries)
    }

    @Test(arguments: [false, true])
    func delayedAuthoritativeDepartureReplacesInferenceWithoutDuplicatingVisit(atArrival: Bool) throws {
        let store = store()
        let source = origin
        store.ledger.visits = [source]
        store.ingest(samples, now: end)
        store.ingest(destination, now: end.addingTimeInterval(60))
        let reportedDeparture = atArrival ? end : start.addingTimeInterval(-60)
        let reported = BlipTimelineVisitObservation(
            id: UUID(), arrivalDate: source.arrivalDate.addingTimeInterval(-600),
            departureDate: reportedDeparture, coordinate: source.coordinate,
            horizontalAccuracy: 10, timeZoneIdentifier: source.timeZoneIdentifier
        )

        store.ingest(reported, now: end.addingTimeInterval(120))
        store.ingest(reported, now: end.addingTimeInterval(180))

        #expect(store.ledger.visits.count == 2)
        #expect(store.ledger.visits[0].id == source.id)
        #expect(store.ledger.visits[0].departureDate == reportedDeparture)
        #expect(store.ledger.visits[0].inferredDepartureUpperBound == nil)
        let drive = try journey(in: store)
        #expect(drive.startDate == reportedDeparture)
        #expect(drive.confidence == (atArrival ? .inferred : .observed))
    }

    @Test
    func laterReturnRemainsSeparate() {
        let store = store()
        let source = origin
        store.ledger.visits = [source]
        store.ingest(destination, now: end.addingTimeInterval(60))
        let returned = BlipTimelineVisitObservation(
            id: UUID(), arrivalDate: end.addingTimeInterval(3_600),
            departureDate: end.addingTimeInterval(5_400), coordinate: source.coordinate,
            horizontalAccuracy: 5, timeZoneIdentifier: source.timeZoneIdentifier
        )

        store.ingest(returned, now: end.addingTimeInterval(6_000))

        #expect(store.ledger.visits.count == 3)
        #expect(store.ledger.visits[0].id == source.id)
        #expect(store.ledger.visits[0].departureDate == end)
        #expect(store.ledger.visits[2].id == returned.id)
    }

    @Test
    func provenanceSurvivesReloadAndLegacyPayloadStillDecodes() throws {
        let source = origin
        let inferred = source.ending(at: start, inferredUpperBound: end)
        let encoded = try BlipTimelinePersistence.encoder.encode(inferred)
        let decoded = try BlipTimelinePersistence.decoder.decode(BlipTimelineVisitObservation.self, from: encoded)
        #expect(decoded.id == source.id)
        #expect(decoded.inferredDepartureUpperBound == end)

        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "inferredDepartureUpperBound")
        legacy.removeValue(forKey: "departureWasReported")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let old = try BlipTimelinePersistence.decoder.decode(BlipTimelineVisitObservation.self, from: legacyData)
        #expect(old.inferredDepartureUpperBound == nil)
        #expect(old.departureWasReported == nil)
        #expect(old.departureDate == start)
    }

    @Test
    func explicitDepartureAndManualJourneyRemainUnchanged() throws {
        let store = store()
        let source = origin
        let reportedDeparture = start.addingTimeInterval(300)
        store.ledger.visits = [BlipTimelineVisitObservation(
            id: source.id, arrivalDate: source.arrivalDate, departureDate: reportedDeparture,
            coordinate: source.coordinate, horizontalAccuracy: 5,
            timeZoneIdentifier: source.timeZoneIdentifier
        )]
        store.ingest(destination, now: end.addingTimeInterval(60))
        let originalDay = try #require(store.days.first { $0.dateKey == "2000-10-05" })
        store.ledger.manuallyEditedDateKeys.insert(originalDay.dateKey)

        store.ingest(samples, now: end.addingTimeInterval(120))
        store.materializeStationaryDays(now: end.addingTimeInterval(180))

        #expect(store.ledger.visits[0].departureDate == reportedDeparture)
        #expect(store.ledger.visits[0].inferredDepartureUpperBound == nil)
        #expect(store.days.first { $0.dateKey == originalDay.dateKey }?.entries == originalDay.entries)
    }
}

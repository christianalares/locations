// Fictional Null Island fixtures; dates and identities are synthetic.
import Foundation
import Testing
@testable import LocationsKit

@MainActor
struct BlipTimelineRouteRecoveryTests {
    @Test(arguments: ["expired", "fresh", "changedInterval"])
    func repairingVisitsPreservesOnlyRoutesThatCannotBeRebuilt(scenario: String) throws {
        let start = Date(timeIntervalSince1970: 967_075_200).addingTimeInterval(36_000)
        let origin = BlipTimelineVisitObservation(
            id: UUID(), arrivalDate: start.addingTimeInterval(-3_600), departureDate: start,
            coordinate: .init(latitude: -0.03, longitude: -0.03), horizontalAccuracy: 5,
            timeZoneIdentifier: "UTC"
        )
        let destination = BlipTimelineVisitObservation(
            id: UUID(), arrivalDate: start.addingTimeInterval(600),
            departureDate: start.addingTimeInterval(3_600),
            coordinate: .init(latitude: 0.01, longitude: -0.01), horizontalAccuracy: 5,
            timeZoneIdentifier: "UTC"
        )
        let samples: [BlipTimelineLocationObservation] = (1...3).map { index in
            let offset = Double(index) * 0.01
            let coordinate = BlipTimelineCoordinate(latitude: -0.03 + offset, longitude: -0.03 + offset * 0.5)
            return BlipTimelineLocationObservation(
                id: UUID(), timestamp: start.addingTimeInterval(Double(index * 150)),
                coordinate: coordinate,
                horizontalAccuracy: 5, speedMetersPerSecond: 15,
                timeZoneIdentifier: "UTC", motion: .automotive
            )
        }
        let now = start.addingTimeInterval(9 * 86_400)
        let recorded = try #require(BlipTimelineDayBuilder.makeDay(
            dateKey: origin.dateKey, observations: samples, visits: [origin, destination],
            homeCoordinate: nil, sourceDeviceID: "iphone", now: now
        ))
        let originalJourney = try #require(recorded.entries.first { $0.kind == .journey })
        let store = BlipTimelineStore(
            arguments: [], calendar: .autoupdatingCurrent,
            cloudSession: nil, persistence: .inMemory
        )
        let currentDestination = BlipTimelineVisitObservation(
            id: destination.id,
            arrivalDate: destination.arrivalDate.addingTimeInterval(scenario == "changedInterval" ? 60 : 0),
            departureDate: destination.departureDate, coordinate: destination.coordinate,
            horizontalAccuracy: 5, timeZoneIdentifier: "UTC"
        )
        store.ledger.visits = [origin, currentDestination]
        store.ledger.observations = scenario == "fresh" ? Array(samples.prefix(1)) : []
        // Missing visit rows force the same rebuild as legacy visit repair.
        store.replaceDays([BlipTimelineDay(
            date: recorded.date, dateKey: recorded.dateKey, timeZoneIdentifier: "UTC",
            coverage: .complete, entries: [originalJourney], metrics: recorded.metrics
        )])

        store.materializeStationaryDays(now: now)

        let repaired = try #require(store.days.first { $0.dateKey == recorded.dateKey })
        let journey = try #require(repaired.entries.first { $0.kind == .journey })
        #expect(repaired.entries.filter { $0.kind == .visit }.count == 2)
        if scenario == "expired" {
            #expect(journey == originalJourney)
            #expect(repaired.metrics?.distanceMeters == originalJourney.distanceMeters)
        } else {
            #expect(journey.route != originalJourney.route)
            #expect(journey.endDate == currentDestination.arrivalDate)
        }
    }
}

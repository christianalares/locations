// Fictional Null Island fixtures; dates and identities are synthetic.
import Foundation
import Testing
@testable import LocationsKit

@MainActor
struct BlipTimelineTests {
    @Test
    func timelineTimesUseTwoDigitHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let midnight = calendar.date(from: DateComponents(
            year: 2000,
            month: 8,
            day: 20,
            hour: 0,
            minute: 0
        ))!

        #expect(BlipTimelineTimeFormatter.string(
            from: midnight,
            locale: Locale(identifier: "en_SE"),
            timeZone: calendar.timeZone
        ) == "00:00")
    }

    @Test
    func emojiPlaceIconsAreNamespacedAndPersisted() throws {
        let storedIcon = BlipTimelinePlaceIcon.storedEmoji("🎾")
        #expect(storedIcon == "emoji:🎾")
        #expect(BlipTimelinePlaceIcon.emoji(from: storedIcon) == "🎾")
        #expect(BlipTimelinePlaceIcon.emoji(from: "🎾") == "🎾")
        #expect(BlipTimelinePlaceIcon.emoji(from: "figure.run") == nil)
        #expect(BlipTimelinePlaceIcon.customEmoji(from: "Padel 🎾") == "🎾")
        #expect(BlipTimelinePlaceIcon.customEmoji(from: "Padel") == nil)
        #expect(BlipTimelinePlaceIcon.title(for: storedIcon) == "Tennis or padel")
        #expect(BlipTimelinePlaceIcon.title(for: "mappin") == "Pin")
        #expect(Set(BlipTimelinePlaceIcon.emojiChoices.map(\.id)).count
            == BlipTimelinePlaceIcon.emojiChoices.count)
        #expect(Set(BlipTimelinePlaceIcon.symbolChoices.map(\.id)).count
            == BlipTimelinePlaceIcon.symbolChoices.count)

        let savedPlace = BlipTimelineSavedPlace(
            id: "null-island-padel",
            title: "Null Island Padel",
            subtitle: nil,
            coordinate: .init(latitude: 0, longitude: 0),
            iconSystemName: storedIcon
        )
        let data = try JSONEncoder().encode(savedPlace)
        let decoded = try JSONDecoder().decode(BlipTimelineSavedPlace.self, from: data)

        #expect(decoded.iconSystemName == storedIcon)
        #expect(BlipTimelinePlaceIcon.emoji(from: decoded.iconSystemName ?? "") == "🎾")
    }

    @Test
    func emojiPickerUsesCompleteUnicodeCatalogAndGlobalNameSearch() {
        #expect(BlipTimelinePlaceIcon.emojiChoices.count > 3_900)
        #expect(Set(BlipTimelinePlaceIcon.emojiChoices.map(\.id)).count
            == BlipTimelinePlaceIcon.emojiChoices.count)

        let sweden = BlipTimelinePlaceIcon.emojiChoices.first { $0.emoji == "🇸🇪" }
        #expect(sweden?.title == "flag: Sweden")
        #expect(sweden?.category == .flags)

        let fullNameMatches = BlipTimelinePlaceIcon.filteredEmojiChoices(
            query: "Sweden",
            category: .smileys
        )
        let partialNameMatches = BlipTimelinePlaceIcon.filteredEmojiChoices(
            query: "Swe",
            category: .animals
        )
        #expect(fullNameMatches.contains { $0.emoji == "🇸🇪" })
        #expect(partialNameMatches.contains { $0.emoji == "🇸🇪" })
        #expect(partialNameMatches.first?.emoji == "🇸🇪")

        for category in BlipTimelineEmojiCategory.allCases where category != .recent {
            #expect(!BlipTimelinePlaceIcon.filteredEmojiChoices(
                query: "",
                category: category
            ).isEmpty)
        }
    }

    @Test
    func aDayAtHomeRemainsCold() {
        let score = BlipTimelineHeatCalculator.score(for: .init(
            distanceMeters: 0,
            movingDuration: 0,
            awayFromHomeDuration: 0,
            meaningfulPlaceCount: 0
        ))

        #expect(score.value == 0)
        #expect(score.level == .cold)
    }

    @Test
    func aBusyCityDayBecomesHotWithoutUsingLocationSampleCount() {
        let score = BlipTimelineHeatCalculator.score(for: .init(
            distanceMeters: 18_000,
            movingDuration: 4 * 3_600,
            awayFromHomeDuration: 10 * 3_600,
            meaningfulPlaceCount: 6
        ))

        #expect(score.value > 0.70)
        #expect(score.level == .hot || score.level == .intense)
    }

    @Test
    func meaningfulPlacesIncreaseHeatBeyondAnEquivalentHomeDay() {
        let quiet = BlipTimelineHeatCalculator.score(for: .init(
            distanceMeters: 2_000,
            movingDuration: 30 * 60,
            awayFromHomeDuration: 0,
            meaningfulPlaceCount: 0
        ))
        let exploring = BlipTimelineHeatCalculator.score(for: .init(
            distanceMeters: 2_000,
            movingDuration: 30 * 60,
            awayFromHomeDuration: 4 * 3_600,
            meaningfulPlaceCount: 4
        ))

        #expect(exploring.value > quiet.value)
    }

    @Test
    func untrackedIsNotMistakenForCold() {
        let date = Date(timeIntervalSince1970: 974_240_000)
        let metrics = BlipTimelineActivityMetrics(
            distanceMeters: 0,
            movingDuration: 0,
            awayFromHomeDuration: 0,
            meaningfulPlaceCount: 0
        )
        let untracked = BlipTimelineDay(
            date: date,
            timeZoneIdentifier: "Europe/Stockholm",
            coverage: .untracked,
            entries: [],
            metrics: metrics
        )
        let cold = BlipTimelineDay(
            date: date,
            timeZoneIdentifier: "Europe/Stockholm",
            coverage: .complete,
            entries: [],
            metrics: metrics
        )

        #expect(untracked.heat == nil)
        #expect(cold.heat?.level == .cold)
    }

    @Test
    func entriesArePresentedChronologically() {
        let earlier = BlipTimelineEntry(
            id: "earlier",
            kind: .visit,
            title: "Earlier",
            startDate: Date(timeIntervalSince1970: 100)
        )
        let later = BlipTimelineEntry(
            id: "later",
            kind: .visit,
            title: "Later",
            startDate: Date(timeIntervalSince1970: 200)
        )
        let day = BlipTimelineDay(
            date: Date(timeIntervalSince1970: 0),
            timeZoneIdentifier: "UTC",
            coverage: .complete,
            entries: [later, earlier],
            metrics: nil
        )

        #expect(day.orderedEntries.map(\.id) == ["earlier", "later"])
    }

    @Test
    func workoutIsAttachedOnlyToTheEntryWithTheStrongestTimeOverlap() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = try #require(calendar.date(from: DateComponents(
            year: 2000,
            month: 8,
            day: 22
        )))
        func minute(_ value: Int) -> Date {
            dayStart.addingTimeInterval(TimeInterval(value * 60))
        }

        let first = BlipTimelineEntry(
            id: "first",
            kind: .visit,
            title: "Gym",
            startDate: minute(9 * 60),
            endDate: minute(10 * 60)
        )
        let second = BlipTimelineEntry(
            id: "second",
            kind: .journey,
            title: "Walk",
            startDate: minute(10 * 60),
            endDate: minute(10 * 60 + 30)
        )
        let day = BlipTimelineDay(
            date: dayStart,
            timeZoneIdentifier: "UTC",
            coverage: .complete,
            entries: [first, second],
            metrics: nil
        )
        let workout = BlipTimelineWorkout(
            id: "workout",
            title: "Strength training",
            systemImage: "dumbbell.fill",
            startDate: minute(9 * 60 + 20),
            endDate: minute(10 * 60 + 5),
            sourceName: "Apple Watch"
        )

        #expect(BlipTimelineWorkoutMatcher.workouts(
            for: first,
            in: day,
            workouts: [workout]
        ).map(\.id) == ["workout"])
        #expect(BlipTimelineWorkoutMatcher.workouts(
            for: second,
            in: day,
            workouts: [workout]
        ).isEmpty)
    }

    @Test
    func workoutOutsideTimelineCoverageDoesNotCreateAnIndependentRow() throws {
        let dayStart = try #require(ISO8601DateFormatter().date(from: "2000-08-22T00:00:00Z"))
        let entry = BlipTimelineEntry(
            id: "morning",
            kind: .visit,
            title: "Morning",
            startDate: dayStart.addingTimeInterval(8 * 3_600),
            endDate: dayStart.addingTimeInterval(9 * 3_600)
        )
        let day = BlipTimelineDay(
            date: dayStart,
            timeZoneIdentifier: "UTC",
            coverage: .partial,
            entries: [entry],
            metrics: nil
        )
        let workout = BlipTimelineWorkout(
            id: "evening-workout",
            title: "Running",
            systemImage: "figure.run",
            startDate: dayStart.addingTimeInterval(18 * 3_600),
            endDate: dayStart.addingTimeInterval(19 * 3_600),
            sourceName: "Apple Watch"
        )

        #expect(BlipTimelineWorkoutMatcher.workouts(
            for: entry,
            in: day,
            workouts: [workout]
        ).isEmpty)
    }

    @Test
    func duplicatePersistedEntryIDsDoNotCreateGhostTimelineRows() throws {
        let json = """
        {
          "dateKey":"2000-08-19",
          "timeZoneIdentifier":"Europe/Stockholm",
          "coverage":"partial",
          "entries":[
            {
              "id":"visit-1",
              "kind":"visit",
              "title":"Null Pointer Café",
              "startDate":"2000-08-19T17:00:00Z",
              "endDate":"2000-08-19T17:30:00Z"
            },
            {
              "id":"visit-1",
              "kind":"visit",
              "title":"Null Pointer Café",
              "startDate":"2000-08-19T17:00:00Z",
              "endDate":"2000-08-19T17:30:00Z"
            }
          ],
          "metrics":{
            "distanceMeters":0,
            "movingDuration":0,
            "awayFromHomeDuration":3600,
            "meaningfulPlaceCount":2
          },
          "updatedAt":"2000-08-19T19:00:00Z",
          "sourceDeviceID":"iphone"
        }
        """.data(using: .utf8)!

        let day = try BlipTimelinePersistence.decoder.decode(BlipTimelineDay.self, from: json)

        #expect(day.entries.map(\.id) == ["visit-1"])
        #expect(day.metrics?.awayFromHomeDuration == 1_800.0)
        #expect(day.metrics?.meaningfulPlaceCount == 1)
    }

    @Test
    func productionStoreNeverLoadsDemoHistoryByDefault() {
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )

        #expect(store.days.isEmpty)
        #expect(store.day(containing: Date()) == nil)
    }

    #if os(macOS)
    @Test
    func macTrackingControlsCannotMutateTheSyncedLedger() {
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )

        store.enableTracking()
        #expect(!store.trackingEnabled)
        #expect(!store.ledger.trackingEnabled)
        #expect(store.trackingState == .unavailable)

        store.trackingEnabled = true
        store.ledger.trackingEnabled = true
        store.disableTracking()
        #expect(store.trackingEnabled)
        #expect(store.ledger.trackingEnabled)
        #expect(store.trackingState == .unavailable)
    }
    #endif

    @Test
    func successfulTimelineSaveClearsAnEarlierPersistenceError() {
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        store.persistenceError = "Earlier protected-file failure"

        store.persistLedger()

        #expect(store.persistenceError == nil)
    }

    @Test
    func localTimelineSaveFailureDoesNotReplaceACloudError() {
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: BlipTimelinePersistence(
                fileURL: URL(fileURLWithPath: "/dev/null/Timeline/timeline-v1.json")
            )
        )
        store.syncError = "Cloud unavailable"

        store.persistLedger()

        #expect(store.persistenceError?.hasPrefix("Timeline could not be saved locally:") == true)
        #expect(store.syncError == "Cloud unavailable")
    }

    @Test
    func launchGapCaptureSpoolSurvivesRecreationAndDrainsExplicitly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("pending-capture-v1.json")
        let spool = BlipTimelinePendingCaptureSpool(fileURL: fileURL)
        let timestamp = Date(timeIntervalSince1970: 955_545_600)
        let observation = BlipTimelineLocationObservation(
            id: UUID(),
            timestamp: timestamp,
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 7,
            speedMetersPerSecond: 14,
            timeZoneIdentifier: "Europe/Stockholm",
            motion: .automotive
        )
        let visit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: timestamp.addingTimeInterval(600),
            departureDate: nil,
            coordinate: .init(latitude: -0.13, longitude: -0.22),
            horizontalAccuracy: 12,
            timeZoneIdentifier: "Europe/Stockholm"
        )

        #expect(spool.append(observations: [observation]))
        #expect(spool.append(visits: [visit]))

        let restored = BlipTimelinePendingCaptureSpool(fileURL: fileURL).load()
        #expect(restored.observations.map(\.id) == [observation.id])
        #expect(restored.visits.map(\.id) == [visit.id])

        spool.clear()
        #expect(BlipTimelinePendingCaptureSpool(fileURL: fileURL).load().isEmpty)
    }

    @Test
    func replayingAPartiallyDrainedVisitSpoolDoesNotDuplicateVisits() {
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        let start = Date().addingTimeInterval(-3_600)
        let first = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: start,
            departureDate: start.addingTimeInterval(600),
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 8,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let second = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: start.addingTimeInterval(1_200),
            departureDate: nil,
            coordinate: .init(latitude: -0.13, longitude: -0.22),
            horizontalAccuracy: 12,
            timeZoneIdentifier: "Europe/Stockholm"
        )

        store.ingest(first)
        store.ingest(second)
        store.ingest(first)

        #expect(store.ledger.visits.map(\.id).filter { $0 == first.id }.count == 1)
        #expect(Set(store.ledger.visits.map(\.id)) == [first.id, second.id])
    }

    @Test
    func dateKeysUseTheTimezoneWhereTheSampleWasCaptured() {
        let instant = ISO8601DateFormatter().date(from: "2000-01-01T00:30:00Z")!

        #expect(BlipTimelineDay.makeDateKey(
            instant,
            timeZoneIdentifier: "America/Los_Angeles"
        ) == "1999-12-31")
        #expect(BlipTimelineDay.makeDateKey(
            instant,
            timeZoneIdentifier: "Europe/Stockholm"
        ) == "2000-01-01")
    }

    @Test
    func cloudDayDecodesWithoutAnAbsoluteMidnightDate() throws {
        let json = """
        {
          "dateKey":"2000-08-18",
          "timeZoneIdentifier":"Europe/Stockholm",
          "coverage":"complete",
          "entries":[],
          "metrics":null,
          "updatedAt":"2000-08-18T12:00:00.000Z",
          "sourceDeviceID":"iphone"
        }
        """.data(using: .utf8)!

        let day = try BlipTimelinePersistence.decoder.decode(BlipTimelineDay.self, from: json)

        #expect(day.dateKey == "2000-08-18")
        #expect(day.timeZoneIdentifier == "Europe/Stockholm")
    }

    @Test
    func movementSamplesBuildACompactTransportJourney() {
        let start = Date(timeIntervalSince1970: 955_545_600)
        let observations = [
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start,
                coordinate: .init(latitude: 0, longitude: 0),
                horizontalAccuracy: 30,
                speedMetersPerSecond: 1.8,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .walking
            ),
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start.addingTimeInterval(600),
                coordinate: .init(latitude: 0.01, longitude: 0.005),
                horizontalAccuracy: 35,
                speedMetersPerSecond: 1.7,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .walking
            ),
        ]
        let dateKey = observations[0].dateKey

        let day = BlipTimelineDayBuilder.makeDay(
            dateKey: dateKey,
            observations: observations,
            visits: [],
            homeCoordinate: nil,
            sourceDeviceID: "iphone"
        )

        #expect(day?.entries.count == 1)
        #expect(day?.entries[0].kind == .journey)
        #expect(day?.entries[0].transportMode == .walking)
        #expect((day?.entries[0].distanceMeters ?? 0) > 1_000)
    }

    @Test
    func equalVisitBoundaryAtDifferentPlacesBuildsAnInferredConnection() throws {
        let boundary = Date(timeIntervalSince1970: 966_785_600)
        let source = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: boundary.addingTimeInterval(-3_600),
            departureDate: boundary,
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 12,
            timeZoneIdentifier: "UTC"
        )
        let destination = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: boundary,
            departureDate: nil,
            coordinate: .init(latitude: 0.02, longitude: 0.015),
            horizontalAccuracy: 15,
            timeZoneIdentifier: "UTC"
        )

        let day = try #require(BlipTimelineDayBuilder.makeDay(
            dateKey: source.dateKey,
            observations: [],
            visits: [source, destination],
            homeCoordinate: nil,
            sourceDeviceID: "iphone",
            now: boundary.addingTimeInterval(600)
        ))
        let journey = try #require(day.entries.first { $0.kind == .journey })

        #expect(journey.startDate == boundary)
        #expect(journey.endDate == boundary)
        #expect(journey.route == [source.coordinate, destination.coordinate])
        #expect((journey.distanceMeters ?? 0) > 1_000)
        #expect(journey.confidence == .inferred)
        #expect(journey.transportMode == .unknown)
    }

    @Test
    func equalVisitBoundaryWithinAccuracyDoesNotCreateAPhantomJourney() throws {
        let boundary = Date(timeIntervalSince1970: 966_785_600)
        let source = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: boundary.addingTimeInterval(-3_600),
            departureDate: boundary,
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 80,
            timeZoneIdentifier: "UTC"
        )
        let destination = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: boundary,
            departureDate: nil,
            coordinate: .init(latitude: 0.0001, longitude: 0.00005),
            horizontalAccuracy: 80,
            timeZoneIdentifier: "UTC"
        )

        let day = try #require(BlipTimelineDayBuilder.makeDay(
            dateKey: source.dateKey,
            observations: [],
            visits: [source, destination],
            homeCoordinate: nil,
            sourceDeviceID: "iphone",
            now: boundary.addingTimeInterval(600)
        ))

        #expect(!day.entries.contains { $0.kind == .journey })
    }

    @Test
    func automotiveMotionKeepsDriveCaptureActiveAcrossARealTrafficGap() {
        let start = Date(timeIntervalSince1970: 966_785_600)
        var detection = BlipTimelineDriveDetection()

        detection.observe(motion: .automotive, speedMetersPerSecond: 0, at: start)

        #expect(detection.isAutomotive(
            at: start.addingTimeInterval(BlipTimelineDriveDetection.continuationDuration - 1)
        ))
        #expect(!detection.isAutomotive(
            at: start.addingTimeInterval(BlipTimelineDriveDetection.continuationDuration)
        ))
    }

    @Test
    func sustainedStationaryMotionEndsARetainedDriveEarly() {
        let start = Date(timeIntervalSince1970: 966_785_600)
        var detection = BlipTimelineDriveDetection()

        detection.observe(motion: .automotive, speedMetersPerSecond: 0, at: start)
        detection.observe(
            motion: .stationary,
            speedMetersPerSecond: 0,
            at: start.addingTimeInterval(120)
        )

        let exit = 120 + BlipTimelineDriveDetection.stationaryExitDuration
        #expect(detection.isAutomotive(at: start.addingTimeInterval(exit - 1)))
        #expect(!detection.isAutomotive(at: start.addingTimeInterval(exit)))
    }

    @Test
    func creepingTrafficPreventsAStationaryExit() {
        let start = Date(timeIntervalSince1970: 966_785_600)
        var detection = BlipTimelineDriveDetection()

        detection.observe(motion: .automotive, speedMetersPerSecond: 0, at: start)
        detection.observe(
            motion: .stationary,
            speedMetersPerSecond: 0,
            at: start.addingTimeInterval(60)
        )
        detection.observe(
            motion: .stationary,
            speedMetersPerSecond: BlipTimelineDriveDetection.minimumMovementSpeed,
            at: start.addingTimeInterval(4 * 60)
        )

        #expect(detection.stationarySince == nil)
        #expect(detection.isAutomotive(
            at: start.addingTimeInterval(BlipTimelineDriveDetection.continuationDuration - 1)
        ))
    }

    @Test
    func drivingSpeedCanSustainCaptureWithoutMotionClassification() {
        let start = Date(timeIntervalSince1970: 966_785_600)
        var detection = BlipTimelineDriveDetection()

        detection.observe(
            motion: .unknown,
            speedMetersPerSecond: BlipTimelineDriveDetection.minimumDrivingSpeed,
            at: start
        )

        #expect(detection.isAutomotive(
            at: start.addingTimeInterval(BlipTimelineDriveDetection.continuationDuration - 1)
        ))
        #expect(!detection.isAutomotive(
            at: start.addingTimeInterval(BlipTimelineDriveDetection.continuationDuration)
        ))
    }

    @Test
    func stationaryGpsSpeedCannotPromoteDenseDriving() {
        let start = Date(timeIntervalSince1970: 966_785_600)
        var promotion = BlipTimelineDrivePromotion()
        let readings = [
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start,
                coordinate: .init(latitude: 0, longitude: 0),
                horizontalAccuracy: 5,
                speedMetersPerSecond: 2.8,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .stationary
            ),
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start.addingTimeInterval(45),
                coordinate: .init(latitude: 0.0002, longitude: 0.0001),
                horizontalAccuracy: 5,
                speedMetersPerSecond: 2.1,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .stationary
            ),
        ]

        let firstPromoted = promotion.observe(readings[0], isCharging: true)
        let secondPromoted = promotion.observe(readings[1], isCharging: true)
        #expect(!firstPromoted)
        #expect(!secondPromoted)
    }

    @Test
    func credibleDisplacementPromotesDenseDrivingMoreQuicklyWhileCharging() {
        let start = Date(timeIntervalSince1970: 966_785_600)
        let first = BlipTimelineLocationObservation(
            id: UUID(),
            timestamp: start,
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 8,
            speedMetersPerSecond: 2,
            timeZoneIdentifier: "Europe/Stockholm",
            motion: .unknown
        )
        let second = BlipTimelineLocationObservation(
            id: UUID(),
            timestamp: start.addingTimeInterval(30),
            coordinate: .init(latitude: 0.0006, longitude: 0),
            horizontalAccuracy: 8,
            speedMetersPerSecond: 2,
            timeZoneIdentifier: "Europe/Stockholm",
            motion: .unknown
        )
        var chargingPromotion = BlipTimelineDrivePromotion()
        var batteryPromotion = BlipTimelineDrivePromotion()

        let chargingFirst = chargingPromotion.observe(first, isCharging: true)
        let chargingSecond = chargingPromotion.observe(second, isCharging: true)
        let batteryFirst = batteryPromotion.observe(first, isCharging: false)
        let batterySecond = batteryPromotion.observe(second, isCharging: false)
        #expect(!chargingFirst)
        #expect(chargingSecond)
        #expect(!batteryFirst)
        #expect(!batterySecond)
    }

    @Test
    func automotiveMotionImmediatelyPromotesDenseDriving() {
        var promotion = BlipTimelineDrivePromotion()
        let observation = BlipTimelineLocationObservation(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 966_785_600),
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 25,
            speedMetersPerSecond: 0,
            timeZoneIdentifier: "Europe/Stockholm",
            motion: .automotive
        )

        let promoted = promotion.observe(observation, isCharging: false)
        #expect(promoted)
    }

    @Test
    func stationaryLiveUpdatesRetainOnlyOneAnchor() {
        let start = Date(timeIntervalSince1970: 966_785_600)
        let observations = (0..<600).map { index in
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start.addingTimeInterval(Double(index)),
                coordinate: .init(
                    latitude: 0 + (index.isMultiple(of: 2) ? 0 : 0.00002),
                    longitude: 0
                ),
                horizontalAccuracy: 8,
                speedMetersPerSecond: 0,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .stationary
            )
        }
        var retention = BlipTimelineObservationRetention()

        let retained = retention.retaining(observations)

        #expect(retained.count == 1)
        #expect(retained.first?.id == observations.first?.id)
    }

    @Test
    func stationaryGpsSpeedDoesNotCreateDenseHomeGeometry() {
        let start = Date(timeIntervalSince1970: 966_785_600)
        let observations = (0..<30).map { index in
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start.addingTimeInterval(Double(index * 10)),
                coordinate: .init(
                    latitude: 0 + (index.isMultiple(of: 2) ? 0 : 0.00002),
                    longitude: 0
                ),
                horizontalAccuracy: 6,
                speedMetersPerSecond: 2.5,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .stationary
            )
        }
        var retention = BlipTimelineObservationRetention()

        let retained = retention.retaining(observations)

        #expect(retained.count == 1)
    }

    @Test
    func denseAutomotiveUpdatesAreBoundedToDetailedRouteGeometry() {
        let start = Date(timeIntervalSince1970: 966_785_600)
        let observations = (0..<21).map { index in
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start.addingTimeInterval(Double(index)),
                coordinate: .init(
                    latitude: 0 + (Double(index) * 0.0001),
                    longitude: 0
                ),
                horizontalAccuracy: 8,
                speedMetersPerSecond: 11,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .automotive
            )
        }
        var retention = BlipTimelineObservationRetention()

        let retained = retention.retaining(observations)

        #expect(retained.count == 5)
        for pair in zip(retained, retained.dropFirst()) {
            #expect(BlipTimelineGeometry.distanceMeters(
                pair.0.coordinate,
                pair.1.coordinate
            ) >= BlipTimelineObservationRetention.detailedRouteDistanceMeters)
        }
    }

    @Test
    func creepingTrafficStillRetainsSlowRouteProgress() {
        let start = Date(timeIntervalSince1970: 966_785_600)
        let coordinates = [0, 0.00004, 0.0001]
        let observations = coordinates.enumerated().map { index, latitude in
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start.addingTimeInterval(Double(index * 10)),
                coordinate: .init(latitude: latitude, longitude: 0),
                horizontalAccuracy: 8,
                speedMetersPerSecond: 0.5,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .automotive
            )
        }
        var retention = BlipTimelineObservationRetention()

        let retained = retention.retaining(observations)

        #expect(retained.map(\.id) == [observations[0].id, observations[2].id])
    }

    @Test
    func movementToStationaryTransitionRetainsOneArrivalEndpoint() {
        let start = Date(timeIntervalSince1970: 966_785_600)
        let observations = [
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start,
                coordinate: .init(latitude: 0, longitude: 0),
                horizontalAccuracy: 8,
                speedMetersPerSecond: 10,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .automotive
            ),
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start.addingTimeInterval(5),
                coordinate: .init(latitude: 0.0005, longitude: 0),
                horizontalAccuracy: 8,
                speedMetersPerSecond: 8,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .automotive
            ),
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start.addingTimeInterval(10),
                coordinate: .init(latitude: 0.0006, longitude: 0),
                horizontalAccuracy: 8,
                speedMetersPerSecond: 0,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .stationary
            ),
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start.addingTimeInterval(15),
                coordinate: .init(latitude: 0.00061, longitude: 0),
                horizontalAccuracy: 8,
                speedMetersPerSecond: 0,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .stationary
            ),
        ]
        var retention = BlipTimelineObservationRetention()

        let retained = retention.retaining(observations)

        #expect(retained.map(\.id) == observations.prefix(3).map(\.id))
    }

    @Test
    func loadingTimelineCompactsRedundantRawObservations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BlipTimelinePersistence(
            fileURL: directory.appendingPathComponent("timeline-v1.json")
        )
        let start = Date(timeIntervalSince1970: 966_785_600)
        var ledger = BlipTimelineLedger.empty
        ledger.observations = (0..<1_000).map { index in
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start.addingTimeInterval(Double(index)),
                coordinate: .init(
                    latitude: 0 + (index.isMultiple(of: 2) ? 0 : 0.00001),
                    longitude: 0
                ),
                horizontalAccuracy: 8,
                speedMetersPerSecond: 0,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .stationary
            )
        }
        try persistence.save(ledger)

        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: persistence
        )

        #expect(store.ledger.observations.count == 1)
        #expect(persistence.load().observations.count == 1)
    }

    @Test
    func loadingTimelineCollapsesNearbyHomePlacesIntoCanonicalHemma() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = BlipTimelinePersistence(
            fileURL: directory.appendingPathComponent("timeline-v1.json")
        )
        let homeCoordinate = BlipTimelineCoordinate(latitude: 0, longitude: 0)
        let englishHome = BlipTimelineSavedPlace(
            id: "home-english",
            title: "Home",
            subtitle: nil,
            coordinate: .init(latitude: -0.00006, longitude: -0.00011),
            isHome: true,
            residentContacts: [
                .init(id: "resident-alice", contactIdentifier: "contact-alice", displayName: "Alice Example"),
            ]
        )
        let olderHemma = BlipTimelineSavedPlace(
            id: "legacy-hemma-older",
            title: "Hemma",
            subtitle: nil,
            coordinate: .init(latitude: 0.00004, longitude: 0.00008),
            isHome: true,
            residentContacts: [
                .init(id: "resident-bob", contactIdentifier: "contact-bob", displayName: "Bob Example"),
            ]
        )
        let canonicalHemma = BlipTimelineSavedPlace(
            id: "legacy-hemma-current",
            title: "Hemma",
            subtitle: nil,
            coordinate: homeCoordinate,
            iconSystemName: "house.fill",
            isHome: true
        )
        let start = Date(timeIntervalSince1970: 966_785_600)
        let entries = [
            BlipTimelineEntry(
                id: "visit-home-english",
                kind: .visit,
                title: "Home",
                startDate: start,
                endDate: start.addingTimeInterval(3_600),
                coordinate: englishHome.coordinate,
                isHome: true,
                placeID: englishHome.id
            ),
            BlipTimelineEntry(
                id: "visit-home-unlinked",
                kind: .visit,
                title: "Hemma",
                startDate: start.addingTimeInterval(3_600),
                coordinate: olderHemma.coordinate,
                isHome: true
            ),
        ]
        var ledger = BlipTimelineLedger.empty
        ledger.homeCoordinate = homeCoordinate
        ledger.savedPlaces = [englishHome, olderHemma, canonicalHemma]
        ledger.placeLabels = ledger.savedPlaces.map {
            BlipTimelinePlaceLabel(
                coordinate: $0.coordinate,
                title: $0.title,
                subtitle: $0.subtitle,
                isHome: $0.isHome
            )
        }
        ledger.days = [BlipTimelineDay(
            date: start,
            timeZoneIdentifier: "Europe/Stockholm",
            coverage: .complete,
            entries: entries,
            metrics: BlipTimelineStore.metrics(for: entries)
        )]
        ledger.visitPlaceAssignments["visit-id"] = BlipTimelineVisitPlaceAssignment(
            place: englishHome,
            remembersPlace: true
        )
        try persistence.save(ledger)

        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: persistence
        )

        let home = try #require(store.savedPlaces.first)
        #expect(store.savedPlaces.count == 1)
        #expect(home.id == canonicalHemma.id)
        #expect(home.title == "Hemma")
        #expect(home.isHome)
        #expect(Set(home.residentContacts.map(\.contactIdentifier))
            == Set(["contact-alice", "contact-bob"]))
        #expect(store.ledger.placeLabels.count == 1)
        #expect(store.ledger.placeLabels.first?.title == "Hemma")
        #expect(store.days.flatMap(\.entries).allSatisfy {
            $0.title == "Hemma"
                && $0.placeID == canonicalHemma.id
                && Set($0.residentContacts.map(\.contactIdentifier))
                    == Set(["contact-alice", "contact-bob"])
        })
        #expect(store.ledger.visitPlaceAssignments["visit-id"]?.place.id
            == canonicalHemma.id)
        #expect(persistence.load().savedPlaces.count == 1)
    }

    @Test
    func absorbingHomeDaysDoesNotCreateAPlaceForEveryGPSFix() {
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        let start = Date(timeIntervalSince1970: 966_785_600)
        let first = BlipTimelineEntry(
            id: "first-home",
            kind: .visit,
            title: "Hemma",
            startDate: start,
            endDate: start.addingTimeInterval(3_600),
            coordinate: .init(latitude: 0, longitude: 0),
            isHome: true
        )
        let second = BlipTimelineEntry(
            id: "second-home",
            kind: .visit,
            title: "Home",
            startDate: start.addingTimeInterval(86_400),
            coordinate: .init(latitude: -0.00006, longitude: -0.00011),
            isHome: true
        )
        store.replaceDays([
            BlipTimelineDay(
                date: start,
                timeZoneIdentifier: "Europe/Stockholm",
                coverage: .complete,
                entries: [first],
                metrics: BlipTimelineStore.metrics(for: [first])
            ),
            BlipTimelineDay(
                date: start.addingTimeInterval(86_400),
                timeZoneIdentifier: "Europe/Stockholm",
                coverage: .partial,
                entries: [second],
                metrics: BlipTimelineStore.metrics(for: [second])
            ),
        ])

        store.materializeStationaryDays(now: start.addingTimeInterval(90_000))

        #expect(store.savedPlaces.count == 1)
        #expect(store.savedPlaces.first?.title == "Hemma")
        #expect(store.ledger.placeLabels.count == 1)
    }

    @Test
    func batchedLocationIngestPreservesEveryDeliveredPoint() throws {
        let start = Date(timeIntervalSince1970: 966_785_600)
        let observations = (0..<4).map { index in
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: start.addingTimeInterval(Double(index * 10)),
                coordinate: .init(
                    latitude: 0 + (Double(index) * 0.001),
                    longitude: 0
                ),
                horizontalAccuracy: 10,
                speedMetersPerSecond: 12,
                timeZoneIdentifier: "Europe/Stockholm",
                motion: .automotive
            )
        }
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )

        store.ingest(
            observations,
            now: start.addingTimeInterval(30)
        )

        #expect(store.ledger.observations.map(\.id) == observations.map(\.id))
        let day = try #require(store.day(containing: start))
        let journey = try #require(day.entries.first { $0.kind == .journey })
        #expect(journey.route.count == observations.count)
        #expect(journey.transportMode == .driving)
    }

    @Test
    func repeatedCopiesOfTheSameGPSFixAreMerged() throws {
        let start = Date(timeIntervalSince1970: 966_785_600)
        let originalID = UUID()
        let coordinate = BlipTimelineCoordinate(latitude: 0, longitude: 0)
        let first = BlipTimelineLocationObservation(
            id: originalID,
            timestamp: start,
            coordinate: coordinate,
            horizontalAccuracy: 40,
            speedMetersPerSecond: 0,
            timeZoneIdentifier: "Europe/Stockholm",
            motion: .unknown
        )
        let improvedDuplicate = BlipTimelineLocationObservation(
            id: UUID(),
            timestamp: start.addingTimeInterval(0.1),
            coordinate: coordinate,
            horizontalAccuracy: 2,
            speedMetersPerSecond: 14,
            timeZoneIdentifier: "Europe/Stockholm",
            motion: .automotive
        )
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )

        store.ingest(
            [first, improvedDuplicate],
            now: start.addingTimeInterval(0.1)
        )

        let stored = try #require(store.ledger.observations.first)
        #expect(store.ledger.observations.count == 1)
        #expect(stored.id == originalID)
        #expect(stored.timestamp == start)
        #expect(stored.horizontalAccuracy == 2)
        #expect(stored.speedMetersPerSecond == 14)
        #expect(stored.motion == .automotive)
    }

    @Test
    func aStationaryVisitSpanningMidnightFillsTheQuietDay() throws {
        let arrival = ISO8601DateFormatter().date(from: "2000-08-18T20:00:00Z")!
        let departure = ISO8601DateFormatter().date(from: "2000-08-20T08:00:00Z")!
        let now = ISO8601DateFormatter().date(from: "2000-08-20T12:00:00Z")!
        let home = BlipTimelineCoordinate(latitude: 0, longitude: 0)
        let visit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: arrival,
            departureDate: departure,
            coordinate: home,
            horizontalAccuracy: 25,
            timeZoneIdentifier: "UTC"
        )

        let day = try #require(BlipTimelineDayBuilder.makeDay(
            dateKey: "2000-08-19",
            observations: [],
            visits: [visit],
            homeCoordinate: home,
            sourceDeviceID: "iphone",
            now: now
        ))

        let entry = try #require(day.entries.first)
        #expect(day.coverage == .complete)
        #expect(day.entries.count == 1)
        #expect(entry.title == "Home")
        #expect(entry.startDate == ISO8601DateFormatter().date(from: "2000-08-19T00:00:00Z"))
        #expect(entry.endDate == ISO8601DateFormatter().date(from: "2000-08-20T00:00:00Z"))
        #expect(entry.confidence == .observed)
        #expect(day.entryCoversEntireDay(entry))
        #expect(day.metrics?.movingDuration == 0)
        #expect(day.metrics?.awayFromHomeDuration == 0)
    }

    @Test
    func reopeningTimelineMaterializesDaysFromAnOngoingStationaryVisit() throws {
        let arrival = ISO8601DateFormatter().date(from: "2000-08-18T20:00:00Z")!
        let now = ISO8601DateFormatter().date(from: "2000-08-20T12:00:00Z")!
        let home = BlipTimelineCoordinate(latitude: 0, longitude: 0)
        let visit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: arrival,
            departureDate: nil,
            coordinate: home,
            horizontalAccuracy: 25,
            timeZoneIdentifier: "UTC"
        )
        let store = BlipTimelineStore(
            arguments: [],
            calendar: Calendar(identifier: .gregorian),
            cloudSession: nil,
            persistence: .inMemory
        )
        store.trackingEnabled = true
        store.ledger.trackingEnabled = true
        store.ledger.homeCoordinate = home
        store.ledger.visits = [visit]

        store.materializeStationaryDays(now: now)

        #expect(store.days.map(\.dateKey) == [
            "2000-08-18",
            "2000-08-19",
            "2000-08-20",
        ])
        let quietDay = try #require(store.days.first { $0.dateKey == "2000-08-19" })
        let quietEntry = try #require(quietDay.entries.first)
        #expect(quietDay.coverage == .complete)
        #expect(quietEntry.title == "Home")
        #expect(quietEntry.confidence == .inferred)
        #expect(quietDay.entryCoversEntireDay(quietEntry))
        let currentDay = try #require(store.days.first { $0.dateKey == "2000-08-20" })
        #expect(currentDay.coverage == .partial)
        #expect(currentDay.entries.first?.endDate == nil)
        #expect(store.pendingSyncCount == 3)
    }

    @Test
    func aDepartureReportWithRefinedEstimatesUpdatesTheOriginalVisit() {
        let originalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let arrival = Date(timeIntervalSince1970: 966_664_800)
        let refinedArrival = Date(timeIntervalSince1970: 966_664_802)
        let departure = Date(timeIntervalSince1970: 966_740_400.5)
        let openVisit = BlipTimelineVisitObservation(
            id: originalID,
            arrivalDate: arrival,
            departureDate: nil,
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 5,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let closedVisit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: refinedArrival,
            departureDate: departure,
            coordinate: .init(latitude: 0.0002, longitude: -0.0003),
            horizontalAccuracy: 18,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        store.ledger.visits = [openVisit]

        let storedVisit = store.ingest(
            closedVisit,
            now: departure.addingTimeInterval(60)
        )

        #expect(store.ledger.visits.count == 1)
        #expect(storedVisit.id == originalID)
        #expect(storedVisit.arrivalDate == refinedArrival)
        #expect(storedVisit.departureDate == departure)
        #expect(storedVisit.coordinate == openVisit.coordinate)
        #expect(storedVisit.horizontalAccuracy == 5)
    }

    @Test
    func aLaterDistinctArrivalEndsThePreviousOpenVisit() {
        let awayArrival = ISO8601DateFormatter().date(from: "2000-08-21T16:00:00Z")!
        let homeArrival = ISO8601DateFormatter().date(from: "2000-08-21T16:10:00Z")!
        let awayVisit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: awayArrival,
            departureDate: nil,
            coordinate: .init(latitude: 0.0045, longitude: -0.001),
            horizontalAccuracy: 87,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let homeVisit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: homeArrival,
            departureDate: nil,
            coordinate: .init(latitude: 0.00004, longitude: 0.00008),
            horizontalAccuracy: 10,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        store.ledger.visits = [awayVisit]

        store.ingest(homeVisit, now: homeArrival.addingTimeInterval(60))

        #expect(store.ledger.visits.count == 2)
        #expect(store.ledger.visits[0].id == awayVisit.id)
        #expect(store.ledger.visits[0].departureDate == homeArrival)
        #expect(store.ledger.visits[1].id == homeVisit.id)
        #expect(store.ledger.visits[1].departureDate == nil)
    }

    @Test
    func materializationRepairsTwoPlacesCarriedAcrossMidnight() throws {
        let awayArrival = ISO8601DateFormatter().date(from: "2000-08-21T16:00:00Z")!
        let homeArrival = ISO8601DateFormatter().date(from: "2000-08-21T16:10:00Z")!
        let now = ISO8601DateFormatter().date(from: "2000-08-22T05:00:00Z")!
        let awayVisit = BlipTimelineVisitObservation(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            arrivalDate: awayArrival,
            departureDate: nil,
            coordinate: .init(latitude: 0.0045, longitude: -0.001),
            horizontalAccuracy: 87,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let homeVisit = BlipTimelineVisitObservation(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            arrivalDate: homeArrival,
            departureDate: nil,
            coordinate: .init(latitude: 0.00004, longitude: 0.00008),
            horizontalAccuracy: 10,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let staleAwayEntry = BlipTimelineEntry(
            id: BlipTimelineDayBuilder.visitEntryID(for: awayVisit, dateKey: "2000-08-21"),
            kind: .visit,
            title: "Visited place",
            startDate: awayArrival,
            coordinate: awayVisit.coordinate
        )
        let staleHomeEntry = BlipTimelineEntry(
            id: BlipTimelineDayBuilder.visitEntryID(for: homeVisit, dateKey: "2000-08-21"),
            kind: .visit,
            title: "Hemma",
            startDate: homeArrival,
            coordinate: homeVisit.coordinate,
            isHome: true
        )
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        store.trackingEnabled = true
        store.ledger.trackingEnabled = true
        store.ledger.homeCoordinate = homeVisit.coordinate
        store.ledger.visits = [awayVisit, homeVisit]
        store.replaceDays([BlipTimelineDay(
            date: ISO8601DateFormatter().date(from: "2000-08-20T22:00:00Z")!,
            dateKey: "2000-08-21",
            timeZoneIdentifier: "Europe/Stockholm",
            coverage: .complete,
            entries: [staleAwayEntry, staleHomeEntry],
            metrics: BlipTimelineStore.metrics(for: [staleAwayEntry, staleHomeEntry])
        )])
        store.ledger.manuallyEditedDateKeys.insert("2000-08-21")

        store.materializeStationaryDays(now: now)

        #expect(store.ledger.visits[0].departureDate == homeArrival)
        #expect(store.ledger.visits[1].departureDate == nil)
        let friday = try #require(store.days.first { $0.dateKey == "2000-08-21" })
        #expect(friday.entries.first { $0.id == staleAwayEntry.id }?.endDate == homeArrival)
        #expect(friday.entries.first { $0.id == staleHomeEntry.id }?.endDate
            == ISO8601DateFormatter().date(from: "2000-08-21T22:00:00Z"))
        #expect(friday.entries.first { $0.id == staleHomeEntry.id }?.title == "Hemma")
        let saturday = try #require(store.days.first { $0.dateKey == "2000-08-22" })
        let saturdayVisits = saturday.entries.filter { $0.kind == .visit }
        #expect(saturdayVisits.count == 1)
        #expect(saturdayVisits[0].id
            == BlipTimelineDayBuilder.visitEntryID(for: homeVisit, dateKey: "2000-08-22"))
        #expect(saturdayVisits[0].isHome)
        #expect(saturdayVisits[0].startDate
            == ISO8601DateFormatter().date(from: "2000-08-21T22:00:00Z"))
    }

    @Test
    func storedVisitRevisionsRepairAnOvernightDuplicate() throws {
        let originalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let arrival = Date(timeIntervalSince1970: 966_664_800)
        let refinedArrival = Date(timeIntervalSince1970: 966_664_802)
        let departure = Date(timeIntervalSince1970: 966_740_400.5)
        let now = ISO8601DateFormatter().date(from: "2000-08-20T20:00:00Z")!
        let openHome = BlipTimelineVisitObservation(
            id: originalID,
            arrivalDate: arrival,
            departureDate: nil,
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 5,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let completedHome = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: refinedArrival,
            departureDate: departure,
            coordinate: .init(latitude: 0.0002, longitude: -0.0003),
            horizontalAccuracy: 18,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let staleContinuation = BlipTimelineEntry(
            id: "visit-966664800000-2000-08-20",
            kind: .visit,
            title: "Hemma",
            startDate: ISO8601DateFormatter().date(from: "2000-08-19T22:00:00Z")!,
            coordinate: openHome.coordinate,
            confidence: .inferred,
            isHome: true
        )
        let completedContinuation = BlipTimelineEntry(
            id: "visit-966664802000-2000-08-20",
            kind: .visit,
            title: "Hemma",
            startDate: ISO8601DateFormatter().date(from: "2000-08-19T22:00:00Z")!,
            endDate: departure,
            coordinate: completedHome.coordinate,
            confidence: .observed,
            isHome: true
        )
        let store = BlipTimelineStore(
            arguments: [],
            calendar: Calendar(identifier: .gregorian),
            cloudSession: nil,
            persistence: .inMemory
        )
        store.trackingEnabled = true
        store.ledger.trackingEnabled = true
        store.ledger.homeCoordinate = openHome.coordinate
        store.ledger.visits = [openHome, completedHome]
        store.replaceDays([BlipTimelineDay(
            date: ISO8601DateFormatter().date(from: "2000-08-19T22:00:00Z")!,
            dateKey: "2000-08-20",
            timeZoneIdentifier: "Europe/Stockholm",
            coverage: .partial,
            entries: [staleContinuation, completedContinuation],
            metrics: BlipTimelineStore.metrics(for: [
                staleContinuation,
                completedContinuation,
            ])
        )])

        store.materializeStationaryDays(now: now)

        #expect(store.ledger.visits.count == 1)
        #expect(store.ledger.visits[0].id == originalID)
        #expect(store.ledger.visits[0].arrivalDate == refinedArrival)
        #expect(store.ledger.visits[0].departureDate == departure)
        let currentDay = try #require(store.days.first { $0.dateKey == "2000-08-20" })
        let homeEntries = currentDay.entries.filter { $0.kind == .visit && $0.isHome }
        let homeEntry = try #require(homeEntries.first)
        #expect(homeEntries.count == 1)
        #expect(homeEntry.startDate
            == ISO8601DateFormatter().date(from: "2000-08-19T22:00:00Z"))
        #expect(homeEntry.endDate == departure)
        #expect(homeEntry.id == "visit-\(originalID.uuidString.lowercased())-2000-08-20")
    }

    @Test
    func returningToACompletedPlaceCreatesANewVisit() {
        let firstArrival = ISO8601DateFormatter().date(from: "2000-08-20T08:00:00Z")!
        let firstDeparture = ISO8601DateFormatter().date(from: "2000-08-20T09:00:00Z")!
        let returnArrival = ISO8601DateFormatter().date(from: "2000-08-20T09:02:00Z")!
        let coordinate = BlipTimelineCoordinate(latitude: 0, longitude: 0)
        let completedVisit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: firstArrival,
            departureDate: firstDeparture,
            coordinate: coordinate,
            horizontalAccuracy: 10,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let returnedVisit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: returnArrival,
            departureDate: nil,
            coordinate: coordinate,
            horizontalAccuracy: 10,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        store.ledger.visits = [completedVisit]

        store.ingest(returnedVisit, now: returnArrival.addingTimeInterval(60))

        #expect(store.ledger.visits.map(\.id) == [completedVisit.id, returnedVisit.id])
    }

    @Test
    func completingTheImmediatelyPrecedingOpenVisitDoesNotDependOnEstimateDrift() {
        let originalID = UUID()
        let coordinate = BlipTimelineCoordinate(latitude: 0, longitude: 0)
        let openVisit = BlipTimelineVisitObservation(
            id: originalID,
            arrivalDate: ISO8601DateFormatter().date(from: "2000-08-20T08:00:00Z")!,
            departureDate: nil,
            coordinate: coordinate,
            horizontalAccuracy: 10,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let completedVisit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: ISO8601DateFormatter().date(from: "2000-08-20T08:20:00Z")!,
            departureDate: ISO8601DateFormatter().date(from: "2000-08-20T10:00:00Z")!,
            coordinate: coordinate,
            horizontalAccuracy: 20,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        store.ledger.visits = [openVisit]

        store.ingest(
            completedVisit,
            now: completedVisit.departureDate!.addingTimeInterval(60)
        )

        #expect(store.ledger.visits.count == 1)
        #expect(store.ledger.visits[0].id == originalID)
        #expect(store.ledger.visits[0].arrivalDate == completedVisit.arrivalDate)
        #expect(store.ledger.visits[0].departureDate == completedVisit.departureDate)
    }

    @Test
    func pastEditedDayFinalizesAndRepairsLegacyThirtyMinuteVisitEnds() throws {
        let cafeArrival = ISO8601DateFormatter().date(from: "2000-08-19T17:00:00Z")!
        let cafeDeparture = ISO8601DateFormatter().date(from: "2000-08-19T17:30:00Z")!
        let homeArrival = ISO8601DateFormatter().date(from: "2000-08-19T18:00:00Z")!
        let now = ISO8601DateFormatter().date(from: "2000-08-20T12:00:00Z")!
        let cafeCoordinate = BlipTimelineCoordinate(latitude: 0.007, longitude: 0.0005)
        let homeCoordinate = BlipTimelineCoordinate(latitude: -0.01, longitude: -0.005)
        let visits = [
            BlipTimelineVisitObservation(
                id: UUID(),
                arrivalDate: cafeArrival,
                departureDate: cafeDeparture,
                coordinate: cafeCoordinate,
                horizontalAccuracy: 20,
                timeZoneIdentifier: "UTC"
            ),
            BlipTimelineVisitObservation(
                id: UUID(),
                arrivalDate: homeArrival,
                departureDate: nil,
                coordinate: homeCoordinate,
                horizontalAccuracy: 10,
                timeZoneIdentifier: "UTC"
            ),
        ]
        let cafeEntry = BlipTimelineEntry(
            id: "edited-cafe",
            kind: .visit,
            title: "Null Pointer Café",
            subtitle: "Null Island workshop",
            startDate: cafeArrival,
            endDate: cafeArrival.addingTimeInterval(30 * 60),
            coordinate: cafeCoordinate
        )
        let homeEntry = BlipTimelineEntry(
            id: "edited-home",
            kind: .visit,
            title: "Hemma",
            startDate: homeArrival,
            endDate: homeArrival.addingTimeInterval(30 * 60),
            coordinate: homeCoordinate,
            isHome: true
        )
        let store = BlipTimelineStore(
            arguments: [],
            calendar: Calendar(identifier: .gregorian),
            cloudSession: nil,
            persistence: .inMemory
        )
        store.trackingEnabled = true
        store.ledger.trackingEnabled = true
        store.ledger.visits = visits
        store.replaceDays([BlipTimelineDay(
            date: ISO8601DateFormatter().date(from: "2000-08-19T00:00:00Z")!,
            dateKey: "2000-08-19",
            timeZoneIdentifier: "UTC",
            coverage: .partial,
            entries: [cafeEntry, homeEntry],
            metrics: BlipTimelineStore.metrics(for: [cafeEntry, homeEntry])
        )])
        store.ledger.manuallyEditedDateKeys.insert("2000-08-19")

        store.materializeStationaryDays(now: now)

        let repaired = try #require(store.days.first { $0.dateKey == "2000-08-19" })
        #expect(repaired.coverage == .complete)
        #expect(repaired.entries.first { $0.id == "edited-cafe" }?.endDate == cafeDeparture)
        #expect(repaired.entries.first { $0.id == "edited-home" }?.endDate
            == ISO8601DateFormatter().date(from: "2000-08-20T00:00:00Z"))
        #expect(repaired.entries.first { $0.id == "edited-home" }?.title == "Hemma")
    }

    @Test
    func editedCurrentDayKeepsTheJourneyConnectingANewVisit() throws {
        let sourceArrival = ISO8601DateFormatter().date(from: "2000-08-22T09:00:00Z")!
        let sourceDeparture = ISO8601DateFormatter().date(from: "2000-08-22T12:00:00Z")!
        let destinationArrival = ISO8601DateFormatter().date(from: "2000-08-22T12:20:00Z")!
        let sourceCoordinate = BlipTimelineCoordinate(latitude: 0.0148, longitude: -0.0444)
        let destinationCoordinate = BlipTimelineCoordinate(latitude: 0.0181, longitude: -0.0071)
        let sourceVisit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: sourceArrival,
            departureDate: sourceDeparture,
            coordinate: sourceCoordinate,
            horizontalAccuracy: 5,
            timeZoneIdentifier: "UTC"
        )
        let destinationVisit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: destinationArrival,
            departureDate: nil,
            coordinate: destinationCoordinate,
            horizontalAccuracy: 5,
            timeZoneIdentifier: "UTC"
        )
        let editedSource = BlipTimelineEntry(
            id: BlipTimelineDayBuilder.visitEntryID(for: sourceVisit, dateKey: "2000-08-22"),
            kind: .visit,
            title: "Null Island Padel",
            startDate: sourceArrival,
            endDate: sourceDeparture,
            coordinate: sourceCoordinate
        )
        let store = BlipTimelineStore(
            arguments: [],
            calendar: Calendar(identifier: .gregorian),
            cloudSession: nil,
            persistence: .inMemory
        )
        store.trackingEnabled = true
        store.ledger.trackingEnabled = true
        store.ledger.visits = [sourceVisit]
        store.ledger.observations = [
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: sourceDeparture.addingTimeInterval(60),
                coordinate: sourceCoordinate,
                horizontalAccuracy: 5,
                speedMetersPerSecond: 10,
                timeZoneIdentifier: "UTC",
                motion: .automotive
            ),
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: destinationArrival.addingTimeInterval(-60),
                coordinate: destinationCoordinate,
                horizontalAccuracy: 5,
                speedMetersPerSecond: 10,
                timeZoneIdentifier: "UTC",
                motion: .automotive
            ),
        ]
        store.replaceDays([BlipTimelineDay(
            date: ISO8601DateFormatter().date(from: "2000-08-22T00:00:00Z")!,
            dateKey: "2000-08-22",
            timeZoneIdentifier: "UTC",
            coverage: .partial,
            entries: [editedSource],
            metrics: BlipTimelineStore.metrics(for: [editedSource])
        )])
        store.ledger.manuallyEditedDateKeys.insert("2000-08-22")

        store.ingest(
            destinationVisit,
            now: destinationArrival.addingTimeInterval(120)
        )

        let updated = try #require(store.days.first { $0.dateKey == "2000-08-22" })
        #expect(updated.entries.first { $0.id == editedSource.id }?.title == "Null Island Padel")
        let journey = try #require(updated.entries.first { $0.kind == .journey })
        #expect(journey.startDate == sourceDeparture)
        #expect(journey.endDate == destinationArrival)
        #expect(journey.transportMode == .driving)
        #expect(updated.entries.contains {
            $0.id == BlipTimelineDayBuilder.visitEntryID(
                for: destinationVisit,
                dateKey: "2000-08-22"
            )
        })
    }

    @Test
    func editedCurrentDayRepairsAPreviouslyMissingConnectingJourney() throws {
        let sourceArrival = ISO8601DateFormatter().date(from: "2000-08-22T09:00:00Z")!
        let sourceDeparture = ISO8601DateFormatter().date(from: "2000-08-22T12:00:00Z")!
        let destinationArrival = ISO8601DateFormatter().date(from: "2000-08-22T12:20:00Z")!
        let sourceCoordinate = BlipTimelineCoordinate(latitude: 0.0148, longitude: -0.0444)
        let destinationCoordinate = BlipTimelineCoordinate(latitude: 0.0181, longitude: -0.0071)
        let sourceVisit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: sourceArrival,
            departureDate: sourceDeparture,
            coordinate: sourceCoordinate,
            horizontalAccuracy: 5,
            timeZoneIdentifier: "UTC"
        )
        let destinationVisit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: destinationArrival,
            departureDate: nil,
            coordinate: destinationCoordinate,
            horizontalAccuracy: 5,
            timeZoneIdentifier: "UTC"
        )
        let editedSource = BlipTimelineEntry(
            id: BlipTimelineDayBuilder.visitEntryID(for: sourceVisit, dateKey: "2000-08-22"),
            kind: .visit,
            title: "Null Island Padel",
            startDate: sourceArrival,
            endDate: sourceDeparture,
            coordinate: sourceCoordinate
        )
        let editedDestination = BlipTimelineEntry(
            id: BlipTimelineDayBuilder.visitEntryID(
                for: destinationVisit,
                dateKey: "2000-08-22"
            ),
            kind: .visit,
            title: "Null Pointer Café",
            startDate: destinationArrival,
            coordinate: destinationCoordinate
        )
        let store = BlipTimelineStore(
            arguments: [],
            calendar: Calendar(identifier: .gregorian),
            cloudSession: nil,
            persistence: .inMemory
        )
        store.trackingEnabled = true
        store.ledger.trackingEnabled = true
        store.ledger.visits = [sourceVisit, destinationVisit]
        store.ledger.observations = [
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: sourceDeparture.addingTimeInterval(60),
                coordinate: sourceCoordinate,
                horizontalAccuracy: 5,
                speedMetersPerSecond: 10,
                timeZoneIdentifier: "UTC",
                motion: .automotive
            ),
            BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: destinationArrival.addingTimeInterval(-60),
                coordinate: destinationCoordinate,
                horizontalAccuracy: 5,
                speedMetersPerSecond: 10,
                timeZoneIdentifier: "UTC",
                motion: .automotive
            ),
        ]
        store.replaceDays([BlipTimelineDay(
            date: ISO8601DateFormatter().date(from: "2000-08-22T00:00:00Z")!,
            dateKey: "2000-08-22",
            timeZoneIdentifier: "UTC",
            coverage: .partial,
            entries: [editedSource, editedDestination],
            metrics: BlipTimelineStore.metrics(for: [editedSource, editedDestination])
        )])
        store.ledger.manuallyEditedDateKeys.insert("2000-08-22")

        store.ingest(BlipTimelineLocationObservation(
            id: UUID(),
            timestamp: destinationArrival.addingTimeInterval(60),
            coordinate: destinationCoordinate,
            horizontalAccuracy: 5,
            speedMetersPerSecond: 0,
            timeZoneIdentifier: "UTC",
            motion: .stationary
        ), now: destinationArrival.addingTimeInterval(120))

        let updated = try #require(store.days.first { $0.dateKey == "2000-08-22" })
        #expect(updated.entries.first { $0.id == editedSource.id }?.title == "Null Island Padel")
        #expect(updated.entries.first { $0.id == editedDestination.id }?.title == "Null Pointer Café")
        let journey = try #require(updated.entries.first { $0.kind == .journey })
        #expect(journey.startDate == sourceDeparture)
        #expect(journey.endDate == destinationArrival)
    }

    @Test
    func visitEntryIdentityDoesNotDependOnAnApproximateArrivalDate() {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let firstReport = BlipTimelineVisitObservation(
            id: id,
            arrivalDate: Date(timeIntervalSince1970: 966_664_800),
            departureDate: nil,
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 10,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let completedReport = BlipTimelineVisitObservation(
            id: id,
            arrivalDate: Date(timeIntervalSince1970: 966_664_802),
            departureDate: Date(timeIntervalSince1970: 966_740_400.5),
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 10,
            timeZoneIdentifier: "Europe/Stockholm"
        )

        #expect(BlipTimelineDayBuilder.visitEntryID(
            for: firstReport,
            dateKey: firstReport.dateKey
        ) == BlipTimelineDayBuilder.visitEntryID(
            for: completedReport,
            dateKey: completedReport.dateKey
        ))
    }

    @Test
    func relabelingAPlaceUpdatesMatchingVisitsAndFutureCapture() {
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        let firstStart = Date(timeIntervalSince1970: 955_545_600)
        let secondStart = firstStart.addingTimeInterval(86_400)
        let first = BlipTimelineEntry(
            id: "visit-first",
            kind: .visit,
            title: "Visited place",
            startDate: firstStart,
            endDate: firstStart.addingTimeInterval(1_800),
            coordinate: .init(latitude: 0, longitude: 0)
        )
        let matching = BlipTimelineEntry(
            id: "visit-matching",
            kind: .visit,
            title: "Visited place",
            startDate: secondStart,
            endDate: secondStart.addingTimeInterval(1_800),
            coordinate: .init(latitude: 0.0003, longitude: 0.0001)
        )
        let farAway = BlipTimelineEntry(
            id: "visit-far",
            kind: .visit,
            title: "Visited place",
            startDate: secondStart.addingTimeInterval(3_600),
            endDate: secondStart.addingTimeInterval(4_200),
            coordinate: .init(latitude: 0.02, longitude: 0.015)
        )
        store.replaceDays([
            BlipTimelineDay(
                date: firstStart,
                timeZoneIdentifier: "Europe/Stockholm",
                coverage: .complete,
                entries: [first],
                metrics: BlipTimelineStore.metrics(for: [first])
            ),
            BlipTimelineDay(
                date: secondStart,
                timeZoneIdentifier: "Europe/Stockholm",
                coverage: .complete,
                entries: [matching, farAway],
                metrics: BlipTimelineStore.metrics(for: [matching, farAway])
            ),
        ])

        store.updateEntry(
            id: first.id,
            title: "Studio",
            subtitle: "Null Island village",
            startDate: first.startDate,
            endDate: first.endDate,
            transportMode: nil,
            isHome: false
        )

        let entries = store.days.flatMap(\.entries)
        #expect(entries.first(where: { $0.id == first.id })?.title == "Studio")
        #expect(entries.first(where: { $0.id == matching.id })?.title == "Studio")
        #expect(entries.first(where: { $0.id == matching.id })?.subtitle == "Null Island village")
        #expect(entries.first(where: { $0.id == farAway.id })?.title == "Visited place")
        #expect(store.pendingSyncCount == 2)
        #expect(store.ledger.placeLabels.count == 1)

        let futureVisit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: secondStart.addingTimeInterval(86_400),
            departureDate: secondStart.addingTimeInterval(88_200),
            coordinate: .init(latitude: 0.0002, longitude: 0.00005),
            horizontalAccuracy: 25,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let futureDay = BlipTimelineDayBuilder.makeDay(
            dateKey: futureVisit.dateKey,
            observations: [],
            visits: [futureVisit],
            homeCoordinate: nil,
            placeLabels: store.ledger.placeLabels,
            sourceDeviceID: "iphone"
        )

        #expect(futureDay?.entries.first?.title == "Studio")
        #expect(futureDay?.entries.first?.subtitle == "Null Island village")
    }

    @Test
    func legacyLedgerWithoutSavedPlaceLabelsStillDecodes() throws {
        let data = "{}".data(using: .utf8)!

        let ledger = try BlipTimelinePersistence.decoder.decode(BlipTimelineLedger.self, from: data)

        #expect(ledger.placeLabels.isEmpty)
        #expect(!ledger.trackingEnabled)
    }

    @Test
    func legacyPlaceAndEntryWithoutResidentsDecodeWithEmptyResidents() throws {
        let placeJSON = """
        {
          "id":"place-legacy",
          "title":"Studio",
          "coordinate":{"latitude":0,"longitude":0},
          "isHome":false,
          "recognitionRadiusMeters":65
        }
        """
        let entryJSON = """
        {
          "id":"entry-legacy",
          "kind":"visit",
          "title":"Studio",
          "startDate":"2000-08-21T08:00:00.000Z",
          "route":[],
          "confidence":"observed",
          "isHome":false
        }
        """

        let place = try BlipTimelinePersistence.decoder.decode(
            BlipTimelineSavedPlace.self,
            from: Data(placeJSON.utf8)
        )
        let entry = try BlipTimelinePersistence.decoder.decode(
            BlipTimelineEntry.self,
            from: Data(entryJSON.utf8)
        )

        #expect(place.residentContacts.isEmpty)
        #expect(entry.residentContacts.isEmpty)
    }

    @Test
    func mapFocusFramesVisitsAndWholeJourneysAboveTheSheet() {
        let visitCoordinate = BlipTimelineCoordinate(latitude: 0, longitude: 0)
        let visit = BlipTimelineEntry(
            id: "visit",
            kind: .visit,
            title: "Studio",
            startDate: Date(),
            coordinate: visitCoordinate
        )
        let journey = BlipTimelineEntry(
            id: "journey",
            kind: .journey,
            title: "Driving",
            startDate: Date(),
            route: [
                .init(latitude: -0.03, longitude: -0.03),
                .init(latitude: 0.03, longitude: 0.03),
            ]
        )

        let visitRegion = BlipTimelineMapFocus.region(for: visit)
        let journeyRegion = BlipTimelineMapFocus.region(for: journey)

        #expect(visitRegion != nil)
        #expect(visitRegion!.center.latitude < visitCoordinate.latitude)
        #expect(journeyRegion != nil)
        for coordinate in journey.route {
            #expect(abs(coordinate.latitude - journeyRegion!.center.latitude)
                <= journeyRegion!.span.latitudeDelta / 2)
            #expect(abs(coordinate.longitude - journeyRegion!.center.longitude)
                <= journeyRegion!.span.longitudeDelta / 2)
        }
    }

    @Test
    func dayOverviewDoesNotOverZoomAroundOneCheckpoint() throws {
        let coordinate = BlipTimelineCoordinate(latitude: 0, longitude: 0)
        let entry = BlipTimelineEntry(
            id: "single-visit",
            kind: .visit,
            title: "Home",
            startDate: Date(),
            coordinate: coordinate
        )
        let day = BlipTimelineDay(
            date: Date(),
            timeZoneIdentifier: "Europe/Stockholm",
            coverage: .partial,
            entries: [entry],
            metrics: BlipTimelineStore.metrics(for: [entry])
        )

        let region = try #require(BlipTimelineMapFocus.region(for: day))

        #expect(region.span.latitudeDelta >= 0.04)
        #expect(region.span.longitudeDelta >= 0.04)
        #expect(abs(coordinate.latitude - region.center.latitude)
            <= region.span.latitudeDelta / 2)
        #expect(abs(coordinate.longitude - region.center.longitude)
            <= region.span.longitudeDelta / 2)
    }

    @Test
    func selectingTheDateHeadingCanReturnToToday() {
        let store = BlipTimelineStore(
            arguments: [],
            calendar: Calendar(identifier: .gregorian),
            cloudSession: nil,
            persistence: .inMemory
        )
        let today = Date(timeIntervalSince1970: 955_545_600)
        store.selectDay(today.addingTimeInterval(-7 * 86_400))

        store.selectToday(now: today)

        #expect(Calendar(identifier: .gregorian).isDate(store.selectedDate, inSameDayAs: today))
    }

    @Test
    func correctionsCanMarkHomeSplitAndMergeWithoutChangingTheDayKey() {
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        let start = Date(timeIntervalSince1970: 955_545_600)
        let entry = BlipTimelineEntry(
            id: "visit-home",
            kind: .visit,
            title: "Unknown place",
            startDate: start,
            endDate: start.addingTimeInterval(3_600),
            coordinate: .init(latitude: 0, longitude: 0)
        )
        let day = BlipTimelineDay(
            date: start,
            timeZoneIdentifier: "Europe/Stockholm",
            coverage: .complete,
            entries: [entry],
            metrics: BlipTimelineStore.metrics(for: [entry])
        )
        store.replaceDays([day])

        store.updateEntry(
            id: entry.id,
            title: "Home",
            subtitle: nil,
            startDate: entry.startDate,
            endDate: entry.endDate,
            transportMode: nil,
            isHome: true
        )
        store.splitEntry(id: entry.id, at: start.addingTimeInterval(1_800))
        let firstID = "\(entry.id)-a"
        store.mergeEntry(id: firstID, towardNext: true)

        #expect(store.days[0].dateKey == day.dateKey)
        #expect(store.days[0].entries.count == 1)
        #expect(store.days[0].entries[0].isHome)
        #expect(store.pendingSyncCount == 1)
    }

    @Test
    func legacyPlaceLabelsBackfillStableSavedPlacesAndVisitLinks() throws {
        let json = """
        {
          "days":[{
            "dateKey":"2000-08-21",
            "timeZoneIdentifier":"Europe/Stockholm",
            "coverage":"complete",
            "entries":[{
              "id":"visit-11111111-1111-1111-1111-111111111111",
              "kind":"visit",
              "title":"Studio",
              "subtitle":"Null Island village",
              "startDate":"2000-08-21T08:00:00.000Z",
              "endDate":"2000-08-21T09:00:00.000Z",
              "coordinate":{"latitude":0,"longitude":0},
              "confidence":"observed",
              "isHome":false
            }],
            "updatedAt":"2000-08-21T10:00:00.000Z",
            "sourceDeviceID":"iphone"
          }],
          "visits":[{
            "id":"11111111-1111-1111-1111-111111111111",
            "arrivalDate":"2000-08-21T08:00:00.000Z",
            "departureDate":"2000-08-21T09:00:00.000Z",
            "coordinate":{"latitude":0,"longitude":0},
            "horizontalAccuracy":20,
            "timeZoneIdentifier":"Europe/Stockholm"
          }],
          "placeLabels":[{
            "coordinate":{"latitude":0,"longitude":0},
            "title":"Studio",
            "subtitle":"Null Island village",
            "isHome":false
          }]
        }
        """
        let ledger = try BlipTimelinePersistence.decoder.decode(
            BlipTimelineLedger.self,
            from: Data(json.utf8)
        )

        let place = try #require(ledger.savedPlaces.first)
        #expect(place.id.hasPrefix("legacy-"))
        #expect(place.title == "Studio")
        #expect(ledger.days[0].entries[0].placeID == place.id)
        #expect(ledger.visitPlaceAssignments["11111111-1111-1111-1111-111111111111"]?.place.id
            == place.id)
    }

    @Test
    func oneVisitPlaceCorrectionPreservesGPSWithoutRelabelingANearbyVisit() throws {
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        let arrival = Date(timeIntervalSince1970: 955_545_600)
        let visit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: arrival,
            departureDate: arrival.addingTimeInterval(1_800),
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 18,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let nearby = BlipTimelineEntry(
            id: "nearby-visit",
            kind: .visit,
            title: "Null Island Market",
            startDate: arrival.addingTimeInterval(3_600),
            endDate: arrival.addingTimeInterval(4_200),
            coordinate: .init(latitude: 0.0002, longitude: 0.0001)
        )
        let captured = try #require(BlipTimelineDayBuilder.makeDay(
            dateKey: visit.dateKey,
            observations: [],
            visits: [visit],
            homeCoordinate: nil,
            sourceDeviceID: "iphone",
            now: arrival.addingTimeInterval(7_200)
        ))
        let day = BlipTimelineDay(
            date: captured.date,
            dateKey: captured.dateKey,
            timeZoneIdentifier: captured.timeZoneIdentifier,
            coverage: captured.coverage,
            entries: captured.entries + [nearby],
            metrics: BlipTimelineStore.metrics(for: captured.entries + [nearby])
        )
        store.ledger.visits = [visit]
        store.replaceDays([day])
        let entry = try #require(captured.entries.first)
        let poiCoordinate = BlipTimelineCoordinate(latitude: 0.0001, longitude: 0.00005)

        store.updateVisitEntry(
            id: entry.id,
            title: "Null Island Diner",
            subtitle: "Zero Meridian Lane",
            startDate: entry.startDate,
            endDate: entry.endDate,
            isHome: false,
            selectedSavedPlaceID: nil,
            placeCoordinate: poiCoordinate,
            mapItemIdentifier: "apple-null-island-diner",
            pointOfInterestCategory: "MKPOICategoryRestaurant",
            iconSystemName: "fork.knife",
            rememberPlace: false
        )

        let entries = store.days[0].entries
        let corrected = try #require(entries.first { $0.id == entry.id })
        #expect(corrected.title == "Null Island Diner")
        #expect(corrected.coordinate == visit.coordinate)
        #expect(corrected.displayCoordinate == poiCoordinate)
        #expect(corrected.placeID == nil)
        #expect(entries.first { $0.id == nearby.id }?.title == "Null Island Market")
        #expect(store.savedPlaces.isEmpty)
        store.materializeStationaryDays(now: arrival.addingTimeInterval(7_200))
        #expect(!store.savedPlaces.contains { $0.title == "Null Island Diner" })
    }

    @Test
    func residentSelectionMergesPrivacyScopedIdentifiersWithoutDuplicates() throws {
        let existing = [
            BlipTimelineResidentReference(
                id: "resident-charlie",
                contactIdentifier: "picker-session-one-charlie",
                displayName: "Charlie Example",
                contactMatchTokens: ["sha256:charlie-email"]
            ),
        ]
        let selected = [
            BlipTimelineResidentReference(
                contactIdentifier: "picker-session-two-charlie",
                displayName: "  CHARLIE   EXAMPLE  ",
                contactMatchTokens: ["sha256:charlie-phone"]
            ),
            BlipTimelineResidentReference(
                contactIdentifier: "picker-session-two-dana",
                displayName: "Dana Example"
            ),
        ]

        let merged = BlipTimelineResidentReference.merging(existing, with: selected)

        #expect(merged.count == 2)
        #expect(merged[0].id == "resident-charlie")
        #expect(merged[0].contactIdentifier == "picker-session-two-charlie")
        #expect(merged[0].displayName == "CHARLIE   EXAMPLE")
        #expect(Set(merged[0].contactMatchTokens) == [
            "sha256:charlie-email", "sha256:charlie-phone",
        ])
        #expect(merged[1].displayName == "Dana Example")
    }

    @Test
    func residentCloudReferenceKeepsStableIdentityButDropsDeviceContactID() throws {
        let local = BlipTimelineResidentReference(
            id: "resident-charlie",
            contactIdentifier: "device-only-contact-id",
            displayName: "Charlie Example",
            contactMatchTokens: ["sha256:charlie-phone"]
        )

        let cloud = local.cloudReference
        let encoded = try BlipTimelinePersistence.encoder.encode(cloud)
        let payload = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(cloud.id == local.id)
        #expect(cloud.displayName == local.displayName)
        #expect(cloud.contactIdentifier.isEmpty)
        #expect(cloud.contactMatchTokens == local.contactMatchTokens)
        #expect(payload["contactIdentifier"] as? String == "")
    }

    @Test
    func residentCloudSchemaMigrationQueuesExistingAssignmentOnlyOnce() {
        let resident = BlipTimelineResidentReference(
            id: "resident-charlie",
            contactIdentifier: "device-only-contact-id",
            displayName: "Charlie Example"
        )
        let entry = BlipTimelineEntry(
            id: "visit-friends",
            kind: .visit,
            title: "Charlie’s place",
            startDate: Date(timeIntervalSince1970: 955_545_600),
            residentContacts: [resident]
        )
        let day = BlipTimelineDay(
            date: entry.startDate,
            dateKey: "2000-04-13",
            timeZoneIdentifier: "UTC",
            coverage: .complete,
            entries: [entry],
            metrics: .derived(from: [entry])
        )
        var ledger = BlipTimelineLedger.empty
        ledger.days = [day]

        let prepared = ledger.prepareResidentCloudSync()
        #expect(prepared)
        #expect(ledger.pendingDateKeys == ["2000-04-13"])
        #expect(ledger.residentCloudSchemaVersion == 1)
        let preparedAgain = ledger.prepareResidentCloudSync()
        #expect(!preparedAgain)
    }

    @Test
    func rememberedApplePlaceCarriesIdentityIconAndFutureRecognition() throws {
        let store = BlipTimelineStore(
            arguments: [],
            calendar: .autoupdatingCurrent,
            cloudSession: nil,
            persistence: .inMemory
        )
        let arrival = Date(timeIntervalSince1970: 955_545_600)
        let visit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: arrival,
            departureDate: arrival.addingTimeInterval(1_800),
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 12,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let day = try #require(BlipTimelineDayBuilder.makeDay(
            dateKey: visit.dateKey,
            observations: [],
            visits: [visit],
            homeCoordinate: nil,
            sourceDeviceID: "iphone",
            now: arrival.addingTimeInterval(7_200)
        ))
        store.ledger.visits = [visit]
        store.replaceDays([day])
        let entry = try #require(day.entries.first)
        let residents = [
            BlipTimelineResidentReference(
                id: "resident-alice",
                contactIdentifier: "contact-alice",
                displayName: "Alice Example"
            ),
            BlipTimelineResidentReference(
                id: "resident-bob",
                contactIdentifier: "contact-bob",
                displayName: "Bob Example"
            ),
        ]

        store.updateVisitEntry(
            id: entry.id,
            title: "Null Island Diner",
            subtitle: "Zero Meridian Lane",
            startDate: entry.startDate,
            endDate: entry.endDate,
            isHome: false,
            selectedSavedPlaceID: nil,
            placeCoordinate: .init(latitude: 0.0001, longitude: 0.00005),
            mapItemIdentifier: "apple-null-island-diner",
            pointOfInterestCategory: "MKPOICategoryRestaurant",
            iconSystemName: "fork.knife",
            residentContacts: residents,
            rememberPlace: true
        )

        let saved = try #require(store.savedPlaces.first)
        #expect(saved.residentContacts == residents)
        #expect(store.days[0].entries.first?.residentContacts == residents)
        #expect(store.ledger.visitPlaceAssignments[visit.id.uuidString.lowercased()]?
            .place.residentContacts == residents)
        let future = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: arrival.addingTimeInterval(86_400),
            departureDate: arrival.addingTimeInterval(88_200),
            coordinate: .init(latitude: 0.0001, longitude: 0),
            horizontalAccuracy: 10,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let futureDay = try #require(BlipTimelineDayBuilder.makeDay(
            dateKey: future.dateKey,
            observations: [],
            visits: [future],
            homeCoordinate: nil,
            savedPlaces: store.savedPlaces,
            sourceDeviceID: "iphone",
            now: future.departureDate!
        ))
        let futureEntry = try #require(futureDay.entries.first)

        #expect(futureEntry.title == "Null Island Diner")
        #expect(futureEntry.placeID == saved.id)
        #expect(futureEntry.mapItemIdentifier == "apple-null-island-diner")
        #expect(futureEntry.placeIcon == "fork.knife")
        #expect(futureEntry.residentContacts == residents)
    }

    @Test
    func adjacentSavedPlacesRemainUnresolvedWhenBothArePlausible() throws {
        let arrival = Date(timeIntervalSince1970: 955_545_600)
        let visit = BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: arrival,
            departureDate: arrival.addingTimeInterval(1_800),
            coordinate: .init(latitude: 0, longitude: 0),
            horizontalAccuracy: 15,
            timeZoneIdentifier: "Europe/Stockholm"
        )
        let places = [
            BlipTimelineSavedPlace(
                id: "null-island-market",
                title: "Null Island Market",
                subtitle: nil,
                coordinate: .init(latitude: 0.00005, longitude: 0)
            ),
            BlipTimelineSavedPlace(
                id: "null-island-diner",
                title: "Null Island Diner",
                subtitle: nil,
                coordinate: .init(latitude: -0.00005, longitude: 0)
            ),
        ]

        let day = try #require(BlipTimelineDayBuilder.makeDay(
            dateKey: visit.dateKey,
            observations: [],
            visits: [visit],
            homeCoordinate: nil,
            placeLabels: places.map {
                BlipTimelinePlaceLabel(
                    coordinate: $0.coordinate,
                    title: $0.title,
                    subtitle: $0.subtitle,
                    isHome: $0.isHome
                )
            },
            savedPlaces: places,
            sourceDeviceID: "iphone",
            now: visit.departureDate!
        ))

        #expect(day.entries.first?.title == "Visited place")
        #expect(day.entries.first?.placeID == nil)
    }
}

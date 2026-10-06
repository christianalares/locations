import Foundation
import Observation

public enum BlipTimelineTrackingState: String, Codable, Equatable, Sendable {
    case stopped
    case requestingPermission
    case active
    case whenInUseOnly
    case denied
    case unavailable

    public var title: String {
        switch self {
        case .stopped: "Tracking off"
        case .requestingPermission: "Waiting for permission"
        case .active: "Low-power tracking on"
        case .whenInUseOnly: "Background access needed"
        case .denied: "Location access denied"
        case .unavailable: "Tracking unavailable"
        }
    }
}

public enum BlipTimelineBackgroundCaptureStatus: String, Codable, Equatable, Sendable {
    case checking
    case ready
    case needsForegroundUse
    case alwaysPermissionNeeded
    case permissionDenied
    case serviceSessionMissing
    case accuracyLimited
    case unavailable

    public var title: String {
        switch self {
        case .checking: "Checking"
        case .ready: "Automatic drive capture armed"
        case .needsForegroundUse: "Open Blip to activate"
        case .alwaysPermissionNeeded: "Always access needed"
        case .permissionDenied: "Location access denied"
        case .serviceSessionMissing: "Background session unavailable"
        case .accuracyLimited: "Precise Location needed"
        case .unavailable: "Background capture unavailable"
        }
    }
}

enum BlipTimelineMotionMode: String, Codable, Sendable {
    case stationary
    case walking
    case cycling
    case automotive
    case unknown

    var transportMode: BlipTimelineTransportMode {
        switch self {
        case .walking: .walking
        case .cycling: .cycling
        case .automotive: .driving
        case .stationary, .unknown: .unknown
        }
    }
}

struct BlipTimelineDriveDetection: Equatable, Sendable {
    static let minimumDrivingSpeed = 8.0
    static let minimumMovementSpeed = 0.8
    static let continuationDuration: TimeInterval = 10 * 60
    static let stationaryExitDuration: TimeInterval = 5 * 60

    private(set) var automotiveUntil: Date?
    private(set) var stationarySince: Date?

    mutating func observe(
        motion: BlipTimelineMotionMode,
        speedMetersPerSecond: Double,
        at date: Date
    ) {
        if motion == .automotive || speedMetersPerSecond >= Self.minimumDrivingSpeed {
            automotiveUntil = max(
                automotiveUntil ?? .distantPast,
                date.addingTimeInterval(Self.continuationDuration)
            )
            stationarySince = nil
            return
        }

        // Slow movement is common in congestion. It is not fresh proof of a
        // drive, but it does prove that the phone has not been stationary for
        // the entire exit window.
        if speedMetersPerSecond >= Self.minimumMovementSpeed {
            stationarySince = nil
        } else if motion == .stationary, automotiveUntil != nil {
            stationarySince = stationarySince ?? date
        }
    }

    func isAutomotive(at date: Date) -> Bool {
        guard date < (automotiveUntil ?? .distantPast) else { return false }
        return !hasSustainedStationary(at: date)
    }

    func hasSustainedStationary(at date: Date) -> Bool {
        guard let stationarySince else { return false }
        return date >= stationarySince.addingTimeInterval(Self.stationaryExitDuration)
    }

    mutating func reset() {
        automotiveUntil = nil
        stationarySince = nil
    }
}

/// Decides when the low-power location stream has produced enough evidence to
/// justify starting the denser automotive stream. A single speed value is not
/// enough at low speeds because GPS fixes at rest can report 1-3 m/s. Core
/// Motion classifications take precedence; otherwise two accurate fixes must
/// show credible displacement within a short window.
struct BlipTimelineDrivePromotion: Sendable {
    static let maximumProbeInterval: TimeInterval = 2 * 60
    static let minimumBatteryDisplacementMeters = 100.0
    static let minimumChargingDisplacementMeters = 50.0
    static let minimumBatteryImpliedSpeed = 2.5
    static let minimumChargingImpliedSpeed = 1.5
    static let maximumProbeAccuracyMeters = 100.0

    private var anchor: BlipTimelineLocationObservation?

    mutating func observe(
        _ observation: BlipTimelineLocationObservation,
        isCharging: Bool
    ) -> Bool {
        switch observation.motion {
        case .stationary, .walking, .cycling:
            reset()
            return false
        case .automotive:
            anchor = observation
            return true
        case .unknown:
            break
        }

        guard observation.horizontalAccuracy >= 0,
              observation.horizontalAccuracy <= Self.maximumProbeAccuracyMeters else {
            return false
        }
        if observation.speedMetersPerSecond >= BlipTimelineDriveDetection.minimumDrivingSpeed {
            anchor = observation
            return true
        }

        guard let anchor else {
            self.anchor = observation
            return false
        }
        let elapsed = observation.timestamp.timeIntervalSince(anchor.timestamp)
        guard elapsed > 0, elapsed <= Self.maximumProbeInterval else {
            self.anchor = observation
            return false
        }
        let measuredDistance = BlipTimelineGeometry.distanceMeters(
            anchor.coordinate,
            observation.coordinate
        )
        // Require movement beyond the uncertainty of both fixes so ordinary
        // indoor/home GPS drift cannot promote the expensive stream.
        let accuracyAllowance = max(
            anchor.horizontalAccuracy,
            observation.horizontalAccuracy
        )
        let reliableDistance = max(0, measuredDistance - accuracyAllowance)
        let minimumDistance = isCharging
            ? Self.minimumChargingDisplacementMeters
            : Self.minimumBatteryDisplacementMeters
        let minimumImpliedSpeed = isCharging
            ? Self.minimumChargingImpliedSpeed
            : Self.minimumBatteryImpliedSpeed
        guard reliableDistance >= minimumDistance,
              reliableDistance / elapsed >= minimumImpliedSpeed else {
            return false
        }
        self.anchor = observation
        return true
    }

    mutating func reset() {
        anchor = nil
    }
}

struct BlipTimelineLocationObservation: Identifiable, Codable, Sendable {
    private static let duplicateTimestampTolerance: TimeInterval = 1
    private static let duplicateDistanceTolerance = 15.0

    let id: UUID
    let timestamp: Date
    let coordinate: BlipTimelineCoordinate
    let horizontalAccuracy: Double
    let speedMetersPerSecond: Double
    let timeZoneIdentifier: String
    let motion: BlipTimelineMotionMode

    var dateKey: String {
        BlipTimelineDay.makeDateKey(timestamp, timeZoneIdentifier: timeZoneIdentifier)
    }

    func canBeMerged(asDuplicateOf other: Self) -> Bool {
        abs(timestamp.timeIntervalSince(other.timestamp)) <= Self.duplicateTimestampTolerance
            && BlipTimelineGeometry.distanceMeters(coordinate, other.coordinate)
                <= Self.duplicateDistanceTolerance
    }

    func mergingDuplicate(_ other: Self) -> Self {
        let moreAccurate = horizontalAccuracy <= other.horizontalAccuracy ? self : other
        return Self(
            id: id,
            timestamp: min(timestamp, other.timestamp),
            coordinate: moreAccurate.coordinate,
            horizontalAccuracy: min(horizontalAccuracy, other.horizontalAccuracy),
            speedMetersPerSecond: max(speedMetersPerSecond, other.speedMetersPerSecond),
            timeZoneIdentifier: moreAccurate.timeZoneIdentifier,
            motion: Self.preferredMotion(motion, other.motion)
        )
    }

    private static func preferredMotion(
        _ first: BlipTimelineMotionMode,
        _ second: BlipTimelineMotionMode
    ) -> BlipTimelineMotionMode {
        let priority: [BlipTimelineMotionMode: Int] = [
            .unknown: 0,
            .stationary: 1,
            .walking: 2,
            .cycling: 3,
            .automotive: 4,
        ]
        return priority[first, default: 0] >= priority[second, default: 0] ? first : second
    }
}

/// Bounds the durable Timeline geometry independently of Core Location's
/// delivery cadence. Navigation configurations can yield fixes every second;
/// persisting all of them makes the ledger grow without adding visible route
/// detail and eventually blocks the UI while the ledger is encoded.
struct BlipTimelineObservationRetention: Sendable {
    static let detailedRouteDistanceMeters = 50.0
    static let creepingTrafficDistanceMeters = 10.0
    static let creepingTrafficInterval: TimeInterval = 20
    static let maximumStoredObservationCount = 8_000

    private var lastRetained: BlipTimelineLocationObservation?
    private var previousReadingShowedMovement = false

    mutating func seedIfNeeded(with observation: BlipTimelineLocationObservation?) {
        guard lastRetained == nil, let observation else { return }
        lastRetained = observation
        previousReadingShowedMovement = Self.showsMovement(observation)
    }

    mutating func retaining(
        _ observations: [BlipTimelineLocationObservation]
    ) -> [BlipTimelineLocationObservation] {
        var retained: [BlipTimelineLocationObservation] = []
        for observation in observations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let showsMovement = Self.showsMovement(observation)
            let shouldRetain: Bool
            if let lastRetained {
                let distance = BlipTimelineGeometry.distanceMeters(
                    lastRetained.coordinate,
                    observation.coordinate
                )
                let elapsed = observation.timestamp.timeIntervalSince(lastRetained.timestamp)
                if showsMovement {
                    // Fifty-metre geometry is already denser than the map's
                    // route simplification. The time-and-distance escape hatch
                    // preserves slow turns while creeping through congestion.
                    shouldRetain = distance >= Self.detailedRouteDistanceMeters
                        || (elapsed >= Self.creepingTrafficInterval
                            && distance >= Self.creepingTrafficDistanceMeters)
                } else {
                    // Preserve a useful arrival endpoint once, then discard the
                    // endless stationary callbacks that caused the regression.
                    // A genuinely displaced fix is also useful when speed or
                    // Core Motion classification has not arrived yet.
                    shouldRetain = (previousReadingShowedMovement
                        && distance >= Self.creepingTrafficDistanceMeters)
                        || distance >= Self.detailedRouteDistanceMeters
                }
            } else {
                shouldRetain = true
            }

            if shouldRetain {
                retained.append(observation)
                lastRetained = observation
            }
            previousReadingShowedMovement = showsMovement
        }
        return retained
    }

    mutating func reset() {
        lastRetained = nil
        previousReadingShowedMovement = false
    }

    static func compact(
        _ observations: [BlipTimelineLocationObservation]
    ) -> [BlipTimelineLocationObservation] {
        var retention = Self()
        let retained = retention.retaining(observations)
        return retained.count > maximumStoredObservationCount
            ? Array(retained.suffix(maximumStoredObservationCount))
            : retained
    }

    private static func showsMovement(_ observation: BlipTimelineLocationObservation) -> Bool {
        switch observation.motion {
        case .walking, .cycling, .automotive:
            true
        case .stationary:
            false
        case .unknown:
            observation.speedMetersPerSecond >= BlipTimelineDriveDetection.minimumMovementSpeed
        }
    }
}

struct BlipTimelineVisitObservation: Identifiable, Codable, Sendable {
    /// Core Location reports an arrival first and may later report the same
    /// visit again with a departure. Both timestamps are documented as
    /// approximate, so a visit update cannot be identified by exact dates.
    private static let estimateRevisionTolerance: TimeInterval = 5 * 60
    private static let minimumPlaceMatchRadius = 120.0

    let id: UUID
    let arrivalDate: Date
    let departureDate: Date?
    let coordinate: BlipTimelineCoordinate
    let horizontalAccuracy: Double
    let timeZoneIdentifier: String
    /// A later arrival bounds a missing departure, but is not a Core Location
    /// departure report. Keep that distinction after refining the boundary
    /// from recorded movement so a delayed authoritative report can replace it.
    var inferredDepartureUpperBound: Date? = nil
    /// Missing in older ledgers, which did not distinguish a real departure
    /// report from the next-arrival fallback.
    var departureWasReported: Bool? = nil

    init(
        id: UUID,
        arrivalDate: Date,
        departureDate: Date?,
        coordinate: BlipTimelineCoordinate,
        horizontalAccuracy: Double,
        timeZoneIdentifier: String,
        inferredDepartureUpperBound: Date? = nil,
        departureWasReported: Bool? = nil
    ) {
        self.id = id
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.timeZoneIdentifier = timeZoneIdentifier
        self.inferredDepartureUpperBound = inferredDepartureUpperBound
        self.departureWasReported = departureWasReported
            ?? (departureDate != nil && inferredDepartureUpperBound == nil)
    }

    var dateKey: String {
        BlipTimelineDay.makeDateKey(arrivalDate, timeZoneIdentifier: timeZoneIdentifier)
    }

    func coveredDateKeys(through referenceDate: Date) -> [String] {
        let effectiveEnd = min(departureDate ?? referenceDate, referenceDate)
        guard arrivalDate <= effectiveEnd else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
        var cursor = calendar.startOfDay(for: arrivalDate)
        // A departure at exactly midnight belongs to the day that just ended,
        // not to a zero-duration visit on the following date.
        let finalInstant = effectiveEnd > arrivalDate
            ? effectiveEnd.addingTimeInterval(-0.001)
            : effectiveEnd
        let finalDay = calendar.startOfDay(for: finalInstant)
        var keys: [String] = []
        while cursor <= finalDay, keys.count < 40 {
            keys.append(BlipTimelineDay.makeDateKey(
                cursor,
                timeZoneIdentifier: timeZoneIdentifier
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }

    /// Returns whether a subsequently delivered Core Location visit can refine
    /// this stored visit. This is intentionally directional: a new open visit
    /// after a completed one is a return to the place, not an update.
    func canBeUpdated(by newer: Self) -> Bool {
        let placeRadius = max(
            Self.minimumPlaceMatchRadius,
            horizontalAccuracy,
            newer.horizontalAccuracy
        )
        guard BlipTimelineGeometry.distanceMeters(coordinate, newer.coordinate) <= placeRadius else {
            return false
        }

        switch (departureDate, newer.departureDate) {
        case (.some, .none):
            return false
        case let (.none, .some(newerDeparture)):
            // This is the normal Core Location lifecycle: the immediately
            // preceding arrival-only report is completed by a report carrying
            // both approximate dates. The API gives no stable identifier or
            // bound on how much its arrival estimate may be refined.
            return arrivalDate <= newerDeparture && newer.arrivalDate <= newerDeparture
        case let (.some(existingDeparture), .some(newerDeparture)):
            if let inferredDepartureUpperBound,
               newer.inferredDepartureUpperBound == nil {
                return newerDeparture >= arrivalDate
                    && newerDeparture <= inferredDepartureUpperBound
                    && newer.arrivalDate <= newerDeparture
                    && newer.arrivalDate < inferredDepartureUpperBound
            }
            return abs(arrivalDate.timeIntervalSince(newer.arrivalDate))
                <= Self.estimateRevisionTolerance
                && abs(existingDeparture.timeIntervalSince(newerDeparture))
                    <= Self.estimateRevisionTolerance
        case (.none, .none):
            return abs(arrivalDate.timeIntervalSince(newer.arrivalDate))
                <= Self.estimateRevisionTolerance
        }
    }

    /// Applies a later report for the same visit while preserving the stable
    /// identity allocated when the visit was first observed.
    func updating(with newer: Self) -> Self {
        let moreAccurate = horizontalAccuracy <= newer.horizontalAccuracy ? self : newer
        return Self(
            id: id,
            arrivalDate: newer.arrivalDate,
            departureDate: newer.departureDate ?? departureDate,
            coordinate: moreAccurate.coordinate,
            horizontalAccuracy: moreAccurate.horizontalAccuracy,
            timeZoneIdentifier: newer.timeZoneIdentifier,
            inferredDepartureUpperBound: newer.departureDate == nil
                ? inferredDepartureUpperBound
                : newer.inferredDepartureUpperBound,
            departureWasReported: newer.departureDate == nil
                ? departureWasReported
                : newer.departureWasReported
        )
    }

    /// Ends an arrival-only visit when a later visit proves that the device
    /// has moved on. Core Location occasionally delivers the new arrival
    /// without first delivering a departure for the previous place.
    func ending(at date: Date, inferredUpperBound: Date? = nil) -> Self {
        guard departureDate == nil || inferredDepartureUpperBound != nil,
              date > arrivalDate else { return self }
        return Self(
            id: id,
            arrivalDate: arrivalDate,
            departureDate: date,
            coordinate: coordinate,
            horizontalAccuracy: horizontalAccuracy,
            timeZoneIdentifier: timeZoneIdentifier,
            inferredDepartureUpperBound: inferredUpperBound ?? date
        )
    }
}

/// Recovers a useful lower boundary only from a continuous recorded movement
/// run connecting the two places. It cannot recover an unrecorded road route
/// or claim that the first moving fix is the exact departure time.
private enum BlipTimelineDepartureRecovery {
    static func departure(
        from origin: BlipTimelineVisitObservation,
        to destination: BlipTimelineVisitObservation,
        observations: [BlipTimelineLocationObservation]
    ) -> (departure: Date, originFix: Date?)? {
        guard isValid(origin.coordinate), isValid(destination.coordinate) else { return nil }

        let placeSeparation = BlipTimelineGeometry.distanceMeters(
            origin.coordinate, destination.coordinate
        )
        guard placeSeparation > max(500, origin.horizontalAccuracy, destination.horizontalAccuracy) else {
            return nil
        }

        let points = observations.filter {
            $0.timestamp >= origin.arrivalDate && $0.timestamp <= destination.arrivalDate
                && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 100
                && isValid($0.coordinate)
        }.sorted { $0.timestamp < $1.timestamp }
        guard let finalIndex = points.lastIndex(where: {
            destination.arrivalDate.timeIntervalSince($0.timestamp) <= 10 * 60
                && BlipTimelineGeometry.distanceMeters($0.coordinate, destination.coordinate)
                    <= max(500, destination.horizontalAccuracy + $0.horizontalAccuracy)
        }) else { return nil }

        var firstIndex = finalIndex
        while firstIndex > 0 {
            let previous = points[firstIndex - 1]
            let current = points[firstIndex]
            let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
            let displacement = BlipTimelineGeometry.distanceMeters(previous.coordinate, current.coordinate)
            guard elapsed > 0, elapsed <= 5 * 60,
                  displacement <= elapsed * 70 + max(previous.horizontalAccuracy, current.horizontalAccuracy) else {
                break
            }
            firstIndex -= 1
        }

        // Prefer the last recorded fix at the origin, so earlier excursions or
        // stationary samples do not lengthen the recovered drive. A stream
        // beginning just outside the place can still supply its own boundary.
        let episode = points[firstIndex...finalIndex]
        let originIndex = episode.lastIndex {
            BlipTimelineGeometry.distanceMeters($0.coordinate, origin.coordinate)
                <= max(120, origin.horizontalAccuracy) + $0.horizontalAccuracy
        }
        let anchorIndex = originIndex ?? firstIndex
        guard BlipTimelineGeometry.distanceMeters(points[anchorIndex].coordinate, origin.coordinate)
                <= max(500, origin.horizontalAccuracy + points[anchorIndex].horizontalAccuracy) else {
            return nil
        }

        let moving = points[anchorIndex...finalIndex].filter { point in
            switch point.motion {
            case .walking, .cycling, .automotive:
                true
            case .unknown:
                point.speedMetersPerSecond >= BlipTimelineDriveDetection.minimumMovementSpeed
            case .stationary:
                false
            }
        }
        guard moving.count >= 3, let first = moving.first, let last = moving.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= 30,
              BlipTimelineGeometry.distanceMeters(first.coordinate, last.coordinate) >= 300,
              first.timestamp < destination.arrivalDate else { return nil }

        return (first.timestamp, originIndex.map { points[$0].timestamp })
    }

    private static func isValid(_ coordinate: BlipTimelineCoordinate) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }
}

struct BlipTimelinePlaceLabel: Codable, Equatable, Sendable {
    let coordinate: BlipTimelineCoordinate
    let title: String
    let subtitle: String?
    let isHome: Bool
}

struct BlipTimelineSavedPlace: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, coordinate, mapCoordinate, mapItemIdentifier
        case pointOfInterestCategory, iconSystemName, isHome, recognitionRadiusMeters
        case residentContacts
    }

    let id: String
    let title: String
    let subtitle: String?
    /// The observed coordinate used to recognize future visits.
    let coordinate: BlipTimelineCoordinate
    /// The canonical Apple Maps coordinate, which may differ from the GPS fix.
    let mapCoordinate: BlipTimelineCoordinate?
    let mapItemIdentifier: String?
    let pointOfInterestCategory: String?
    let iconSystemName: String?
    let isHome: Bool
    let recognitionRadiusMeters: Double
    let residentContacts: [BlipTimelineResidentReference]

    init(
        id: String,
        title: String,
        subtitle: String?,
        coordinate: BlipTimelineCoordinate,
        mapCoordinate: BlipTimelineCoordinate? = nil,
        mapItemIdentifier: String? = nil,
        pointOfInterestCategory: String? = nil,
        iconSystemName: String? = nil,
        isHome: Bool = false,
        recognitionRadiusMeters: Double = 65,
        residentContacts: [BlipTimelineResidentReference] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.mapCoordinate = mapCoordinate
        self.mapItemIdentifier = mapItemIdentifier
        self.pointOfInterestCategory = pointOfInterestCategory
        self.iconSystemName = iconSystemName
        self.isHome = isHome
        self.recognitionRadiusMeters = min(max(recognitionRadiusMeters, 20), 120)
        var seenContactIdentifiers = Set<String>()
        self.residentContacts = residentContacts.filter {
            seenContactIdentifiers.insert($0.contactIdentifier.isEmpty ? $0.id : $0.contactIdentifier).inserted
        }
    }

    func updating(
        title: String? = nil,
        subtitle: String?? = nil,
        mapCoordinate: BlipTimelineCoordinate?? = nil,
        mapItemIdentifier: String?? = nil,
        pointOfInterestCategory: String?? = nil,
        iconSystemName: String?? = nil,
        isHome: Bool? = nil,
        residentContacts: [BlipTimelineResidentReference]? = nil
    ) -> Self {
        Self(
            id: id,
            title: title ?? self.title,
            subtitle: subtitle ?? self.subtitle,
            coordinate: coordinate,
            mapCoordinate: mapCoordinate ?? self.mapCoordinate,
            mapItemIdentifier: mapItemIdentifier ?? self.mapItemIdentifier,
            pointOfInterestCategory: pointOfInterestCategory ?? self.pointOfInterestCategory,
            iconSystemName: iconSystemName ?? self.iconSystemName,
            isHome: isHome ?? self.isHome,
            recognitionRadiusMeters: recognitionRadiusMeters,
            residentContacts: residentContacts ?? self.residentContacts
        )
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            title: try values.decode(String.self, forKey: .title),
            subtitle: try values.decodeIfPresent(String.self, forKey: .subtitle),
            coordinate: try values.decode(BlipTimelineCoordinate.self, forKey: .coordinate),
            mapCoordinate: try values.decodeIfPresent(
                BlipTimelineCoordinate.self,
                forKey: .mapCoordinate
            ),
            mapItemIdentifier: try values.decodeIfPresent(
                String.self,
                forKey: .mapItemIdentifier
            ),
            pointOfInterestCategory: try values.decodeIfPresent(
                String.self,
                forKey: .pointOfInterestCategory
            ),
            iconSystemName: try values.decodeIfPresent(String.self, forKey: .iconSystemName),
            isHome: try values.decodeIfPresent(Bool.self, forKey: .isHome) ?? false,
            recognitionRadiusMeters: try values.decodeIfPresent(
                Double.self,
                forKey: .recognitionRadiusMeters
            ) ?? 65,
            residentContacts: try values.decodeIfPresent(
                [BlipTimelineResidentReference].self,
                forKey: .residentContacts
            ) ?? []
        )
    }
}

struct BlipTimelineVisitPlaceAssignment: Codable, Equatable, Sendable {
    let place: BlipTimelineSavedPlace
    let remembersPlace: Bool
}

enum BlipTimelineGeometry {
    static func distanceMeters(
        _ first: BlipTimelineCoordinate,
        _ second: BlipTimelineCoordinate
    ) -> Double {
        let earthRadius = 6_371_000.0
        let latitudeDelta = (second.latitude - first.latitude) * .pi / 180
        let longitudeDelta = (second.longitude - first.longitude) * .pi / 180
        let firstLatitude = first.latitude * .pi / 180
        let secondLatitude = second.latitude * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(firstLatitude) * cos(secondLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

struct BlipTimelineLedger: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case days, observations, visits, pendingDateKeys, pendingDeletionDateKeys
        case manuallyEditedDateKeys, trackingEnabled, pendingDeleteAll, homeCoordinate
        case placeLabels, savedPlaces, visitPlaceAssignments, backgroundCaptureStatus
        case residentCloudSchemaVersion
        case syncGeneration, syncRevision, syncedRevision, syncServerURL, lastBackupAt
        case pendingDeleteAllRevision
    }

    var days: [BlipTimelineDay]
    var observations: [BlipTimelineLocationObservation]
    var visits: [BlipTimelineVisitObservation]
    var pendingDateKeys: Set<String>
    var pendingDeletionDateKeys: Set<String>
    var manuallyEditedDateKeys: Set<String>
    var trackingEnabled: Bool
    var pendingDeleteAll: Bool
    var homeCoordinate: BlipTimelineCoordinate?
    var placeLabels: [BlipTimelinePlaceLabel]
    var savedPlaces: [BlipTimelineSavedPlace]
    var visitPlaceAssignments: [String: BlipTimelineVisitPlaceAssignment]
    var backgroundCaptureStatus: BlipTimelineBackgroundCaptureStatus?
    var residentCloudSchemaVersion: Int
    var syncGeneration: Int? = nil
    var syncRevision: Int = 0
    var syncedRevision: Int = 0
    var syncServerURL: String? = nil
    var lastBackupAt: Date? = nil
    var pendingDeleteAllRevision: Int? = nil

    static let empty = BlipTimelineLedger(
        days: [],
        observations: [],
        visits: [],
        pendingDateKeys: [],
        pendingDeletionDateKeys: [],
        manuallyEditedDateKeys: [],
        trackingEnabled: false,
        pendingDeleteAll: false,
        homeCoordinate: nil,
        placeLabels: [],
        savedPlaces: [],
        visitPlaceAssignments: [:],
        backgroundCaptureStatus: nil,
        residentCloudSchemaVersion: 0
    )
}

extension BlipTimelineLedger {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        days = try values.decodeIfPresent([BlipTimelineDay].self, forKey: .days) ?? []
        observations = try values.decodeIfPresent(
            [BlipTimelineLocationObservation].self,
            forKey: .observations
        ) ?? []
        visits = try values.decodeIfPresent(
            [BlipTimelineVisitObservation].self,
            forKey: .visits
        ) ?? []
        pendingDateKeys = try values.decodeIfPresent(
            Set<String>.self,
            forKey: .pendingDateKeys
        ) ?? []
        pendingDeletionDateKeys = try values.decodeIfPresent(
            Set<String>.self,
            forKey: .pendingDeletionDateKeys
        ) ?? []
        manuallyEditedDateKeys = try values.decodeIfPresent(
            Set<String>.self,
            forKey: .manuallyEditedDateKeys
        ) ?? []
        trackingEnabled = try values.decodeIfPresent(Bool.self, forKey: .trackingEnabled) ?? false
        pendingDeleteAll = try values.decodeIfPresent(Bool.self, forKey: .pendingDeleteAll) ?? false
        homeCoordinate = try values.decodeIfPresent(
            BlipTimelineCoordinate.self,
            forKey: .homeCoordinate
        )
        placeLabels = try values.decodeIfPresent(
            [BlipTimelinePlaceLabel].self,
            forKey: .placeLabels
        ) ?? []
        savedPlaces = try values.decodeIfPresent(
            [BlipTimelineSavedPlace].self,
            forKey: .savedPlaces
        ) ?? []
        visitPlaceAssignments = try values.decodeIfPresent(
            [String: BlipTimelineVisitPlaceAssignment].self,
            forKey: .visitPlaceAssignments
        ) ?? [:]
        backgroundCaptureStatus = try values.decodeIfPresent(
            BlipTimelineBackgroundCaptureStatus.self,
            forKey: .backgroundCaptureStatus
        )
        residentCloudSchemaVersion = try values.decodeIfPresent(
            Int.self,
            forKey: .residentCloudSchemaVersion
        ) ?? 0
        syncGeneration = try values.decodeIfPresent(Int.self, forKey: .syncGeneration)
        syncRevision = try values.decodeIfPresent(Int.self, forKey: .syncRevision) ?? 0
        syncedRevision = try values.decodeIfPresent(Int.self, forKey: .syncedRevision) ?? 0
        syncServerURL = try values.decodeIfPresent(String.self, forKey: .syncServerURL)
        lastBackupAt = try values.decodeIfPresent(Date.self, forKey: .lastBackupAt)
        pendingDeleteAllRevision = try values.decodeIfPresent(Int.self, forKey: .pendingDeleteAllRevision)
        migrateLegacyPlacesIfNeeded()
    }

    /// Queues existing resident-bearing days once when Cloud learns a newer
    /// resident schema. This preserves assignments created before the Worker
    /// knew how to retain them.
    mutating func prepareResidentCloudSync(version: Int = 1) -> Bool {
        guard residentCloudSchemaVersion < version else { return false }
        pendingDateKeys.formUnion(days.compactMap { day in
            day.entries.contains { !$0.residentContacts.isEmpty } ? day.dateKey : nil
        })
        residentCloudSchemaVersion = version
        return true
    }

    private mutating func migrateLegacyPlacesIfNeeded() {
        if savedPlaces.isEmpty, !placeLabels.isEmpty {
            let activeHome = homeCoordinate.flatMap { home in
                placeLabels
                    .filter(\.isHome)
                    .min {
                        BlipTimelineGeometry.distanceMeters($0.coordinate, home)
                            < BlipTimelineGeometry.distanceMeters($1.coordinate, home)
                    }
            }
            savedPlaces = placeLabels.map { label in
                let isCurrentHome = activeHome.map { $0.coordinate == label.coordinate }
                    ?? (homeCoordinate == nil && label.isHome)
                return BlipTimelineSavedPlace(
                    id: Self.legacyPlaceID(for: label),
                    title: label.title,
                    subtitle: label.subtitle,
                    coordinate: label.coordinate,
                    iconSystemName: isCurrentHome ? "house.fill" : nil,
                    isHome: isCurrentHome,
                    recognitionRadiusMeters: 65
                )
            }
        }

        guard !savedPlaces.isEmpty else { return }
        days = days.map { day in
            let entries = day.entries.map { entry -> BlipTimelineEntry in
                guard entry.kind == .visit,
                      entry.placeID == nil,
                      let coordinate = entry.coordinate,
                      let place = savedPlaces
                        .filter({
                            $0.title == entry.title
                                && $0.subtitle == entry.subtitle
                                && BlipTimelineGeometry.distanceMeters(
                                    $0.coordinate,
                                    coordinate
                                ) <= 120
                        })
                        .min(by: {
                            BlipTimelineGeometry.distanceMeters($0.coordinate, coordinate)
                                < BlipTimelineGeometry.distanceMeters($1.coordinate, coordinate)
                        }) else { return entry }
                return BlipTimelineEntry(
                    id: entry.id,
                    kind: entry.kind,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    startDate: entry.startDate,
                    endDate: entry.endDate,
                    coordinate: entry.coordinate,
                    route: entry.route,
                    distanceMeters: entry.distanceMeters,
                    transportMode: entry.transportMode,
                    confidence: entry.confidence,
                    isHome: entry.isHome,
                    placeID: place.id,
                    placeCoordinate: place.mapCoordinate,
                    mapItemIdentifier: place.mapItemIdentifier,
                    placeCategory: place.pointOfInterestCategory,
                    placeIcon: place.iconSystemName,
                    residentContacts: place.residentContacts
                )
            }
            guard entries != day.entries else { return day }
            return BlipTimelineDay(
                date: day.date,
                dateKey: day.dateKey,
                timeZoneIdentifier: day.timeZoneIdentifier,
                coverage: day.coverage,
                entries: entries,
                metrics: BlipTimelineActivityMetrics.derived(from: entries),
                updatedAt: day.updatedAt,
                sourceDeviceID: day.sourceDeviceID
            )
        }

        for visit in visits where visitPlaceAssignments[visit.id.uuidString.lowercased()] == nil {
            let visitEntryBase = "visit-\(visit.id.uuidString.lowercased())"
            let matchingEntry = days.lazy.compactMap { day in
                day.entries.first {
                    $0.id == visitEntryBase || $0.id.hasPrefix("\(visitEntryBase)-")
                }
            }.first
            guard let placeID = matchingEntry?.placeID,
                  let place = savedPlaces.first(where: { $0.id == placeID }) else { continue }
            visitPlaceAssignments[visit.id.uuidString.lowercased()] = .init(
                place: place,
                remembersPlace: true
            )
        }
    }

    @discardableResult
    mutating func compactRedundantObservations() -> Int {
        let compacted = BlipTimelineObservationRetention.compact(observations)
        let removedCount = observations.count - compacted.count
        guard removedCount > 0 else { return 0 }
        observations = compacted
        return removedCount
    }

    /// Collapses multiple saved records that describe the same physical place.
    /// Legacy Timeline days used a coordinate-derived ID, so each slightly
    /// different GPS fix at Home could otherwise become another remembered
    /// place during cloud reconciliation.
    @discardableResult
    mutating func canonicalizeSavedPlaces() -> Int {
        guard !savedPlaces.isEmpty else { return 0 }
        let originalSavedPlaces = savedPlaces
        let originalPlaceLabels = placeLabels
        let originalAssignments = visitPlaceAssignments
        let originalDays = days
        let originalHomeCoordinate = homeCoordinate

        var groups: [[BlipTimelineSavedPlace]] = []
        for place in savedPlaces {
            let matchingIndices = groups.indices.filter { index in
                groups[index].contains { Self.representsSamePlace($0, place) }
            }
            guard let firstIndex = matchingIndices.first else {
                groups.append([place])
                continue
            }
            var mergedGroup = groups[firstIndex]
            mergedGroup.append(place)
            for index in matchingIndices.dropFirst().reversed() {
                mergedGroup.append(contentsOf: groups.remove(at: index))
            }
            groups[firstIndex] = mergedGroup
        }

        var canonicalPlaces: [BlipTimelineSavedPlace] = []
        var canonicalIDByLegacyID: [String: String] = [:]
        for group in groups {
            let preferred = group.sorted {
                Self.prefersCanonicalPlace($0, over: $1, homeCoordinate: homeCoordinate)
            }.first!
            let canonical = Self.mergingPlaceMetadata(preferred: preferred, group: group)
            canonicalPlaces.append(canonical)
            for place in group {
                canonicalIDByLegacyID[place.id] = canonical.id
            }
        }
        savedPlaces = canonicalPlaces

        let placeByID = Dictionary(uniqueKeysWithValues: savedPlaces.map { ($0.id, $0) })
        let canonicalHome = savedPlaces.first(where: \.isHome)
        if homeCoordinate == nil {
            homeCoordinate = canonicalHome?.coordinate
        }

        days = days.map { day in
            let entries = day.entries.map { entry -> BlipTimelineEntry in
                guard entry.kind == .visit else { return entry }
                let mappedPlace = entry.placeID
                    .flatMap { canonicalIDByLegacyID[$0] ?? $0 }
                    .flatMap { placeByID[$0] }
                let nearbyHome: BlipTimelineSavedPlace?
                if entry.isHome,
                   let home = canonicalHome,
                   let coordinate = entry.coordinate,
                   BlipTimelineGeometry.distanceMeters(coordinate, home.coordinate) <= 120 {
                    nearbyHome = home
                } else {
                    nearbyHome = nil
                }
                guard let place = mappedPlace ?? nearbyHome else { return entry }
                return BlipTimelineEntry(
                    id: entry.id,
                    kind: entry.kind,
                    title: place.title,
                    subtitle: place.subtitle,
                    startDate: entry.startDate,
                    endDate: entry.endDate,
                    coordinate: entry.coordinate,
                    route: entry.route,
                    distanceMeters: entry.distanceMeters,
                    transportMode: entry.transportMode,
                    confidence: entry.confidence,
                    isHome: place.isHome,
                    placeID: place.id,
                    placeCoordinate: place.mapCoordinate,
                    mapItemIdentifier: place.mapItemIdentifier,
                    placeCategory: place.pointOfInterestCategory,
                    placeIcon: place.iconSystemName,
                    residentContacts: place.residentContacts
                )
            }
            guard entries != day.entries else { return day }
            return BlipTimelineDay(
                date: day.date,
                dateKey: day.dateKey,
                timeZoneIdentifier: day.timeZoneIdentifier,
                coverage: day.coverage,
                entries: entries,
                metrics: BlipTimelineActivityMetrics.derived(from: entries),
                updatedAt: day.updatedAt,
                sourceDeviceID: day.sourceDeviceID
            )
        }

        visitPlaceAssignments = visitPlaceAssignments.mapValues { assignment in
            let mappedPlace = canonicalIDByLegacyID[assignment.place.id]
                .flatMap { placeByID[$0] }
            let nearbyHome: BlipTimelineSavedPlace?
            if assignment.place.isHome,
               let home = canonicalHome,
               BlipTimelineGeometry.distanceMeters(
                   assignment.place.coordinate,
                   home.coordinate
               ) <= 120 {
                nearbyHome = home
            } else {
                nearbyHome = nil
            }
            guard let place = mappedPlace ?? nearbyHome else { return assignment }
            return BlipTimelineVisitPlaceAssignment(
                place: place,
                remembersPlace: assignment.remembersPlace
            )
        }
        placeLabels = savedPlaces.map {
            BlipTimelinePlaceLabel(
                coordinate: $0.coordinate,
                title: $0.title,
                subtitle: $0.subtitle,
                isHome: $0.isHome
            )
        }

        let changed = originalSavedPlaces != savedPlaces
            || originalPlaceLabels != placeLabels
            || originalAssignments != visitPlaceAssignments
            || originalDays != days
            || originalHomeCoordinate != homeCoordinate
        guard changed else { return 0 }
        return max(1, originalSavedPlaces.count - savedPlaces.count)
    }

    private static func representsSamePlace(
        _ first: BlipTimelineSavedPlace,
        _ second: BlipTimelineSavedPlace
    ) -> Bool {
        if first.id == second.id { return true }
        if let firstMapID = first.mapItemIdentifier,
           let secondMapID = second.mapItemIdentifier,
           firstMapID == secondMapID {
            return true
        }
        let distance = BlipTimelineGeometry.distanceMeters(first.coordinate, second.coordinate)
        if first.isHome, second.isHome, distance <= 120 { return true }
        guard normalizedPlaceText(first.title) == normalizedPlaceText(second.title) else {
            return false
        }
        let firstSubtitle = first.subtitle.map(normalizedPlaceText)
        let secondSubtitle = second.subtitle.map(normalizedPlaceText)
        guard firstSubtitle == secondSubtitle || firstSubtitle == nil || secondSubtitle == nil else {
            return false
        }
        return distance <= max(first.recognitionRadiusMeters, second.recognitionRadiusMeters)
    }

    private static func normalizedPlaceText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func prefersCanonicalPlace(
        _ first: BlipTimelineSavedPlace,
        over second: BlipTimelineSavedPlace,
        homeCoordinate: BlipTimelineCoordinate?
    ) -> Bool {
        let firstScore = canonicalPlaceScore(first)
        let secondScore = canonicalPlaceScore(second)
        if firstScore != secondScore { return firstScore > secondScore }
        if first.isHome, second.isHome, let homeCoordinate {
            let firstDistance = BlipTimelineGeometry.distanceMeters(
                first.coordinate,
                homeCoordinate
            )
            let secondDistance = BlipTimelineGeometry.distanceMeters(
                second.coordinate,
                homeCoordinate
            )
            if firstDistance != secondDistance { return firstDistance < secondDistance }
        }
        return first.id < second.id
    }

    private static func canonicalPlaceScore(_ place: BlipTimelineSavedPlace) -> Int {
        var score = place.id.hasPrefix("legacy-") ? 0 : 100
        if place.isHome {
            let normalizedTitle = normalizedPlaceText(place.title)
            if normalizedTitle == normalizedPlaceText("Hemma") {
                score += 1_000
            } else if normalizedTitle != normalizedPlaceText("Home") {
                score += 500
            }
        }
        if place.mapItemIdentifier != nil { score += 40 }
        if place.mapCoordinate != nil { score += 20 }
        if place.pointOfInterestCategory != nil { score += 10 }
        if place.iconSystemName != nil { score += 5 }
        if !place.residentContacts.isEmpty { score += 5 }
        if place.subtitle != nil { score += 1 }
        return score
    }

    private static func mergingPlaceMetadata(
        preferred: BlipTimelineSavedPlace,
        group: [BlipTimelineSavedPlace]
    ) -> BlipTimelineSavedPlace {
        let isHome = group.contains(where: \.isHome)
        let residentContacts = ([preferred] + group)
            .map(\.residentContacts)
            .reduce([]) { BlipTimelineResidentReference.merging($0, with: $1) }
        return BlipTimelineSavedPlace(
            id: preferred.id,
            title: preferred.title,
            subtitle: preferred.subtitle ?? group.compactMap(\.subtitle).first,
            coordinate: preferred.coordinate,
            mapCoordinate: preferred.mapCoordinate ?? group.compactMap(\.mapCoordinate).first,
            mapItemIdentifier: preferred.mapItemIdentifier
                ?? group.compactMap(\.mapItemIdentifier).first,
            pointOfInterestCategory: preferred.pointOfInterestCategory
                ?? group.compactMap(\.pointOfInterestCategory).first,
            iconSystemName: isHome ? "house.fill"
                : preferred.iconSystemName ?? group.compactMap(\.iconSystemName).first,
            isHome: isHome,
            recognitionRadiusMeters: group.map(\.recognitionRadiusMeters).max()
                ?? preferred.recognitionRadiusMeters,
            residentContacts: residentContacts
        )
    }

    private static func legacyPlaceID(for label: BlipTimelinePlaceLabel) -> String {
        "legacy-\(String(label.coordinate.latitude.bitPattern, radix: 16))-"
            + String(label.coordinate.longitude.bitPattern, radix: 16)
    }
}

struct BlipTimelinePersistence {
    let fileURL: URL?

    static func applicationSupport(fileManager: FileManager = .default) -> Self {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return Self(fileURL: root
            .appendingPathComponent("Locations", isDirectory: true)
            .appendingPathComponent("Timeline", isDirectory: true)
            .appendingPathComponent("timeline-v1.json", isDirectory: false))
    }

    static let inMemory = BlipTimelinePersistence(fileURL: nil)

    func load() -> BlipTimelineLedger {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return .empty }
        return (try? Self.decoder.decode(BlipTimelineLedger.self, from: data)) ?? .empty
    }

    func save(_ ledger: BlipTimelineLedger) throws {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(ledger)
#if os(iOS)
        // Timeline capture must remain writable while the phone is locked.
        // Applying complete protection to the atomic temporary file and only
        // relaxing it after replacement makes the replacement itself fail in
        // the background.
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
#else
        try data.write(to: fileURL, options: .atomic)
#endif
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalDateFormatStyle.format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(value, strategy: fractionalDateFormatStyle) { return date }
            if let date = try? Date(value, strategy: wholeSecondDateFormatStyle) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO 8601 date: \(value)"
            )
        }
        return decoder
    }

    private static let fractionalDateFormatStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let wholeSecondDateFormatStyle = Date.ISO8601FormatStyle()
}

struct BlipTimelinePendingCapturePayload: Codable {
    var observations: [BlipTimelineLocationObservation]
    var visits: [BlipTimelineVisitObservation]

    static let empty = Self(observations: [], visits: [])

    var isEmpty: Bool { observations.isEmpty && visits.isEmpty }
}

/// A background Core Location relaunch can deliver fixes before SwiftUI has
/// constructed Blip's Timeline store. Keep that short gap crash-safe without
/// making the full application model part of Core Location's restoration path.
struct BlipTimelinePendingCaptureSpool {
    private let fileURL: URL?

    init(persistence: BlipTimelinePersistence = .applicationSupport()) {
        self.init(fileURL: persistence.fileURL.map {
            $0.deletingLastPathComponent()
                .appendingPathComponent("pending-capture-v1.json", isDirectory: false)
        })
    }

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    func load() -> BlipTimelinePendingCapturePayload {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let payload = try? BlipTimelinePersistence.decoder.decode(
                  BlipTimelinePendingCapturePayload.self,
                  from: data
              ) else { return .empty }
        return payload
    }

    @discardableResult
    func append(
        observations: [BlipTimelineLocationObservation] = [],
        visits: [BlipTimelineVisitObservation] = []
    ) -> Bool {
        guard let fileURL else { return false }
        var payload = load()
        payload.observations.append(contentsOf: observations)
        payload.visits.append(contentsOf: visits)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try BlipTimelinePersistence.encoder.encode(payload)
#if os(iOS)
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
#else
            try data.write(to: fileURL, options: .atomic)
#endif
            return true
        } catch {
            return false
        }
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private struct BlipTimelineCloudEnvelope: Decodable {
    let days: [BlipTimelineDay]
}

private struct BlipTimelineExportEnvelope: Encodable {
    let format = "blip-timeline-v1"
    let exportedAt = Date()
    let days: [BlipTimelineDay]
}

extension BlipTimelineStore {
    public var selectedDay: BlipTimelineDay? {
        day(containing: selectedDate)
    }

    public var pendingSyncCount: Int {
        ledger.pendingDateKeys.count + ledger.pendingDeletionDateKeys.count
            + (ledger.pendingDeleteAll ? 1 : 0)
    }

    var savedPlaces: [BlipTimelineSavedPlace] {
        ledger.savedPlaces.sorted {
            if $0.isHome != $1.isHome { return $0.isHome }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func enrichSavedPlace(
        id: String,
        mapCoordinate: BlipTimelineCoordinate,
        mapItemIdentifier: String?,
        pointOfInterestCategory: String?,
        iconSystemName: String?
    ) {
        guard let place = ledger.savedPlaces.first(where: { $0.id == id }) else { return }
        let enriched = place.updating(
            mapCoordinate: .some(mapCoordinate),
            mapItemIdentifier: .some(mapItemIdentifier),
            pointOfInterestCategory: .some(pointOfInterestCategory),
            iconSystemName: .some(iconSystemName)
        )
        upsertSavedPlace(enriched)

        var changedDateKeys = Set<String>()
        days = days.map { day in
            let entries = day.entries.map { entry -> BlipTimelineEntry in
                guard entry.placeID == id else { return entry }
                return BlipTimelineEntry(
                    id: entry.id,
                    kind: entry.kind,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    startDate: entry.startDate,
                    endDate: entry.endDate,
                    coordinate: entry.coordinate,
                    route: entry.route,
                    distanceMeters: entry.distanceMeters,
                    transportMode: entry.transportMode,
                    confidence: entry.confidence,
                    isHome: entry.isHome,
                    placeID: entry.placeID,
                    placeCoordinate: enriched.mapCoordinate,
                    mapItemIdentifier: enriched.mapItemIdentifier,
                    placeCategory: enriched.pointOfInterestCategory,
                    placeIcon: enriched.iconSystemName,
                    residentContacts: enriched.residentContacts
                )
            }
            guard entries != day.entries else { return day }
            changedDateKeys.insert(day.dateKey)
            return BlipTimelineDay(
                date: day.date,
                dateKey: day.dateKey,
                timeZoneIdentifier: day.timeZoneIdentifier,
                coverage: day.coverage,
                entries: entries,
                metrics: Self.metrics(for: entries),
                updatedAt: Date(),
                sourceDeviceID: sourceDeviceID
            )
        }
        for (visitID, assignment) in ledger.visitPlaceAssignments
            where assignment.place.id == id {
            ledger.visitPlaceAssignments[visitID] = .init(
                place: enriched,
                remembersPlace: assignment.remembersPlace
            )
        }
        ledger.days = days
        ledger.pendingDateKeys.formUnion(changedDateKeys)
        persistLedger()
    }

    public func resumeTrackingAndSync() async {
        // UI/demo launches must remain deterministic and must never let live
        // capture or Cloud replacement tear down the scene under test.
        guard !usesDemoData else { return }
#if os(iOS)
        materializeStationaryDays()
        if trackingEnabled {
            captureController?.resumeIfAuthorized()
        } else {
            captureController?.refreshAuthorizationState()
        }
#endif
        await synchronizeWithCloud()
    }

    public func prepareForegroundTimelineCapture() {
#if os(iOS)
        guard trackingEnabled else { return }
        captureController?.resumeIfAuthorized()
#endif
    }

    public func enableTracking() {
#if os(iOS)
        trackingEnabled = true
        ledger.trackingEnabled = true
        persistLedger()
        captureController?.enableTracking()
#else
        trackingState = .unavailable
#endif
    }

    public func disableTracking() {
#if os(iOS)
        trackingEnabled = false
        trackingState = .stopped
        ledger.trackingEnabled = false
        persistLedger()
        captureController?.stopTracking()
#else
        trackingState = .unavailable
#endif
    }

    public func synchronizeWithCloud() async {
        guard !usesDemoData,
              let cloudSession,
              cloudSession.isConnected,
              !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
#if os(iOS)
            scheduleAutomaticSync()
#endif
        }
        do {
#if os(iOS)
            try await prepareCloudBackup(using: cloudSession)
            try await uploadCloudBackup(using: cloudSession)
#endif
            let data = try await cloudSession.authorizedData(
                path: "native/v1/timeline/days?start=2000-01-01&limit=10000"
            )
            let remote = try BlipTimelinePersistence.decoder.decode(
                BlipTimelineCloudEnvelope.self,
                from: data
            ).days
            mergeRemoteDays(remote)
            lastSyncAt = Date()
            syncError = nil
            persistLedger(scheduleSync: false)
        } catch {
            syncError = error.localizedDescription
        }
    }

    public func exportTimeline() throws -> URL {
        let data = try BlipTimelinePersistence.encoder.encode(
            BlipTimelineExportEnvelope(days: days.sorted { $0.dateKey < $1.dateKey })
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlipTimelineExports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("blip-timeline.json")
#if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: url, options: .atomic)
#endif
        return url
    }

    public func deleteEverything() async {
        disableTracking()
        days = []
        ledger.days = []
        ledger.observations = []
        ledger.visits = []
        ledger.pendingDateKeys = []
        ledger.pendingDeletionDateKeys = []
        ledger.manuallyEditedDateKeys = []
        ledger.homeCoordinate = nil
        ledger.placeLabels = []
        ledger.savedPlaces = []
        ledger.visitPlaceAssignments = [:]
        ledger.pendingDeleteAll = true
        ledger.pendingDeleteAllRevision = ledger.syncRevision + 1
        persistLedger()
        await synchronizeWithCloud()
    }

    public func deleteDay(dateKey: String) {
        days.removeAll { $0.dateKey == dateKey }
        ledger.days = days
        ledger.observations.removeAll { $0.dateKey == dateKey }
        ledger.visits.removeAll { $0.dateKey == dateKey }
        ledger.pendingDateKeys.remove(dateKey)
        ledger.pendingDeletionDateKeys.insert(dateKey)
        ledger.manuallyEditedDateKeys.remove(dateKey)
        persistLedger()
    }

    public func updateEntry(
        id entryID: String,
        title: String,
        subtitle: String?,
        startDate: Date,
        endDate: Date?,
        transportMode: BlipTimelineTransportMode?,
        isHome: Bool
    ) {
        guard let day = dayContainingEntry(entryID),
              let entry = day.entries.first(where: { $0.id == entryID }) else { return }
        let editedPlaceID = entry.kind == .visit
            ? (entry.placeID ?? "place-\(UUID().uuidString.lowercased())")
            : entry.placeID
        let updated = BlipTimelineEntry(
            id: entry.id,
            kind: entry.kind,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? entry.title
                : title.trimmingCharacters(in: .whitespacesAndNewlines),
            subtitle: subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: startDate,
            endDate: endDate.map { max($0, startDate) },
            coordinate: entry.coordinate,
            route: entry.route,
            distanceMeters: entry.distanceMeters,
            transportMode: entry.kind == .journey ? transportMode : entry.transportMode,
            confidence: entry.confidence,
            isHome: entry.kind == .visit && isHome,
            placeID: editedPlaceID,
            placeCoordinate: entry.placeCoordinate,
            mapItemIdentifier: entry.mapItemIdentifier,
            placeCategory: entry.placeCategory,
            placeIcon: entry.placeIcon,
            residentContacts: entry.residentContacts
        )
        if updated.isHome, let coordinate = updated.coordinate {
            ledger.homeCoordinate = coordinate
        }
        if entry.kind == .visit, let coordinate = updated.coordinate {
            if entry.isHome,
               !updated.isHome,
               let homeCoordinate = ledger.homeCoordinate,
               BlipTimelineGeometry.distanceMeters(homeCoordinate, coordinate) <= 120 {
                ledger.homeCoordinate = nil
            }
            let label = BlipTimelinePlaceLabel(
                coordinate: coordinate,
                title: updated.title,
                subtitle: updated.subtitle,
                isHome: updated.isHome
            )
            if let editedPlaceID {
                upsertSavedPlace(BlipTimelineSavedPlace(
                    id: editedPlaceID,
                    title: updated.title,
                    subtitle: updated.subtitle,
                    coordinate: coordinate,
                    mapCoordinate: updated.placeCoordinate,
                    mapItemIdentifier: updated.mapItemIdentifier,
                    pointOfInterestCategory: updated.placeCategory,
                    iconSystemName: updated.placeIcon,
                    isHome: updated.isHome,
                    residentContacts: updated.residentContacts
                ))
            }
            upsertPlaceLabel(label)
            applyPlaceLabel(label, replacingEntryID: entryID, with: updated)
            return
        }
        commitEditedDay(day, replacing: entryID, with: [updated])
    }

    func updateVisitEntry(
        id entryID: String,
        title: String,
        subtitle: String?,
        startDate: Date,
        endDate: Date?,
        isHome: Bool,
        selectedSavedPlaceID: String?,
        placeCoordinate: BlipTimelineCoordinate?,
        mapItemIdentifier: String?,
        pointOfInterestCategory: String?,
        iconSystemName: String?,
        residentContacts: [BlipTimelineResidentReference] = [],
        rememberPlace: Bool
    ) {
        guard let day = dayContainingEntry(entryID),
              let entry = day.entries.first(where: { $0.id == entryID }),
              entry.kind == .visit,
              let recognitionCoordinate = entry.coordinate else { return }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = cleanTitle.isEmpty ? entry.title : cleanTitle
        let cleanSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingPlace = selectedSavedPlaceID.flatMap { selectedID in
            ledger.savedPlaces.first { $0.id == selectedID }
        }
        let placeID = selectedSavedPlaceID ?? "place-\(UUID().uuidString.lowercased())"
        let place = BlipTimelineSavedPlace(
            id: placeID,
            title: resolvedTitle,
            subtitle: cleanSubtitle?.isEmpty == true ? nil : cleanSubtitle,
            coordinate: recognitionCoordinate,
            mapCoordinate: placeCoordinate ?? existingPlace?.mapCoordinate,
            mapItemIdentifier: mapItemIdentifier ?? existingPlace?.mapItemIdentifier,
            pointOfInterestCategory: pointOfInterestCategory
                ?? existingPlace?.pointOfInterestCategory,
            iconSystemName: iconSystemName ?? existingPlace?.iconSystemName,
            isHome: isHome,
            recognitionRadiusMeters: existingPlace?.recognitionRadiusMeters ?? 65,
            residentContacts: residentContacts
        )
        let associatesWithSavedPlace = rememberPlace || existingPlace != nil
            || !residentContacts.isEmpty

        if isHome {
            ledger.homeCoordinate = recognitionCoordinate
            ledger.savedPlaces = ledger.savedPlaces.map { saved in
                guard saved.isHome, saved.id != place.id else { return saved }
                return saved.updating(isHome: false)
            }
        } else if entry.isHome,
                  let homeCoordinate = ledger.homeCoordinate,
                  BlipTimelineGeometry.distanceMeters(homeCoordinate, recognitionCoordinate) <= 120 {
            ledger.homeCoordinate = nil
        }

        if rememberPlace || !residentContacts.isEmpty {
            upsertSavedPlace(place)
        } else if let selectedSavedPlaceID {
            // Selecting an existing saved place never forgets it merely because
            // this edit is scoped to one visit.
            ledger.savedPlaces.removeAll { $0.id == selectedSavedPlaceID }
            if let existingPlace { ledger.savedPlaces.append(existingPlace) }
        }

        let updated = BlipTimelineEntry(
            id: entry.id,
            kind: entry.kind,
            title: place.title,
            subtitle: place.subtitle,
            startDate: startDate,
            endDate: endDate.map { max($0, startDate) },
            coordinate: entry.coordinate,
            route: entry.route,
            distanceMeters: entry.distanceMeters,
            transportMode: entry.transportMode,
            confidence: entry.confidence,
            isHome: place.isHome,
            placeID: associatesWithSavedPlace ? place.id : nil,
            placeCoordinate: place.mapCoordinate,
            mapItemIdentifier: place.mapItemIdentifier,
            placeCategory: place.pointOfInterestCategory,
            placeIcon: place.iconSystemName,
            residentContacts: place.residentContacts
        )

        if let visit = visit(forEntryID: entryID) {
            ledger.visitPlaceAssignments[visit.id.uuidString.lowercased()] = .init(
                place: place,
                remembersPlace: associatesWithSavedPlace
            )
            applyVisitPlaceAssignment(visit: visit, editedEntry: updated)
        } else {
            commitEditedDay(day, replacing: entryID, with: [updated])
        }
        persistLedger()
    }

    public func deleteEntry(id entryID: String) {
        guard let day = dayContainingEntry(entryID) else { return }
        commitEditedDay(day, replacing: entryID, with: [])
    }

    public func splitEntry(id entryID: String, at splitDate: Date) {
        guard let day = dayContainingEntry(entryID),
              let entry = day.entries.first(where: { $0.id == entryID }),
              let endDate = entry.endDate,
              splitDate > entry.startDate,
              splitDate < endDate else { return }
        let ratio = splitDate.timeIntervalSince(entry.startDate)
            / endDate.timeIntervalSince(entry.startDate)
        let routeIndex = min(
            max(Int((Double(max(entry.route.count - 1, 0)) * ratio).rounded()), 0),
            max(entry.route.count - 1, 0)
        )
        let firstRoute = entry.route.isEmpty ? [] : Array(entry.route[...routeIndex])
        let secondRoute = entry.route.isEmpty ? [] : Array(entry.route[routeIndex...])
        let first = copiedEntry(
            entry,
            id: "\(entry.id)-a",
            startDate: entry.startDate,
            endDate: splitDate,
            route: firstRoute,
            distanceMeters: entry.distanceMeters.map { $0 * ratio }
        )
        let second = copiedEntry(
            entry,
            id: "\(entry.id)-b",
            startDate: splitDate,
            endDate: endDate,
            route: secondRoute,
            distanceMeters: entry.distanceMeters.map { $0 * (1 - ratio) }
        )
        commitEditedDay(day, replacing: entryID, with: [first, second])
    }

    public func canMergeEntry(id entryID: String, towardNext: Bool) -> Bool {
        guard let day = dayContainingEntry(entryID),
              let index = day.orderedEntries.firstIndex(where: { $0.id == entryID }) else {
            return false
        }
        return mergeCandidateIndex(
            in: day.orderedEntries,
            from: index,
            towardNext: towardNext
        ) != nil
    }

    public func mergeEntry(id entryID: String, towardNext: Bool) {
        guard let day = dayContainingEntry(entryID),
              let index = day.orderedEntries.firstIndex(where: { $0.id == entryID }) else { return }
        guard let otherIndex = mergeCandidateIndex(
            in: day.orderedEntries,
            from: index,
            towardNext: towardNext
        ) else { return }
        let first = day.orderedEntries[min(index, otherIndex)]
        let second = day.orderedEntries[max(index, otherIndex)]
        let merged = BlipTimelineEntry(
            id: first.id,
            kind: first.kind,
            title: first.title,
            subtitle: first.subtitle ?? second.subtitle,
            startDate: first.startDate,
            endDate: second.endDate ?? first.endDate,
            coordinate: first.coordinate ?? second.coordinate,
            route: first.route + second.route.dropFirst(),
            distanceMeters: (first.distanceMeters ?? 0) + (second.distanceMeters ?? 0),
            transportMode: first.transportMode ?? second.transportMode,
            confidence: first.confidence == .observed && second.confidence == .observed
                ? .observed
                : .inferred,
            isHome: first.isHome || second.isHome,
            placeID: first.placeID ?? second.placeID,
            placeCoordinate: first.placeCoordinate ?? second.placeCoordinate,
            mapItemIdentifier: first.mapItemIdentifier ?? second.mapItemIdentifier,
            placeCategory: first.placeCategory ?? second.placeCategory,
            placeIcon: first.placeIcon ?? second.placeIcon,
            residentContacts: Self.mergedResidents(
                first.residentContacts,
                second.residentContacts
            )
        )
        let lower = min(index, otherIndex)
        let upper = max(index, otherIndex)
        let removedIDs = Set(day.orderedEntries[lower...upper].map(\.id))
        var entries = day.entries.filter { !removedIDs.contains($0.id) }
        entries.append(merged)
        commitEditedDay(day, entries: entries)
    }

    private func mergeCandidateIndex(
        in entries: [BlipTimelineEntry],
        from index: Int,
        towardNext: Bool
    ) -> Int? {
        let direction = towardNext ? 1 : -1
        for distance in 1...2 {
            let candidate = index + (direction * distance)
            if entries.indices.contains(candidate),
               entries[candidate].kind == entries[index].kind {
                return candidate
            }
        }
        return nil
    }

    func ingest(
        _ observation: BlipTimelineLocationObservation,
        now: Date = Date()
    ) {
        ingest([observation], now: now)
    }

    func ingest(
        _ observations: [BlipTimelineLocationObservation],
        now: Date = Date()
    ) {
        guard !observations.isEmpty else { return }
        if let newestTimestamp = observations.map(\.timestamp).max() {
            lastSampleAt = max(lastSampleAt ?? .distantPast, newestTimestamp)
        }
        var affectedDateKeys = Set<String>()
        for observation in observations.sorted(by: { $0.timestamp < $1.timestamp }) {
            affectedDateKeys.insert(observation.dateKey)
            if let duplicateIndex = ledger.observations.lastIndex(where: {
                $0.canBeMerged(asDuplicateOf: observation)
            }) {
                let existing = ledger.observations[duplicateIndex]
                let merged = existing.mergingDuplicate(observation)
                affectedDateKeys.insert(existing.dateKey)
                affectedDateKeys.insert(merged.dateKey)
                ledger.observations[duplicateIndex] = merged
            } else {
                ledger.observations.append(observation)
            }
        }
        ledger.observations.sort { $0.timestamp < $1.timestamp }
        let cutoff = now.addingTimeInterval(-8 * 24 * 3_600)
        ledger.observations.removeAll { $0.timestamp < cutoff }
        if ledger.observations.count
            > BlipTimelineObservationRetention.maximumStoredObservationCount {
            ledger.observations.removeFirst(
                ledger.observations.count
                    - BlipTimelineObservationRetention.maximumStoredObservationCount
            )
        }
        affectedDateKeys.formUnion(reconcileStoredVisits(through: now))
        for dateKey in affectedDateKeys.sorted() {
            rebuildCapturedDay(dateKey: dateKey, now: now)
        }
    }

    @discardableResult
    func ingest(
        _ visit: BlipTimelineVisitObservation,
        now: Date = Date()
    ) -> BlipTimelineVisitObservation {
        let previous = ledger.visits.last
        let referenceDate = now
        var affectedVisits = [visit]
        let storedVisit: BlipTimelineVisitObservation
        if let replayIndex = ledger.visits.firstIndex(where: { $0.id == visit.id }) {
            // Crash-safe spool replay can present an already persisted visit
            // again. Match its durable UUID before considering adjacency so a
            // partial drain never creates an out-of-order duplicate.
            let existing = ledger.visits[replayIndex]
            affectedVisits.append(existing)
            storedVisit = existing.canBeUpdated(by: visit)
                ? existing.updating(with: visit)
                : existing
            ledger.visits[replayIndex] = storedVisit
        } else if let previous, previous.canBeUpdated(by: visit) {
            affectedVisits.append(previous)
            storedVisit = previous.updating(with: visit)
            ledger.visits[ledger.visits.index(before: ledger.visits.endIndex)] = storedVisit
        } else if let completedIndex = earlierVisitIndex(completedBy: visit) {
            let existing = ledger.visits[completedIndex]
            affectedVisits.append(existing)
            storedVisit = existing.updating(with: visit)
            ledger.visits[completedIndex] = storedVisit
        } else {
            storedVisit = visit
            ledger.visits.append(visit)
        }
        let repairedDateKeys = reconcileStoredVisits(through: referenceDate)
        var affectedDateKeys = Set((affectedVisits + [storedVisit]).flatMap {
            $0.coveredDateKeys(through: referenceDate)
        })
        affectedDateKeys.formUnion(repairedDateKeys)
        let cutoff = now.addingTimeInterval(-32 * 24 * 3_600)
        ledger.visits.removeAll { ($0.departureDate ?? referenceDate) < cutoff }
        for dateKey in affectedDateKeys.sorted() {
            rebuildCapturedDay(dateKey: dateKey, now: referenceDate)
        }
        return ledger.visits.last(where: { $0.id == storedVisit.id }) ?? storedVisit
    }

    private func earlierVisitIndex(completedBy visit: BlipTimelineVisitObservation) -> Int? {
        guard visit.departureDate != nil, visit.inferredDepartureUpperBound == nil else { return nil }

        let candidates = ledger.visits.indices.filter {
            let existing = ledger.visits[$0]
            let isExactCompletedReplay = existing.departureWasReported == true
                && existing.arrivalDate == visit.arrivalDate
                && existing.departureDate == visit.departureDate
            return (existing.inferredDepartureUpperBound != nil || isExactCompletedReplay)
                && existing.canBeUpdated(by: visit)
        }

        // A later return to the same place must remain a separate visit. Only
        // replace a uniquely matching interval whose missing departure was
        // explicitly inferred, or replay an identical completed report whose
        // callback UUID was replaced by the original stable visit identity.
        return candidates.count == 1 ? candidates.first : nil
    }

    func updateCaptureState(_ state: BlipTimelineTrackingState, isActive: Bool) {
        trackingState = state
        isActivelySampling = isActive
    }

    func updateBackgroundCaptureStatus(_ status: BlipTimelineBackgroundCaptureStatus) {
        guard backgroundCaptureStatus != status || ledger.backgroundCaptureStatus != status else {
            return
        }
        backgroundCaptureStatus = status
        ledger.backgroundCaptureStatus = status
        persistLedger()
    }

    func applyInferredPlaceName(entryID: String, title: String, subtitle: String?) {
        guard let day = dayContainingEntry(entryID),
              !ledger.manuallyEditedDateKeys.contains(day.dateKey),
              let entry = day.entries.first(where: { $0.id == entryID }),
              entry.kind == .visit,
              entry.title == "Visited place" || entry.title == "Current place" else { return }
        let named = BlipTimelineEntry(
            id: entry.id,
            kind: entry.kind,
            title: title,
            subtitle: subtitle,
            startDate: entry.startDate,
            endDate: entry.endDate,
            coordinate: entry.coordinate,
            route: entry.route,
            distanceMeters: entry.distanceMeters,
            transportMode: entry.transportMode,
            confidence: entry.confidence,
            isHome: entry.isHome,
            placeID: entry.placeID,
            placeCoordinate: entry.placeCoordinate,
            mapItemIdentifier: entry.mapItemIdentifier,
            placeCategory: entry.placeCategory,
            placeIcon: entry.placeIcon,
            residentContacts: entry.residentContacts
        )
        var entries = day.entries.filter { $0.id != entry.id }
        entries.append(named)
        replaceDay(BlipTimelineDay(
            date: day.date,
            dateKey: day.dateKey,
            timeZoneIdentifier: day.timeZoneIdentifier,
            coverage: day.coverage,
            entries: entries,
            metrics: Self.metrics(for: entries),
            updatedAt: Date(),
            sourceDeviceID: sourceDeviceID
        ), pendingUpload: true)
    }

    func cloudSafeDay(_ day: BlipTimelineDay) -> BlipTimelineDay {
        let entries = day.entries.map { entry in
            BlipTimelineEntry(
                id: entry.id,
                kind: entry.kind,
                title: entry.title,
                subtitle: entry.subtitle,
                startDate: entry.startDate,
                endDate: entry.endDate,
                coordinate: entry.coordinate,
                route: entry.route,
                distanceMeters: entry.distanceMeters,
                transportMode: entry.transportMode,
                confidence: entry.confidence,
                isHome: entry.isHome,
                placeID: entry.placeID,
                placeCoordinate: entry.placeCoordinate,
                mapItemIdentifier: entry.mapItemIdentifier,
                placeCategory: entry.placeCategory,
                placeIcon: entry.placeIcon,
                residentContacts: entry.residentContacts.map(\.cloudReference)
            )
        }
        return BlipTimelineDay(
            date: day.date,
            dateKey: day.dateKey,
            timeZoneIdentifier: day.timeZoneIdentifier,
            coverage: day.coverage,
            entries: entries,
            metrics: day.metrics,
            updatedAt: day.updatedAt,
            sourceDeviceID: day.sourceDeviceID
        )
    }

    func mergeRemoteDays(_ remote: [BlipTimelineDay]) {
#if os(macOS)
        // The Mac is a read-only mirror. Older builds could mark cached days
        // as local writes merely by finalizing their coverage. Neither those
        // pending flags nor their newer timestamps may hide the phone's data.
        // Clear obsolete write intent only after a complete successful fetch.
        days = remote.sorted { $0.date < $1.date }
        ledger.pendingDateKeys.removeAll()
        ledger.pendingDeletionDateKeys.removeAll()
        ledger.pendingDeleteAll = false
#else
        var merged = Dictionary(uniqueKeysWithValues: days.map { ($0.dateKey, $0) })
        for day in remote {
            guard !ledger.pendingDeleteAll,
                  !ledger.pendingDeletionDateKeys.contains(day.dateKey) else { continue }
            let localIsPending = ledger.pendingDateKeys.contains(day.dateKey)
            if !localIsPending,
               merged[day.dateKey] == nil || day.updatedAt >= merged[day.dateKey]!.updatedAt {
                merged[day.dateKey] = day
            }
        }
        days = merged.values.sorted { $0.date < $1.date }
#endif
        ledger.days = days
        absorbPlaceLabels(from: days)
    }

    func materializeStationaryDays(now: Date = Date()) {
        // Older ledgers may already have a reverse-geocoded or manually named
        // arrival-day entry without a separate saved place label.
        absorbPlaceLabels(from: days)
        let originalVisits = ledger.visits.filter { $0.departureDate != nil || trackingEnabled }
        var candidateDateKeys = Set(originalVisits.flatMap { $0.coveredDateKeys(through: now) })
        let repairedDateKeys = reconcileStoredVisits(through: now)
        let visits = ledger.visits.filter { $0.departureDate != nil || trackingEnabled }
        let coveredDateKeys = Set(visits.flatMap { $0.coveredDateKeys(through: now) })
        candidateDateKeys.formUnion(coveredDateKeys)
        candidateDateKeys.formUnion(repairedDateKeys)
        finalizePastCoverageAndRepairLegacyEdits(now: now, visits: visits)
        for dateKey in candidateDateKeys.sorted() {
            guard !ledger.manuallyEditedDateKeys.contains(dateKey) else { continue }
            let visitsForDay = visits.filter {
                $0.coveredDateKeys(through: now).contains(dateKey)
            }
            let expectedEntryIDs = Set(visitsForDay.map {
                BlipTimelineDayBuilder.visitEntryID(for: $0, dateKey: dateKey)
            })
            let existingDay = days.first(where: { $0.dateKey == dateKey })
            let existingEntryIDs = Set(existingDay?.entries.compactMap { entry in
                entry.kind == .visit && entry.id.hasPrefix("visit-") ? entry.id : nil
            } ?? [])
            if repairedDateKeys.contains(dateKey) || expectedEntryIDs != existingEntryIDs {
                if expectedEntryIDs.isEmpty,
                   ledger.observations.allSatisfy({ $0.dateKey != dateKey }),
                   let existingDay,
                   existingDay.entries.allSatisfy({ $0.id.hasPrefix("visit-") }) {
                    removeAutomaticallyCapturedDay(dateKey)
                } else {
                    rebuildCapturedDay(dateKey: dateKey, now: now)
                }
            }
        }
        persistLedger()
    }

    private func reconcileStoredVisits(through referenceDate: Date) -> Set<String> {
        var repairedDateKeys = Set<String>()
        var reconciled: [BlipTimelineVisitObservation] = []
        // The ledger preserves callback delivery order. A departure report
        // completes the immediately preceding arrival report; looking farther
        // back could collapse a genuine later return to the same place.
        for visit in ledger.visits {
            if let previous = reconciled.last, previous.canBeUpdated(by: visit) {
                let updated = previous.updating(with: visit)
                repairedDateKeys.formUnion(previous.coveredDateKeys(through: referenceDate))
                repairedDateKeys.formUnion(visit.coveredDateKeys(through: referenceDate))
                repairedDateKeys.formUnion(updated.coveredDateKeys(through: referenceDate))
                reconciled[reconciled.index(before: reconciled.endIndex)] = updated
            } else {
                reconciled.append(visit)
            }
        }

        // A person can occupy only one stationary visit at a time. If Core
        // Location starts a later, distinct visit without completing an older
        // arrival-only visit, the later arrival is the best available upper
        // bound for the older stay. Repair every such legacy interval so only
        // the chronologically latest visit can remain open.
        for index in reconciled.indices {
            var current = reconciled[index]
            guard let nextVisit = reconciled.filter({ $0.arrivalDate > current.arrivalDate })
                .min(by: { $0.arrivalDate < $1.arrivalDate }) else { continue }
            let nextArrival = nextVisit.arrivalDate
            let isLegacyCollapsedBoundary = current.departureDate == nextArrival
                && current.inferredDepartureUpperBound == nil
                && current.departureWasReported != true
            guard current.departureDate == nil || current.inferredDepartureUpperBound != nil
                    || isLegacyCollapsedBoundary else { continue }

            let recovered = BlipTimelineDepartureRecovery.departure(
                from: current, to: nextVisit, observations: ledger.observations
            )
            // Old ledgers did not distinguish inferred closures. An exact
            // shared boundary alone is not enough to rewrite one: require the
            // same strong recorded movement evidence used for new captures.
            if isLegacyCollapsedBoundary {
                guard recovered != nil else { continue }
                current.inferredDepartureUpperBound = nextArrival
            }
            var end = min(
                current.departureDate ?? nextArrival,
                recovered?.departure ?? nextArrival,
                nextArrival
            )
            if let recovered, let originFix = recovered.originFix,
               let previousDeparture = current.departureDate,
               originFix >= previousDeparture {
                // A delayed fix back at the origin can prove a later final
                // exit. Without that evidence, preserve an earlier recovered
                // boundary when retention has removed its first samples.
                end = min(recovered.departure, nextArrival)
            }
            let ended = current.ending(at: end, inferredUpperBound: nextArrival)
            guard ended.departureDate != reconciled[index].departureDate
                    || ended.inferredDepartureUpperBound != reconciled[index].inferredDepartureUpperBound else {
                continue
            }
            repairedDateKeys.formUnion(current.coveredDateKeys(through: referenceDate))
            repairedDateKeys.formUnion(ended.coveredDateKeys(through: referenceDate))
            reconciled[index] = ended
        }
        ledger.visits = reconciled
        return repairedDateKeys
    }

    private func finalizePastCoverageAndRepairLegacyEdits(
        now: Date,
        visits: [BlipTimelineVisitObservation]
    ) {
        var changedDateKeys = Set<String>()
        days = days.map { day in
            var coverage = day.coverage
            if coverage == .partial,
               day.dateKey != BlipTimelineDay.makeDateKey(
                    now,
                    timeZoneIdentifier: day.timeZoneIdentifier
               ) {
                coverage = .complete
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: day.timeZoneIdentifier)
                ?? .autoupdatingCurrent
            guard let interval = calendar.dateInterval(of: .day, for: day.date) else {
                return day
            }
            let entries = day.entries.map { entry -> BlipTimelineEntry in
                guard ledger.manuallyEditedDateKeys.contains(day.dateKey),
                      entry.kind == .visit else { return entry }

                // Keep the user's title, Home classification, and other edits,
                // but fill an absent endpoint from the stable captured visit.
                // This repairs manually edited days that otherwise retain two
                // open rows after the underlying ledger has been normalized.
                if entry.endDate == nil,
                   let visit = visits.first(where: {
                       BlipTimelineDayBuilder.visitEntryID(
                           for: $0,
                           dateKey: day.dateKey
                       ) == entry.id
                   }) {
                    let repairedEnd: Date?
                    if let departureDate = visit.departureDate {
                        repairedEnd = min(departureDate, interval.end)
                    } else if interval.end <= now {
                        repairedEnd = interval.end
                    } else {
                        repairedEnd = nil
                    }
                    guard repairedEnd != nil else { return entry }
                    return BlipTimelineEntry(
                        id: entry.id,
                        kind: entry.kind,
                        title: entry.title,
                        subtitle: entry.subtitle,
                        startDate: entry.startDate,
                        endDate: repairedEnd,
                        coordinate: entry.coordinate,
                        route: entry.route,
                        distanceMeters: entry.distanceMeters,
                        transportMode: entry.transportMode,
                        confidence: visit.departureDate == nil || visit.inferredDepartureUpperBound != nil
                            ? .inferred : .observed,
                        isHome: entry.isHome,
                        placeID: entry.placeID,
                        placeCoordinate: entry.placeCoordinate,
                        mapItemIdentifier: entry.mapItemIdentifier,
                        placeCategory: entry.placeCategory,
                        placeIcon: entry.placeIcon,
                        residentContacts: entry.residentContacts
                    )
                }

                guard let coordinate = entry.coordinate,
                      let endDate = entry.endDate,
                      abs(endDate.timeIntervalSince(entry.startDate) - 30 * 60) <= 1,
                      let visit = visits.first(where: {
                          let beginsThisEntry = abs(
                              $0.arrivalDate.timeIntervalSince(entry.startDate)
                          ) <= 1
                          let carriesIntoThisDay = entry.startDate == interval.start
                              && $0.arrivalDate < interval.start
                              && $0.coveredDateKeys(through: now).contains(day.dateKey)
                          return (beginsThisEntry || carriesIntoThisDay)
                              && BlipTimelineGeometry.distanceMeters(
                                  coordinate,
                                  $0.coordinate
                              ) <= max(120, $0.horizontalAccuracy)
                      }) else { return entry }
                let repairedEnd: Date?
                if let departureDate = visit.departureDate {
                    repairedEnd = min(departureDate, interval.end)
                } else if interval.end <= now {
                    repairedEnd = interval.end
                } else {
                    repairedEnd = nil
                }
                return BlipTimelineEntry(
                    id: entry.id,
                    kind: entry.kind,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    startDate: entry.startDate,
                    endDate: repairedEnd,
                    coordinate: entry.coordinate,
                    route: entry.route,
                    distanceMeters: entry.distanceMeters,
                    transportMode: entry.transportMode,
                    confidence: visit.departureDate == nil || visit.inferredDepartureUpperBound != nil
                        ? .inferred : .observed,
                    isHome: entry.isHome,
                    placeID: entry.placeID,
                    placeCoordinate: entry.placeCoordinate,
                    mapItemIdentifier: entry.mapItemIdentifier,
                    placeCategory: entry.placeCategory,
                    placeIcon: entry.placeIcon,
                    residentContacts: entry.residentContacts
                )
            }
            guard coverage != day.coverage || entries != day.entries else { return day }
            changedDateKeys.insert(day.dateKey)
            return BlipTimelineDay(
                date: day.date,
                dateKey: day.dateKey,
                timeZoneIdentifier: day.timeZoneIdentifier,
                coverage: coverage,
                entries: entries,
                metrics: Self.metrics(for: entries),
                updatedAt: now,
                sourceDeviceID: sourceDeviceID
            )
        }
        ledger.days = days
        ledger.pendingDateKeys.formUnion(changedDateKeys)
    }

    private func removeAutomaticallyCapturedDay(_ dateKey: String) {
        days.removeAll { $0.dateKey == dateKey }
        ledger.days = days
        ledger.pendingDateKeys.remove(dateKey)
        ledger.pendingDeletionDateKeys.insert(dateKey)
    }

    private func rebuildCapturedDay(dateKey: String, now: Date = Date()) {
        let observations = ledger.observations.filter { $0.dateKey == dateKey }
        let visits = ledger.visits.filter {
            $0.coveredDateKeys(through: now).contains(dateKey)
        }
        guard var day = BlipTimelineDayBuilder.makeDay(
            dateKey: dateKey,
            observations: observations,
            visits: visits,
            homeCoordinate: ledger.homeCoordinate,
            placeLabels: ledger.placeLabels,
            savedPlaces: ledger.savedPlaces,
            visitPlaceAssignments: ledger.visitPlaceAssignments,
            sourceDeviceID: sourceDeviceID,
            now: now
        ) else {
            persistLedger()
            return
        }
        // Visit reconciliation can rebuild a day after its raw location
        // samples have expired. Keep a previously recorded journey when its
        // exact interval is unchanged and there are no samples to rebuild it.
        // The repaired visits still replace stale rows and midnight carryovers.
        let previousEntries = days.first { $0.dateKey == dateKey }?.entries ?? []
        let preservedEntries = day.entries.map { entry in
            guard entry.kind == .journey, let end = entry.endDate,
                  !observations.contains(where: {
                      $0.timestamp >= entry.startDate && $0.timestamp <= end
                  }),
                  let recorded = previousEntries.first(where: {
                      $0.kind == .journey && $0.id == entry.id
                          && $0.startDate == entry.startDate && $0.endDate == end
                          && $0.route.count > entry.route.count
                  }) else { return entry }
            return recorded
        }
        if preservedEntries != day.entries {
            day = BlipTimelineDay(
                date: day.date, dateKey: day.dateKey,
                timeZoneIdentifier: day.timeZoneIdentifier, coverage: day.coverage,
                entries: preservedEntries, metrics: Self.metrics(for: preservedEntries),
                updatedAt: day.updatedAt, sourceDeviceID: day.sourceDeviceID
            )
        }
        if ledger.manuallyEditedDateKeys.contains(dateKey),
           let edited = days.first(where: { $0.dateKey == dateKey }) {
            // Preserve corrected history. New, later checkpoints may still join
            // an edited current day, so correcting breakfast never stops capture
            // for the afternoon.
            let existingEnd = edited.entries.compactMap { $0.endDate ?? $0.startDate }.max()
                ?? edited.date
            let boundary = existingEnd.addingTimeInterval(30)
            let additions = day.entries.filter { entry in
                if entry.kind == .journey {
                    guard !edited.entries.contains(where: { $0.id == entry.id }) else {
                        return false
                    }
                    // A connecting journey normally starts exactly when the
                    // last edited visit ends. Judge it by where it leads, or it
                    // disappears while the later destination is still added.
                    if (entry.endDate ?? entry.startDate) > boundary { return true }
                    guard let journeyEnd = entry.endDate else { return false }
                    let hasEditedOrigin = edited.entries.contains {
                        $0.kind == .visit && $0.endDate.map {
                            abs($0.timeIntervalSince(entry.startDate)) <= 1
                        } == true
                    }
                    let hasEditedDestination = edited.entries.contains {
                        $0.kind == .visit
                            && abs($0.startDate.timeIntervalSince(journeyEnd)) <= 1
                    }
                    return hasEditedOrigin && hasEditedDestination
                }
                return entry.startDate > boundary
            }
            guard !additions.isEmpty else {
                persistLedger()
                return
            }
            let entries = (edited.entries + additions).sorted { $0.startDate < $1.startDate }
            replaceDay(BlipTimelineDay(
                date: edited.date,
                dateKey: edited.dateKey,
                timeZoneIdentifier: edited.timeZoneIdentifier,
                coverage: day.coverage,
                entries: entries,
                metrics: Self.metrics(for: entries),
                updatedAt: Date(),
                sourceDeviceID: sourceDeviceID
            ), pendingUpload: true)
            return
        }
        replaceDay(day, pendingUpload: true)
    }

    private func commitEditedDay(
        _ day: BlipTimelineDay,
        replacing entryID: String,
        with replacements: [BlipTimelineEntry]
    ) {
        var entries = day.entries.filter { $0.id != entryID }
        entries.append(contentsOf: replacements)
        commitEditedDay(day, entries: entries)
    }

    private func commitEditedDay(_ day: BlipTimelineDay, entries: [BlipTimelineEntry]) {
        ledger.manuallyEditedDateKeys.insert(day.dateKey)
        replaceDay(BlipTimelineDay(
            date: day.date,
            dateKey: day.dateKey,
            timeZoneIdentifier: day.timeZoneIdentifier,
            coverage: day.coverage,
            entries: entries,
            metrics: Self.metrics(for: entries),
            updatedAt: Date(),
            sourceDeviceID: sourceDeviceID
        ), pendingUpload: true)
    }

    private func replaceDay(_ day: BlipTimelineDay, pendingUpload: Bool) {
        days.removeAll { $0.dateKey == day.dateKey }
        days.append(day)
        days.sort { $0.date < $1.date }
        ledger.days = days
        ledger.pendingDeletionDateKeys.remove(day.dateKey)
        if pendingUpload { ledger.pendingDateKeys.insert(day.dateKey) }
        persistLedger()
    }

    private func upsertSavedPlace(_ place: BlipTimelineSavedPlace) {
        ledger.savedPlaces.removeAll { $0.id == place.id }
        ledger.savedPlaces.append(place)
        if ledger.canonicalizeSavedPlaces() > 0 {
            days = ledger.days.sorted { $0.date < $1.date }
        }
    }

    private func visit(forEntryID entryID: String) -> BlipTimelineVisitObservation? {
        ledger.visits.first { visit in
            let base = "visit-\(visit.id.uuidString.lowercased())"
            return entryID == base || entryID.hasPrefix("\(base)-")
        }
    }

    private func applyVisitPlaceAssignment(
        visit: BlipTimelineVisitObservation,
        editedEntry: BlipTimelineEntry
    ) {
        guard let assignment = ledger.visitPlaceAssignments[visit.id.uuidString.lowercased()] else {
            return
        }
        let place = assignment.place
        var changedDateKeys = Set<String>()
        days = days.map { day in
            let visitEntryID = BlipTimelineDayBuilder.visitEntryID(for: visit, dateKey: day.dateKey)
            let entries = day.entries.map { entry -> BlipTimelineEntry in
                if entry.id == editedEntry.id { return editedEntry }
                guard entry.id == visitEntryID else { return entry }
                return BlipTimelineEntry(
                    id: entry.id,
                    kind: entry.kind,
                    title: place.title,
                    subtitle: place.subtitle,
                    startDate: entry.startDate,
                    endDate: entry.endDate,
                    coordinate: entry.coordinate,
                    route: entry.route,
                    distanceMeters: entry.distanceMeters,
                    transportMode: entry.transportMode,
                    confidence: entry.confidence,
                    isHome: place.isHome,
                    placeID: assignment.remembersPlace ? place.id : nil,
                    placeCoordinate: place.mapCoordinate,
                    mapItemIdentifier: place.mapItemIdentifier,
                    placeCategory: place.pointOfInterestCategory,
                    placeIcon: place.iconSystemName,
                    residentContacts: place.residentContacts
                )
            }
            guard entries != day.entries else { return day }
            changedDateKeys.insert(day.dateKey)
            return BlipTimelineDay(
                date: day.date,
                dateKey: day.dateKey,
                timeZoneIdentifier: day.timeZoneIdentifier,
                coverage: day.coverage,
                entries: entries,
                metrics: Self.metrics(for: entries),
                updatedAt: Date(),
                sourceDeviceID: sourceDeviceID
            )
        }
        ledger.manuallyEditedDateKeys.formUnion(changedDateKeys)
        ledger.pendingDateKeys.formUnion(changedDateKeys)
        ledger.days = days
    }

    private func upsertPlaceLabel(_ label: BlipTimelinePlaceLabel) {
        ledger.placeLabels.removeAll {
            BlipTimelineGeometry.distanceMeters($0.coordinate, label.coordinate) <= 120
        }
        ledger.placeLabels.append(label)
    }

    private func applyPlaceLabel(
        _ label: BlipTimelinePlaceLabel,
        replacingEntryID entryID: String,
        with editedEntry: BlipTimelineEntry
    ) {
        var changedDateKeys = Set<String>()
        days = days.map { day in
            let entries = day.entries.map { entry in
                if entry.id == entryID { return editedEntry }
                guard entry.kind == .visit,
                      let coordinate = entry.coordinate,
                      BlipTimelineGeometry.distanceMeters(coordinate, label.coordinate) <= 120 else {
                    return entry
                }
                return BlipTimelineEntry(
                    id: entry.id,
                    kind: entry.kind,
                    title: label.title,
                    subtitle: label.subtitle,
                    startDate: entry.startDate,
                    endDate: entry.endDate,
                    coordinate: entry.coordinate,
                    route: entry.route,
                    distanceMeters: entry.distanceMeters,
                    transportMode: entry.transportMode,
                    confidence: entry.confidence,
                    isHome: label.isHome,
                    placeID: editedEntry.placeID,
                    placeCoordinate: editedEntry.placeCoordinate,
                    mapItemIdentifier: editedEntry.mapItemIdentifier,
                    placeCategory: editedEntry.placeCategory,
                    placeIcon: editedEntry.placeIcon,
                    residentContacts: editedEntry.residentContacts
                )
            }
            guard entries != day.entries else { return day }
            changedDateKeys.insert(day.dateKey)
            return BlipTimelineDay(
                date: day.date,
                dateKey: day.dateKey,
                timeZoneIdentifier: day.timeZoneIdentifier,
                coverage: day.coverage,
                entries: entries,
                metrics: Self.metrics(for: entries),
                updatedAt: Date(),
                sourceDeviceID: sourceDeviceID
            )
        }
        ledger.manuallyEditedDateKeys.formUnion(changedDateKeys)
        ledger.pendingDateKeys.formUnion(changedDateKeys)
        ledger.days = days
        persistLedger()
    }

    private func absorbPlaceLabels(from remoteDays: [BlipTimelineDay]) {
        for entry in remoteDays.flatMap(\.entries) where entry.kind == .visit {
            guard let coordinate = entry.coordinate,
                  entry.isHome || !Self.genericPlaceTitles.contains(entry.title) else { continue }
            if entry.placeID == nil,
               entry.placeCoordinate != nil || entry.mapItemIdentifier != nil
                || entry.placeCategory != nil || entry.placeIcon != nil {
                // New entries without a place ID were explicitly scoped to
                // this visit. Do not turn them into remembered places later.
                continue
            }
            let placeID = entry.placeID
                ?? "legacy-\(String(coordinate.latitude.bitPattern, radix: 16))-"
                + String(coordinate.longitude.bitPattern, radix: 16)
            let place = BlipTimelineSavedPlace(
                id: placeID,
                title: entry.title,
                subtitle: entry.subtitle,
                coordinate: coordinate,
                mapCoordinate: entry.placeCoordinate,
                mapItemIdentifier: entry.mapItemIdentifier,
                pointOfInterestCategory: entry.placeCategory,
                iconSystemName: entry.placeIcon,
                isHome: entry.isHome,
                residentContacts: entry.residentContacts
            )
            if place.isHome, ledger.homeCoordinate == nil {
                ledger.homeCoordinate = coordinate
            }
            upsertSavedPlace(place)
        }
    }

    private static let genericPlaceTitles = Set(["Home", "Visited place", "Current place"])

    private func dayContainingEntry(_ entryID: String) -> BlipTimelineDay? {
        days.first { $0.entries.contains(where: { $0.id == entryID }) }
    }

    private func copiedEntry(
        _ entry: BlipTimelineEntry,
        id: String,
        startDate: Date,
        endDate: Date,
        route: [BlipTimelineCoordinate],
        distanceMeters: Double?
    ) -> BlipTimelineEntry {
        BlipTimelineEntry(
            id: id,
            kind: entry.kind,
            title: entry.title,
            subtitle: entry.subtitle,
            startDate: startDate,
            endDate: endDate,
            coordinate: entry.coordinate,
            route: route,
            distanceMeters: distanceMeters,
            transportMode: entry.transportMode,
            confidence: entry.confidence,
            isHome: entry.isHome,
            placeID: entry.placeID,
            placeCoordinate: entry.placeCoordinate,
            mapItemIdentifier: entry.mapItemIdentifier,
            placeCategory: entry.placeCategory,
            placeIcon: entry.placeIcon,
            residentContacts: entry.residentContacts
        )
    }

    private static func mergedResidents(
        _ first: [BlipTimelineResidentReference],
        _ second: [BlipTimelineResidentReference]
    ) -> [BlipTimelineResidentReference] {
        BlipTimelineResidentReference.merging(first, with: second)
    }

    static func metrics(for entries: [BlipTimelineEntry]) -> BlipTimelineActivityMetrics {
        .derived(from: entries)
    }
}

@MainActor
enum BlipTimelineDayBuilder {
    static func makeDay(
        dateKey: String,
        observations: [BlipTimelineLocationObservation],
        visits: [BlipTimelineVisitObservation],
        homeCoordinate: BlipTimelineCoordinate?,
        placeLabels: [BlipTimelinePlaceLabel] = [],
        savedPlaces: [BlipTimelineSavedPlace] = [],
        visitPlaceAssignments: [String: BlipTimelineVisitPlaceAssignment] = [:],
        sourceDeviceID: String,
        now: Date = Date()
    ) -> BlipTimelineDay? {
        let candidatePoints = observations.sorted { $0.timestamp < $1.timestamp }
        let candidateVisits = visits.sorted { $0.arrivalDate < $1.arrivalDate }
        guard let zoneID = candidatePoints.first?.timeZoneIdentifier
                ?? candidateVisits.first?.timeZoneIdentifier else { return nil }
        guard let date = date(from: dateKey, timeZoneIdentifier: zoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneID) ?? .autoupdatingCurrent
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        let sortedPoints = candidatePoints.filter {
            $0.timestamp >= date && $0.timestamp < dayEnd
        }
        let sortedVisits = candidateVisits.filter { visit in
            let effectiveEnd = min(visit.departureDate ?? now, now)
            return visit.arrivalDate < dayEnd && effectiveEnd > date
        }
        guard !sortedPoints.isEmpty || !sortedVisits.isEmpty else { return nil }
        var entries: [BlipTimelineEntry] = []

        for visit in sortedVisits {
            let assignment = visitPlaceAssignments[visit.id.uuidString.lowercased()]
            let savedPlace = assignment?.place ?? closestSavedPlace(
                to: visit.coordinate,
                horizontalAccuracy: visit.horizontalAccuracy,
                places: savedPlaces
            )
            let placeLabel = savedPlace == nil && savedPlaces.isEmpty ? closestPlaceLabel(
                to: visit.coordinate,
                within: max(120, visit.horizontalAccuracy),
                labels: placeLabels
            ) : nil
            let isHome = savedPlace?.isHome ?? placeLabel?.isHome ?? homeCoordinate.map {
                distance($0, visit.coordinate) <= max(120, visit.horizontalAccuracy)
            } ?? false
            let segmentStart = max(visit.arrivalDate, date)
            let segmentEnd: Date?
            if let departureDate = visit.departureDate {
                segmentEnd = min(departureDate, dayEnd)
            } else if dayEnd <= now {
                segmentEnd = dayEnd
            } else {
                segmentEnd = nil
            }
            entries.append(BlipTimelineEntry(
                id: visitEntryID(for: visit, dateKey: dateKey),
                kind: .visit,
                title: savedPlace?.title ?? placeLabel?.title ?? (isHome ? "Home" : "Visited place"),
                subtitle: savedPlace?.subtitle ?? placeLabel?.subtitle,
                startDate: segmentStart,
                endDate: segmentEnd,
                coordinate: visit.coordinate,
                confidence: visit.inferredDepartureUpperBound != nil
                    || (visit.departureDate == nil && visit.arrivalDate < date)
                    ? .inferred
                    : .observed,
                isHome: isHome,
                placeID: assignment?.remembersPlace == false ? nil : savedPlace?.id,
                placeCoordinate: savedPlace?.mapCoordinate,
                mapItemIdentifier: savedPlace?.mapItemIdentifier,
                placeCategory: savedPlace?.pointOfInterestCategory,
                placeIcon: savedPlace?.iconSystemName,
                residentContacts: savedPlace?.residentContacts ?? []
            ))
        }

        if sortedVisits.count >= 2 {
            for pair in zip(sortedVisits, sortedVisits.dropFirst()) {
                guard let departure = pair.0.departureDate,
                      pair.1.arrivalDate >= departure else { continue }
                if pair.1.arrivalDate == departure {
                    let endpointSeparation = distance(pair.0.coordinate, pair.1.coordinate)
                    let uncertaintyRadius = max(
                        120,
                        max(pair.0.horizontalAccuracy, pair.1.horizontalAccuracy)
                    )
                    guard endpointSeparation > uncertaintyRadius else { continue }
                }
                var route = sortedPoints.filter {
                    $0.timestamp >= departure && $0.timestamp <= pair.1.arrivalDate
                }.map(\.coordinate)
                if route.first != pair.0.coordinate { route.insert(pair.0.coordinate, at: 0) }
                if route.last != pair.1.coordinate { route.append(pair.1.coordinate) }
                entries.append(journey(
                    start: departure,
                    end: pair.1.arrivalDate,
                    route: route,
                    observations: sortedPoints.filter {
                        $0.timestamp >= departure && $0.timestamp <= pair.1.arrivalDate
                    },
                    hasInferredBoundary: pair.0.inferredDepartureUpperBound != nil
                ))
            }
        } else if sortedPoints.count >= 2 {
            let route = compactRoute(sortedPoints.map(\.coordinate))
            let routeDistance = distance(of: route)
            if routeDistance >= 120 {
                entries.append(journey(
                    start: sortedPoints.first!.timestamp,
                    end: sortedPoints.last!.timestamp,
                    route: route,
                    observations: sortedPoints
                ))
            } else if sortedVisits.isEmpty, let last = sortedPoints.last {
                let savedPlace = closestSavedPlace(
                    to: last.coordinate,
                    horizontalAccuracy: last.horizontalAccuracy,
                    places: savedPlaces
                )
                let placeLabel = savedPlace == nil && savedPlaces.isEmpty ? closestPlaceLabel(
                    to: last.coordinate,
                    within: 120,
                    labels: placeLabels
                ) : nil
                let isHome = savedPlace?.isHome ?? placeLabel?.isHome
                    ?? homeCoordinate.map { distance($0, last.coordinate) <= 120 }
                    ?? false
                entries.append(BlipTimelineEntry(
                    id: stableID(prefix: "place", date: sortedPoints.first!.timestamp),
                    kind: .visit,
                    title: savedPlace?.title ?? placeLabel?.title ?? (isHome ? "Home" : "Current place"),
                    subtitle: savedPlace?.subtitle ?? placeLabel?.subtitle,
                    startDate: sortedPoints.first!.timestamp,
                    endDate: sortedPoints.last!.timestamp,
                    coordinate: last.coordinate,
                    confidence: .inferred,
                    isHome: isHome,
                    placeID: savedPlace?.id,
                    placeCoordinate: savedPlace?.mapCoordinate,
                    mapItemIdentifier: savedPlace?.mapItemIdentifier,
                    placeCategory: savedPlace?.pointOfInterestCategory,
                    placeIcon: savedPlace?.iconSystemName,
                    residentContacts: savedPlace?.residentContacts ?? []
                ))
            }
        }

        let coverage: BlipTimelineCoverage = dateKey == BlipTimelineDay.makeDateKey(
            now,
            timeZoneIdentifier: zoneID
        ) ? .partial : .complete
        let ordered = entries.sorted { $0.startDate < $1.startDate }
        return BlipTimelineDay(
            date: date,
            dateKey: dateKey,
            timeZoneIdentifier: zoneID,
            coverage: coverage,
            entries: ordered,
            metrics: BlipTimelineStore.metrics(for: ordered),
            updatedAt: Date(),
            sourceDeviceID: sourceDeviceID
        )
    }

    private static func journey(
        start: Date,
        end: Date,
        route: [BlipTimelineCoordinate],
        observations: [BlipTimelineLocationObservation],
        hasInferredBoundary: Bool = false
    ) -> BlipTimelineEntry {
        let mode = dominantMode(observations)
        return BlipTimelineEntry(
            id: stableID(prefix: "journey", date: start),
            kind: .journey,
            title: mode.title,
            startDate: start,
            endDate: end,
            route: compactRoute(route),
            distanceMeters: distance(of: route),
            transportMode: mode,
            confidence: observations.count >= 3 && !hasInferredBoundary ? .observed : .inferred
        )
    }

    private static func dominantMode(
        _ observations: [BlipTimelineLocationObservation]
    ) -> BlipTimelineTransportMode {
        var counts: [BlipTimelineTransportMode: Int] = [:]
        for observation in observations {
            var mode = observation.motion.transportMode
            if mode == .unknown {
                switch observation.speedMetersPerSecond {
                case 1.2..<3.4: mode = .walking
                case 3.4..<8: mode = .cycling
                case 8...: mode = .driving
                default: break
                }
            }
            counts[mode, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? .unknown
    }

    private static func compactRoute(
        _ route: [BlipTimelineCoordinate]
    ) -> [BlipTimelineCoordinate] {
        guard route.count > 2 else { return route }
        var result = [route[0]]
        for point in route.dropFirst().dropLast() where distance(result.last!, point) >= 35 {
            result.append(point)
        }
        result.append(route.last!)
        return result
    }

    private static func distance(of route: [BlipTimelineCoordinate]) -> Double {
        zip(route, route.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    private static func distance(
        _ first: BlipTimelineCoordinate,
        _ second: BlipTimelineCoordinate
    ) -> Double {
        BlipTimelineGeometry.distanceMeters(first, second)
    }

    private static func closestPlaceLabel(
        to coordinate: BlipTimelineCoordinate,
        within radius: Double,
        labels: [BlipTimelinePlaceLabel]
    ) -> BlipTimelinePlaceLabel? {
        labels
            .map { ($0, distance($0.coordinate, coordinate)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?
            .0
    }

    private static func closestSavedPlace(
        to coordinate: BlipTimelineCoordinate,
        horizontalAccuracy: Double,
        places: [BlipTimelineSavedPlace]
    ) -> BlipTimelineSavedPlace? {
        let matches = places.compactMap { place -> (BlipTimelineSavedPlace, Double)? in
            let measuredDistance = distance(place.coordinate, coordinate)
            let accuracyAllowance = min(max(horizontalAccuracy, 0), 80)
            let radius = max(place.recognitionRadiusMeters, accuracyAllowance)
            return measuredDistance <= radius ? (place, measuredDistance) : nil
        }.sorted { $0.1 < $1.1 }
        guard let closest = matches.first else { return nil }
        if matches.count > 1, matches[1].1 - closest.1 < 20 {
            // Adjacent POIs are ambiguous. Keep the generic visit until the
            // person confirms which business they actually visited.
            return nil
        }
        return closest.0
    }

    private static func date(from key: String, timeZoneIdentifier: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
        return calendar.date(from: DateComponents(
            year: parts[0],
            month: parts[1],
            day: parts[2]
        ))
    }

    private static func stableID(prefix: String, date: Date) -> String {
        "\(prefix)-\(Int64(date.timeIntervalSince1970 * 1_000))"
    }

    static func visitEntryID(
        for visit: BlipTimelineVisitObservation,
        dateKey: String
    ) -> String {
        let base = "visit-\(visit.id.uuidString.lowercased())"
        return visit.dateKey == dateKey ? base : "\(base)-\(dateKey)"
    }
}

private extension BlipTimelineTransportMode {
    var title: String {
        switch self {
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .driving: "Driving"
        case .transit: "Transit"
        case .train: "Train"
        case .ferry: "Ferry"
        case .flight: "Flight"
        case .unknown: "Journey"
        }
    }
}

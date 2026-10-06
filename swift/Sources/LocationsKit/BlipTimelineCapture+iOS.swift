#if os(iOS)
@preconcurrency import CoreLocation
@preconcurrency import CoreMotion
import Foundation
@preconcurrency import UIKit

/// A tiny launch-time seam for Core Location. Apple gives a relaunched app only
/// a short window to recreate outstanding sessions, so this intentionally does
/// not construct Blip's conversations, cloud runtime, or full application model.
@MainActor
public enum BlipTimelineAutomaticCaptureBootstrap {
    private static let trackingEnabledKey = "locations.timeline.automaticCaptureEnabled"

    public static func restoreAfterLaunch(defaults: UserDefaults = .standard) {
        let enabled: Bool
        if let stored = defaults.object(forKey: trackingEnabledKey) as? Bool {
            enabled = stored
        } else {
            enabled = BlipTimelinePersistence.applicationSupport().load().trackingEnabled
            defaults.set(enabled, forKey: trackingEnabledKey)
        }
        BlipTimelineCaptureController.shared.restoreAfterLaunch(
            trackingEnabled: enabled
        )
    }

    public static func prepareForegroundCapture() {
        BlipTimelineCaptureController.shared.prepareForegroundCapture()
    }

    static func persistTrackingEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: trackingEnabledKey)
    }
}

/// Combines low-cost visit/significant-change monitoring with adaptive route
/// capture. Confirmed drives keep a denser standard-location session alive;
/// other movement remains coarse and short-lived.
@MainActor
final class BlipTimelineCaptureController: NSObject, CLLocationManagerDelegate {
    static let shared = BlipTimelineCaptureController()

    private enum SamplingProfile: Equatable {
        case lowPower
        case movementProbe
        case drivingOnBattery
        case drivingWhileCharging
    }

    private enum LiveUpdateSource {
        case lowPower
        case denseDrive
    }

    private struct DiagnosticBlockers {
        var permissionDenied = false
        var insufficientlyInUse = false
        var serviceSessionRequired = false
        var alwaysAuthorizationDenied = false
        var accuracyLimited = false
        var authorizationRequestInProgress = false
    }

    private static let observationFlushInterval: TimeInterval = 10
    private static let maximumBufferedObservationCount = 12

    weak var sink: BlipTimelineStore?

    private let manager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private var currentMotion = BlipTimelineMotionMode.unknown
    private var driveDetection = BlipTimelineDriveDetection()
    private var drivePromotion = BlipTimelineDrivePromotion()
    private var observationRetention = BlipTimelineObservationRetention()
    private var trackingRequested = false
    private var burstDeadline: Date?
    private var burstMonitorTask: Task<Void, Never>?
    private var observationFlushTask: Task<Void, Never>?
    private var pendingObservations: [BlipTimelineLocationObservation] = []
    private var pendingVisits: [BlipTimelineVisitReading] = []
    private let pendingCaptureSpool = BlipTimelinePendingCaptureSpool()
    private var samplingProfile: SamplingProfile?
    private var serviceSession: CLServiceSession?
    private var serviceDiagnosticTask: Task<Void, Never>?
    /// The low-power automatic anchor. This remains outstanding so Core
    /// Location can pause it at home and resume/relaunch Blip on movement.
    private var liveUpdateTask: Task<Void, Never>?
    /// The expensive automotive stream. It exists only while a drive has been
    /// confirmed and is cancelled as soon as Blip returns to idle monitoring.
    private var denseDriveUpdateTask: Task<Void, Never>?
    private var serviceDiagnostic: DiagnosticBlockers?
    private var updaterDiagnostic: DiagnosticBlockers?
    private var hasReceivedUpdaterDiagnostic = false
    private var continuousDeliveryStartedInForeground = false
    private var significantChangeMonitoringStarted = false
    private var suppressInitialStationarySignificantChange = false
    private var isBursting = false
    private var motionUpdatesStarted = false
    private var movementProbeTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        UIDevice.current.isBatteryMonitoringEnabled = true
        applySamplingProfile(.lowPower)
    }

    func restoreAfterLaunch(trackingEnabled: Bool) {
        trackingRequested = trackingEnabled
        if trackingEnabled {
            resumeIfAuthorized()
        } else {
            stopTracking()
        }
    }

    func prepareForegroundCapture() {
        guard trackingRequested else { return }
        resumeIfAuthorized()
    }

    func attach(to sink: BlipTimelineStore, trackingEnabled: Bool) {
        self.sink = sink
        observationRetention.seedIfNeeded(with: sink.ledger.observations.last)
        trackingRequested = trackingEnabled
        BlipTimelineAutomaticCaptureBootstrap.persistTrackingEnabled(trackingEnabled)
        if trackingEnabled {
            resumeIfAuthorized()
        }
        let recovered = pendingCaptureSpool.load()
        if !recovered.observations.isEmpty {
            sink.ingest(recovered.observations)
        }
        for visit in recovered.visits {
            ingestVisit(visit, into: sink)
        }
        // Ingest persists before returning. Keep the spool if disk persistence
        // failed so the next launch can retry; duplicate ingestion is safe.
        if !recovered.isEmpty, sink.persistenceError == nil {
            pendingCaptureSpool.clear()
        }
        flushPendingObservations()
        let visits = pendingVisits
        pendingVisits.removeAll(keepingCapacity: true)
        for visit in visits {
            ingestVisit(makeVisitObservation(from: visit), into: sink)
        }
        if trackingEnabled {
            publishBackgroundCaptureStatus()
        } else {
            // The tiny launch flag and the ledger can briefly disagree after a
            // crash. Recover already delivered data first; then ledger-off is
            // authoritative and tears down the stale restored pipeline.
            stopTracking(preservePendingCapture: sink.persistenceError != nil)
        }
    }

    func enableTracking() {
        trackingRequested = true
        BlipTimelineAutomaticCaptureBootstrap.persistTrackingEnabled(true)
        switch manager.authorizationStatus {
        case .notDetermined:
            sink?.updateCaptureState(.requestingPermission, isActive: false)
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            sink?.updateCaptureState(.whenInUseOnly, isActive: false)
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            startLowPowerMonitoring()
        case .denied, .restricted:
            sink?.updateCaptureState(.denied, isActive: false)
        @unknown default:
            sink?.updateCaptureState(.unavailable, isActive: false)
        }
    }

    func resumeIfAuthorized() {
        guard trackingRequested else {
            stopTracking()
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            startLowPowerMonitoring()
        case .authorizedWhenInUse:
            sink?.updateCaptureState(.whenInUseOnly, isActive: false)
        case .notDetermined:
            sink?.updateCaptureState(.requestingPermission, isActive: false)
        case .denied, .restricted:
            sink?.updateCaptureState(.denied, isActive: false)
        @unknown default:
            sink?.updateCaptureState(.unavailable, isActive: false)
        }
    }

    func refreshAuthorizationState() {
        guard trackingRequested else {
            sink?.updateCaptureState(.stopped, isActive: false)
            return
        }
        resumeIfAuthorized()
    }

    func stopTracking(preservePendingCapture: Bool = false) {
        trackingRequested = false
        BlipTimelineAutomaticCaptureBootstrap.persistTrackingEnabled(false)
        flushPendingObservations()
        pendingObservations.removeAll(keepingCapacity: false)
        pendingVisits.removeAll(keepingCapacity: false)
        if !preservePendingCapture {
            pendingCaptureSpool.clear()
        }
        invalidateContinuousBackgroundDelivery()
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        significantChangeMonitoringStarted = false
        suppressInitialStationarySignificantChange = false
        stopMotionUpdates()
        burstMonitorTask?.cancel()
        burstMonitorTask = nil
        burstDeadline = nil
        driveDetection.reset()
        drivePromotion.reset()
        observationRetention.reset()
        applySamplingProfile(.lowPower)
        isBursting = false
        movementProbeTask?.cancel()
        movementProbeTask = nil
        sink?.updateCaptureState(.stopped, isActive: false)
        sink?.updateBackgroundCaptureStatus(.unavailable)
    }

    private func startLowPowerMonitoring() {
        guard CLLocationManager.locationServicesEnabled() else {
            sink?.updateCaptureState(.unavailable, isActive: false)
            return
        }
        manager.startMonitoringVisits()
        if CLLocationManager.significantLocationChangeMonitoringAvailable(),
           !significantChangeMonitoringStarted {
            // Core Location commonly emits the current fix immediately when
            // significant-change monitoring is registered. Treat that first
            // foreground, stationary fix as initialization rather than as a
            // movement wake-up, otherwise merely opening Blip at home powers a
            // live GPS burst for several minutes.
            suppressInitialStationarySignificantChange =
                UIApplication.shared.applicationState == .active
            manager.startMonitoringSignificantLocationChanges()
            significantChangeMonitoringStarted = true
        }
        if !isBursting {
            driveDetection.reset()
            applySamplingProfile(.lowPower)
        }
        // Keep only the low-power stream outstanding while idle. The denser
        // automotive stream is a separate, drive-scoped task so opening Blip
        // at home cannot leave navigation-grade GPS running all day.
        primeContinuousBackgroundLocationDelivery()
        sink?.updateCaptureState(.active, isActive: isBursting)
    }

    /// Establish the resumable automatic Core Location pipeline. This method is
    /// deliberately idempotent because it runs during initial launch, Core
    /// Location background relaunch, and later foreground transitions.
    private func primeContinuousBackgroundLocationDelivery() {
        let isForeground = UIApplication.shared.applicationState == .active
        if isForeground, !continuousDeliveryStartedInForeground {
            invalidateContinuousBackgroundDelivery()
        }
        let isCreatingPipeline = serviceSession == nil
        if serviceSession == nil {
            startServiceSession()
        }
        if isCreatingPipeline {
            continuousDeliveryStartedInForeground = isForeground
        }
        startLiveUpdatesIfNeeded()
    }

    private func startServiceSession() {
        serviceDiagnostic = nil
        sink?.updateBackgroundCaptureStatus(.checking)
        let session = CLServiceSession(authorization: .always)
        serviceSession = session
        serviceDiagnosticTask?.cancel()
        serviceDiagnosticTask = Task { @MainActor [weak self] in
            do {
                for try await diagnostic in session.diagnostics {
                    guard !Task.isCancelled else { return }
                    self?.serviceDiagnostic = DiagnosticBlockers(
                        permissionDenied: diagnostic.authorizationDenied
                            || diagnostic.authorizationDeniedGlobally
                            || diagnostic.authorizationRestricted,
                        insufficientlyInUse: diagnostic.insufficientlyInUse,
                        serviceSessionRequired: diagnostic.serviceSessionRequired,
                        alwaysAuthorizationDenied: diagnostic.alwaysAuthorizationDenied,
                        accuracyLimited: diagnostic.fullAccuracyDenied,
                        authorizationRequestInProgress: diagnostic.authorizationRequestInProgress
                    )
                    self?.publishBackgroundCaptureStatus()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.sink?.updateBackgroundCaptureStatus(.unavailable)
            }
        }
    }

    private func startLiveUpdatesIfNeeded() {
        guard manager.authorizationStatus == .authorizedAlways,
              trackingRequested,
              serviceSession != nil,
              liveUpdateTask == nil else { return }
        let configuration = CLLocationUpdate.LiveConfiguration.default
        updaterDiagnostic = nil
        hasReceivedUpdaterDiagnostic = false
        sink?.updateBackgroundCaptureStatus(.checking)
        liveUpdateTask = Task { @MainActor [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(configuration) {
                    guard !Task.isCancelled, let self else { return }
                    self.hasReceivedUpdaterDiagnostic = true
                    self.updaterDiagnostic = DiagnosticBlockers(
                        permissionDenied: update.authorizationDenied
                            || update.authorizationDeniedGlobally
                            || update.authorizationRestricted,
                        insufficientlyInUse: update.insufficientlyInUse,
                        serviceSessionRequired: update.serviceSessionRequired,
                        accuracyLimited: update.accuracyLimited,
                        authorizationRequestInProgress: update.authorizationRequestInProgress
                    )
                    self.publishBackgroundCaptureStatus()
                    let reading = update.location.map {
                        BlipTimelineLocationReading(
                            timestamp: $0.timestamp,
                            coordinate: .init(
                                latitude: $0.coordinate.latitude,
                                longitude: $0.coordinate.longitude
                            ),
                            horizontalAccuracy: $0.horizontalAccuracy,
                            speedMetersPerSecond: $0.speed
                        )
                    }
                    self.handleLiveUpdate(
                        reading,
                        stationary: update.stationary,
                        source: .lowPower
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
            // A live sequence can finish without throwing. Clear the completed
            // task in both cases or the idempotence guard would prevent the
            // automatic pipeline from ever being recreated.
            guard !Task.isCancelled else { return }
            self?.liveUpdateTask = nil
            self?.sink?.updateBackgroundCaptureStatus(.unavailable)
            self?.scheduleLiveUpdateRestart()
        }
    }

    private func scheduleLiveUpdateRestart() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self,
                  self.trackingRequested else { return }
            self.startLiveUpdatesIfNeeded()
        }
    }

    private func startDenseDriveUpdatesIfNeeded() {
        guard manager.authorizationStatus == .authorizedAlways,
              trackingRequested,
              isBursting,
              serviceSession != nil,
              denseDriveUpdateTask == nil else { return }
        denseDriveUpdateTask = Task { @MainActor [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                    guard !Task.isCancelled, let self else { return }
                    let reading = update.location.map {
                        BlipTimelineLocationReading(
                            timestamp: $0.timestamp,
                            coordinate: .init(
                                latitude: $0.coordinate.latitude,
                                longitude: $0.coordinate.longitude
                            ),
                            horizontalAccuracy: $0.horizontalAccuracy,
                            speedMetersPerSecond: $0.speed
                        )
                    }
                    self.handleLiveUpdate(
                        reading,
                        stationary: update.stationary,
                        source: .denseDrive
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            self?.denseDriveUpdateTask = nil
            guard let self, self.isBursting else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.startDenseDriveUpdatesIfNeeded()
            }
        }
    }

    private func handleLiveUpdate(
        _ reading: BlipTimelineLocationReading?,
        stationary: Bool,
        source: LiveUpdateSource
    ) {
        if stationary {
            handleAutomaticPause(reading)
            return
        }
        guard let reading else { return }
        switch source {
        case .lowPower:
            handleLowPowerLocation(reading)
        case .denseDrive:
            handleLocations(
                [reading],
                beginMovementBurstIfNeeded: false
            )
        }
    }

    private func handleLowPowerLocation(_ reading: BlipTimelineLocationReading) {
        handleLocations(
            [reading],
            beginMovementBurstIfNeeded: false
        )
        guard !isBursting else { return }
        beginMovementProbe()
        let effectiveMotion = currentMotion
        let observation = BlipTimelineLocationObservation(
            id: UUID(),
            timestamp: reading.timestamp,
            coordinate: reading.coordinate,
            horizontalAccuracy: reading.horizontalAccuracy,
            speedMetersPerSecond: effectiveMotion == .stationary
                ? 0
                : max(0, reading.speedMetersPerSecond),
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            motion: effectiveMotion
        )
        if drivePromotion.observe(
            observation,
            isCharging: isDeviceCharging
        ) {
            beginMovementBurst()
        }
    }

    private var isDeviceCharging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full:
            true
        case .unknown, .unplugged:
            false
        @unknown default:
            false
        }
    }

    private func beginMovementProbe(duration: TimeInterval = 2 * 60) {
        guard trackingRequested, !isBursting else { return }
        applySamplingProfile(.movementProbe)
        startMotionUpdates()
        movementProbeTask?.cancel()
        movementProbeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, !self.isBursting else { return }
            self.stopMovementProbe()
        }
    }

    private func stopMovementProbe() {
        movementProbeTask?.cancel()
        movementProbeTask = nil
        drivePromotion.reset()
        if !isBursting {
            stopMotionUpdates()
            applySamplingProfile(.lowPower)
        }
    }

    private func publishBackgroundCaptureStatus() {
        let diagnostics = [serviceDiagnostic, updaterDiagnostic]
            .compactMap { $0 }
        let status: BlipTimelineBackgroundCaptureStatus
        if diagnostics.contains(where: { $0.permissionDenied }) {
            status = .permissionDenied
        } else if diagnostics.contains(where: { $0.alwaysAuthorizationDenied }) {
            status = .alwaysPermissionNeeded
        } else if diagnostics.contains(where: { $0.insufficientlyInUse }) {
            status = .needsForegroundUse
        } else if diagnostics.contains(where: { $0.serviceSessionRequired }) {
            status = .serviceSessionMissing
        } else if diagnostics.contains(where: { $0.accuracyLimited }) {
            status = .accuracyLimited
        } else if diagnostics.contains(where: { $0.authorizationRequestInProgress }) {
            status = .checking
        } else if serviceSession != nil, liveUpdateTask != nil,
                  hasReceivedUpdaterDiagnostic {
            status = .ready
        } else {
            status = .checking
        }
        sink?.updateBackgroundCaptureStatus(status)
    }

    private func invalidateContinuousBackgroundDelivery() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
        denseDriveUpdateTask?.cancel()
        denseDriveUpdateTask = nil
        serviceDiagnosticTask?.cancel()
        serviceDiagnosticTask = nil
        serviceSession?.invalidate()
        serviceSession = nil
        serviceDiagnostic = nil
        updaterDiagnostic = nil
        hasReceivedUpdaterDiagnostic = false
        continuousDeliveryStartedInForeground = false
    }

    private func beginMovementBurst(minimumDuration: TimeInterval = 180) {
        guard manager.authorizationStatus == .authorizedAlways,
              trackingRequested else { return }
        let now = Date()
        burstDeadline = max(burstDeadline ?? .distantPast, now.addingTimeInterval(minimumDuration))
        if !isBursting {
            isBursting = true
            movementProbeTask?.cancel()
            movementProbeTask = nil
            refreshSamplingProfile(at: now)
            startMotionUpdates()
            primeContinuousBackgroundLocationDelivery()
            startDenseDriveUpdatesIfNeeded()
            sink?.updateCaptureState(.active, isActive: true)
        } else {
            refreshSamplingProfile(at: now)
        }
        guard burstMonitorTask == nil else { return }
        burstMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                self.refreshSamplingProfile(at: now)
                if self.driveDetection.hasSustainedStationary(at: now)
                    || now >= self.burstDeadline ?? .distantPast {
                    self.endMovementBurst()
                    return
                }
            }
        }
    }

    private func endMovementBurst() {
        flushPendingObservations()
        denseDriveUpdateTask?.cancel()
        denseDriveUpdateTask = nil
        stopMotionUpdates()
        burstMonitorTask?.cancel()
        burstMonitorTask = nil
        burstDeadline = nil
        driveDetection.reset()
        drivePromotion.reset()
        applySamplingProfile(.lowPower)
        isBursting = false
        sink?.updateCaptureState(.active, isActive: false)
    }

    private func applySamplingProfile(_ profile: SamplingProfile) {
        guard samplingProfile != profile else { return }
        samplingProfile = profile
        switch profile {
        case .lowPower:
            manager.activityType = .other
            // The resumable live-update sequence remains outstanding, but Core
            // Location owns its stationary pause. These manager settings only
            // apply to the visit/significant-change fallback path.
            manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            manager.distanceFilter = 500
            manager.pausesLocationUpdatesAutomatically = false
        case .movementProbe:
            manager.activityType = .other
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 80
            manager.pausesLocationUpdatesAutomatically = false
        case .drivingOnBattery:
            manager.activityType = .automotiveNavigation
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 75
            manager.pausesLocationUpdatesAutomatically = false
        case .drivingWhileCharging:
            manager.activityType = .automotiveNavigation
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 50
            manager.pausesLocationUpdatesAutomatically = false
        }
        // Sampling profiles drive classification and UI state. The automatic
        // Core Location sequence itself remains outstanding across every
        // profile so the system can pause and resume it without a handoff gap.
        startLiveUpdatesIfNeeded()
    }

    private func refreshSamplingProfile(at date: Date = Date()) {
        guard driveDetection.isAutomotive(at: date) else {
            applySamplingProfile(isBursting ? .movementProbe : .lowPower)
            return
        }
        switch UIDevice.current.batteryState {
        case .charging, .full:
            applySamplingProfile(.drivingWhileCharging)
        case .unknown, .unplugged:
            applySamplingProfile(.drivingOnBattery)
        @unknown default:
            applySamplingProfile(.drivingOnBattery)
        }
    }

    private func startMotionUpdates() {
        guard CMMotionActivityManager.isActivityAvailable(),
              !motionUpdatesStarted else { return }
        motionUpdatesStarted = true
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            let mode: BlipTimelineMotionMode
            if activity.cycling {
                mode = .cycling
            } else if activity.walking || activity.running {
                mode = .walking
            } else if activity.automotive {
                mode = .automotive
            } else if activity.stationary {
                mode = .stationary
            } else {
                mode = .unknown
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentMotion = mode
                let now = Date()
                self.driveDetection.observe(
                    motion: mode,
                    speedMetersPerSecond: 0,
                    at: now
                )
                if mode == .automotive, !self.isBursting {
                    self.beginMovementBurst()
                } else if self.driveDetection.isAutomotive(at: now) {
                    self.burstDeadline = max(
                        self.burstDeadline ?? .distantPast,
                        self.driveDetection.automotiveUntil ?? .distantPast
                    )
                } else if !self.isBursting,
                          mode == .walking || mode == .cycling {
                    self.stopMovementProbe()
                }
                self.refreshSamplingProfile(at: now)
            }
        }
    }

    private func stopMotionUpdates() {
        guard motionUpdatesStarted else {
            currentMotion = .unknown
            return
        }
        motionManager.stopActivityUpdates()
        motionUpdatesStarted = false
        currentMotion = .unknown
    }

    private func enqueue(_ observations: [BlipTimelineLocationObservation]) {
        guard !observations.isEmpty else { return }
        if sink == nil,
           pendingCaptureSpool.append(observations: observations) {
            return
        }
        pendingObservations.append(contentsOf: observations)
        if pendingObservations.count >= Self.maximumBufferedObservationCount {
            flushPendingObservations()
            return
        }
        guard observationFlushTask == nil else { return }
        observationFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.observationFlushInterval))
            guard !Task.isCancelled else { return }
            self?.flushPendingObservations()
        }
    }

    private func flushPendingObservations() {
        observationFlushTask?.cancel()
        observationFlushTask = nil
        guard !pendingObservations.isEmpty, let sink else { return }
        let observations = pendingObservations
        pendingObservations.removeAll(keepingCapacity: true)
        sink.ingest(observations)
    }

    private func handleLocations(
        _ locations: [BlipTimelineLocationReading],
        beginMovementBurstIfNeeded: Bool = true
    ) {
        guard trackingRequested else { return }
        let now = Date()
        let recent = locations.filter {
            $0.horizontalAccuracy >= 0
                && $0.horizontalAccuracy <= kCLLocationAccuracyThreeKilometers
                && abs($0.timestamp.timeIntervalSince(now)) <= 5 * 60
        }
        guard !recent.isEmpty else { return }
        // Classify the wake-up readings before starting a burst so a drive uses
        // the automotive profile from its first standard-location request.
        for reading in recent {
            let speed = currentMotion == .stationary
                ? 0
                : max(0, reading.speedMetersPerSecond)
            driveDetection.observe(
                motion: currentMotion,
                speedMetersPerSecond: speed,
                at: reading.timestamp
            )
        }
        if beginMovementBurstIfNeeded, !isBursting { beginMovementBurst() }
        // Coarse fixes can wake and promote the session, but only useful route
        // geometry belongs in the Timeline ledger.
        let valid = recent.filter { $0.horizontalAccuracy <= 250 }
        guard !valid.isEmpty else { return }
        var candidates: [BlipTimelineLocationObservation] = []
        for reading in valid {
            let speed = currentMotion == .stationary
                ? 0
                : max(0, reading.speedMetersPerSecond)
            if driveDetection.isAutomotive(at: now) {
                burstDeadline = max(
                    burstDeadline ?? .distantPast,
                    driveDetection.automotiveUntil ?? .distantPast
                )
            } else if speed >= BlipTimelineDriveDetection.minimumMovementSpeed
                || currentMotion == .walking || currentMotion == .cycling {
                burstDeadline = max(
                    burstDeadline ?? .distantPast,
                    now.addingTimeInterval(3 * 60)
                )
            }
            candidates.append(BlipTimelineLocationObservation(
                id: UUID(),
                timestamp: reading.timestamp,
                coordinate: reading.coordinate,
                horizontalAccuracy: reading.horizontalAccuracy,
                speedMetersPerSecond: speed,
                timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
                motion: currentMotion
            ))
        }
        refreshSamplingProfile(at: now)
        enqueue(observationRetention.retaining(candidates))
    }

    /// Core Location sends a stationary update before it suspends this same
    /// live-update sequence. Persist the final useful fix and wind down only
    /// Blip's classification work. The service session and update task must
    /// remain alive so iOS can resume or relaunch Blip on the next movement.
    private func handleAutomaticPause(_ reading: BlipTimelineLocationReading?) {
        if let reading {
            handleLocations(
                [reading],
                beginMovementBurstIfNeeded: false
            )
        }
        flushPendingObservations()
        if isBursting {
            endMovementBurst()
        } else {
            stopMovementProbe()
            driveDetection.reset()
            sink?.updateCaptureState(.active, isActive: false)
        }
    }

    private func handleSignificantChangeLocations(
        _ locations: [BlipTimelineLocationReading]
    ) {
        if suppressInitialStationarySignificantChange {
            suppressInitialStationarySignificantChange = false
            let isStationary = locations.allSatisfy {
                max(0, $0.speedMetersPerSecond)
                    < BlipTimelineDriveDetection.minimumMovementSpeed
            }
            if UIApplication.shared.applicationState == .active, isStationary {
                return
            }
        }
        for location in locations {
            handleLowPowerLocation(location)
        }
    }

    private func handleVisit(_ reading: BlipTimelineVisitReading) {
        guard trackingRequested else { return }
        let observation = makeVisitObservation(from: reading)
        guard let sink else {
            if !pendingCaptureSpool.append(visits: [observation]) {
                pendingVisits.append(reading)
            }
            return
        }
        flushPendingObservations()
        ingestVisit(observation, into: sink)
    }

    private func makeVisitObservation(
        from reading: BlipTimelineVisitReading
    ) -> BlipTimelineVisitObservation {
        BlipTimelineVisitObservation(
            id: UUID(),
            arrivalDate: reading.arrivalDate,
            departureDate: reading.departureDate,
            coordinate: reading.coordinate,
            horizontalAccuracy: reading.horizontalAccuracy,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        )
    }

    private func ingestVisit(
        _ observation: BlipTimelineVisitObservation,
        into sink: BlipTimelineStore
    ) {
        let storedVisit = sink.ingest(observation)
        resolvePlaceName(
            for: BlipTimelineVisitReading(
                arrivalDate: observation.arrivalDate,
                departureDate: observation.departureDate,
                coordinate: observation.coordinate,
                horizontalAccuracy: observation.horizontalAccuracy
            ),
            entryID: BlipTimelineDayBuilder.visitEntryID(
                for: storedVisit,
                dateKey: storedVisit.dateKey
            )
        )
        // An arrival confirms that we have stopped and should remain on the
        // low-power monitors. A departure is the movement signal that merits a
        // short live-location probe.
        if observation.departureDate != nil {
            beginMovementProbe(duration: 120)
        }
    }

    private func resolvePlaceName(for reading: BlipTimelineVisitReading, entryID: String) {
        let location = CLLocation(
            latitude: reading.coordinate.latitude,
            longitude: reading.coordinate.longitude
        )
        Task { @MainActor [weak self] in
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
                  let title = placemark.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return }
            let area = [placemark.subLocality, placemark.locality]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0 != title }
            self?.sink?.applyInferredPlaceName(
                entryID: entryID,
                title: title,
                subtitle: area
            )
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.trackingRequested {
                self.resumeIfAuthorized()
            } else {
                self.refreshAuthorizationState()
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let readings = locations.map {
            BlipTimelineLocationReading(
                timestamp: $0.timestamp,
                coordinate: .init(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude
                ),
                horizontalAccuracy: $0.horizontalAccuracy,
                speedMetersPerSecond: $0.speed
            )
        }
        Task { @MainActor [weak self] in
            self?.handleSignificantChangeLocations(readings)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard visit.arrivalDate != .distantPast else { return }
        let reading = BlipTimelineVisitReading(
            arrivalDate: visit.arrivalDate,
            departureDate: visit.departureDate == .distantFuture ? nil : visit.departureDate,
            coordinate: .init(
                latitude: visit.coordinate.latitude,
                longitude: visit.coordinate.longitude
            ),
            horizontalAccuracy: visit.horizontalAccuracy
        )
        Task { @MainActor [weak self] in self?.handleVisit(reading) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code == .denied else { return }
        Task { @MainActor [weak self] in
            self?.sink?.updateCaptureState(.denied, isActive: false)
        }
    }
}

private struct BlipTimelineLocationReading: Sendable {
    let timestamp: Date
    let coordinate: BlipTimelineCoordinate
    let horizontalAccuracy: Double
    let speedMetersPerSecond: Double
}

private struct BlipTimelineVisitReading: Sendable {
    let arrivalDate: Date
    let departureDate: Date?
    let coordinate: BlipTimelineCoordinate
    let horizontalAccuracy: Double
}

#endif

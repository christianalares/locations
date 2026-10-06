import CoreLocation
import SwiftUI
import UIKit

@MainActor
final class LocationsLocationPermissions: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization
    @Published private(set) var servicesEnabled: Bool
    @Published private(set) var requestedAlways: Bool
    @Published private(set) var requestedPrecise: Bool

    private static let requestedAlwaysKey = "locations.permissions.requestedAlways"
    private static let requestedPreciseKey = "locations.permissions.requestedPrecise"
    private let manager: CLLocationManager
    private var requestAlwaysAfterWhenInUse = false

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        servicesEnabled = CLLocationManager.locationServicesEnabled()
        requestedAlways = UserDefaults.standard.bool(forKey: Self.requestedAlwaysKey)
        requestedPrecise = UserDefaults.standard.bool(forKey: Self.requestedPreciseKey)
        super.init()
        manager.delegate = self
    }

    var isReady: Bool {
        servicesEnabled
            && authorizationStatus == .authorizedAlways
            && accuracyAuthorization == .fullAccuracy
    }

    var summary: String {
        guard servicesEnabled else { return "Location Services off" }

        switch authorizationStatus {
        case .notDetermined: return "Access not requested"
        case .denied, .restricted: return "Location access off"
        case .authorizedWhenInUse: return "While Using only"
        case .authorizedAlways:
            return accuracyAuthorization == .fullAccuracy
                ? "Always · Precise"
                : "Always · Approximate"
        @unknown default: return "Location unavailable"
        }
    }

    var attentionTitle: String? {
        guard servicesEnabled else { return "Location Services are off" }

        switch authorizationStatus {
        case .notDetermined: return "Allow location access"
        case .denied, .restricted: return "Location access is off"
        case .authorizedWhenInUse: return "Background access needed"
        case .authorizedAlways:
            return accuracyAuthorization == .reducedAccuracy
                ? "Precise Location needed"
                : nil
        @unknown default: return "Location unavailable"
        }
    }

    var attentionMessage: String {
        guard servicesEnabled else {
            return "Turn on Location Services in iPhone Settings to record new visits and journeys."
        }

        switch authorizationStatus {
        case .notDetermined:
            return "Allow location access so Locations can prepare to record visits and drives."
        case .denied, .restricted:
            return "Allow location access in iPhone Settings to use tracking."
        case .authorizedWhenInUse:
            return "Choose Always to keep recording when your phone is locked."
        case .authorizedAlways:
            return "Turn on Precise Location for useful visits and drive routes."
        @unknown default:
            return "Check your iPhone’s location settings."
        }
    }

    var actionTitle: String {
        guard servicesEnabled else { return "Open iPhone Settings" }

        switch authorizationStatus {
        case .notDetermined: return "Allow location access"
        case .authorizedWhenInUse where !requestedAlways: return "Allow Always access"
        case .authorizedAlways where accuracyAuthorization == .reducedAccuracy && !requestedPrecise:
            return "Allow Precise Location"
        default: return "Open iPhone Settings"
        }
    }

    func refresh() {
        servicesEnabled = CLLocationManager.locationServicesEnabled()
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
    }

    func promptOnLaunchIfNeeded() {
        refresh()
        guard servicesEnabled else { return }

        switch authorizationStatus {
        case .notDetermined:
            requestWhenInUseThenAlways()
        case .authorizedWhenInUse:
            requestAlwaysIfNeeded()
        case .authorizedAlways:
            requestPreciseIfNeeded()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func requestNeededAccess() {
        refresh()
        guard servicesEnabled else {
            openSettings()
            return
        }

        switch authorizationStatus {
        case .notDetermined:
            requestWhenInUseThenAlways()
        case .authorizedWhenInUse where !requestedAlways:
            requestAlwaysIfNeeded()
        case .authorizedAlways where accuracyAuthorization == .reducedAccuracy && !requestedPrecise:
            requestPreciseIfNeeded()
        case .authorizedWhenInUse, .authorizedAlways, .denied, .restricted:
            openSettings()
        @unknown default:
            openSettings()
        }
    }

    private func requestWhenInUseThenAlways() {
        requestAlwaysAfterWhenInUse = true
        manager.requestWhenInUseAuthorization()
    }

    private func requestAlwaysIfNeeded() {
        guard !requestedAlways else { return }
        requestedAlways = true
        UserDefaults.standard.set(true, forKey: Self.requestedAlwaysKey)
        manager.requestAlwaysAuthorization()
    }

    private func requestPreciseIfNeeded() {
        guard accuracyAuthorization == .reducedAccuracy, !requestedPrecise else { return }
        requestedPrecise = true
        UserDefaults.standard.set(true, forKey: Self.requestedPreciseKey)
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "TimelineCapture") {
            [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refresh()
            if self.requestAlwaysAfterWhenInUse,
               self.authorizationStatus == .authorizedWhenInUse {
                self.requestAlwaysAfterWhenInUse = false
                self.requestAlwaysIfNeeded()
            } else if self.authorizationStatus == .authorizedAlways {
                self.requestPreciseIfNeeded()
            }
        }
    }
}

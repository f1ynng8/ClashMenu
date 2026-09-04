import CoreLocation
import Foundation

@MainActor
final class LocationPermissionService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var onChange: ((CLAuthorizationStatus) -> Void)?
    private var isRequestInFlight = false

    override init() {
        super.init()
        self.manager.delegate = self
    }

    func currentStatus() -> CLAuthorizationStatus {
        self.manager.authorizationStatus
    }

    func requestIfNeeded(onChange: ((CLAuthorizationStatus) -> Void)? = nil) {
        self.onChange = onChange
        guard CLLocationManager.locationServicesEnabled() else { return }

        switch self.manager.authorizationStatus {
        case .notDetermined:
            guard !self.isRequestInFlight else { return }
            self.isRequestInFlight = true
            self.manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            self.manager.startUpdatingLocation()
        case .authorizedAlways, .authorizedWhenInUse, .denied, .restricted:
            onChange?(self.manager.authorizationStatus)
        @unknown default:
            onChange?(self.manager.authorizationStatus)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            if status != .notDetermined {
                self.manager.stopUpdatingLocation()
                self.isRequestInFlight = false
            }
            self.onChange?(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.manager.stopUpdatingLocation()
            self.isRequestInFlight = false
        }
    }
}

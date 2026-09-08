import CoreLocation
import Combine
import Foundation

@MainActor
final class MediaLocationService: NSObject, ObservableObject {
    private let manager = CLLocationManager()
    @Published private var latestLocation: CLLocation?
    private let maximumAge: TimeInterval = 30
    private let maximumHorizontalAccuracy: CLLocationAccuracy = 100

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func prepareForMediaCapture() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func snapshot() -> MediaLocationSnapshot {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return MediaLocationSnapshot(latitude: nil, longitude: nil, horizontalAccuracy: nil, capturedAt: nil, status: .denied)
        case .notDetermined:
            return .unavailable
        case .authorizedAlways, .authorizedWhenInUse:
            break
        @unknown default:
            return .unavailable
        }

        guard let location = latestLocation else {
            return MediaLocationSnapshot(latitude: nil, longitude: nil, horizontalAccuracy: nil, capturedAt: nil, status: .timeout)
        }
        guard abs(location.timestamp.timeIntervalSinceNow) <= maximumAge else {
            return MediaLocationSnapshot(latitude: nil, longitude: nil, horizontalAccuracy: location.horizontalAccuracy, capturedAt: location.timestamp, status: .timeout)
        }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= maximumHorizontalAccuracy else {
            return MediaLocationSnapshot(latitude: nil, longitude: nil, horizontalAccuracy: location.horizontalAccuracy, capturedAt: location.timestamp, status: .lowAccuracy)
        }

        return MediaLocationSnapshot(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            capturedAt: location.timestamp,
            status: .available
        )
    }

    func stop() {
        manager.stopUpdatingLocation()
    }
}

extension MediaLocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.latestLocation = location
        }
    }
}

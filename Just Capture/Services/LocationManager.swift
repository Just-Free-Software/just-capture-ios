import Foundation
import CoreLocation
import MapKit
import Observation

@Observable
class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var currentLocation: CLLocation?
    private(set) var currentAddress: String?
    /// Timestamp of the fix `currentAddress` was geocoded from, so callers can
    /// tell whether the address matches `currentLocation`.
    private(set) var currentAddressDate: Date?
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    /// Returns the current fix only if it was taken within `maxAge` seconds.
    /// An old fix from a previous launch could be miles away, which is worse
    /// than no location in an alert email.
    func freshLocation(maxAge: TimeInterval = 120) -> CLLocation? {
        guard let location = currentLocation, -location.timestamp.timeIntervalSinceNow <= maxAge else { return nil }
        return location
    }
    
    /// The geocoded address, only if it belongs to the given fix.
    func address(for location: CLLocation) -> String? {
        guard currentAddressDate == location.timestamp else { return nil }
        return currentAddress
    }
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // A recording's trail shouldn't stop because iOS thinks you've stopped.
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus
    }

    /// Receives the first usable fix of a recording, then is cleared.
    private var onFirstUsableFix: ((CLLocation) -> Void)?
    /// Newest usable fix, read each time a clip ends. Not observed, because it
    /// changes about once a second and no view shows it.
    @ObservationIgnored private var latestUsableFix: CLLocation?
    private var trackingStartedAt: Date?
    private var lastAddressedFixAt: Date?
    /// Addresses are looked up this often at most while tracking, since Apple
    /// throttles geocoding and only the start address is used.
    private static let trackingAddressInterval: TimeInterval = 60

    func startTracking(onFirstUsableFix: @escaping (CLLocation) -> Void) {
        self.onFirstUsableFix = onFirstUsableFix
        latestUsableFix = nil
        trackingStartedAt = Date()
        lastAddressedFixAt = nil
        manager.startUpdatingLocation()
    }

    /// Keeps the newest fix, because the last clip finishes writing just after
    /// recording stops and still needs a location.
    func stopTracking() {
        onFirstUsableFix = nil
        trackingStartedAt = nil
        manager.stopUpdatingLocation()
    }

    /// Where the phone is now, or nil if there's been no usable fix recently.
    func recentUsableFix() -> CLLocation? {
        guard let latestUsableFix,
              -latestUsableFix.timestamp.timeIntervalSinceNow <= LocationPoint.currentFixMaxAge else { return nil }
        return latestUsableFix
    }

    /// The newest position known, however old, including one iOS remembers
    /// from before this recording. A clip's trail line says if it's not current.
    var lastKnownFix: CLLocation? {
        latestUsableFix ?? manager.location.flatMap { LocationPoint.isUsable($0) ? $0 : nil }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    /// While tracking, only some fixes become `currentLocation`, so that emails
    /// waiting for a location get one whose address has been looked up.
    private func shouldUpdateCurrentLocation(with location: CLLocation) -> Bool {
        guard let trackingStartedAt, let lastAddressedFixAt else { return true }
        // Replace a fix from before recording started as soon as possible.
        if lastAddressedFixAt < trackingStartedAt { return location.timestamp >= trackingStartedAt }
        return location.timestamp.timeIntervalSince(lastAddressedFixAt) >= Self.trackingAddressInterval
    }
    
    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }
    
    func requestLocation() {
        manager.requestLocation()
    }
    
    func reverseGeocode() async -> String? {
        guard let location = currentLocation else { return nil }
        let coordString = String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
        
        let accuracy = location.horizontalAccuracy
        let isRough = accuracy > LocationPoint.streetAddressMaxAccuracy
        var addressString = isRough ? LocationPoint.approximateAddress(area: coordString, accuracy: accuracy) : coordString
        if let request = MKReverseGeocodingRequest(location: location),
           let mapItem = try? await request.mapItems.first {
            if isRough {
                let representations = mapItem.addressRepresentations
                let area = representations?.cityWithContext ?? representations?.regionName ?? coordString
                addressString = LocationPoint.approximateAddress(area: area, accuracy: accuracy)
            } else {
                addressString = mapItem.address?.fullAddress ?? mapItem.name ?? coordString
            }
        }
// A newer fix may have arrived while geocoding; don't pair its
        // location with this older address.
        guard currentLocation?.timestamp == location.timestamp else { return addressString }
        currentAddress = addressString
        currentAddressDate = location.timestamp
        return addressString
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if self.trackingStartedAt != nil, !EmailSettings.current.includeLocation {
                // "Save location" was turned off mid-recording.
                self.stopTracking()
                return
            }
            if self.trackingStartedAt != nil,
               let usable = locations.last(where: LocationPoint.isUsable) {
                self.latestUsableFix = usable
                // iOS may deliver an old cached fix first; that isn't the start.
                if let recent = self.recentUsableFix() {
                    self.onFirstUsableFix?(recent)
                    self.onFirstUsableFix = nil
                }
            }
            if let location = locations.last, self.shouldUpdateCurrentLocation(with: location) {
                self.lastAddressedFixAt = location.timestamp
                self.currentLocation = location
                _ = await self.reverseGeocode()
            }
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed: \(error)")
    }
    
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            // Warm up a fix as soon as we're allowed to, so the first alert
            // email isn't sent before any location is known.
            if EmailSettings.current.includeLocation,
               manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                // A one-off request would cancel tracking that's already on.
                if self.trackingStartedAt != nil {
                    manager.startUpdatingLocation()
                } else {
                    manager.requestLocation()
                }
            }
        }
    }
}

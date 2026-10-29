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
        authorizationStatus = manager.authorizationStatus
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
        
        var addressString = coordString
        if let request = MKReverseGeocodingRequest(location: location),
           let mapItem = try? await request.mapItems.first {
            addressString = mapItem.address?.fullAddress ?? mapItem.name ?? coordString
        }
        // A newer fix may have arrived while geocoding; don't pair its
        // location with this older address.
        guard currentLocation?.timestamp == location.timestamp else { return addressString }
        currentAddress = addressString
        currentAddressDate = location.timestamp
        return addressString
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            Task { @MainActor in
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
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
}

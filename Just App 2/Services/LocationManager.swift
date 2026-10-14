import Foundation
import CoreLocation
import MapKit
import Observation

@Observable
class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var currentLocation: CLLocation?
    private(set) var currentAddress: String?
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
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
        
        guard let request = MKReverseGeocodingRequest(location: location) else {
            let coordString = String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
            self.currentAddress = coordString
            return coordString
        }
        
        do {
            let mapItems = try await request.mapItems
            if let mapItem = mapItems.first {
                let addressString = mapItem.name ?? String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
                self.currentAddress = addressString
                return addressString
            }
        } catch {
            let coordString = String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
            self.currentAddress = coordString
            return coordString
        }
        return nil
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
        }
    }
}

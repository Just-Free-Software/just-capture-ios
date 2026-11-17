import Foundation
import CoreLocation

/// A session's `location.txt`, read back into something a screen can show.
/// The file is written by `RecordingSession.locationText`, and the two must
/// stay in step. Anything this doesn't recognize is skipped rather than
/// treated as an error, since the file may come from another version of the
/// app on someone else's phone.
struct SessionLocationInfo: Equatable {
    struct Point: Identifiable, Equatable {
        let id: Int
        /// As written by the recording phone, in its time zone.
        let time: String
        /// "Recording start" or "Clip 3".
        let label: String
        let latitude: Double?
        let longitude: Double?
        /// e.g. "within 12 m".
        let accuracy: String?
        /// The phone had no current position, so this is an older one.
        let isLastKnown: Bool

        var coordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        var mapURL: URL? {
            guard let latitude, let longitude else { return nil }
            return URL(string: "https://www.google.com/maps?q=\(latitude),\(longitude)")
        }
    }

    var started: String?
    var startingAddress: String?
    var points: [Point] = []

    /// Every known position, oldest first.
    var route: [CLLocationCoordinate2D] {
        points.compactMap(\.coordinate)
    }

    init?(text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if let value = Self.value(of: "Recording started:", in: line) {
                started = value
            } else if let value = Self.value(of: "Starting address:", in: line) {
                startingAddress = value
            } else if let point = Self.point(from: line, id: points.count) {
                points.append(point)
            }
        }
        if started == nil && startingAddress == nil && points.isEmpty { return nil }
    }

    private static func value(of prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// A trail line: time | clip or "recording start" | then some of
    /// "last known position", "lat, lon", "within N m", a map link, or
    /// "no location available".
    private static func point(from line: String, id: Int) -> Point? {
        let fields = line.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3 else { return nil }

        var latitude: Double?
        var longitude: Double?
        var accuracy: String?
        var isLastKnown = false
        for field in fields.dropFirst(2) {
            if field == "last known position" {
                isLastKnown = true
            } else if field.hasPrefix("within ") {
                accuracy = field
            } else if !field.hasPrefix("http") {
                let parts = field.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
                   (-90...90).contains(lat), (-180...180).contains(lon) {
                    latitude = lat
                    longitude = lon
                }
            }
        }
        return Point(id: id, time: fields[0], label: label(for: fields[1]), latitude: latitude, longitude: longitude, accuracy: accuracy, isLastKnown: isLastKnown)
    }

    /// "chunk_2.mp4" is the third clip, which the rest of the app calls Clip 3.
    private static func label(for name: String) -> String {
        if name == "recording start" { return "Recording start" }
        if name.hasPrefix("chunk_"), let index = Int(name.dropFirst(6).prefix(while: \.isNumber)) {
            return "Clip \(index + 1)"
        }
        return name
    }
}

import Foundation
import SwiftData

/// A single GPS sample on a recorded route. Stored only when GPS is used, and
/// never leaves the device.
@Model
final class RoutePoint {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var latitude: Double = 0
    var longitude: Double = 0
    var altitude: Double = 0
    var horizontalAccuracy: Double = 0
    var speed: Double = 0

    var session: ActivitySession?

    init(timestamp: Date, latitude: Double, longitude: Double,
         altitude: Double, horizontalAccuracy: Double, speed: Double) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
    }
}

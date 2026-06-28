import Foundation

enum ActivityType: String, CaseIterable, Identifiable, Codable {
    case walk = "Walk"
    case run  = "Run"
    case ride = "Ride"

    var id: String { rawValue }

    var sfSymbol: String {
        switch self {
        case .walk: return "figure.walk"
        case .run:  return "figure.run"
        case .ride: return "bicycle"
        }
    }

    /// Walk/run distance can come from the pedometer; cycling needs GPS.
    var pedometerDistance: Bool { self != .ride }

    /// Rough MET value for a calorie-burn estimate.
    var met: Double {
        switch self {
        case .walk: return 3.5
        case .run:  return 9.0
        case .ride: return 7.5
        }
    }
}

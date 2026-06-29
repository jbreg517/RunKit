import Foundation

/// Metric / imperial preference, stored in `@AppStorage("unitSystem")`. Mirrors
/// LiftKit's unit handling; the formatters keep distance/pace/speed/elevation
/// strings consistent across every screen. When the suite matures this moves into
/// the shared `KitUI` package alongside the `RK` design tokens.
enum UnitSystem: String, CaseIterable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }
    var label: String { self == .metric ? "Metric" : "Imperial" }

    var distanceUnit: String  { self == .metric ? "km"   : "mi"  }
    var paceUnit: String      { self == .metric ? "/km"  : "/mi" }
    var speedUnit: String     { self == .metric ? "km/h" : "mph" }
    var elevationUnit: String { self == .metric ? "m"    : "ft"  }

    private static let metersPerMile = 1609.344
    private static let feetPerMeter  = 3.28084

    /// Meters → display distance (km or mi).
    func distance(_ meters: Double) -> Double {
        self == .metric ? meters / 1000 : meters / Self.metersPerMile
    }

    /// Meters → display elevation (m or ft).
    func elevation(_ meters: Double) -> Double {
        self == .metric ? meters : meters * Self.feetPerMeter
    }

    /// Typed display distance (km/mi) → meters. `nil` when unparseable.
    func meters(fromDisplay text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value >= 0 else { return nil }
        return self == .metric ? value * 1000 : value * Self.metersPerMile
    }

    func distanceString(_ meters: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f %@", distance(meters), distanceUnit)
    }

    func elevationString(_ meters: Double) -> String {
        String(format: "%.0f %@", elevation(meters), elevationUnit)
    }

    /// Time per unit distance → "m:ss /km" (or /mi). "--" when not computable.
    func paceString(seconds: Double, meters: Double) -> String {
        let d = distance(meters)
        guard d > 0.01, seconds > 0 else { return "--" }
        let perUnit = Int((seconds / d).rounded())
        return String(format: "%d:%02d %@", perUnit / 60, perUnit % 60, paceUnit)
    }

    /// Average speed over a distance/time → "x.x km/h" (or mph).
    func speedString(seconds: Double, meters: Double) -> String {
        guard seconds > 0, meters > 0 else { return "--" }
        let perHour = distance(meters) / (seconds / 3600)
        return String(format: "%.1f %@", perHour, speedUnit)
    }

    /// Instantaneous speed (m/s) → "x.x km/h" (or mph).
    func speedString(metersPerSecond mps: Double) -> String {
        String(format: "%.1f %@", distance(mps * 3600), speedUnit)
    }

    /// Seconds-per-unit (e.g. current pace) → "m:ss /km" (or /mi).
    func paceString(secondsPerUnit s: Double) -> String {
        guard s > 0, s.isFinite else { return "--" }
        let v = Int(s.rounded())
        return String(format: "%d:%02d %@", v / 60, v % 60, paceUnit)
    }

    // MARK: Spoken (for voice announcements)

    var spokenUnit: String { self == .metric ? "kilometer" : "mile" }

    func spokenPace(seconds: Double, meters: Double) -> String {
        let d = distance(meters)
        guard d > 0.01, seconds > 0 else { return "unavailable" }
        let p = Int((seconds / d).rounded()), m = p / 60, s = p % 60
        return "\(m) minute\(m == 1 ? "" : "s") \(s) second\(s == 1 ? "" : "s") per \(spokenUnit)"
    }

    func spokenSpeed(seconds: Double, meters: Double) -> String {
        guard seconds > 0, meters > 0 else { return "unavailable" }
        let v = distance(meters) / (seconds / 3600)
        return String(format: "%.1f %@s per hour", v, spokenUnit)
    }
}

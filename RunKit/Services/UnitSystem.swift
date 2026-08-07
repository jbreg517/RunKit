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

    var weightUnit: String    { self == .metric ? "kg"   : "lb"  }

    private static let metersPerMile = 1609.344
    private static let feetPerMeter  = 3.28084
    private static let poundsPerKg   = 2.2046226

    // MARK: Weight
    //
    // Ruck loads are stored in kilograms everywhere — model, wire format, HealthKit
    // metadata — and converted only for display. Storing whatever the user happened
    // to be looking at would rewrite their history the moment they switched units.

    /// Kilograms → display weight (kg or lb).
    func weight(_ kg: Double) -> Double {
        self == .metric ? kg : kg * Self.poundsPerKg
    }

    /// Display weight (kg or lb) → kilograms.
    func kilograms(fromDisplay value: Double) -> Double {
        self == .metric ? value : value / Self.poundsPerKg
    }

    /// Typed display weight → kilograms. `nil` when unparseable, which callers treat
    /// as "leave it alone" rather than as zero.
    func kilograms(fromDisplay text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value >= 0 else { return nil }
        return kilograms(fromDisplay: value)
    }

    func weightString(_ kg: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f %@", weight(kg), weightUnit)
    }

    /// A step that lands on round numbers in the unit being shown: plates and pack
    /// weights come in 2.5 kg or 5 lb, and a stepper that moves in converted
    /// fractions is unusable.
    var weightStepKg: Double { self == .metric ? 2.5 : 5 / Self.poundsPerKg }

    /// Kilogram-kilometres — the ruck volume figure — in display units (kg·km or
    /// lb·mi). Both factors convert, so this is not a simple scale of the metric one.
    func loadVolume(kgKilometers: Double) -> Double {
        self == .metric ? kgKilometers
                        : kgKilometers * Self.poundsPerKg * 1000 / Self.metersPerMile
    }

    func loadVolumeString(kgKilometers: Double) -> String {
        String(format: "%.0f %@·%@", loadVolume(kgKilometers: kgKilometers),
               weightUnit, distanceUnit)
    }

    /// Metres in one display unit — 1000 for a kilometre, 1609.344 for a mile.
    var metersPerUnit: Double { self == .metric ? 1000 : Self.metersPerMile }

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

    // MARK: Pace entry

    /// Typed "mm:ss" (or plain minutes) per unit → seconds per **metre**, so the
    /// stored target survives a units switch. 0 when the field is empty or junk.
    func secondsPerMeter(fromPaceText text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        let parts = trimmed.split(separator: ":")
        var perUnit = 0.0
        if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
            perUnit = m * 60 + s
        } else if let m = Double(trimmed.replacingOccurrences(of: ",", with: ".")) {
            perUnit = m * 60
        }
        return perUnit > 0 ? perUnit / metersPerUnit : 0
    }

    /// Seconds per metre → the "mm:ss" the user typed. Empty when there's no target.
    func paceText(fromSecondsPerMeter s: Double) -> String {
        guard s > 0 else { return "" }
        let perUnit = Int((s * metersPerUnit).rounded())
        return String(format: "%d:%02d", perUnit / 60, perUnit % 60)
    }

    // MARK: Spoken (for voice announcements)

    var spokenUnit: String { self == .metric ? "kilometer" : "mile" }

    /// Distance phrased for speech, e.g. "3.2 kilometers".
    func spokenDistance(_ meters: Double) -> String {
        String(format: "%.1f %@s", distance(meters), spokenUnit)
    }

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

import Foundation

/// Builds CSV and GPX exports of the user's own data.
///
/// This is a **principle, not a feature**: "your data is actually portable" is a
/// core claim against server-bound competitors, so export stays free forever and
/// emits standard formats any other tool can read — CSV for the session log, GPX
/// 1.1 (the format Strava/Garmin/Apple all import) for routes.
///
/// Everything is generated on-device and handed to the share sheet; nothing is
/// uploaded anywhere.
enum ExportService {

    // MARK: CSV

    private static let csvHeader = [
        "started_at", "ended_at", "type", "workout_type", "custom_workout",
        "active_seconds", "paused_seconds", "distance_meters",
        "steps", "flights", "active_energy_kcal",
        "used_gps", "distance_estimated", "manual_distance",
        "route_points", "notes",
    ].joined(separator: ",")

    /// One row per session, newest first. Values are RFC 4180 quoted.
    static func csv(_ sessions: [ActivitySession]) -> String {
        let iso = ISO8601DateFormatter()
        var out = [csvHeader]
        for s in sessions.sorted(by: { $0.startedAt > $1.startedAt }) {
            out.append([
                iso.string(from: s.startedAt),
                s.endedAt.map { iso.string(from: $0) } ?? "",
                s.type.rawValue,
                s.workoutType.rawValue,
                s.customWorkoutName,
                String(format: "%.0f", s.activeSeconds),
                String(format: "%.0f", s.pausedSeconds),
                String(format: "%.1f", s.distanceMeters),
                "\(s.steps)",
                "\(s.flights)",
                String(format: "%.0f", s.activeEnergyKcal),
                s.usedGPS ? "true" : "false",
                s.distanceEstimated ? "true" : "false",
                s.manualDistance ? "true" : "false",
                "\(s.route.count)",
                s.notes ?? "",
            ].map(field).joined(separator: ","))
        }
        return out.joined(separator: "\n")
    }

    /// RFC 4180: quote when the value contains a comma, quote or newline, and
    /// escape embedded quotes by doubling them.
    private static func field(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: GPX

    /// GPX 1.1 track for one session. Returns nil when there's no route to write.
    static func gpx(_ session: ActivitySession) -> String? {
        let points = session.sortedRoute
        guard !points.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        let name = "RunKit \(session.type.rawValue) \(iso.string(from: session.startedAt))"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="RunKit" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(escape(name))</name>
            <time>\(iso.string(from: session.startedAt))</time>
          </metadata>
          <trk>
            <name>\(escape(name))</name>
            <type>\(session.type.rawValue)</type>
            <trkseg>
        """
        for p in points {
            xml += """

              <trkpt lat="\(p.latitude)" lon="\(p.longitude)">
                <ele>\(String(format: "%.1f", p.altitude))</ele>
                <time>\(iso.string(from: p.timestamp))</time>
              </trkpt>
            """
        }
        xml += """

            </trkseg>
          </trk>
        </gpx>
        """
        return xml
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Files

    /// Writes `text` to a uniquely-named file in the temp directory and returns
    /// the URL for the share sheet.
    static func writeTemp(_ text: String, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Every session as CSV, plus a GPX per session that has a route.
    static func exportAll(_ sessions: [ActivitySession]) throws -> [URL] {
        var urls = [try writeTemp(csv(sessions), name: "RunKit-sessions-\(stamp()).csv")]
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd-HHmm"
        for s in sessions where !s.route.isEmpty {
            if let x = gpx(s) {
                urls.append(try writeTemp(
                    x, name: "RunKit-\(s.type.rawValue)-\(iso.string(from: s.startedAt)).gpx"))
            }
        }
        return urls
    }
}

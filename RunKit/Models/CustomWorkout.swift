import Foundation
import SwiftData

/// A reusable workout. Cards are stored as JSON rather than a SwiftData
/// relationship: to-many relationships have no guaranteed order, and for a
/// structured workout the **order is the workout**. A plain `String` attribute
/// also keeps the model trivially CloudKit-compatible.
///
/// Split out of `ActivitySegment.swift` in v0.51 so that file could stay pure
/// Foundation and be shared with the watch target. The attribute names and the
/// type name are unchanged, so existing stores migrate untouched — only the file
/// it lives in moved.
@Model
final class CustomWorkout {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    /// Legacy attribute name, kept so existing stores migrate without a schema
    /// change — the contents are `ActivitySegment`s.
    var stepsJSON: String = "[]"
    var isFavorite: Bool = false

    init(name: String, segments: [ActivitySegment]) {
        self.name = name
        self.segments = segments
    }

    var segments: [ActivitySegment] {
        get { ActivitySegment.decode(stepsJSON) }
        set { stepsJSON = ActivitySegment.encode(newValue) }
    }

    /// Total distance in metres, or nil when any card is time-based.
    var totalMeters: Double? {
        let s = segments
        guard !s.isEmpty, s.allSatisfy({ $0.endsOnDistance }) else { return nil }
        return s.reduce(0) { $0 + $1.meters }
    }
}

import Foundation

/// Apple's cardio-fitness estimate (VO₂ max), shaped for a chart.
///
/// Pure functions over samples read from HealthKit — no queries, no storage — so
/// the maths is cheap to call from a view and easy to reason about.
///
/// RunKit never computes or writes VO₂ max. Apple Watch estimates it during
/// outdoor walks, runs and hikes; everything here is presentation of a number
/// somebody else measured.
enum CardioFitness {

    struct Point: Identifiable, Equatable {
        let date: Date
        /// ml/(kg·min).
        let value: Double
        var id: Date { date }
    }

    /// A charted window: the points plus everything the card needs to describe
    /// them, computed once so the view does no arithmetic while drawing.
    struct Series: Equatable {
        var points: [Point] = []
        /// Reading count *before* daily collapsing — what Health actually holds.
        var sampleCount = 0

        var isEmpty: Bool { points.isEmpty }
        var latest: Point? { points.last }
        var first: Point? { points.first }
        var low: Double { points.map(\.value).min() ?? 0 }
        var high: Double { points.map(\.value).max() ?? 0 }

        /// Vertical bounds for the chart.
        ///
        /// Padded to a **minimum span** because VO₂ max barely moves: a series
        /// wandering between 47.9 and 48.3 auto-scaled to its own extremes draws
        /// a dramatic mountain range out of noise. A fixed floor keeps a flat
        /// year looking flat.
        var bounds: ClosedRange<Double> {
            guard !points.isEmpty else { return 0...1 }
            let mid = (low + high) / 2
            let span = max(high - low, Self.minimumSpan)
            let pad = span * 0.15
            return (mid - span / 2 - pad)...(mid + span / 2 + pad)
        }
        private static let minimumSpan: Double = 6

        /// Change across the window, or nil when there is too little to compare.
        ///
        /// Endpoints of a sparse, noisy series are a bad summary — one unusually
        /// hot day at either end swings the answer. With enough readings this
        /// averages the first and last three instead.
        var change: Double? {
            guard points.count >= 2 else { return nil }
            let values = points.map(\.value)
            guard values.count >= 6 else { return values.last! - values.first! }
            let head = values.prefix(3).reduce(0, +) / 3
            let tail = values.suffix(3).reduce(0, +) / 3
            return tail - head
        }

        /// Days covered, for phrasing the change ("over the last 5 months").
        var spanDays: Int {
            guard let a = first?.date, let b = latest?.date else { return 0 }
            return max(0, Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0)
        }
    }

    /// How far back the card looks. Long, because the signal is slow — a month
    /// of readings can be a single dot.
    static let windowMonths = 12

    static func windowStart(_ now: Date = Date(), _ cal: Calendar = .current) -> Date {
        cal.date(byAdding: .month, value: -windowMonths, to: now) ?? now
    }

    /// Collapses raw samples to one point per day, keeping the day's **last**
    /// reading so the headline figure matches what the Health app shows as most
    /// recent. Two readings on one day would otherwise draw a vertical spike at
    /// a single x position.
    static func series(from samples: [(date: Date, value: Double)],
                       calendar cal: Calendar = .current) -> Series {
        var byDay: [Date: (date: Date, value: Double)] = [:]
        for sample in samples where sample.value > 0 {
            let day = cal.startOfDay(for: sample.date)
            if let existing = byDay[day], existing.date > sample.date { continue }
            byDay[day] = sample
        }
        let points = byDay.values
            .sorted { $0.date < $1.date }
            .map { Point(date: $0.date, value: $0.value) }
        return Series(points: points, sampleCount: samples.count)
    }
}

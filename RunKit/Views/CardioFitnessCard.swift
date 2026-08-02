import SwiftUI

/// VO₂ max over the last year, as Apple Watch measured it.
///
/// Hand-rolled with `Path` rather than Swift Charts, matching `weeklyVolumeCard`:
/// a line, a fill and two axis labels are not worth a framework dependency or the
/// type-checking cost inside an already-large view.
///
/// **The window is fixed at twelve months and deliberately ignores the Stats
/// period picker.** VO₂ max is a slow signal — a week or a month of readings is
/// often one dot, which is a worse answer than a year of context.
struct CardioFitnessCard: View {
    let series: CardioFitness.Series

    private var chartHeight: CGFloat { 120 }

    var body: some View {
        VStack(alignment: .leading, spacing: RKSpacing.sm) {
            header
            if series.isEmpty {
                empty
            } else {
                chart
                axisLabels
                summaryLines
            }
            Text("Apple Watch estimates this during outdoor walks, runs and hikes. The Health app rates it against your age and sex.")
                .font(.system(size: 11))
                .foregroundColor(RKColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RKSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RKColor.surface)
        .cornerRadius(RKRadius.large)
        .padding(.horizontal, RKSpacing.md)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Cardio fitness", systemImage: "lungs.fill")
                .font(RKFont.heading)
                .foregroundColor(RKColor.textPrimary)
            Spacer()
            if let latest = series.latest {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", latest.value))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(RKColor.accent)
                    Text("VO₂ max")
                        .font(.system(size: 11))
                        .foregroundColor(RKColor.textMuted)
                }
            }
        }
    }

    /// One message for two situations that HealthKit cannot tell apart: no
    /// readings, and a read that was never authorised.
    private var empty: some View {
        Text("No VO₂ max readings in Apple Health yet. Apple Watch estimates cardio fitness during outdoor walks, runs and hikes of around 20 minutes, and needs your age, sex, height and weight set in Health. If you have readings but see nothing here, check RunKit's access under Health ▸ Sharing ▸ Apps.")
            .font(RKFont.caption)
            .foregroundColor(RKColor.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Chart

    private var chart: some View {
        HStack(spacing: 4) {
            // A gutter rather than an overlay: labels floating on the plot collide
            // with the line exactly when the series touches its own extremes,
            // which is most of the time.
            VStack(alignment: .leading) {
                bound(series.bounds.upperBound)
                Spacer()
                bound(series.bounds.lowerBound)
            }
            .frame(width: 22, alignment: .leading)
            plot
        }
        .frame(height: chartHeight)
    }

    private var plot: some View {
        GeometryReader { geo in
            let points = positions(in: geo.size)
            ZStack {
                area(points, height: geo.size.height)
                    .fill(LinearGradient(colors: [RKColor.accent.opacity(0.28),
                                                  RKColor.accent.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                line(points)
                    .stroke(RKColor.accent,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    Circle()
                        .fill(RKColor.accent)
                        .frame(width: 7, height: 7)
                        .position(last)
                }
            }
        }
    }

    private func bound(_ value: Double) -> some View {
        Text(String(format: "%.0f", value))
            .font(.system(size: 10))
            .foregroundColor(RKColor.textMuted)
    }

    /// Points are placed by **date**, not by index, so a three-month gap in
    /// readings shows as a gap rather than being compressed away.
    private func positions(in size: CGSize) -> [CGPoint] {
        let bounds = series.bounds
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0, let start = series.first?.date, let end = series.latest?.date else { return [] }
        let seconds = end.timeIntervalSince(start)
        // Keeps the trailing dot and the first stroke cap off the card edge.
        let inset: CGFloat = 6
        let width = max(1, size.width - inset * 2)
        let height = max(1, size.height - inset * 2)
        return series.points.map { point in
            let fx = seconds > 0 ? CGFloat(point.date.timeIntervalSince(start) / seconds) : 0.5
            let fy = CGFloat((point.value - bounds.lowerBound) / span)
            return CGPoint(x: inset + fx * width, y: inset + (1 - fy) * height)
        }
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    private func area(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last, points.count > 1 else { return path }
        path.move(to: CGPoint(x: first.x, y: height))
        for point in points { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.closeSubpath()
        return path
    }

    private var axisLabels: some View {
        HStack {
            Text(series.first.map { shortDate($0.date) } ?? "")
            Spacer()
            Text(series.latest.map { shortDate($0.date) } ?? "")
        }
        .font(.system(size: 10))
        .foregroundColor(RKColor.textMuted)
        .padding(.leading, 26)      // clears the value gutter, so dates sit under the plot
    }

    // MARK: Written summary

    @ViewBuilder
    private var summaryLines: some View {
        if series.points.count < 2 {
            Text("One reading so far. A trend needs a few more — keep recording outdoor sessions on your Watch.")
                .font(RKFont.caption)
                .foregroundColor(RKColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if let change = series.change {
                Text(changeText(change))
                    .font(RKFont.bodyBold)
                    .foregroundColor(changeColor(change))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(format: "Range %.1f–%.1f · %d reading%@",
                        series.low, series.high, series.sampleCount,
                        series.sampleCount == 1 ? "" : "s"))
                .font(RKFont.caption)
                .foregroundColor(RKColor.textMuted)
        }
    }

    /// Half a point either way is inside the estimate's own noise, so it reads as
    /// steady rather than as progress or decline.
    private func changeText(_ change: Double) -> String {
        let window = spanText
        if abs(change) < 0.5 { return "Steady over \(window)." }
        let direction = change > 0 ? "Up" : "Down"
        return String(format: "%@ %.1f over %@.", direction, abs(change), window)
    }

    private func changeColor(_ change: Double) -> Color {
        if abs(change) < 0.5 { return RKColor.textSecondary }
        return change > 0 ? RKColor.success : RKColor.textSecondary
    }

    private var spanText: String {
        let days = series.spanDays
        if days >= 60 {
            let months = Int((Double(days) / 30.4).rounded())
            return "the last \(months) months"
        }
        if days >= 14 { return "the last \(days / 7) weeks" }
        return days <= 1 ? "today" : "the last \(days) days"
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
    }
}

import SwiftUI
import MapKit

/// Reusable route map. GPS stretches draw as a solid accent line; estimated
/// stretches (where GPS dropped and distance was filled in) draw faded + dashed,
/// with a legend so it's clear which parts are measured vs. estimated.
/// Shows a non-interactive thumbnail that expands to fullscreen on tap.
struct RouteMapView: View {
    let points: [RoutePoint]            // expected pre-sorted by time
    var height: CGFloat = 260

    @State private var showFull = false

    private var displayPoints: [RoutePoint] { RouteMath.downsample(points) }
    private var segments: [RouteSegment] { RouteMath.segments(displayPoints) }
    private var hasEstimated: Bool { segments.contains(where: \.estimated) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            map(interactive: false)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: RKRadius.large))
                .allowsHitTesting(false)
            if hasEstimated { legend.padding(RKSpacing.sm) }
        }
        .contentShape(Rectangle())
        .onTapGesture { showFull = true }
        .fullScreenCover(isPresented: $showFull) { fullScreen }
    }

    private var fullScreen: some View {
        NavigationStack {
            map(interactive: true)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottomLeading) {
                    if hasEstimated { legend.padding() }
                }
                .navigationTitle("Route")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showFull = false }
                    }
                }
        }
    }

    @ViewBuilder
    private func map(interactive: Bool) -> some View {
        Map(initialPosition: RouteMath.region(displayPoints).map { .region($0) } ?? .automatic,
            interactionModes: interactive ? .all : []) {
            ForEach(segments) { seg in
                MapPolyline(coordinates: seg.coordinates)
                    .stroke(
                        seg.estimated ? RKColor.accent.opacity(0.55) : RKColor.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round,
                                           dash: seg.estimated ? [6, 6] : [])
                    )
            }
            if let start = displayPoints.first?.coordinate {
                Annotation("Start", coordinate: start) { dot(RKColor.success) }
            }
            if displayPoints.count > 1, let end = displayPoints.last?.coordinate {
                Annotation("End", coordinate: end) { dot(RKColor.accent) }
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white, lineWidth: 2))
    }

    private var legend: some View {
        HStack(spacing: RKSpacing.md) {
            legendItem(color: RKColor.accent, dashed: false, label: "GPS")
            legendItem(color: RKColor.accent.opacity(0.55), dashed: true, label: "Estimated")
        }
        .padding(.horizontal, RKSpacing.sm)
        .padding(.vertical, RKSpacing.xs)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func legendItem(color: Color, dashed: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            DashSample()
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round,
                                                  dash: dashed ? [4, 3] : []))
                .frame(width: 18, height: 3)
            Text(label).font(RKFont.caption).foregroundColor(RKColor.textSecondary)
        }
    }
}

/// A short horizontal line used to render the legend swatch.
private struct DashSample: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

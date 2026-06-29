import SwiftUI
import MapKit
import CoreLocation

/// Live map for the active session: the route recorded so far plus the current
/// position (system blue dot), with the camera following the latest fix.
struct LiveRouteMapView: View {
    let coordinates: [CLLocationCoordinate2D]
    let current: CLLocationCoordinate2D?

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            if coordinates.count >= 2 {
                MapPolyline(coordinates: coordinates)
                    .stroke(RKColor.accent,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .onAppear { recenter() }
        .onChange(of: current?.latitude) { _, _ in recenter() }
    }

    private func recenter() {
        guard let c = current else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .region(MKCoordinateRegion(
                center: c, latitudinalMeters: 500, longitudinalMeters: 500))
        }
    }
}

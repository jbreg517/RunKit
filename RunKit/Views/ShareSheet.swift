import SwiftUI
import UIKit

/// Minimal `UIActivityViewController` wrapper — SwiftUI's `ShareLink` handles a
/// single item well but not a variable-length set of file URLs, which is what
/// export produces (one CSV plus a GPX per recorded route).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

import QuickLookUI
import SwiftUI

/// Quick Look, embedded in the window (FR-045).
///
/// Previews are generated out of process, so a malformed file found somewhere on the disk renders
/// as a failed thumbnail instead of taking the app down with it — which matters when the whole
/// point is looking at things nobody remembers creating.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // Typed explicitly because the framework declares the initialiser as returning `id`.
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        // Selecting a video to see how big it is should not start playing it.
        view.autostarts = false
        // Closed when SwiftUI takes the view down instead, which happens well before the window
        // does. Leaving it to the window would hold every preview of the session open.
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? URL) != url else { return }
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

import QuickLookUI
import SwiftUI

/// Quick Look, embedded in the window (FR-045).
///
/// Previews are generated out of process, so a malformed file found somewhere on the disk renders
/// as a failed thumbnail instead of taking the app down with it — which matters when the whole
/// point is looking at things nobody remembers creating.
struct QuickLookPreview: NSViewRepresentable {
    /// Nil while there is nothing to show. The view stays mounted through that rather than being
    /// taken down and rebuilt, because building one opens a connection to the rendering process
    /// and closing one tears it down.
    let url: URL?

    /// Used only if it is asked for a size against an unbounded proposal, which the panel never
    /// does.
    private static let fallback = CGSize(width: 260, height: 200)

    func makeNSView(context: Context) -> QLPreviewView {
        // Typed explicitly because the framework declares the initialiser as returning `id`.
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        // Selecting a video to see how big it is should not start playing it.
        view.autostarts = false
        // Closed when SwiftUI takes the view down instead, which happens well before the window
        // does. Leaving it to the window would hold every preview of the session open.
        view.shouldCloseWithWindow = false

        // A preview reports the size its content would like to be, and left alone that travels
        // outwards until the panel and then the window have resized themselves around a
        // photograph. What is being looked at gets no say in how big the thing looking at it is.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }

        view.previewItem = url as NSURL?
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? URL) != url else { return }
        view.previewItem = url as NSURL?
    }

    /// Takes exactly what it is offered. Returning nil defers to the view's own idea of how big it
    /// ought to be, which is the half of the problem AppKit priorities do not cover.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: QLPreviewView,
        context: Context
    ) -> CGSize? {
        let offered = proposal.replacingUnspecifiedDimensions(by: Self.fallback)
        return CGSize(
            width: offered.width.isFinite ? offered.width : Self.fallback.width,
            height: offered.height.isFinite ? offered.height : Self.fallback.height
        )
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

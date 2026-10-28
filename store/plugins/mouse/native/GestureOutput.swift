import CoreGraphics
import Foundation

/// Where a glide's frames go: scroll events (`ScrollOutput`) or a trackpad gesture (`GestureOutput`).
protocol GlideOutput: AnyObject {
    func emit(y: Int64, x: Int64, phase: ScrollOutput.Phase, hint: ScrollOutput.Hint)
    func finish()
    func cancel()
    func reset()
}

extension ScrollOutput: GlideOutput {}

/// The wheel acting as a trackpad gesture: pinch-zoom, rotation, the pinch that shows Launchpad / the desktop, or a
/// three-finger swipe between Spaces. The amounts per pixel of wheel travel follow Mac Mouse Fix
/// (https://github.com/noah-nuebling/mac-mouse-fix, MMF License).
final class GestureOutput: GlideOutput {
    enum Kind { case zoom, rotate, pinch, swipe }

    var kind = Kind.zoom
    /// The natural-scrolling setting; swipes and pinches are flipped by it.
    var inverted = true
    private let dock = DockSwipe()
    private var open = false

    func emit(y: Int64, x: Int64, phase: ScrollOutput.Phase, hint: ScrollOutput.Hint) {
        let amount = Double(x + y)
        let gesture: TrackpadGestures.Phase = phase == .start ? .began : phase == .continue ? .changed : phase == .end ? .ended : .cancelled
        switch kind {
        case .zoom: TrackpadGestures.magnify(amount / 800, phase: gesture)
        case .rotate: TrackpadGestures.rotate(amount / 8, phase: gesture)
        case .pinch: dock.post(delta: -amount / 600, kind: .pinch, phase: gesture, inverted: inverted)
        case .swipe: dock.post(delta: -amount / 600, kind: .horizontal, phase: gesture, inverted: inverted)
        }
        open = phase == .start || phase == .continue
    }

    func finish() { if open { emit(y: 0, x: 0, phase: .end, hint: .gesture) } }
    func cancel() { if open { emit(y: 0, x: 0, phase: .cancel, hint: .gesture) } }
    func reset() { open = false }
}

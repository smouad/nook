import CoreGraphics
import Foundation

// The event sequence below follows what Mac Mouse Fix's GestureScrollSimulator does to look like a trackpad swipe to
// apps (https://github.com/noah-nuebling/mac-mouse-fix, MMF License), translated to Swift.

/// Posts scroll events, either as a trackpad swipe or as plain pixel scrolling.
///
/// A swipe is a gesture while the "fingers" are down (began, changed, ended), then momentum (begin, continue, end).
/// Apps that snap or animate scrolling themselves (Safari, Chrome, YouTube Shorts, Xcode) wait for that sequence, and a
/// zero-motion "may begin" + "cancelled" pair after the end tells them not to start momentum of their own.
final class ScrollOutput {
    enum Hint { case gesture, momentum }
    enum Phase { case start, `continue`, end, cancel }

    private enum ScrollPhase: Int64 { case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128 }
    private enum MomentumPhase: Int64 { case none = 0, begin = 1, `continue` = 2, end = 3 }

    /// Trackpad style. False sends plain pixel events with no phases.
    var swipe = true
    var flags: CGEventFlags = []
    /// Content direction is inverted from the device's (the "natural scrolling" flag apps read).
    var invertedFromDevice = true

    /// What is in flight right now; nil when a swipe isn't open.
    private(set) var current: Hint?
    private let source = CGEventSource(stateID: .hidSystemState)
    private let postEvent: (CGEvent) -> Void

    init(postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }) {
        self.postEvent = postEvent
    }
    private var lineY = BiasedSubPixelator(), lineX = BiasedSubPixelator()

    func reset() {
        current = nil
        lineY.reset(); lineX.reset()
    }

    func emit(y: Int64, x: Int64, phase: Phase, hint: Hint) {
        if phase == .start { lineY.reset(); lineX.reset() }
        guard swipe else {
            if y != 0 || x != 0 { post(y: y, x: x, scroll: .none, momentum: .none) }
            return
        }
        let ending = phase == .end || phase == .cancel
        switch hint {
        case .gesture:
            var scroll: ScrollPhase = phase == .start ? .began : (ending ? .ended : .changed)
            if current == .momentum {
                // New touch while coasting: stop the momentum, then begin a fresh gesture.
                post(y: 0, x: 0, scroll: .none, momentum: .end)
                if phase == .continue { scroll = .began }
            }
            post(y: y, x: x, scroll: scroll, momentum: .none)
            if phase == .cancel { tap() }
        case .momentum:
            var momentum: MomentumPhase = ending ? .end : .continue
            if current != .momentum {
                post(y: 0, x: 0, scroll: .ended, momentum: .none) // the fingers lift; the glide goes on as momentum
                if !ending { momentum = .begin }
            }
            post(y: y, x: x, scroll: .none, momentum: momentum)
            if ending { tap() }
        }
        current = ending ? nil : hint
    }

    /// MMF's unanimated LineScroll output: a noncontinuous wheel event with exact pixel,
    /// truncated/minimum-one line and 16.16 fixed-point line deltas.
    func emitUnanimated(y: Int64, x: Int64) {
        guard y != 0 || x != 0, let event = CGEvent(source: source) else { return }
        event.type = .scrollWheel
        func line(_ pixels: Int64) -> Int64 {
            let truncated = pixels / 10
            return truncated == 0 ? Int64(pixels.signum()) : truncated
        }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: line(y))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: line(x))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: y)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: x)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Self.fixedLines(y))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Self.fixedLines(x))
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: MouseFixService.marker)
        postEvent(event)
    }

    private static func fixedLines(_ pixels: Int64) -> Int64 {
        Int64((Double(pixels) / 10 * 65_536).rounded())
    }

    /// Closes whatever is open with a proper end.
    func finish() { if let current { emit(y: 0, x: 0, phase: .end, hint: current) } }

    /// Closes whatever is open and tells apps to stop any momentum of their own.
    func cancel() { if let current { emit(y: 0, x: 0, phase: .cancel, hint: current) } }

    /// A real trackpad sends these when two fingers touch it and lift off without scrolling.
    private func tap() {
        post(y: 0, x: 0, scroll: .mayBegin, momentum: .none)
        post(y: 0, x: 0, scroll: .cancelled, momentum: .none)
    }

    /// A wheel event carries its distance three ways (pixels, lines, fixed-point lines) and apps read whichever they
    /// like, so all three are filled in; a line is about 10 pixels.
    private func post(y: Int64, x: Int64, scroll: ScrollPhase, momentum: MomentumPhase) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(truncatingIfNeeded: y), wheel2: Int32(truncatingIfNeeded: x), wheel3: 0) else { return }
        let linesY = lineY.whole(Double(y) / 10), linesX = lineX.whole(Double(x) / 10)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scroll.rawValue)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
        // The line values go first: setting them rewrites the pixel values (as lines × 8), so the exact pixels come after.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: linesY)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: linesX)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: y)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: x)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Self.fixedLines(y))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Self.fixedLines(x))
        if let inverted = CGEventField(rawValue: 137) { event.setIntegerValueField(inverted, value: invertedFromDevice ? 1 : 0) }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: MouseFixService.marker)
        postEvent(event)
        if swipe, scroll != .none { postGesture(y: y, x: x, scroll: scroll) }
    }

    /// The companion "gesture" event a trackpad sends with every scroll phase, which Safari and others use to
    /// recognise a swipe (undocumented fields).
    private func postGesture(y: Int64, x: Int64, scroll: ScrollPhase) {
        guard let event = CGEvent(source: source),
              let type = CGEventField(rawValue: 55), let kind = CGEventField(rawValue: 110),
              let dx = CGEventField(rawValue: 116), let dy = CGEventField(rawValue: 119), let phase = CGEventField(rawValue: 132)
        else { return }
        event.setIntegerValueField(type, value: 29)
        event.setIntegerValueField(kind, value: 6)
        // The gesture moves a bit further than the pixels: it makes click-and-drag page swipes easy enough to trigger.
        event.setDoubleValueField(dx, value: x == 0 ? -0.0 : Double(x) * 1.67)
        event.setDoubleValueField(dy, value: y == 0 ? -0.0 : Double(y) * 1.67)
        event.setIntegerValueField(phase, value: scroll.rawValue)
        event.setIntegerValueField(.eventSourceUserData, value: MouseFixService.marker)
        postEvent(event)
    }
}

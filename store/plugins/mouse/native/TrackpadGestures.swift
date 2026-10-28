import ApplicationServices
import CoreGraphics
import Foundation

// The synthetic trackpad gestures below (smart zoom, pinch-zoom, rotation, Spaces / Mission Control swipes) use the
// undocumented event fields found by Mac Mouse Fix and the projects it credits (https://github.com/noah-nuebling/mac-mouse-fix,
// MMF License), translated to Swift: the event layout, the "origin offset" bookkeeping, the end-phase override and the
// repeated end events that unstick a swipe the system ignored under load.

enum TrackpadGestures {
    enum Phase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

    private static func field(_ number: UInt32) -> CGEventField { CGEventField(rawValue: number) ?? .eventSourceUserData }

    /// A gesture event (type 29) with its kind in field 110; the caller fills in the rest.
    private static func gesture(kind: Double) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(field(55), value: 29)
        event.setIntegerValueField(field(110), value: Int64(kind))
        return event
    }

    /// Two-finger double tap: zooms in on the content under the pointer (Safari, Preview…).
    static func smartZoom() { gesture(kind: 22)?.post(tap: .cghidEventTap) }

    /// Pinch to zoom: `amount` is a fraction (0.1 = 10%).
    static func magnify(_ amount: Double, phase: Phase) {
        guard let event = gesture(kind: 8) else { return }
        event.setIntegerValueField(field(132), value: phase.rawValue)
        event.setDoubleValueField(field(113), value: amount)
        event.post(tap: .cghidEventTap)
    }

    /// Two-finger rotation, in degrees.
    static func rotate(_ degrees: Double, phase: Phase) {
        guard let event = gesture(kind: 5) else { return }
        event.setIntegerValueField(field(132), value: phase.rawValue)
        event.setDoubleValueField(field(114), value: degrees)
        event.post(tap: .cghidEventTap)
    }
}

/// What a swipe does with its phases: the end becomes a cancel if the swipe was heading back where it started (so a
/// half-hearted swipe snaps back instead of committing), and an ending swipe carries the speed it was going at.
struct DockSwipeState {
    private(set) var origin = 0.0
    private(set) var last = 0.0

    /// Returns false when the event should be skipped (a change that moved nothing).
    mutating func update(delta: Double, phase: TrackpadGestures.Phase) -> Bool {
        switch phase {
        case .began: origin = delta
        case .changed:
            if delta == 0 { return false }
            origin += delta
        case .ended, .cancelled: break
        }
        return true
    }

    func exitSpeed(for phase: TrackpadGestures.Phase) -> Double { phase == .ended || phase == .cancelled ? last * 100 : 0 }

    /// An ended swipe whose last movement opposes its overall direction is a cancel.
    func resolved(_ phase: TrackpadGestures.Phase) -> TrackpadGestures.Phase {
        guard phase == .ended else { return phase }
        func sign(_ x: Double) -> Int { x > 0 ? 1 : x < 0 ? -1 : 0 }
        return sign(last) == sign(origin) ? .ended : .cancelled
    }

    mutating func finish(delta: Double) { last = delta }
}

/// Swipes between Spaces (horizontal), into Mission Control (vertical) and the pinch that shows Launchpad / the desktop.
final class DockSwipe {
    enum Kind: Int64 { case horizontal = 1, vertical = 2, pinch = 3 }

    private var state = DockSwipeState()
    private var resends: [DispatchWorkItem] = []

    /// `delta` follows the pointer's movement already scaled (see `Scale`); `inverted` is the natural-scrolling setting.
    func post(delta: Double, kind: Kind, phase: TrackpadGestures.Phase, inverted: Bool) {
        resends.forEach { $0.cancel() }
        resends.removeAll()
        guard state.update(delta: delta, phase: phase) else { return }
        let resolved = state.resolved(phase)
        let exit = state.exitSpeed(for: resolved)
        state.finish(delta: delta)

        guard let first = CGEvent(source: nil), let second = CGEvent(source: nil) else { return }
        let f = { (n: UInt32) in CGEventField(rawValue: n) ?? .eventSourceUserData }
        first.setDoubleValueField(f(55), value: 29)
        first.setDoubleValueField(f(41), value: 33231)

        second.setDoubleValueField(f(55), value: 30) // a "magnify" event carrying a dock-swipe payload
        second.setDoubleValueField(f(110), value: 23) // dock swipe
        second.setDoubleValueField(f(132), value: Double(resolved.rawValue))
        second.setDoubleValueField(f(134), value: Double(resolved.rawValue))
        second.setDoubleValueField(f(124), value: state.origin)
        // The origin again, as the bits of a 32-bit float inside a 64-bit integer.
        second.setIntegerValueField(f(135), value: Int64(Float(state.origin).bitPattern))
        second.setDoubleValueField(f(41), value: 33231)
        let encodedKind = Double(Float(bitPattern: UInt32(kind.rawValue)))
        second.setDoubleValueField(f(119), value: encodedKind)
        second.setDoubleValueField(f(139), value: encodedKind)
        second.setDoubleValueField(f(123), value: Double(kind.rawValue))
        second.setDoubleValueField(f(165), value: Double(kind.rawValue))
        second.setIntegerValueField(f(136), value: inverted ? 1 : 0)
        if resolved == .ended || resolved == .cancelled {
            second.setDoubleValueField(f(129), value: exit)
            second.setDoubleValueField(f(130), value: exit)
        }
        second.post(tap: .cgSessionEventTap)
        first.post(tap: .cgSessionEventTap)

        if resolved == .ended || resolved == .cancelled {
            // The system sometimes ignores the first end under load and leaves the swipe stuck; the same event again
            // a moment later frees it.
            for delay in [0.2, 0.5] {
                let work = DispatchWorkItem { second.post(tap: .cgSessionEventTap); first.post(tap: .cgSessionEventTap) }
                resends.append(work)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    /// How far a drag of `dx` / `dy` points moves a swipe, so a horizontal one follows the pointer across the Spaces.
    enum Scale {
        /// - spaces: how many Spaces are on the display; unknown counts as one, which is exact for two.
        static func horizontal(screenWidth: Double, spaces: Int) -> Double {
            let offsetForOneSpace = spaces <= 1 ? 2.0 : 1.0 + 1.0 / Double(spaces - 1)
            return offsetForOneSpace / (screenWidth + 63) // 63: the gap between Spaces
        }

        static func vertical(screenHeight: Double) -> Double { 1 / screenHeight }
    }
}

/// How many Spaces a display has, from the window server's own list (looked up at runtime: it isn't public API, and if
/// it isn't there the count is unknown, which only makes a swipe a little less exact).
enum SpaceCount {
    static func spaces(on display: CGDirectDisplayID) -> Int? {
        typealias Connection = @convention(c) () -> Int32
        typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard let connectionSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID"), // RTLD_DEFAULT
              let copySymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCopyManagedDisplaySpaces"),
              let list = unsafeBitCast(copySymbol, to: CopySpaces.self)(unsafeBitCast(connectionSymbol, to: Connection.self)())?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        var id: String?
        if let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() { id = CFUUIDCreateString(nil, uuid) as String? }
        let entry = list.first { ($0["Display Identifier"] as? String) == id } ?? (list.count == 1 ? list[0] : nil)
        return (entry?["Spaces"] as? [Any])?.count
    }
}

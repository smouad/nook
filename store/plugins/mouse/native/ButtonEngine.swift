import Foundation

/// Adapts the original Mac Mouse Fix ClickCycle recognizer to Nook's timer/action/drag effects.
/// Physical releases and pointer cleanup remain balanced by Nook even after the recognizer kills a cycle.
final class ButtonEngine {
    static let holdDelay = 0.25 // a press this long runs the button's hold action
    static let levelWindow = 0.26 // a press this soon after the last one is the next click of a double/triple click
    static let spacesDistance = 50.0 // px of travel for the one-shot Spaces/Mission Control shortcut
    static let dragDistance = 7.0 // px of travel before a drag starts scrolling or swiping

    enum Timer: Hashable { case hold, level }

    enum ScrollPhase: Equatable { case began, changed, ended }
    enum SwipePhase: Equatable { case began, changed, ended, cancelled }
    enum SwipeAxis: Equatable { case horizontal, vertical }

    enum Effect: Equatable {
        case run(String)
        /// Give clicks back that the button's rule had no action for.
        case replay(button: Int64, clicks: Int)
        /// Start the timer, replacing a running one with the same key; `nil` stops it.
        case timer(button: Int64, Timer, after: Double?)
        /// Detach (true) or reattach (false) the pointer from the mouse. Balanced across buttons.
        case freezePointer(Bool)
        /// A drag acting as a scroll gesture, in pixels of drag.
        case scroll(dx: Double, dy: Double, ScrollPhase)
        /// A drag acting as a three-finger swipe (Spaces left/right, Mission Control up/down), in pixels of drag.
        case swipe(SwipeAxis, dx: Double, dy: Double, SwipePhase)
    }

    private struct Cycle {
        var rule: MouseConfig.ButtonRule
        var level = 1
        var pressed = true
        var handled = false // an action fired or a drag started: nothing more happens for this press
        var frozen = false
        var scrolling = false
        var swipeAxis: SwipeAxis? // set once a swipe drag has started
        var travelled = (x: 0.0, y: 0.0)
    }

    private var cycles: [Int64: Cycle] = [:]
    private var frozenCount = 0
    private struct TimerKey: Hashable { var button: Int64; var kind: Timer }
    private var scheduled: [TimerKey: Foundation.Timer] = [:]
    private let callbackQueue = DispatchQueue(label: "nook.mouse.click-cycle")
    private lazy var clickCycle = ClickCycle(buttonQueue: callbackQueue)
    private let device = Device(identifier: 1)
    private var emitted: [Effect] = []
    private var triggerCallback: ClickCycleTriggerCallback {
        { [weak self] phase, level, device, number, onRelease in
            self?.trigger(phase, level, device, number, &onRelease)
        }
    }

    deinit {
        clickCycle.kill()
        for timer in scheduled.values { timer.invalidate() }
    }

    /// Whether the adapter still owns a press or a pending click for `button`.
    func isActive(_ button: Int64) -> Bool { cycles[button] != nil }

    // MARK: Input

    func press(_ button: Int64, rule: MouseConfig.ButtonRule) -> [Effect] {
        emitted = []
        if cycles[button] != nil { emitted += end(button) }
        var cycle = Cycle(rule: rule)
        if rule.drag != "none" { cycle.frozen = true; emitted += freeze(true) }
        cycles[button] = cycle
        withTimerCreation(button: button) {
            clickCycle.handleClick(device: device, button: Int(button), downNotUp: true,
                                   maxClickLevel: max(1, rule.maxLevel), triggerCallback: triggerCallback)
        }
        pruneTimers()
        return emitted
    }

    func release(_ button: Int64) -> [Effect] {
        guard var cycle = cycles[button] else { return [] }
        emitted = []
        cycle.pressed = false
        cycles[button] = cycle
        clickCycle.handleClick(device: device, button: Int(button), downNotUp: false,
                               maxClickLevel: max(1, cycle.rule.maxLevel), triggerCallback: triggerCallback)
        if let current = cycles[button] {
            if current.handled || !clickCycle.isActiveFor(button: NSNumber(value: button)) {
                emitted += end(button)
            } else if current.frozen {
                emitted += unfreeze(button)
            }
        }
        pruneTimers()
        return emitted
    }

    func timerFired(_ button: Int64, _ kind: Timer) -> [Effect] {
        guard let timer = scheduled.removeValue(forKey: TimerKey(button: button, kind: kind)), timer.isValid else { return [] }
        emitted = []
        // Foundation.Timer.fire runs the original timer closure, which queues its state transition.
        // Draining that serial queue keeps Nook's effect boundary synchronous and testable.
        timer.fire()
        callbackQueue.sync {}
        timer.invalidate()
        if let cycle = cycles[button], !cycle.pressed,
           !clickCycle.isActiveFor(button: NSNumber(value: button)) {
            emitted += end(button)
        }
        pruneTimers()
        return emitted
    }

    private func withTimerCreation(button: Int64, _ block: () -> Void) {
        precondition(CoolTimer.onCreate == nil)
        CoolTimer.onCreate = { [unowned self] interval, timer in
            let kind: Timer = interval == Self.holdDelay ? .hold : .level
            let key = TimerKey(button: button, kind: kind)
            scheduled.removeValue(forKey: key)?.invalidate()
            scheduled[key] = timer
            emitted.append(.timer(button: button, kind, after: interval))
        }
        defer { CoolTimer.onCreate = nil }
        block()
    }

    private func pruneTimers() {
        for key in scheduled.keys.filter({ scheduled[$0]?.isValid != true }) {
            scheduled.removeValue(forKey: key)
            emitted.append(.timer(button: key.button, key.kind, after: nil))
        }
    }

    private func killRecognition(_ button: Int64) {
        if clickCycle.isActiveFor(button: NSNumber(value: button)) { clickCycle.kill() }
    }

    private func trigger(_ phase: ClickCycleTriggerPhase, _ level: ClickLevel, _ device: Device,
                         _ number: ButtonNumber, _ onRelease: inout [UnconditionalReleaseCallback]) {
        let button = Int64(number)
        guard var cycle = cycles[button], !cycle.handled else { return }
        cycle.level = level
        cycles[button] = cycle
        let greaterLevel = level < cycle.rule.maxLevel
        let downEffect = cycle.rule.hold != "none" || cycle.rule.drag != "none" || cycle.rule.scroll != "none"
        switch phase {
        case .press where !greaterLevel && !downEffect,
             .release where !greaterLevel && downEffect,
             .levelExpired where greaterLevel:
            emitted += fire(button)
        case .hold where cycle.rule.hold != "none":
            emitted += fire(button, hold: true)
        default:
            break
        }
    }

    func drag(_ button: Int64, dx: Double, dy: Double) -> [Effect] {
        guard var cycle = cycles[button], cycle.pressed, cycle.rule.drag != "none" else { return [] }
        if cycle.scrolling {
            return [.scroll(dx: dx, dy: dy, .changed)]
        }
        if let axis = cycle.swipeAxis { return [.swipe(axis, dx: dx, dy: dy, .changed)] }
        guard !cycle.handled else { return [] }
        cycle.travelled.x += dx
        cycle.travelled.y += dy
        let distance = max(abs(cycle.travelled.x), abs(cycle.travelled.y))
        switch cycle.rule.drag {
        case "swipe":
            guard distance >= Self.dragDistance else { cycles[button] = cycle; return [] }
            // The axis is decided once and kept: vertical when the drag is mostly up/down, otherwise horizontal.
            let axis: SwipeAxis = abs(cycle.travelled.x) < abs(cycle.travelled.y) ? .vertical : .horizontal
            cycle.handled = true
            killRecognition(button)
            cycle.swipeAxis = axis
            cycles[button] = cycle
            return [.timer(button: button, .hold, after: nil), .timer(button: button, .level, after: nil),
                    .swipe(axis, dx: dx, dy: dy, .began)]
        case "scroll":
            guard distance >= Self.dragDistance else { cycles[button] = cycle; return [] }
            cycle.handled = true
            killRecognition(button)
            cycle.scrolling = true
            let travelled = cycle.travelled
            cycles[button] = cycle
            return [.timer(button: button, .hold, after: nil), .timer(button: button, .level, after: nil),
                    .scroll(dx: travelled.x, dy: travelled.y, .began)]
        default: // "spaces": like a three-finger swipe, right → the Space on the left, up → Mission Control, down → App Exposé
            guard distance >= Self.spacesDistance else { cycles[button] = cycle; return [] }
            cycle.handled = true
            killRecognition(button)
            cycles[button] = cycle
            let action = abs(cycle.travelled.x) > abs(cycle.travelled.y)
                ? (cycle.travelled.x > 0 ? "spaceLeft" : "spaceRight")
                : (cycle.travelled.y < 0 ? "missionControl" : "appExpose")
            return [.timer(button: button, .hold, after: nil), .timer(button: button, .level, after: nil), .run(action)]
        }
    }

    /// What the wheel should do while a button that maps one is held ("zoom", "horizontal", "quick", "precise", …), if any.
    /// Using it counts as the button's gesture, so releasing it doesn't also click.
    func scrollWhileHeld() -> (mode: String, effects: [Effect])? {
        guard let button = cycles.keys.sorted().first(where: { cycles[$0]?.pressed == true && cycles[$0]?.rule.scroll != "none" }),
              var cycle = cycles[button] else { return nil }
        guard !cycle.handled else { return (cycle.rule.scroll, []) }
        cycle.handled = true
        killRecognition(button)
        cycles[button] = cycle
        return (cycle.rule.scroll, [.timer(button: button, .hold, after: nil), .timer(button: button, .level, after: nil)])
    }

    /// Abandon everything (the helper is being turned off, or the tap was interrupted).
    func cancelAll() -> [Effect] {
        clickCycle.kill()
        for timer in scheduled.values { timer.invalidate() }
        scheduled.removeAll()
        return cycles.keys.sorted().flatMap { end($0, cancelled: true) }
    }

    // MARK: Helpers

    /// The click of `button`'s current level (or its hold) goes off: run the mapped action, or give the clicks back.
    private func fire(_ button: Int64, hold: Bool = false) -> [Effect] {
        guard var cycle = cycles[button], !cycle.handled else { return [] }
        cycle.handled = true
        killRecognition(button)
        cycles[button] = cycle
        let action = hold ? cycle.rule.hold : cycle.rule.action(level: cycle.level)
        return [action == "none" ? .replay(button: button, clicks: cycle.level) : .run(action)]
    }

    private func end(_ button: Int64, cancelled: Bool = false) -> [Effect] {
        guard let cycle = cycles.removeValue(forKey: button) else { return [] }
        var effects: [Effect] = [.timer(button: button, .hold, after: nil), .timer(button: button, .level, after: nil)]
        if cycle.scrolling { effects.append(.scroll(dx: 0, dy: 0, .ended)) }
        if let axis = cycle.swipeAxis { effects.append(.swipe(axis, dx: 0, dy: 0, cancelled ? .cancelled : .ended)) }
        if cycle.frozen { effects += freeze(false) }
        return effects
    }

    /// Reattach the pointer now (the button is up) but keep the cycle, which is waiting for another click.
    private func unfreeze(_ button: Int64) -> [Effect] {
        guard var cycle = cycles[button], cycle.frozen else { return [] }
        cycle.frozen = false
        cycles[button] = cycle
        return freeze(false)
    }

    private func freeze(_ on: Bool) -> [Effect] {
        if on {
            frozenCount += 1
            return frozenCount == 1 ? [.freezePointer(true)] : []
        }
        frozenCount = max(0, frozenCount - 1)
        return frozenCount == 0 ? [.freezePointer(false)] : []
    }
}

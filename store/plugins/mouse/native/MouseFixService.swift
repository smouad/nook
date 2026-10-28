import AppKit

/// Mouse tab engine: smooth wheel scrolling, scroll modifiers and button remapping for any mouse.
///
/// One active event tap (needs Accessibility) runs on its own thread, so scrolling stays smooth even while the
/// notch UI is busy. It only handles wheel clicks and the extra buttons (middle, back, forward…): left/right
/// clicks and pointer movement are never touched. The tap drains outstanding releases before stopping.
final class MouseFixService {
    /// Stamped on events we post so our own tap lets them through.
    static let marker: Int64 = 0x4E4F_4F4B

    private let lock = NSLock()
    private var _config = MouseConfig.load()
    private var _learning = false
    private var _running = false
    private var _error: String?

    private var tapThread: TapThread?
    private var trustTimer: Timer?
    private var learnTimeout: DispatchWorkItem?

    var config: MouseConfig {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue }; newValue.save() }
    }

    fileprivate var learning: Bool { lock.withLock { _learning } }
    private var isRunning: Bool { lock.withLock { _running } }
    fileprivate func report(running: Bool, error: String? = nil) {
        lock.withLock { _running = running; _error = error }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            PluginEvents.emit("mouse", self.state(), to: "mouse")
        }
    }

    // MARK: Lifecycle

    func start() { reconfigure(prompt: false) }

    func shutdown() {
        learnTimeout?.cancel(); learnTimeout = nil
        trustTimer?.invalidate(); trustTimer = nil
        tapThread?.stopAndWait()
        tapThread = nil
        CGAssociateMouseAndMouseCursorPosition(1) // never leave the pointer frozen
    }

    /// Keep a live tap until every swallowed physical button has released. Permission and tap
    /// failures are retried while wanted, including permission revocation after successful startup.
    private func reconfigure(prompt: Bool) {
        let wanted = config.enabled || learning
        if !wanted {
            tapThread?.setWanted(false)
            trustTimer?.invalidate()
            trustTimer = nil
            return
        }
        if trustTimer == nil {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.reconfigure(prompt: false)
            }
        }
        guard AXIsProcessTrusted() else {
            tapThread?.setWanted(false)
            report(running: false, error: "Allow Nook in Accessibility to use mouse controls.")
            if prompt {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            return
        }
        if let thread = tapThread, !thread.isFinished {
            thread.setWanted(true)
            return
        }
        let thread = TapThread(service: self)
        tapThread = thread
        thread.start()
    }

    // MARK: Bridge

    func handle(_ fn: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        switch fn {
        case "state": break
        case "set":
            guard let next = config.merging(args.first as? [String: Any] ?? [:]) else { return reply(nil, "Invalid setting") }
            let turnedOn = next.enabled && !config.enabled // only the switch asks for Accessibility, not every slider move
            config = next
            reconfigure(prompt: turnedOn)
        case "setButton":
            guard let button = args.first as? String ?? (args.first as? NSNumber)?.stringValue, (Int(button) ?? 0) >= 2 else {
                return reply(nil, "Only the extra buttons (middle, back, forward…) can be remapped")
            }
            var next = config
            let current = next.buttons[button] ?? MouseConfig.ButtonRule()
            var json = (try? JSONEncoder().encode(current)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            for (k, v) in (args.dropFirst().first as? [String: Any]) ?? [:] where json[k] != nil { json[k] = v }
            if let data = try? JSONSerialization.data(withJSONObject: json), let rule = try? JSONDecoder().decode(MouseConfig.ButtonRule.self, from: data) {
                next.buttons[button] = rule
            }
            next.normalize()
            config = next
        case "applyPreset":
            guard let name = args.first as? String, name == "defaults" || name == "mmf" else { return reply(nil, "Unknown preset") }
            var next = config.applyingMMFDefaults()
            next.normalize()
            config = next
        case "removeButton":
            var next = config
            next.buttons[args.first as? String ?? ""] = nil
            config = next
        case "learn":
            setLearning(args.first as? Bool ?? false)
        case "openPrivacy":
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        default:
            return reply(nil, "Unknown mouse call: \(fn)")
        }
        reply(state(), nil)
    }

    private func setLearning(_ on: Bool) {
        learnTimeout?.cancel()
        lock.withLock { _learning = on }
        if on {
            let timeout = DispatchWorkItem { [weak self] in
                self?.lock.withLock { self?._learning = false }
                self?.reconfigure(prompt: false)
                PluginEvents.emit("mouse", ["learning": false], to: "mouse")
            }
            learnTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        }
        reconfigure(prompt: on)
    }

    private func state() -> [String: Any] {
        [
            "config": config.json,
            "trusted": AXIsProcessTrusted(),
            "running": isRunning,
            "error": lock.withLock { _error } as Any? ?? NSNull(),
            "learning": learning,
            "actions": MouseActions.all.map { ["id": $0.id, "label": $0.label] },
            "engine": MouseEngineProvenance.json,
        ]
    }

    /// Tap thread → main: a button was pressed while learning.
    fileprivate func learned(button: Int64) {
        // Claim the single learning result on the tap thread; a second overlapping press must
        // not become another learned button while the main queue is handling the first one.
        let accepted = lock.withLock {
            let wasLearning = _learning
            _learning = false
            return wasLearning
        }
        guard accepted else { return }
        DispatchQueue.main.async { [self] in
            learnTimeout?.cancel()
            reconfigure(prompt: false)
            PluginEvents.emit("mouse", ["learning": false, "button": button], to: "mouse")
        }
    }
}

/// Owns the event tap and its run loop. Everything inside runs on this thread.
private final class TapThread: Thread {
    private unowned let service: MouseFixService
    private let scroller: MouseScroller
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop? { get { loopLock.withLock { _runLoop } } set { loopLock.withLock { _runLoop = newValue } } }
    private var _runLoop: CFRunLoop?
    private let loopLock = NSLock()
    private let exited = DispatchSemaphore(value: 0)

    private var balance = MouseButtonBalance()
    private let buttons = ButtonEngine() // decides what presses, releases and drags mean
    private struct TimerKey: Hashable { var button: Int64; var kind: ButtonEngine.Timer }
    private var timers: [TimerKey: CFRunLoopTimer] = [:]
    private var frozen = false // we detached the pointer from the mouse and must give it back
    private let dragScroll = ScrollOutput() // a button drag that scrolls
    private var dragPixels = (y: BiasedSubPixelator(), x: BiasedSubPixelator())
    private var dragScrollSign = 1.0
    private let swipe = DockSwipe()
    private var swipeScale = 0.0
    private var swipeNatural = true

    init(service: MouseFixService) {
        self.service = service
        scroller = MouseScroller { [unowned service] in service.config }
        super.init()
        name = "nook.mouse"
        qualityOfService = .userInteractive
    }

    /// Draining cancels actions and scrolling, but retains the tap to consume owed releases.
    func setWanted(_ wanted: Bool) {
        guard let runLoop else { return } // startup reads the current service state before running
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            let wasDraining = balance.draining
            balance.setWanted(wanted)
            if wanted, let tap {
                guard CFMachPortIsValid(tap) else {
                    CFRunLoopStop(CFRunLoopGetCurrent())
                    return
                }
                CGEvent.tapEnable(tap: tap, enable: true)
                if wasDraining { service.report(running: true) }
            }
            if !wanted || !service.config.enabled {
                cancelButtons()
                scroller.cancelScroll()
            }
            if balance.canStop { CFRunLoopStop(CFRunLoopGetCurrent()) }
        }
        CFRunLoopWakeUp(runLoop)
    }

    func stopAndWait() {
        cancel() // main() checks this before it starts running, so a thread that's still setting up won't run forever
        if let runLoop {
            // Queued, not stopped directly: a stop sent before the loop is running would be lost.
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
            CFRunLoopWakeUp(runLoop)
        }
        if !isFinished { _ = exited.wait(timeout: .now() + 1) }
    }

    override func main() {
        defer { exited.signal() }
        guard !isCancelled else { return }
        let events: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<TapThread>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            service.report(running: false, error: "Couldn't start the mouse event tap. Check Accessibility; Nook will retry automatically.")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        scroller.start()
        CGEvent.tapEnable(tap: tap, enable: true)
        service.report(running: true)
        balance.setWanted(service.config.enabled || service.learning)
        if !isCancelled && !balance.canStop { CFRunLoopRun() }

        service.report(running: false)
        cancelButtons()
        scroller.stop()
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)
    }

    // MARK: Events

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelButtons()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == MouseFixService.marker { return pass } // ours
        let config = service.config
        let wanted = config.enabled || service.learning
        // Observe settings here too: a release may beat the queued reconfiguration block.
        if !wanted, !balance.draining {
            balance.setWanted(false)
            cancelButtons()
            scroller.cancelScroll()
        }

        switch type {
        case .scrollWheel:
            guard config.enabled, !balance.draining else { return pass }
            // A held button that maps the wheel decides what it does (zoom, sideways, …), and counts as its gesture.
            if let held = buttons.scrollWhileHeld() {
                perform(held.effects)
                return scroller.handle(event, held: held.mode)
            }
            return scroller.handle(event)

        case .otherMouseDown:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            // A repeat cannot turn a suppressed press into a visible one while draining.
            if balance.suppressed.contains(button) { return nil }
            guard !balance.draining else { return pass }
            if service.learning, balance.suppress(button) {
                service.learned(button: button)
                return nil
            }
            guard config.enabled, let rule = config.buttons[String(button)], rule.isActive,
                  balance.suppress(button) else { return pass }
            perform(buttons.press(button, rule: rule))
            return nil

        case .otherMouseDragged:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            guard balance.suppressed.contains(button) else { return pass }
            perform(buttons.drag(button, dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY)))
            return nil

        case .otherMouseUp:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            guard balance.release(button) else { return pass }
            perform(buttons.release(button))
            if balance.canStop { CFRunLoopStop(CFRunLoopGetCurrent()) }
            return nil

        default:
            return pass
        }
    }

    // MARK: Button gestures

    /// Carry out what the button engine decided.
    private func perform(_ effects: [ButtonEngine.Effect]) {
        for effect in effects {
            switch effect {
            case let .run(action):
                if service.config.enabled, !balance.draining { MouseActions.run(action) }
            case let .replay(button, clicks):
                MouseActions.click(button: button, count: clicks) // a click the button had no action for: give it back
            case let .timer(button, kind, after):
                let key = TimerKey(button: button, kind: kind)
                if let old = timers.removeValue(forKey: key) { CFRunLoopTimerInvalidate(old) }
                guard let after else { continue }
                let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + after, 0, 0, 0) { [weak self] _ in
                    guard let self else { return }
                    timers[key] = nil
                    guard service.config.enabled, !balance.draining else { return }
                    perform(buttons.timerFired(button, kind))
                }
                CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
                timers[key] = timer
            case let .freezePointer(on):
                if on, !frozen {
                    CGAssociateMouseAndMouseCursorPosition(0) // the pointer stays put while you drag
                    frozen = true
                } else if !on, frozen {
                    CGAssociateMouseAndMouseCursorPosition(1)
                    frozen = false
                }
            case let .scroll(dx, dy, phase):
                scrollFromDrag(dx: dx, dy: dy, phase: phase)
            case let .swipe(axis, dx, dy, phase):
                swipeFromDrag(axis: axis, dx: dx, dy: dy, phase: phase)
            }
        }
    }

    /// A button drag acting as two fingers on a trackpad: content follows the pointer's movement.
    private func scrollFromDrag(dx: Double, dy: Double, phase: ButtonEngine.ScrollPhase) {
        switch phase {
        case .began:
            let natural = (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? true
            dragScroll.reset()
            dragScroll.swipe = true
            dragScroll.invertedFromDevice = natural
            dragPixels = (BiasedSubPixelator(), BiasedSubPixelator())
            dragScrollSign = natural ? 1 : -1
            dragScroll.emit(y: dragPixels.y.whole(dy * dragScrollSign), x: dragPixels.x.whole(dx * dragScrollSign), phase: .start, hint: .gesture)
        case .changed:
            let y = dragPixels.y.whole(dy * dragScrollSign), x = dragPixels.x.whole(dx * dragScrollSign)
            if y != 0 || x != 0 { dragScroll.emit(y: y, x: x, phase: .continue, hint: .gesture) }
        case .ended:
            dragScroll.finish()
            dragScroll.reset()
        }
    }

    /// A button drag acting as three fingers on a trackpad: sideways moves between Spaces, up/down into Mission Control.
    private func swipeFromDrag(axis: ButtonEngine.SwipeAxis, dx: Double, dy: Double, phase: ButtonEngine.SwipePhase) {
        if phase == .began {
            let at = CGEvent(source: nil)?.location ?? .zero
            var id = CGDirectDisplayID(), count: UInt32 = 0
            CGGetDisplaysWithPoint(at, 1, &id, &count)
            let size = count > 0 ? CGDisplayBounds(id).size : CGSize(width: 1440, height: 900)
            swipeScale = (axis == .horizontal
                ? DockSwipe.Scale.horizontal(screenWidth: Double(size.width), spaces: count > 0 ? SpaceCount.spaces(on: id) ?? 1 : 1)
                : DockSwipe.Scale.vertical(screenHeight: Double(size.height)))
            swipeNatural = (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? true
        }
        let flip = swipeNatural ? 1.0 : -1.0 // the drag is flipped for "unnatural" scrolling
        let delta = axis == .horizontal ? -dx * flip * swipeScale : dy * flip * swipeScale
        let gesture: TrackpadGestures.Phase = phase == .began ? .began : phase == .changed ? .changed : phase == .ended ? .ended : .cancelled
        swipe.post(delta: delta, kind: axis == .horizontal ? .horizontal : .vertical, phase: gesture, inverted: swipeNatural)
    }

    /// Abandon every button in progress: stop timers, reattach the pointer, end a drag scroll. Presses already
    /// swallowed keep their releases owed through `balance`.
    private func cancelButtons() {
        perform(buttons.cancelAll())
        for timer in timers.values { CFRunLoopTimerInvalidate(timer) }
        timers.removeAll()
        if frozen {
            CGAssociateMouseAndMouseCursorPosition(1)
            frozen = false
        }
    }
}

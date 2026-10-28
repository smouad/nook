import AppKit

/// End-to-end wheel/frame checks with in-memory CGEvents and replaceable output/scheduling.
/// No event tap, display link, user preferences, permissions, or posted input is involved.
enum ScrollerTests {
    private final class Frames: ScrollFrameDriver {
        var isRunning = false
        var starts = 0
        var stops = 0
        func start() -> Bool { starts += 1; isRunning = true; return true }
        func stop() { stops += 1; isRunning = false }
    }
    private final class GestureSink: GlideOutput {
        struct Frame { var y: Int64; var x: Int64; var phase: ScrollOutput.Phase }
        var frames: [Frame] = []
        var finishes = 0
        var cancellations = 0
        func emit(y: Int64, x: Int64, phase: ScrollOutput.Phase, hint: ScrollOutput.Hint) {
            frames.append(Frame(y: y, x: x, phase: phase))
        }
        func finish() { finishes += 1 }
        func cancel() { cancellations += 1 }
        func reset() {}
    }
    private final class Harness {
        var config: MouseConfig
        var now = 100.0
        var events: [CGEvent] = []
        let frames = Frames()
        let gestures = GestureSink()
        lazy var output = ScrollOutput { [unowned self] in events.append($0) }
        lazy var scroller = MouseScroller(config: { [unowned self] in config }, scrollOutput: output,
                                         gestureOutput: gestures, clock: { [unowned self] in now }, frameDriver: frames)
        init(smoothness: String = "high", speedMode: String = "medium") {
            config = MouseConfig()
            config.enabled = true
            config.reverse = false
            config.horizontalModifier = "shift"
            config.quickModifier = "none"
            config.preciseModifier = "none"
            config.zoomModifier = "none"
            config.smoothness = smoothness
            config.speedMode = speedMode
            NookMMFAnalyzerSetClockForTesting(now)
            NookMMFAnalyzerReset()
        }
        func wheel(points: Int64 = 37, flags: CGEventFlags = [], held: String? = nil) -> Unmanaged<CGEvent>? {
            NookMMFAnalyzerSetClockForTesting(now)
            let event = CGEvent(source: nil)!
            event.type = .scrollWheel
            event.timestamp = 0 // Use the injected monotonic clock.
            event.flags = flags
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(points.signum()))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: points)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
            return scroller.handle(event, held: held)
        }
        func advance(_ seconds: Double, render: Bool = true) {
            now += seconds
            NookMMFAnalyzerSetClockForTesting(now)
            if render { scroller.step() }
        }
    }

    static func run() -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        defer { NookMMFAnalyzerReset(); NookMMFAnalyzerSetClockForTesting(.nan) }
        func pixels(_ event: CGEvent, _ axis: Int = 1) -> Int64 {
            event.getIntegerValueField(axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2)
        }

        let off = Harness(smoothness: "off")
        check(off.wheel() == nil, "Off consumes a wheel tick through MMF's accelerated output path")
        check(off.events.count == 1 && pixels(off.events[0]) == 30, "A first off tick maps the analyzer sentinel to the MMF minimum")
        let line = off.events[0]
        check(line.type == .scrollWheel && line.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              "Off emits the original noncontinuous LineScroll event type")
        check(line.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3 &&
              line.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1) == 196_608,
              "Off preserves MMF line and 16.16 fixed-point representations")
        check(!off.frames.isRunning, "Off does not start a display link")
        off.advance(0.01, render: false)
        check(off.wheel() == nil && pixels(off.events.last!) > 30, "A fast off tick still uses the original acceleration curve")

        let system = Harness(smoothness: "off", speedMode: "system")
        check(system.wheel(points: 37) == nil && pixels(system.events[0]) == 37,
              "System speed preserves the physical event's pixel distance")
        check(system.events[0].getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3 &&
              system.events[0].getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1) == 242_483,
              "System output truncates lines and rounds fixed point exactly like MMF")
        system.advance(0.05, render: false)
        check(system.wheel(points: -7, flags: .maskShift) == nil && pixels(system.events.last!, 2) == -7,
              "System speed reads the original input axis before horizontal remapping")
        check(pixels(system.events.last!) == 0 && system.events.last!.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -1,
              "Small horizontal distances retain a signed minimum-one line delta")
        check(!system.events.last!.flags.contains(.maskShift), "A used horizontal modifier is hidden from the target app")

        let animated = Harness()
        check(animated.wheel() == nil && animated.events.contains { pixels($0) > 0 }, "A cold high-smoothness tick emits an immediate frame")
        check(animated.frames.isRunning, "Animated scrolling starts the injected frame driver")
        let beforeSwitch = animated.events.count
        animated.advance(0.03, render: false)
        check(animated.wheel(flags: .maskShift) == nil, "Horizontal modifier consumes its first tick")
        let afterSwitch = Array(animated.events.dropFirst(beforeSwitch))
        check(afterSwitch.contains { pixels($0, 2) > 0 }, "Horizontal modifier restarts output immediately instead of swallowing the first tick")
        check(afterSwitch.allSatisfy { pixels($0) == 0 }, "Horizontal modifier cancels the old vertical glide before the new frame")
        check(afterSwitch.contains { $0.getIntegerValueField(.scrollWheelEventScrollPhase) == 8 },
              "A modifier change sends a cancellation to the old scroll gesture")
        animated.advance(0.03, render: false)
        check(animated.wheel(held: "zoom") == nil && !animated.gestures.frames.isEmpty,
              "Switching from scrolling to zoom uses the injected gesture sink")
        check(animated.gestures.frames.first?.phase == .start, "The pure touch-driver Bezier begins a fresh gesture")
        animated.advance(0.3)
        check(animated.gestures.finishes == 1 && animated.gestures.frames.reduce(Int64(0)) { $0 + $1.y + $1.x } == 60,
              "A pure touch-driver tick completes exactly its MMF medium-speed distance")

        let animatedSystem = Harness(speedMode: "system")
        check(animatedSystem.wheel(points: 37) == nil, "Animated system speed consumes input")
        animatedSystem.advance(1)
        check(animatedSystem.events.reduce(Int64(0)) { $0 + pixels($1) } == 37,
              "Animated system speed covers exactly the system pixel amount")

        for regular in [false, true] {
            let changedStyle = Harness()
            _ = changedStyle.wheel()
            let previousCount = changedStyle.events.count
            changedStyle.advance(0.03, render: false)
            if regular { changedStyle.config.smoothness = "regular" }
            else { changedStyle.config.scrollStyle = "classic" }
            _ = changedStyle.wheel()
            let switched = Array(changedStyle.events.dropFirst(previousCount))
            check(switched.contains { $0.getIntegerValueField(.scrollWheelEventScrollPhase) == 8 },
                  "Changing output style closes the previous trackpad gesture")
            check(switched.contains { pixels($0) > 0 && $0.getIntegerValueField(.scrollWheelEventScrollPhase) == 0 },
                  "The new regular/Classic glide starts immediately with unphased output")
            let plainCount = changedStyle.events.count
            changedStyle.config.smoothness = "high"
            changedStyle.config.scrollStyle = "trackpad"
            changedStyle.advance(0.03, render: false)
            _ = changedStyle.wheel()
            check(changedStyle.events.dropFirst(plainCount).first(where: { pixels($0) > 0 })?
                    .getIntegerValueField(.scrollWheelEventScrollPhase) == 1,
                  "Changing back to trackpad style starts with began, not changed")
        }
        return checks
    }
}

import CoreGraphics
import CoreVideo
import Foundation

protocol ScrollFrameDriver: AnyObject {
    var isRunning: Bool { get }
    func start() -> Bool
    func stop()
}


// The scrolling model (tick analysis, acceleration, fast scroll, the constant-speed-then-drag glide that restarts on
// every tick, cancelling on a tick the other way) is adapted from Mac Mouse Fix by Noah Nuebling
// (https://github.com/noah-nuebling/mac-mouse-fix, MMF License), translated to Swift.

/// Turns a mouse wheel's clicks into smooth, pixel-based scrolling.
///
/// Every tick is analysed (how fast the wheel is spinning, how many quick swipes in a row) to decide how far it scrolls.
/// That distance, plus whatever is left of the previous glide, becomes a new glide: constant speed for a moment, then a
/// drag curve that eases out, so a click doesn't feel like a jump and a spin carries on a little. A tick the other
/// way stops the glide (and is swallowed). Trackpads and Magic Mouse send continuous events, which are left alone.
///
/// State is only touched from the event tap's thread; the display link just hands frames over to it.
final class MouseScroller {
    private let config: () -> MouseConfig
    private var analyzer = MouseScrollAnalyzer()
    private var mode = ScrollProfile.Mode.normal
    private var profile = ScrollProfile.make(MouseConfig(), mode: .normal, horizontal: false, screenPixels: 1080)
    private let scrollOutput: ScrollOutput
    private let gestureOutput = GestureOutput()
    private let gestureSink: GlideOutput?
    private let clock: () -> Double
    private let frameDriver: ScrollFrameDriver?
    private lazy var output: GlideOutput = scrollOutput

    private struct Glide {
        var vector: (y: Double, x: Double) // everything this glide scrolls
        var curve: ScrollGlide
        var start: Double
        var lastValue = 0.0
        var lastFrame: Double
        var gestureUntil: Double // until then the glide is the "fingers down" gesture, not momentum
        var speed = 0.0 // px/s of the last frame; 0 until a frame has moved
        var started = false // the first frame has been sent
    }
    private var glide: Glide?
    private var pixelY = BiasedSubPixelator(), pixelX = BiasedSubPixelator()
    private var lastTick = -Double.infinity
    private var horizontalOverride = false
    private var display = (width: 1920.0, height: 1080.0)

    private var frames: CVDisplayLink? // ticks once per screen refresh, so apps get one event per frame
    private var idleUntil = 0.0 // the display link stays up until then after a scroll, so the next one starts without delay
    private var activity: NSObjectProtocol?
    private var framePending = false
    private let pendingLock = NSLock()

    /// The "fingers down" part of a glide lasts at least this long after each tick; later it can turn into momentum.
    private static let gestureHold = 0.16
    private static let frameTime = 1.0 / 60
    private static let linkIdle = 0.75

    init(config: @escaping () -> MouseConfig, scrollOutput: ScrollOutput = ScrollOutput(),
         gestureOutput: GlideOutput? = nil, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         frameDriver: ScrollFrameDriver? = nil) {
        self.config = config
        self.scrollOutput = scrollOutput
        self.gestureSink = gestureOutput
        self.clock = clock
        self.frameDriver = frameDriver
    }

    /// Call on the thread whose run loop drives the animation.
    func start() {
        guard frameDriver == nil else { return }
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        // The display link calls from its own thread; hop back so all state stays on this one.
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            self?.requestFrame(on: runLoop)
            return kCVReturnSuccess
        }
        frames = link
    }

    func stop() {
        cancelScroll()
        frames = nil
    }

    /// Stops the glide where it is, telling apps the swipe was cancelled so they don't coast on their own.
    func cancelScroll() {
        if glide != nil { output.cancel() }
        glide = nil
        output.reset()
        pixelY.reset(); pixelX.reset()
        idleUntil = 0
        stopFrames()
    }

    private func requestFrame(on runLoop: CFRunLoop) {
        pendingLock.lock()
        let skip = framePending // a frame is already queued; don't pile up
        framePending = true
        pendingLock.unlock()
        guard !skip else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            pendingLock.lock(); framePending = false; pendingLock.unlock()
            step()
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Drive the animation from the screen the pointer is on. False if frames can't be produced.
    private func startFrames() -> Bool {
        if let frameDriver { return frameDriver.start() }
        guard let frames else { return false }
        if CVDisplayLinkIsRunning(frames) { return true }
        var id = CGDirectDisplayID(), count: UInt32 = 0
        CGGetDisplaysWithPoint(CGEvent(source: nil)?.location ?? .zero, 1, &id, &count)
        if count > 0 {
            CVDisplayLinkSetCurrentCGDisplay(frames, id)
            display = (Double(CGDisplayPixelsWide(id)), Double(CGDisplayPixelsHigh(id)))
        }
        guard CVDisplayLinkStart(frames) == kCVReturnSuccess else { return false }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                        reason: "Animating mouse scroll")
        return true
    }

    private func stopFrames() {
        frameDriver?.stop()
        if let frames, CVDisplayLinkIsRunning(frames) { CVDisplayLinkStop(frames) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: Input

    /// Returns nil when the event was consumed, or the event (possibly edited) to pass on.
    /// - held: what the wheel should do because a mapped mouse button is held ("zoom", "horizontal", "quick"…).
    func handle(_ event: CGEvent, held: String? = nil) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // Only a plain, one-axis wheel: trackpads, Magic Mouse, tablets and our own events carry phases or pixels.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.tabletEventDeviceID) == 0,
              !(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) != 0 && event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) != 0)
        else { return pass }
        let c = config()
        var outFlags = event.flags

        var dy = Self.tick(event, axis: 1), dx = Self.tick(event, axis: 2)
        guard dy != 0 || dx != 0 else { return pass }
        // Each effect comes from a held mouse button or from a modifier key; a used modifier is hidden from the app.
        func wanted(_ name: String, _ modifier: String) -> Bool {
            if held == name { return true }
            guard Self.active(modifier, in: outFlags) else { return false }
            outFlags.subtract(Self.mask(modifier))
            return true
        }
        let swapAxes = wanted("horizontal", c.horizontalModifier)
        if swapAxes { swap(&dy, &dx) }
        let gesture = held.flatMap(ScrollProfile.Mode.init) ?? (wanted("zoom", c.zoomModifier) ? .zoom : nil)
        let quick = gesture == nil && wanted("quick", c.quickModifier)
        let precise = gesture == nil && !quick && wanted("precise", c.preciseModifier)
        if c.reverse { dy = -dy; dx = -dx }

        let newMode: ScrollProfile.Mode = gesture ?? (quick ? .quick : precise ? .precise : .normal)
        if newMode != mode || swapAxes != horizontalOverride {
            cancelScroll()
            mode = newMode
            horizontalOverride = swapAxes
            analyzer.reset()
        }
        let nextProfile = ScrollProfile.make(c, mode: mode, horizontal: dy == 0, screenPixels: dy == 0 ? display.width : display.height)
        if glide != nil, !mode.isGesture, profile.sendsGesture != nextProfile.sendsGesture {
            // Close an in-flight trackpad gesture before changing its output format.
            cancelScroll()
            analyzer.reset()
        }
        profile = nextProfile

        // Unanimated scrolling still uses MMF's acceleration and fast-scroll analysis. Only a failed
        // display link falls back to the original wheel event.
        let cold = !(frameDriver?.isRunning ?? frames.map { CVDisplayLinkIsRunning($0) } ?? false)
        guard !profile.animated || startFrames() else {
            cancelScroll()
            let factor = c.speed * (precise ? 0.25 : 1) * (quick ? 3 : 1)
            return passThrough(event, swapAxes: swapAxes, reverse: c.reverse, factor: factor, flags: outFlags)
        }

        let now = clock()
        let time = Self.seconds(of: event) ?? now
        let direction = dy != 0 ? (dy > 0 ? 1 : 3) : (dx > 0 ? 2 : 4) // upstream MFDirection up/right/down/left
        let remaining = remainingVector()
        if MouseWheelReversal.shouldFilter(dy: dy, dx: dx, remainingY: remaining.y, remainingX: remaining.x,
                                          gap: time - lastTick, filterChatter: c.filterChatter) { return nil }
        lastTick = time

        // Starting the display link refreshes its display dimensions.
        profile = ScrollProfile.make(c, mode: mode, horizontal: dy == 0, screenPixels: dy == 0 ? display.width : display.height)
        analyzer.tickIntervalMax = profile.tickIntervalMax
        analyzer.swipeMaxInterval = profile.swipeMaxInterval
        analyzer.swipeMinTickSpeed = profile.swipeMinTickSpeed
        analyzer.primesInterval = profile.primesInterval
        let analysis = analyzer.update(time: time, direction: direction)

        // A tick the other way while scrolling stops the scroll, and that tick does nothing else.
        if !profile.usesSystemSpeed, analysis.directionChanged, let glide, glide.speed > 0 {
            cancelScroll()
            return nil
        }

        let pixels: Double
        if profile.usesSystemSpeed {
            let inputAxis = swapAxes ? (dy == 0 ? 1 : 2) : (dy == 0 ? 2 : 1)
            let field: CGEventField = inputAxis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
            pixels = abs(Double(event.getIntegerValueField(field)))
        } else {
            pixels = floor(floor(profile.acceleration.pixels(forTickInterval: analysis.tickInterval))
                * (profile.speedup?.factor(swipes: Double(analysis.swipeCounter + 1)) ?? 1))
        }
        let sign = (dy != 0 ? dy : dx) > 0 ? 1.0 : -1.0
        if !profile.animated {
            cancelScroll()
            scrollOutput.swipe = false
            scrollOutput.flags = outFlags
            scrollOutput.invertedFromDevice = true
            scrollOutput.emitUnanimated(y: dy != 0 ? Int64(sign * pixels) : 0,
                                        x: dy == 0 ? Int64(sign * pixels) : 0)
            return nil
        }

        var left = remaining
        let freshSwipe = analysis.tickCounter == 0 && analysis.swipeCounter == 0
        if glide == nil || freshSwipe {
            pixelY.reset(); pixelX.reset()
            if freshSwipe { left = (0, 0) } // a new swipe doesn't inherit the old one's leftovers
        }
        let vector = (y: left.y + (dy != 0 ? sign * pixels : 0), x: left.x + (dy == 0 ? sign * pixels : 0))
        let distance = hypot(vector.y, vector.x)
        guard distance >= 1 else { return nil }

        let baseDuration = profile.baseDuration(analysis.tickInterval)
        let controlPoints = profile.speedSmoothing.map {
            ScrollGlide.speedSmoothingControlPoints(amount: $0, currentSpeed: glide?.speed ?? 0,
                                                   distance: distance, baseDuration: baseDuration)
        } ?? profile.baseControlPoints
        let curve = ScrollGlide(distance: distance, baseDuration: baseDuration,
                                dragA: profile.dragA, dragB: profile.dragB, stopSpeed: profile.stopSpeed,
                                baseControlPoints: controlPoints, useDrag: profile.useDrag)
        let wasRunning = glide != nil
        if !wasRunning {
            output = mode.isGesture ? (gestureSink ?? gestureOutput) : scrollOutput
            output.reset()
            scrollOutput.invertedFromDevice = true
            gestureOutput.inverted = true
            gestureOutput.kind = mode.gestureKind ?? .zoom
        }
        scrollOutput.swipe = profile.sendsGesture
        scrollOutput.flags = outFlags
        glide = Glide(vector: vector, curve: curve, start: glide?.lastFrame ?? time, lastValue: 0,
                      lastFrame: glide?.lastFrame ?? now, gestureUntil: now + Self.gestureHold,
                      speed: glide?.speed ?? 0, started: glide?.started ?? false)
        if cold {
            // A display link takes a few frames to deliver its first callback. Don't wait for it: start one frame
            // into the glide and send that frame now.
            glide?.start -= Self.frameTime
            glide?.lastFrame -= Self.frameTime
            step()
        }
        return nil
    }

    /// Smoothing off: keep the wheel's own events, only swapping, flipping and scaling them.
    private func passThrough(_ event: CGEvent, swapAxes: Bool, reverse: Bool, factor: Double, flags: CGEventFlags) -> Unmanaged<CGEvent>? {
        let flip = reverse ? -1.0 : 1.0
        func line(_ v: Int64) -> Int64 {
            guard v != 0 else { return 0 }
            let n = (Double(v) * flip * factor).rounded()
            return Int64(n == 0 ? flip * Double(v.signum()) : n) // a click always moves at least one line
        }
        func point(_ v: Int64) -> Int64 { Int64((Double(v) * flip * factor).rounded()) }

        var lines = (y: event.getIntegerValueField(.scrollWheelEventDeltaAxis1), x: event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        var points = (y: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), x: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        var fixed = (y: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), x: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        if swapAxes { swap(&lines.y, &lines.x); swap(&points.y, &points.x); swap(&fixed.y, &fixed.x) }

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: line(lines.y))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: line(lines.x))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: point(points.y))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: point(points.x))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed.y * flip * factor)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed.x * flip * factor)
        event.flags = flags
        return Unmanaged.passUnretained(event)
    }

    // MARK: Animation

    /// What the current glide still has to scroll.
    private func remainingVector() -> (y: Double, x: Double) { glide.map { remainingVector(for: $0) } ?? (0, 0) }

    func step() {
        guard var g = glide else {
            if clock() >= idleUntil { stopFrames() }
            return
        }
        guard config().enabled else { cancelScroll(); return }
        let now = clock()
        let dt = max(now - g.lastFrame, 0.001)
        let time = now - g.start
        let done = time >= g.curve.duration
        let value = done ? g.curve.distance : g.curve.value(at: time)
        let share = g.curve.distance > 0 ? (value - g.lastValue) / g.curve.distance : 0
        let deltaY = g.vector.y * share, deltaX = g.vector.x * share
        let wasInDrag = g.lastValue >= g.curve.constantSpeedDistance
        g.lastValue = value
        g.lastFrame = now
        g.speed = hypot(deltaY, deltaX) / dt

        let wholeY = pixelY.whole(deltaY), wholeX = pixelX.whole(deltaX)
        let left = remainingVector(for: g)
        // Enough whole pixels already went out: nothing more would move.
        let last = done || (pixelY.peek(left.y) == 0 && pixelX.peek(left.x) == 0)
        // Momentum only once every pixel of the frame comes from the drag part, and not right after a tick.
        let hint: ScrollOutput.Hint = now >= g.gestureUntil && wasInDrag ? .momentum : .gesture

        if wholeY != 0 || wholeX != 0 {
            output.emit(y: wholeY, x: wholeX, phase: g.started ? .continue : .start, hint: hint)
            g.started = true
        }
        if last {
            if g.started { output.finish() }
            glide = nil
            output.reset()
            pixelY.reset(); pixelX.reset()
            idleUntil = now + Self.linkIdle
        } else {
            glide = g
        }
    }

    private func remainingVector(for g: Glide) -> (y: Double, x: Double) {
        let left = g.curve.distance > 0 ? 1 - g.lastValue / g.curve.distance : 0
        return (g.vector.y * left, g.vector.x * left)
    }

    // MARK: Helpers

    private static let timebase: mach_timebase_info = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    /// When the wheel actually turned, from the event's own timestamp (more accurate than when we got to it).
    private static func seconds(of event: CGEvent) -> Double? {
        guard event.timestamp > 0 else { return nil }
        return Double(event.timestamp) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// One wheel tick on an axis (1 = vertical, 2 = horizontal): only the direction counts, not how far the system says it went.
    private static func tick(_ event: CGEvent, axis: Int) -> Double {
        let line = event.getIntegerValueField(axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2)
        if line != 0 { return Double(line.signum()) }
        let point = event.getIntegerValueField(axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2)
        return Double(point.signum())
    }

    private static func mask(_ name: String) -> CGEventFlags {
        switch name {
        case "shift": .maskShift
        case "option": .maskAlternate
        case "control": .maskControl
        case "command": .maskCommand
        default: []
        }
    }

    private static func active(_ name: String, in flags: CGEventFlags) -> Bool {
        let m = mask(name)
        return !m.isEmpty && flags.contains(m)
    }
}

import Foundation

/// Checks for the scroll maths and analysis. Pure computation: no events, timers or permissions.
func scrollChecks(_ check: (Bool, String) -> Void) {
    func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

    // Evaluate the Nook adapters against the original compiled MMF classes. Fractional
    // curvature exercises the real Bezier control-point algorithm rather than a power approximation.
    for curvature in [0.0, 0.25, 0.5, 1.0, 1.75, 2.0] {
        let adapted = ScrollAcceleration(yMin: 7, yMax: 137, curvature: curvature, tickIntervalMax: 0.2)
        let original = BezierCappedAccelerationCurve(xMin: 5, xMax: 1 / 0.015,
            yMin: 7, yMax: 137, curvature: curvature, defaultEpsilon: 0.05)
        for interval in [0.001, 0.015, 0.02, 0.035, 0.075, 0.15, 0.2, 1.0] {
            let expected = original.evaluate(at: 1 / max(0.015, interval))
            check(adapted.pixels(forTickInterval: interval) == expected,
                  "Acceleration adapter runs the original MMF Bezier (curvature \(curvature), interval \(interval))")
        }
    }
    let fastAdapter = ScrollSpeedup(threshold: 2, factorAtThreshold: 1.33, growth: 7.5)
    let fastOriginal = ScrollSpeedupCurve(swipeThreshold: 2, initialSpeedup: 1.33, exponentialSpeedup: 7.5)
    for swipes in [0.0, 1, 2, 2.5, 3, 4, 6, 10] {
        check(fastAdapter.factor(swipes: swipes) == fastOriginal.evaluate(at: swipes),
              "Fast-scroll adapter runs the original MMF exponential (swipes \(swipes))")
    }
    for (distance, base, a, b, stop) in [(90.0, 0.220, 40.0, 0.7, 30.0),
                                       (10, 0.180, 23, 1, 30), (300, 0.140, 15, 1.05, 50)] {
        let adapted = ScrollGlide(distance: distance, baseDuration: base, dragA: a, dragB: b, stopSpeed: stop)
        let original = LineHybridCurve(minDuration: base, distance: distance,
                                      dragCoefficient: a, dragExponent: b, stopSpeed: stop)
        check(near(adapted.duration, original.duration), "Line-hybrid duration comes from the original MMF curve")
        check(near(adapted.constantSpeedDistance, original.baseDistance),
              "Line-hybrid transition distance comes from the original MMF curve")
        for sample in 1..<80 {
            let unitTime = Double(sample) / 80
            check(near(adapted.value(at: unitTime * adapted.duration), original.evaluate(at: unitTime) * distance, 1e-10),
                  "Line-hybrid samples run the original MMF drag implementation")
        }
    }
    // The low and touch-driver presets use the original Bezier path without a drag tail.
    for control in [0.85, 0.5] {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0),
                      CGPoint(x: control, y: 1), CGPoint(x: 1, y: 1)]
        let adapted = ScrollGlide(distance: 120, baseDuration: 0.250, dragA: 23, dragB: 1,
                                  stopSpeed: 30, baseControlPoints: points, useDrag: false)
        let original = Bezier(controlPoints: points, defaultEpsilon: 0.001)
        for sample in 1..<80 {
            let t = Double(sample) / 80
            check(near(adapted.value(at: t * 0.250), original.evaluate(at: t) * 120, 1e-10),
                  "Pure Bezier samples run the original MMF implementation")
        }
    }
    let smoothingPoints = ScrollGlide.speedSmoothingControlPoints(amount: 0.15, currentSpeed: 600,
                                                                 distance: 90, baseDuration: 0.220)
    let smoothAdapter = ScrollGlide(distance: 90, baseDuration: 0.220, dragA: 40, dragB: 0.7,
                                   stopSpeed: 30, baseControlPoints: smoothingPoints)
    let smoothOriginal = BezierHybridCurve(baseCurve: Bezier(controlPoints: smoothingPoints, defaultEpsilon: 0.01),
        minDuration: 0.220, distance: 90, dragCoefficient: 40, dragExponent: 0.7,
        stopSpeed: 30, distanceEpsilon: 0.2)
    check(smoothAdapter.duration == smoothOriginal.duration, "Speed-smoothed hybrid keeps MMF duration")
    for sample in 1..<80 {
        let t = Double(sample) / 80
        check(near(smoothAdapter.value(at: t * smoothAdapter.duration), smoothOriginal.evaluate(at: t) * 90, 1e-10),
              "Speed-smoothed hybrid samples run MMF's original transition search")
    }

    // A glide always covers exactly its distance, moves forward only, and ends within the cap.
    for distance in [10.0, 60, 90, 300, 2000, 40_000] {
        for base in [0.110, 0.180, 0.220, 0.300] {
            for (a, b, stop) in [(23.0, 1.0, 30.0), (40, 0.7, 30), (15, 1.05, 50), (30, 0.7, 1)] {
                let glide = ScrollGlide(distance: distance, baseDuration: base, dragA: a, dragB: b, stopSpeed: stop)
                let label = "d=\(distance) T=\(base) a=\(a) b=\(b)"
                check(glide.value(at: 0) == 0, "Starts at zero (\(label))")
                check(near(glide.value(at: glide.duration), distance), "Ends exactly on the distance (\(label))")
                check(glide.value(at: glide.duration + 5) == distance, "Stays on the distance afterwards (\(label))")
                check(glide.duration <= ScrollGlide.maxDuration + 1e-9 && glide.duration > 0, "Duration is capped (\(label))")
                var last = 0.0
                for i in 0...400 {
                    let v = glide.value(at: glide.duration * Double(i) / 400)
                    check(v >= last - 1e-9 && v <= distance + 1e-9, "Moves forward without overshooting (\(label))")
                    last = v
                }
            }
        }
    }
    // Too slow for a drag tail: a plain straight line.
    let slow = ScrollGlide(distance: 5, baseDuration: 0.5, dragA: 23, dragB: 1, stopSpeed: 30)
    check(near(slow.duration, 0.5) && near(slow.value(at: 0.25), 2.5), "A slow scroll is a straight line")
    // The documented default (high smoothness, one tick of 90 px): about a third of a second, with a tail.
    let one = ScrollGlide(distance: 90, baseDuration: 0.220, dragA: 40, dragB: 0.7, stopSpeed: 30)
    check(one.duration > 0.30 && one.duration < 0.45, "A single tick glides for about 0.38 s")
    check(one.constantSpeedDistance > 30 && one.constantSpeedDistance < 70, "...with a constant-speed part of about 44 px")

    // Acceleration: a lone tick is yMin, a very fast spin is yMax, and it grows with speed.
    let line = ScrollAcceleration(yMin: 60, yMax: 120)
    check(near(line.pixels(forTickInterval: 1), 60) && near(line.pixels(forTickInterval: 0.160), 60), "A lone tick scrolls the minimum")
    check(near(line.pixels(forTickInterval: 0.015), 120) && near(line.pixels(forTickInterval: 0.001), 120), "A fast spin scrolls the maximum")
    var previous = 0.0
    for interval in stride(from: 0.2, through: 0.01, by: -0.005) {
        let p = line.pixels(forTickInterval: interval)
        check(p >= previous - 1e-9, "More speed never scrolls less")
        previous = p
    }
    let curved = ScrollAcceleration(yMin: 1, yMax: 20, curvature: 2)
    let straight = ScrollAcceleration(yMin: 1, yMax: 20)
    check(curved.pixels(forTickInterval: 0.07) > straight.pixels(forTickInterval: 0.07), "Curvature brings the speed-up in sooner")
    check(near(curved.pixels(forTickInterval: 1), 1) && near(curved.pixels(forTickInterval: 0.015), 20), "...but keeps the same ends")

    // Fast scroll: nothing below the threshold, the set factor one swipe past it, then growing.
    let speedup = ScrollSpeedup(threshold: 2, factorAtThreshold: 1.33, growth: 7.5)
    check(speedup.factor(swipes: 1) == 1 && near(speedup.factor(swipes: 2), 1), "No fast scroll below the threshold")
    check(near(speedup.factor(swipes: 3), 1.33), "The first swipe past the threshold has the set factor")
    check(speedup.factor(swipes: 5) > speedup.factor(swipes: 4) && speedup.factor(swipes: 4) > 1.33, "Keeps growing")
    check(speedup.factor(swipes: 5000) <= 100_000, "Capped")

    // Sub-pixel rounding never loses distance and never lets a scroll stall short.
    var pixelator = BiasedSubPixelator()
    var total = 0.0, whole: Int64 = 0
    for i in 0..<500 {
        let v = 0.3 + 0.2 * Double(i % 7)
        total += v; whole += pixelator.whole(v)
        check(Double(whole) >= total - 1e-9 && Double(whole) <= total + 1 + 1e-9, "Rounds up without drifting")
    }
    var down = BiasedSubPixelator()
    check(down.whole(-0.2) == -1, "Negative input rounds away from zero")
    var up = BiasedSubPixelator()
    check(up.whole(0.2) == 1, "Positive input rounds away from zero")
    var peeked = BiasedSubPixelator()
    _ = peeked.whole(1.4) // leaves a carry of -0.6
    let preview = peeked.peek(0.5)
    check(peeked.peek(0.5) == preview, "Peeking doesn't use anything up")
    check(peeked.whole(0.5) == preview, "...and matches what comes out next")

    // Tick analysis uses the original Objective-C engine, including its DBL_MAX first-tick sentinel.
    // The input clock and analyzer clock advance together; no timers or input taps are installed.
    func analyze(_ analyzer: inout MouseScrollAnalyzer, time: Double, direction: Int) -> ScrollAnalysis {
        NookMMFAnalyzerSetClockForTesting(time)
        return analyzer.update(time: time, direction: direction)
    }
    defer { NookMMFAnalyzerSetClockForTesting(.nan) }
    var analyzer = MouseScrollAnalyzer()
    analyzer.reset()
    let first = analyze(&analyzer, time: 100, direction: 1)
    check(first.tickCounter == 0 && first.tickInterval == Double.greatestFiniteMagnitude && !first.directionChanged,
          "The original analyzer marks a lone tick with DBL_MAX")
    let second = analyze(&analyzer, time: 100.05, direction: 1)
    check(second.tickCounter == 1 && near(second.tickInterval, 0.05), "A close tick joins the run")
    let third = analyze(&analyzer, time: 100.07, direction: 1)
    check(third.tickCounter == 2 && near(third.tickInterval, (0.05 + 0.02) / 2), "The interval is averaged over the run")
    let later = analyze(&analyzer, time: 100.5, direction: 1)
    check(later.tickCounter == 0 && later.tickInterval == Double.greatestFiniteMagnitude, "A long pause starts a new run")
    var flip = MouseScrollAnalyzer()
    flip.reset()
    _ = analyze(&flip, time: 1, direction: 1); _ = analyze(&flip, time: 1.03, direction: 1)
    let flipped = analyze(&flip, time: 1.06, direction: 2)
    check(flipped.directionChanged && flipped.tickCounter == 0 && flipped.swipeCounter == 0, "A tick the other way resets the analysis")
    check(!analyze(&flip, time: 1.09, direction: 2).directionChanged, "...once")

    var primed = MouseScrollAnalyzer()
    primed.reset(); primed.primesInterval = true
    _ = analyze(&primed, time: 5, direction: 1)
    check(near(analyze(&primed, time: 5.04, direction: 1).tickInterval, (0.160 + 0.04) / 2),
          "High smoothness primes MMF's original three-entry RollingAverage")
    _ = analyze(&primed, time: 5.10, direction: 1)
    check(near(analyze(&primed, time: 5.13, direction: 1).tickInterval, (0.04 + 0.06 + 0.03) / 3),
          "The original circular buffer evicts the priming interval after three ticks")

    // Quick swipes in a row build fast scroll; a slow one ends the streak.
    var swipes = MouseScrollAnalyzer()
    swipes.reset()
    var t = 10.0
    func spin(_ ticks: Int, every gap: Double) -> ScrollAnalysis {
        var last = analyze(&swipes, time: t, direction: 1)
        for _ in 1..<ticks { t += gap; last = analyze(&swipes, time: t, direction: 1) }
        return last
    }
    check(spin(6, every: 0.04).swipeCounter == 0, "The first swipe has nothing before it")
    t += 0.3
    check(spin(6, every: 0.04).swipeCounter == 1, "A second quick swipe soon after counts")
    t += 0.3
    check(spin(6, every: 0.04).swipeCounter == 2, "...and a third")
    t += 1.5
    check(spin(2, every: 0.04).swipeCounter == 0, "A long pause ends the streak")
    t += 0.3
    check(spin(3, every: 0.12).swipeCounter == 0, "A slow swipe isn't a streak")

    swipes.reset(); t = 20
    check(spin(100, every: 0.01).swipeCounter == 0,
          "A continuous free-spinning wheel does not gain MMF's disabled extra fast-scroll increments")

    // Profiles.
    var config = MouseConfig()
    config.smoothness = "regular"
    let regular = ScrollProfile.make(config, mode: .normal, horizontal: false, screenPixels: 1080)
    check(near(regular.acceleration.yMin, 60) && near(regular.acceleration.yMax, 120), "Regular: 60 to 120 px per tick")
    check(near(regular.baseDuration(0.160), 0.180) && regular.baseDuration(0.001) < 0.115, "Regular: 180 ms down to 110 ms")
    config.smoothness = "high"
    let high = ScrollProfile.make(config, mode: .normal, horizontal: false, screenPixels: 1080)
    check(near(high.acceleration.yMin, 90) && near(high.acceleration.yMax, 180) && near(high.baseDuration(0.05), 0.220), "High: 90 to 180 px, 220 ms")
    config.speedMode = "custom"; config.speed = 2
    check(near(ScrollProfile.make(config, mode: .normal, horizontal: false, screenPixels: 1080).acceleration.yMin, 180), "Speed scales the distance")
    config.speedMode = "custom"; config.speed = 1; config.acceleration = 0
    let flat = ScrollProfile.make(config, mode: .normal, horizontal: false, screenPixels: 1080)
    check(near(flat.acceleration.yMin, flat.acceleration.yMax), "No acceleration scrolls the same per tick")
    config.acceleration = 0.5
    let precise = ScrollProfile.make(config, mode: .precise, horizontal: false, screenPixels: 1080)
    check(near(precise.acceleration.yMin, 1) && near(precise.acceleration.yMax, 20) && !precise.sendsGesture && precise.speedup == nil, "Precise: tiny steps, no fast scroll, plain events")
    let quick = ScrollProfile.make(config, mode: .quick, horizontal: false, screenPixels: 1000)
    check(near(quick.acceleration.yMin, 425) && near(quick.acceleration.yMax, 1275), "Quick scrolls most of a window per tick")
    config.speedMode = "medium"
    config.smoothness = "regular"
    check(!ScrollProfile.make(config, mode: .normal, horizontal: false, screenPixels: 1080).sendsGesture,
          "MMF regular smoothness sends continuous events without trackpad phases")
    config.smoothness = "high"
    for (speed, minimum, maximum) in [("low", 60.0, 120.0), ("medium", 90.0, 180.0), ("high", 150.0, 240.0)] {
        config.speedMode = speed
        let profile = ScrollProfile.make(config, mode: .normal, horizontal: false, screenPixels: 1080)
        check(near(profile.acceleration.yMin, minimum) && near(profile.acceleration.yMax, maximum),
              "MMF high-smoothness speed table matches original for \(speed)")
    }
    config.speedMode = "system"
    check(ScrollProfile.make(config, mode: .normal, horizontal: false, screenPixels: 1080).usesSystemSpeed,
          "macOS speed preserves Apple's accelerated pixel distance")
    config.smoothness = "off"; config.speedMode = "medium"
    let off = ScrollProfile.make(config, mode: .normal, horizontal: false, screenPixels: 1080)
    check(!off.animated && near(off.acceleration.yMin, 30) && near(off.acceleration.yMax, 60),
          "MMF off still accelerates using its 30-to-60-pixel medium table")
    let defaults = MouseConfig().applyingMMFDefaults()
    check(defaults.smoothness == "high" && defaults.speedMode == "medium" && defaults.reverse,
          "Preset restores source scrolling defaults")
    check(defaults.preciseModifier == "option" && defaults.quickModifier == "control" && defaults.zoomModifier == "command",
          "Preset restores source modifier defaults")
    check(defaults.buttons.count == 3 && !defaults.enabled, "Preset fills buttons without enabling mouse controls")
    config.scrollStyle = "classic"
    check(!ScrollProfile.make(config, mode: .normal, horizontal: false, screenPixels: 1080).sendsGesture, "Classic style sends plain events")
}

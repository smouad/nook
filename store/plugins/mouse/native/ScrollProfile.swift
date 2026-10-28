import Foundation

// Adapter for MMF 3.1.0 Helper/Core/Config/ScrollConfig.swift. The evaluated curves themselves are
// the original source under upstream/. User-facing Nook custom speed remains an explicit extension.
struct ScrollProfile {
    enum Mode: Equatable {
        case normal, precise, quick, zoom, rotate, pinch, swipe
        var isGesture: Bool { self == .zoom || self == .rotate || self == .pinch || self == .swipe }
        init?(_ name: String) {
            switch name {
            case "zoom": self = .zoom
            case "rotate": self = .rotate
            case "pinch": self = .pinch
            case "swipe": self = .swipe
            default: return nil
            }
        }
        var gestureKind: GestureOutput.Kind? {
            switch self {
            case .zoom: .zoom
            case .rotate: .rotate
            case .pinch: .pinch
            case .swipe: .swipe
            default: nil
            }
        }
    }

    var mode: Mode
    var baseDuration: (Double) -> Double
    var dragA: Double
    var dragB: Double
    var stopSpeed: Double
    var acceleration: ScrollAcceleration
    var speedup: ScrollSpeedup?
    var swipeMaxInterval: Double
    var swipeMinTickSpeed: Double
    var primesInterval: Bool
    var sendsGesture: Bool
    var useDrag = true
    var baseControlPoints: [CGPoint]?
    var speedSmoothing: Double?
    var usesSystemSpeed = false
    var animated = true
    var tickIntervalMax: Double { acceleration.tickIntervalMax }

    static func make(_ c: MouseConfig, mode: Mode, horizontal: Bool, screenPixels: Double) -> ScrollProfile {
        let high = c.smoothness == "high"
        let off = c.smoothness == "off"
        let custom = c.speedMode == "custom"
        let multiplier = custom ? c.speed : 1
        func table(_ values: [Double]) -> Double {
            values[c.speedMode == "low" ? 0 : c.speedMode == "high" ? 2 : 1] * multiplier
        }
        let touch = mode.isGesture
        var minimum = table(touch ? [45, 60, 90] : off ? [20, 30, 40] : high ? [60, 90, 150] : [30, 60, 120])
        var maximum = table(touch ? [90, 120, 180] : off ? [40, 60, 80] : high ? [120, 180, 240] : [90, 120, 180])
        var curvature = touch ? table([0.25, 0, 0]) / multiplier : off ? table([4.25, 3, 2.25]) / multiplier : high ? 0 : table([0.25, 0, 0]) / multiplier
        if !touch {
            maximum *= 0.9 + 0.1 * screenPixels / (horizontal ? 1920 : 1080)
        }
        if custom { maximum = minimum + (maximum - minimum) * (c.acceleration / 0.5) }
        if mode == .precise {
            minimum = 1; maximum = 20; curvature = 2
        } else if mode == .quick {
            minimum = screenPixels * 0.85 * 0.5
            maximum = screenPixels * 0.85 * 1.5
            curvature = 0
        }
        let tickMax = mode == .quick ? 0.200 : 0.160
        var result = ScrollProfile(
            mode: mode, baseDuration: Self.regularBaseDuration,
            dragA: high ? 40 : 23, dragB: high ? 0.7 : 1, stopSpeed: 30,
            acceleration: ScrollAcceleration(yMin: minimum, yMax: max(minimum, maximum), curvature: curvature, tickIntervalMax: tickMax),
            speedup: ScrollSpeedup(threshold: off ? 6 : high ? 2 : 3, factorAtThreshold: off ? 1.4 : 1.33, growth: off ? 3 : 7.5),
            swipeMaxInterval: off ? 0.325 : high ? 0.600 : 0.375,
            swipeMinTickSpeed: high ? 12 : 16, primesInterval: high,
            sendsGesture: high && c.scrollStyle == "trackpad")
        result.usesSystemSpeed = c.speedMode == "system" && mode != .precise && mode != .quick && mode != .pinch && mode != .swipe
        result.animated = !off
        switch mode {
        case .zoom, .rotate, .pinch, .swipe:
            result.baseDuration = { _ in mode == .zoom || mode == .rotate ? 0.250 : 0.180 }
            result.baseControlPoints = mode == .zoom || mode == .rotate ? [_P(0, 0), _P(0, 0), _P(0.5, 1), _P(1, 1)] : nil
            result.useDrag = false
            result.sendsGesture = false
            result.animated = true
            result.swipeMaxInterval = 0.375
            result.swipeMinTickSpeed = 16
            result.speedup = mode == .zoom || mode == .rotate ? ScrollSpeedup(threshold: 3, factorAtThreshold: 1.33, growth: 7.5) : nil
        case .quick:
            result.baseDuration = { _ in 0.300 }
            result.dragA = 30; result.dragB = 0.7; result.stopSpeed = 1
            result.speedup = ScrollSpeedup(threshold: 1, factorAtThreshold: 2, growth: 10)
            result.swipeMaxInterval = 0.725; result.swipeMinTickSpeed = 12
            result.sendsGesture = true
            result.animated = true
        case .precise:
            result.baseDuration = { _ in 0.140 }
            result.dragA = 15; result.dragB = 1.05; result.stopSpeed = 50
            result.speedup = nil
            result.sendsGesture = false
        case .normal:
            if high {
                result.baseDuration = { _ in 0.220 }
                result.speedSmoothing = 0
            } else if c.smoothness == "low" {
                // MMF 3.1.0 disables this experimental option in compiled ScrollConfig. Nook exposes the
                // author's documented VeryLowInertia cubic instead of its fatalError branch.
                result.baseDuration = { interval in 0.250 - 0.150 * min(1, max(0, (0.160 - interval) / 0.159)) }
                result.baseControlPoints = [_P(0, 0), _P(0, 0), _P(0.85, 1), _P(1, 1)]
                result.useDrag = false
                result.speedup = nil
                result.sendsGesture = false
            }
        }
        return result
    }

    private static func regularBaseDuration(_ interval: Double) -> Double {
        let u = min(1, max(0, (interval - 0.160) / (0.001 - 0.160)))
        return (180 - 70 * (exp(4 * u) - 1) / (exp(4.0) - 1)) / 1000
    }
}

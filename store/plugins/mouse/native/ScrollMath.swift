import Foundation

// The original Mac Mouse Fix curves in ../upstream/Shared/Math are compiled unchanged.
// This file adapts their normalized curve API to Nook's distance/time scroll interface.

/// Pixels per wheel tick, evaluated by Mac Mouse Fix's original acceleration Bezier.
struct ScrollAcceleration {
    let yMin: Double
    let yMax: Double
    let curvature: Double
    let tickIntervalMax: Double
    static let tickIntervalAcceleratedEnd = 0.015
    private let curve: BezierCappedAccelerationCurve

    init(yMin: Double, yMax: Double, curvature: Double = 0, tickIntervalMax: Double = 0.160) {
        self.yMin = yMin
        self.yMax = yMax
        self.curvature = curvature
        self.tickIntervalMax = tickIntervalMax
        curve = BezierCappedAccelerationCurve(
            xMin: 1 / tickIntervalMax, xMax: 1 / Self.tickIntervalAcceleratedEnd,
            yMin: yMin, yMax: yMax, curvature: curvature, defaultEpsilon: 0.05)
    }

    func pixels(forTickInterval interval: Double) -> Double {
        curve.evaluate(at: 1 / max(interval, Self.tickIntervalAcceleratedEnd))
    }
}

/// Consecutive quick swipes use Mac Mouse Fix's original fast-scroll curve.
struct ScrollSpeedup {
    let threshold: Double
    let factorAtThreshold: Double
    let growth: Double
    private let curve: ScrollSpeedupCurve

    init(threshold: Double, factorAtThreshold: Double, growth: Double) {
        self.threshold = threshold
        self.factorAtThreshold = factorAtThreshold
        self.growth = growth
        curve = ScrollSpeedupCurve(swipeThreshold: Int(threshold), initialSpeedup: factorAtThreshold,
                                   exponentialSpeedup: growth)
    }

    func factor(swipes: Double) -> Double {
        min(100_000, curve.evaluate(at: swipes))
    }
}

/// Adapts original MMF Bezier and hybrid-drag curves to pixels and elapsed seconds.
struct ScrollGlide {
    let distance: Double
    let duration: Double
    private let curve: Curve
    let constantSpeedDistance: Double

    /// Nook's bound for an animation after a very large wheel spin.
    static let maxDuration = 1.5

    init(distance: Double, baseDuration: Double, dragA: Double, dragB: Double, stopSpeed: Double,
         baseControlPoints: [CGPoint]? = nil, useDrag: Bool = true) {
        self.distance = distance
        if !useDrag {
            curve = Bezier(controlPoints: baseControlPoints ?? [_P(0, 0), _P(1, 1)], defaultEpsilon: 0.001)
            duration = min(Self.maxDuration, baseDuration)
            constantSpeedDistance = distance
        } else {
            let hybrid: HybridCurve
            if let points = baseControlPoints {
                hybrid = BezierHybridCurve(baseCurve: Bezier(controlPoints: points, defaultEpsilon: 0.01),
                                           minDuration: baseDuration, distance: distance,
                                           dragCoefficient: dragA, dragExponent: dragB,
                                           stopSpeed: stopSpeed, distanceEpsilon: 0.2)
            } else {
                hybrid = LineHybridCurve(minDuration: baseDuration, distance: distance,
                                         dragCoefficient: dragA, dragExponent: dragB, stopSpeed: stopSpeed)
            }
            curve = hybrid
            duration = min(Self.maxDuration, hybrid.duration)
            constantSpeedDistance = hybrid.baseDistance
        }
    }

    /// This reproduces Scroll.m's control-point construction, including its duration units.
    static func speedSmoothingControlPoints(amount: Double, currentSpeed: Double,
                                           distance: Double, baseDuration: Double) -> [CGPoint] {
        let x = 1 / (baseDuration / 1000)
        let y = abs(currentSpeed) / distance
        let magnitude = hypot(x, y)
        return [_P(0, 0), _P(amount * x / magnitude, amount * y / magnitude), _P(1, 1)]
    }

    func value(at time: Double) -> Double {
        guard time > 0 else { return 0 }
        guard time < duration else { return distance }
        return curve.evaluate(at: time / duration) * distance
    }
}

// Narrow replacements for declarations normally supplied by MMF's Objective-C bridge.
// Keep the original enum values and scalar helpers so the original source needs no edits.
typealias P = CGPoint
func _P(_ x: Double, _ y: Double) -> P { P(x: x, y: y) }

@objc enum MFAxis: Int { case none = 0, horizontal = 1, vertical = 2 }
let kMFAxisHorizontal = MFAxis.horizontal
let kMFAxisVertical = MFAxis.vertical

@objc enum MFIntervalDirection: Int { case ascending = 0, descending = 1, none = 2 }
let kMFIntervalDirectionAscending = MFIntervalDirection.ascending
let kMFIntervalDirectionDescending = MFIntervalDirection.descending
let kMFIntervalDirectionNone = MFIntervalDirection.none

@objc enum MFHybridSubCurve: Int { case none = 0, base = 1, drag = 2 }
let kMFHybridSubCurveBase = MFHybridSubCurve.base
let kMFHybridSubCurveDrag = MFHybridSubCurve.drag

func directionsAreOpposite(_ first: MFIntervalDirection, _ second: MFIntervalDirection) -> Bool {
    first != .none && second != .none && first != second
}

func mfsign(_ value: some (Numeric & Comparable)) -> Int {
    (value > 0) ? 1 : (value < 0) ? -1 : 0
}

// MMF's logging framework and prerelease-only curve diagnostics have no Nook dependency.
func DDLogDebug(_ message: @autoclosure () -> String) {}
func DDLogWarn(_ message: @autoclosure () -> String) {}
func DDLogError(_ message: @autoclosure () -> String) {}
func runningPreRelease() -> Bool { false }

/// Turns fractional pixel amounts into whole pixels without losing any: the rounding error is carried to the next call.
/// Rounds away from zero in the direction of the first non-zero input, so a scroll never stalls short of its target.
struct BiasedSubPixelator {
    private var error = 0.0
    private var bias = 0.0 // +1 rounds up, -1 rounds down, 0 not decided yet

    mutating func reset() { error = 0; bias = 0 }

    mutating func whole(_ value: Double) -> Int64 {
        if bias == 0, value != 0 { bias = value > 0 ? 1 : -1 }
        let total = value + error
        let rounded = bias >= 0 ? total.rounded(.up) : total.rounded(.down)
        error = total - rounded
        return Int64(rounded)
    }

    /// What `whole` would return, without using it up.
    func peek(_ value: Double) -> Int64 {
        let total = value + error
        return Int64(bias >= 0 ? total.rounded(.up) : total.rounded(.down))
    }
}

import Foundation

/// Values returned by the original Objective-C Mac Mouse Fix scroll analyzer.
struct ScrollAnalysis: Equatable {
    var tickInterval: Double
    var tickCounter: Int
    var swipeCounter: Int
    var directionChanged: Bool
}

/// Configuration adapter. Tick/swipe counting runs in the unmodified upstream implementation.
struct MouseScrollAnalyzer {
    var tickIntervalMax = 0.160
    var tickIntervalMin = 0.001
    var swipeThreshold = 2
    var swipeMaxInterval = 0.600
    var swipeMinTickSpeed = 12.0
    var primesInterval = false

    // Upstream intentionally stores one process-wide analyzer state. Nook has one active scroller.
    init() { NookMMFAnalyzerReset() }

    mutating func reset() { NookMMFAnalyzerReset() }

    mutating func update(time: Double, direction: Int) -> ScrollAnalysis {
        let config = NookMMFAnalyzerConfig(
            tickIntervalMax: tickIntervalMax, tickIntervalMin: tickIntervalMin,
            swipeThreshold: Int32(swipeThreshold), swipeMaxInterval: swipeMaxInterval,
            swipeMinTickSpeed: swipeMinTickSpeed, primesInterval: ObjCBool(primesInterval))
        let result = NookMMFAnalyzerUpdate(time, Int32(direction), config)
        return ScrollAnalysis(tickInterval: result.tickInterval, tickCounter: Int(result.tickCounter),
                              swipeCounter: Int(result.swipeCounter), directionChanged: result.directionChanged.boolValue)
    }
}

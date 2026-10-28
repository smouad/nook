import Foundation

/// ClickCycle only needs stable device identity. Nook owns input routing and physical release balance.
final class Device: NSObject {
    private let identifier: NSNumber
    init(identifier: Int) { self.identifier = NSNumber(value: identifier); super.init() }
    func uniqueID() -> NSNumber { identifier }
}

/// Nook schedules timers on its input run loop. The original recognizer retains and invalidates
/// these Foundation timers; ButtonEngine forwards their deadlines and explicitly fires them.
enum CoolTimer {
    static var onCreate: ((TimeInterval, Foundation.Timer) -> Void)?
    static func scheduledTimer(timeInterval: TimeInterval, repeats: Bool,
                               block: @escaping (Foundation.Timer) -> Void) -> Foundation.Timer {
        let timer = Foundation.Timer(timeInterval: timeInterval, repeats: repeats, block: block)
        onCreate?(timeInterval, timer)
        return timer
    }
}

enum SharedUtilitySwift {
    /// The host serializes input and timer creation on its own run loop.
    static func doOnMain(_ block: () -> Void) { block() }
}

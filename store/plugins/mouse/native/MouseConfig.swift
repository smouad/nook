import Foundation

/// Mouse tab settings: saved as JSON in UserDefaults, edited by the Mouse plugin through `nook.mouse.*`.
struct MouseConfig: Codable, Equatable {
    static let smoothnessLevels = ["off", "low", "regular", "high"]
    static let modifiers = ["none", "shift", "option", "control", "command"]
    static let scrollStyles = ["trackpad", "classic"]
    static let speedModes = ["system", "low", "medium", "high", "custom"]

    var enabled = false
    var smoothness = "regular"
    var speed = 1.0 // 0.3 … 3, × the base distance of one wheel tick
    var speedMode = "medium" // MMF's own speed tables; custom retains Nook's multiplier
    var acceleration = 0.5 // 0 … 1, how much a fast spin speeds scrolling up
    var reverse = false
    var filterChatter = false // opt in only for wheels that bounce on direction changes
    var scrollStyle = "trackpad" // "trackpad": a swipe-like gesture then momentum (page snapping works); "classic": plain scroll events
    var horizontalModifier = "shift" // hold to scroll sideways
    var preciseModifier = "none" // hold to scroll slowly
    var quickModifier = "none" // hold to scroll fast
    var zoomModifier = "none" // hold to zoom with the wheel
    var buttons: [String: ButtonRule] = [:] // mouse button number → rule (2 = middle, 3 = back, 4 = forward…)

    static let dragModes = ["none", "spaces", "swipe", "scroll"]
    /// What the wheel does while a button is held. "pinch" shows Launchpad / the desktop; "swipe" moves between Spaces.
    static let heldScrollModes = ["none", "horizontal", "quick", "precise", "zoom", "rotate", "pinch", "swipe"]

    struct ButtonRule: Codable, Equatable {
        var click = "none"
        var double = "none" // second press within a moment
        var triple = "none" // third press
        var hold = "none" // press and hold
        /// "none" | "spaces" (a shortcut: left/right = Spaces, up = Mission Control, down = App Exposé) | "swipe" (a live
        /// three-finger swipe between Spaces and into Mission Control) | "scroll" (the drag scrolls)
        var drag = "none"
        var scroll = "none" // what the wheel does while the button is held

        var isActive: Bool { click != "none" || double != "none" || triple != "none" || hold != "none" || drag != "none" || scroll != "none" }

        /// The highest click level that has an action: 1 for single, 2 for double, 3 for triple.
        var maxLevel: Int { triple != "none" ? 3 : double != "none" ? 2 : 1 }

        func action(level: Int) -> String { level >= 3 ? triple : level == 2 ? double : click }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            click = try c.decodeIfPresent(String.self, forKey: .click) ?? "none"
            double = try c.decodeIfPresent(String.self, forKey: .double) ?? "none"
            triple = try c.decodeIfPresent(String.self, forKey: .triple) ?? "none"
            hold = try c.decodeIfPresent(String.self, forKey: .hold) ?? "none"
            drag = try c.decodeIfPresent(String.self, forKey: .drag) ?? "none"
            scroll = try c.decodeIfPresent(String.self, forKey: .scroll) ?? "none"
        }
    }

    init() { self = applyingMMFDefaults() }

    /// Missing keys fall back to defaults, so adding a setting later never wipes what people saved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MouseConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        smoothness = try c.decodeIfPresent(String.self, forKey: .smoothness) ?? d.smoothness
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        // Preserve existing Nook speed/acceleration values until the user chooses an MMF speed or preset.
        speedMode = try c.decodeIfPresent(String.self, forKey: .speedMode) ?? "custom"
        acceleration = try c.decodeIfPresent(Double.self, forKey: .acceleration) ?? d.acceleration
        reverse = try c.decodeIfPresent(Bool.self, forKey: .reverse) ?? d.reverse
        filterChatter = try c.decodeIfPresent(Bool.self, forKey: .filterChatter) ?? d.filterChatter
        scrollStyle = try c.decodeIfPresent(String.self, forKey: .scrollStyle) ?? d.scrollStyle
        horizontalModifier = try c.decodeIfPresent(String.self, forKey: .horizontalModifier) ?? d.horizontalModifier
        preciseModifier = try c.decodeIfPresent(String.self, forKey: .preciseModifier) ?? d.preciseModifier
        quickModifier = try c.decodeIfPresent(String.self, forKey: .quickModifier) ?? d.quickModifier
        zoomModifier = try c.decodeIfPresent(String.self, forKey: .zoomModifier) ?? d.zoomModifier
        buttons = try c.decodeIfPresent([String: ButtonRule].self, forKey: .buttons) ?? d.buttons
        normalize()
    }

    /// Clamp numbers and drop unknown choices, so a bad value from a plugin can't break scrolling.
    mutating func normalize() {
        if !Self.smoothnessLevels.contains(smoothness) { smoothness = "regular" }
        if !Self.scrollStyles.contains(scrollStyle) { scrollStyle = "trackpad" }
        if !Self.speedModes.contains(speedMode) { speedMode = "medium" }
        speed = min(3, max(0.3, speed))
        acceleration = min(1, max(0, acceleration))
        if !Self.modifiers.contains(horizontalModifier) { horizontalModifier = "none" }
        if !Self.modifiers.contains(preciseModifier) { preciseModifier = "none" }
        if !Self.modifiers.contains(quickModifier) { quickModifier = "none" }
        if !Self.modifiers.contains(zoomModifier) { zoomModifier = "none" }
        let known = Set(MouseActions.all.map(\.id))
        buttons = buttons.filter { Int($0.key).map { $0 >= 2 } ?? false } // left (0) and right (1) are never remapped
            .mapValues { rule in
                var r = rule
                if !known.contains(r.click) { r.click = "none" }
                if !known.contains(r.double) { r.double = "none" }
                if !known.contains(r.triple) { r.triple = "none" }
                if !known.contains(r.hold) { r.hold = "none" }
                if !Self.dragModes.contains(r.drag) { r.drag = "none" }
                if !Self.heldScrollModes.contains(r.scroll) { r.scroll = "none" }
                return r
            }
    }

    /// Mac Mouse Fix's default button layout (its buttons 3, 4 and 5 are ours 2, 3 and 4): middle looks up, holds for the
    /// desktop, double-clicks for Launchpad and drags between Spaces; the back button looks up, pinches with the wheel
    /// and drags between Spaces; the forward button smart-zooms, zooms with the wheel and drags to scroll.
    static func preset(_ name: String) -> [String: ButtonRule]? {
        guard name == "defaults" || name == "mmf" else { return nil }
        func rule(_ edit: (inout ButtonRule) -> Void) -> ButtonRule { var r = ButtonRule(); edit(&r); return r }
        return [
            "2": rule { $0.click = "lookUp"; $0.double = "launchpad"; $0.hold = "showDesktop"; $0.drag = "swipe" },
            "3": rule { $0.click = "lookUp"; $0.scroll = "pinch"; $0.drag = "swipe" },
            "4": rule { $0.click = "smartZoom"; $0.scroll = "zoom"; $0.drag = "scroll" },
        ]
    }

    /// Scroll values from MMF 3.1.0's default_config.plist, plus its 3-/5-button layouts.
    /// Keep the runtime switch under the user's control when applying the preset.
    func applyingMMFDefaults() -> MouseConfig {
        var result = self
        result.smoothness = "high"
        result.speedMode = "medium"
        result.speed = 1
        result.acceleration = 0.5
        result.reverse = true
        result.filterChatter = false
        result.scrollStyle = "trackpad"
        result.horizontalModifier = "shift"
        result.preciseModifier = "option"
        result.quickModifier = "control"
        result.zoomModifier = "command"
        for (button, rule) in Self.preset("mmf") ?? [:] { result.buttons[button] = rule }
        return result
    }

    // MARK: Persistence

    private static var file: URL? {
        ProcessInfo.processInfo.environment["NOOK_DATA_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("mouse.json") }
    }

    static func load() -> MouseConfig {
        if let file, let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(MouseConfig.self, from: data) { return config }
        // Read-only migration. Never write Nook's old preferences from the helper.
        return UserDefaults(suiteName: "com.yusuf.nook")?.data(forKey: "mouseFixConfig")
            .flatMap { try? JSONDecoder().decode(MouseConfig.self, from: $0) } ?? MouseConfig()
    }

    func save() {
        guard let file = Self.file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(self).write(to: file, options: .atomic)
        } catch { FileHandle.standardError.write(Data("Couldn’t save mouse settings: \(error.localizedDescription)\n".utf8)) }
    }

    // MARK: Bridge

    var json: [String: Any] {
        (try? JSONEncoder().encode(self)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// Overlay the keys a plugin sent on top of the current values; nil if a value has the wrong type.
    func merging(_ patch: [String: Any]) -> MouseConfig? {
        var merged = json
        for (k, v) in patch where k != "buttons" && merged[k] != nil { merged[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              var result = try? JSONDecoder().decode(MouseConfig.self, from: data) else { return nil }
        result.normalize()
        return result
    }
}

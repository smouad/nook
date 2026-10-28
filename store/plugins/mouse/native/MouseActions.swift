import AppKit

// The per-app Back/Forward methods (mouse buttons for apps that take them, ⌘[ ⌘] or the app's own shortcut for the
// ones that don't) follow Mac Mouse Fix's "Universal Back and Forward" by Noah Nuebling
// (https://github.com/noah-nuebling/mac-mouse-fix, MMF License).

/// Things a mouse button can do. System actions resolve their current Keyboard Shortcuts binding before posting.
enum MouseActions {
    static let all: [(id: String, label: String)] = [
        ("none", "Default"),
        ("missionControl", "Mission Control"),
        ("appExpose", "App Exposé"),
        ("launchpad", "Launchpad"),
        ("showDesktop", "Show Desktop"),
        ("spaceLeft", "Space to the left"),
        ("spaceRight", "Space to the right"),
        ("back", "Back"),
        ("forward", "Forward"),
        ("leftClick", "Primary click"),
        ("rightClick", "Secondary click"),
        ("middleClick", "Middle click"),
        ("spotlight", "Spotlight"),
        ("emoji", "Emoji & symbols"),
        ("lockScreen", "Lock screen"),
        ("lookUp", "Look up"),
        ("smartZoom", "Smart zoom"),
        ("screenshot", "Screenshot"),
        ("copy", "Copy"),
        ("paste", "Paste"),
        ("newTab", "New tab"),
        ("closeTab", "Close tab"),
        ("playPause", "Play / pause"),
        ("nextTrack", "Next track"),
        ("previousTrack", "Previous track"),
        ("volumeUp", "Volume up"),
        ("volumeDown", "Volume down"),
        ("mute", "Mute"),
        ("brightnessUp", "Brightness up"),
        ("brightnessDown", "Brightness down"),
    ]

    /// Safe from any thread.
    static func run(_ id: String) {
        if let action = symbolicHotkey(for: id) {
            SymbolicHotkeys.post(action) { failure in
                guard let failure else { return }
                if openApplicationFallback(for: action) { return }
                let label = all.first(where: { $0.id == id })?.label ?? id
                FileHandle.standardError.write(Data("\(label): \(failure.rawValue)\n".utf8))
                PluginEvents.emit("mouseActionUnavailable", ["action": id, "message": "\(label): \(failure.rawValue)"], to: "mouse")
            }
            return
        }
        switch id {
        case "back": navigate(back: true)
        case "forward": navigate(back: false)
        case "smartZoom": TrackpadGestures.smartZoom()
        case "screenshot": key(21, [.maskShift, .maskCommand]) // ⇧⌘4
        case "copy": key(8, .maskCommand)
        case "paste": key(9, .maskCommand)
        case "newTab": key(17, .maskCommand)
        case "closeTab": key(13, .maskCommand)
        case "leftClick": click(button: 0)
        case "rightClick": click(button: 1)
        case "middleClick": click(button: 2)
        case "emoji": key(49, [.maskControl, .maskCommand])
        case "lockScreen": key(12, [.maskControl, .maskCommand])
        case "playPause": mediaKey(16)
        case "nextTrack": mediaKey(17)
        case "previousTrack": mediaKey(18)
        case "volumeUp": mediaKey(0)
        case "volumeDown": mediaKey(1)
        case "mute": mediaKey(7)
        case "brightnessUp": mediaKey(2)
        case "brightnessDown": mediaKey(3)
        default: break
        }
    }

    static func symbolicHotkey(for id: String) -> SymbolicHotkeys.Action? {
        switch id {
        case "missionControl": .missionControl
        case "appExpose": .appExpose
        case "showDesktop": .showDesktop
        case "spaceLeft": .spaceLeft
        case "spaceRight": .spaceRight
        case "lookUp": .lookUp
        case "spotlight": .spotlight
        case "launchpad": .launchpad
        default: nil
        }
    }

    /// Opening these system apps does not depend on whether their keyboard shortcut is enabled.
    /// Other symbolic actions report an unavailable shortcut rather than changing System Settings.
    private static func openApplicationFallback(for action: SymbolicHotkeys.Action) -> Bool {
        let url: URL?
        switch action {
        case .missionControl:
            let path = "/System/Applications/Mission Control.app"
            url = FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        case .launchpad:
            url = ["com.apple.launchpad.launcher", "com.apple.apps.launcher"].lazy
                .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        default: return false
        }
        return url.map { NSWorkspace.shared.open($0) } ?? false
    }

    private static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: MouseFixService.marker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// `count` presses + releases of a button (0 = left, 1 = right, 2 = middle, 3 = back…) at the pointer, with the click
    /// count an app expects for a double or triple click; tagged so our own tap lets them through.
    static func click(button: Int64, count: Int = 1) {
        let at = CGEvent(source: nil)?.location ?? .zero
        let (down, up, named): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case 0: (.leftMouseDown, .leftMouseUp, .left)
        case 1: (.rightMouseDown, .rightMouseUp, .right)
        default: (.otherMouseDown, .otherMouseUp, .center)
        }
        for n in 1...max(1, count) {
            for type in [down, up] {
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: named) else { continue }
                if button >= 2 { event.setIntegerValueField(.mouseEventButtonNumber, value: button) } // CGMouseButton only names left, right and center
                event.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                event.setIntegerValueField(.eventSourceUserData, value: MouseFixService.marker)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: Universal back and forward

    /// Apps whose Back/Forward is ⌘[ ⌘] (on top of every other Apple app).
    private static let commandBracket: Set<String> = [
        "org.zotero.zotero", "com.apple.systempreferences", "com.apple.AppStore", "dev.warp.Warp-Stable", "com.apple.Music",
        "com.apple.AddressBook", "com.apple.TV", "com.apple.iBooksX", "com.apple.Preview",
    ]
    private static let optionCommandBracket: Set<String> = ["com.apple.Notes", "com.apple.freeform"]
    private static let commandArrow: Set<String> = ["com.adobe.Acrobat.Pro", "com.apple.iCal"]

    /// Back/forward in whatever app is under the pointer: its own shortcut where it has one, otherwise the mouse's
    /// back/forward buttons, which most other apps (browsers, editors) understand.
    private static func navigate(back: Bool) {
        let id = appUnderPointer()?.bundleIdentifier ?? ""
        if optionCommandBracket.contains(id) {
            key(back ? 33 : 30, [.maskAlternate, .maskCommand])
        } else if commandArrow.contains(id) {
            key(back ? 123 : 124, .maskCommand)
        } else if id.hasPrefix("com.apple.") || commandBracket.contains(id) {
            key(back ? 33 : 30, .maskCommand)
        } else {
            click(button: back ? 3 : 4)
        }
    }

    /// The app owning the frontmost window at the pointer, falling back to the active app.
    private static func appUnderPointer() -> NSRunningApplication? {
        let at = CGEvent(source: nil)?.location ?? .zero
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        for window in windows ?? [] { // front to back
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(at),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid) else { continue }
            return app
        }
        return NSWorkspace.shared.frontmostApplication
    }

    /// Hardware keys (play, volume…) travel as system-defined events, not key codes.
    private static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: (key << 16) | (state << 8), data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

}

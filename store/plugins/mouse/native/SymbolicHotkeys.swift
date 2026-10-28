import AppKit
import Carbon
import Darwin

// Adapted from Mac Mouse Fix 3.1.0, Helper/Core/Actions/SymbolicHotKeys.m, by Noah Nuebling
// (https://github.com/noah-nuebling/mac-mouse-fix, MMF License). Keep the original alongside the
// vendored sources. This uses MMF's binding lookup, keyboard-layout search and event sequence.
// Unlike MMF, it never enables or changes an unavailable system shortcut.
enum SymbolicHotkeys {
    enum Action: Int32, CaseIterable {
        case missionControl = 32, appExpose = 33, showDesktop = 36, spotlight = 64
        case lookUp = 70, spaceLeft = 79, spaceRight = 81, launchpad = 160
    }

    struct Binding: Equatable {
        var enabled: Bool
        var keyEquivalent: UInt16
        var keyCode: CGKeyCode
        var flags: CGEventFlags
    }

    struct Shortcut: Equatable {
        var keyCode: CGKeyCode
        var flags: CGEventFlags
    }

    enum Unavailable: String, Error {
        case disabled = "The system keyboard shortcut is disabled. Enable it in Keyboard → Keyboard Shortcuts."
        case missing = "No system keyboard shortcut is available. Assign one in Keyboard → Keyboard Shortcuts."
        case unreachable = "The system keyboard shortcut cannot be entered with the current keyboard layout."
        case eventCreation = "The keyboard shortcut could not be created."
    }

    /// The pure part of MMF's search: preserve non-character keys and find character keys in the active layout.
    static func resolve(_ binding: Binding, character: (CGKeyCode) -> String?) -> Result<Shortcut, Unavailable> {
        guard binding.enabled else { return .failure(.disabled) }
        if binding.keyEquivalent == UInt16.max {
            guard binding.keyCode != UInt16.max else { return .failure(.missing) }
            return .success(Shortcut(keyCode: binding.keyCode, flags: binding.flags))
        }
        let wanted = String(utf16CodeUnits: [binding.keyEquivalent], count: 1)
        if binding.keyCode < 128, character(binding.keyCode) == wanted {
            return .success(Shortcut(keyCode: binding.keyCode, flags: binding.flags))
        }
        for code in CGKeyCode(0)..<128 where character(code) == wanted {
            return .success(Shortcut(keyCode: code, flags: binding.flags))
        }
        return .failure(.unreachable)
    }

    /// Event creation is separate from posting, so tests can verify it without controlling the user's desktop.
    static func events(for shortcut: Shortcut, restoring flags: CGEventFlags) -> [CGEvent]? {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) else { return nil }
        down.flags = shortcut.flags
        up.flags = flags // MMF restores the physical modifiers on key-up.
        for event in [down, up] { event.setIntegerValueField(.eventSourceUserData, value: MouseFixService.marker) }
        return [down, up]
    }

    /// Carbon's input-source APIs must run on the main thread, as in the original MMF implementation.
    static func post(_ action: Action, completion: @escaping (Unavailable?) -> Void) {
        let perform = {
            guard let binding = systemBinding(action) else { completion(.missing); return }
            let resolution = resolveCurrentLayout(binding)
            switch resolution {
            case let .failure(error): completion(error)
            case let .success(shortcut):
                let originalFlags = CGEventSource.flagsState(.combinedSessionState)
                guard let events = events(for: shortcut, restoring: originalFlags) else { completion(.eventCreation); return }
                events.forEach { $0.post(tap: .cgSessionEventTap) }
                completion(nil)
            }
        }
        if Thread.isMainThread { perform() } else { DispatchQueue.main.async(execute: perform) }
    }

    // These read-only CGS entry points are the same ones used by MMF. Dynamic loading makes absence recoverable.
    private typealias GetBinding = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static func systemBinding(_ action: Action) -> Binding? {
        if let library = skyLight,
           let get = dlsym(library, "CGSGetSymbolicHotKeyValue"), let enabled = dlsym(library, "CGSIsSymbolicHotKeyEnabled") {
            let isEnabled = unsafeBitCast(enabled, to: IsEnabled.self)(action.rawValue)
            if !isEnabled { return Binding(enabled: false, keyEquivalent: UInt16.max, keyCode: UInt16.max, flags: []) }
            var character = UInt16.max, code = UInt16.max, flags: UInt32 = 0
            let read = unsafeBitCast(get, to: GetBinding.self)
            guard read(action.rawValue, &character, &code, &flags) == 0 else { return nil }
            return Binding(enabled: true, keyEquivalent: character, keyCode: code, flags: CGEventFlags(rawValue: UInt64(flags)))
        }
        // Preserve explicit user choices if the private readers are unavailable on a future macOS version.
        let preferences = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        if let raw = preferences?[String(action.rawValue)] {
            guard let entry = raw as? [String: Any] else { return nil }
            guard let enabled = entry["enabled"] as? Bool else { return nil }
            if !enabled { return Binding(enabled: false, keyEquivalent: UInt16.max, keyCode: UInt16.max, flags: []) }
            guard let value = entry["value"] as? [String: Any], value["type"] as? String == "standard",
                  let parameters = value["parameters"] as? [NSNumber], parameters.count == 3,
                  let character = UInt16(exactly: parameters[0].intValue), let code = UInt16(exactly: parameters[1].intValue) else { return nil }
            return Binding(enabled: true, keyEquivalent: character, keyCode: code, flags: CGEventFlags(rawValue: parameters[2].uint64Value))
        }
        // Defaults are used only when no override exists, never for a disabled or malformed user override.
        let defaults: [Action: Shortcut] = [
            .missionControl: Shortcut(keyCode: 126, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
            .appExpose: Shortcut(keyCode: 125, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
            .showDesktop: Shortcut(keyCode: 103, flags: .maskSecondaryFn),
            .spotlight: Shortcut(keyCode: 49, flags: .maskCommand),
            .lookUp: Shortcut(keyCode: 2, flags: [.maskControl, .maskCommand]),
            .spaceLeft: Shortcut(keyCode: 123, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
            .spaceRight: Shortcut(keyCode: 124, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
        ]
        return defaults[action].map { Binding(enabled: true, keyEquivalent: UInt16.max, keyCode: $0.keyCode, flags: $0.flags) }
    }

    private static func resolveCurrentLayout(_ binding: Binding) -> Result<Shortcut, Unavailable> {
        if !binding.enabled || binding.keyEquivalent == UInt16.max { return resolve(binding) { _ in nil } }
        guard let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return .failure(.unreachable) }
        var source = current
        let ascii = TISGetInputSourceProperty(current, kTISPropertyInputSourceIsASCIICapable)
            .map { Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue() == kCFBooleanTrue } ?? false
        if !ascii {
            // macOS resolves shortcuts with ABC for non-ASCII layouts; MMF uses this same fallback.
            let query = [kTISPropertyInputSourceID as String: "com.apple.keylayout.ABC"] as CFDictionary
            guard let sources = TISCreateInputSourceList(query, false)?.takeRetainedValue() as? [TISInputSource],
                  let abc = sources.first else { return .failure(.unreachable) }
            source = abc
        }
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return .failure(.unreachable) }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let keyboard = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return .failure(.unreachable) }
            let layout = address.assumingMemoryBound(to: UCKeyboardLayout.self)
            return resolve(binding) { code in
                var dead: UInt32 = 0, length = 0
                var units = [UniChar](repeating: 0, count: 255)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, keyboard, 0, &dead,
                                            units.count, &length, &units)
                guard status == noErr, length > 0 else { return nil }
                let result = String(utf16CodeUnits: units, count: length)
                return result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? nil : result
            }
        }
    }
}

import AppKit

enum ActionTests {
    /// Uses in-memory mappings and CGEvents only: no settings reads/writes or event posting.
    static func run() -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        let customFlags: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand]
        let custom = SymbolicHotkeys.Binding(enabled: true, keyEquivalent: UInt16.max, keyCode: 17, flags: customFlags)
        let customResult = try? SymbolicHotkeys.resolve(custom) { _ in preconditionFailure("Non-character bindings need no keyboard layout") }.get()
        check(customResult == SymbolicHotkeys.Shortcut(keyCode: 17, flags: customFlags), "Use the user's configured key and modifiers, not a hardcoded default")

        var disabled = custom
        disabled.enabled = false
        if case .failure(.disabled) = SymbolicHotkeys.resolve(disabled, character: { _ in "t" }) { checks += 1 }
        else { preconditionFailure("An explicitly disabled binding must stay disabled") }

        var missing = custom
        missing.keyCode = UInt16.max
        if case .failure(.missing) = SymbolicHotkeys.resolve(missing, character: { _ in nil }) { checks += 1 }
        else { preconditionFailure("An absent binding must not post an invalid key") }

        // A character shortcut follows the current layout even if its original physical key moved.
        let characterBinding = SymbolicHotkeys.Binding(enabled: true, keyEquivalent: 122, keyCode: 6, flags: .maskControl)
        let translated = try? SymbolicHotkeys.resolve(characterBinding) { code in
            switch code { case 6: "y"; case 16: "z"; default: nil }
        }.get()
        check(translated == SymbolicHotkeys.Shortcut(keyCode: 16, flags: .maskControl), "Find the original shortcut character on the current layout")
        var characterOnly = characterBinding
        characterOnly.keyCode = UInt16.max
        let foundWithoutGuess = try? SymbolicHotkeys.resolve(characterOnly) { $0 == 16 ? "z" : nil }.get()
        check(foundWithoutGuess?.keyCode == 16, "A character binding can resolve without an original physical key")
        var visited: [CGKeyCode] = []
        let unchanged = try? SymbolicHotkeys.resolve(characterBinding) { code in visited.append(code); return code == 6 ? "z" : nil }.get()
        check(unchanged?.keyCode == 6 && visited == [6], "Prefer the configured physical key when its character still matches")
        if case .failure(.unreachable) = SymbolicHotkeys.resolve(characterBinding, character: { _ in nil }) { checks += 1 }
        else { preconditionFailure("An unreachable character must not rewrite the system shortcut") }

        let physicalFlags: CGEventFlags = [.maskControl, .maskAlternate]
        let events = SymbolicHotkeys.events(for: SymbolicHotkeys.Shortcut(keyCode: 17, flags: customFlags), restoring: physicalFlags)!
        check(events.count == 2 && events[0].type == .keyDown && events[1].type == .keyUp, "Create a complete press/release pair")
        check(events[0].getIntegerValueField(.keyboardEventKeycode) == 17 && events[1].getIntegerValueField(.keyboardEventKeycode) == 17,
              "Both events use the configured key")
        check(events[0].flags == customFlags && events[1].flags == physicalFlags, "Restore held physical modifiers on release, as MMF does")
        check(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == MouseFixService.marker }, "Synthetic shortcuts bypass Nook's own hotkeys")
        check(MouseActions.symbolicHotkey(for: "missionControl") == .missionControl && MouseActions.symbolicHotkey(for: "showDesktop") == .showDesktop,
              "System actions resolve symbolic bindings")
        check(MouseActions.symbolicHotkey(for: "spaceLeft") == .spaceLeft && MouseActions.symbolicHotkey(for: "spaceRight") == .spaceRight,
              "Spaces actions follow user keyboard preferences")
        check(MouseActions.symbolicHotkey(for: "lookUp") == .lookUp && MouseActions.symbolicHotkey(for: "launchpad") == .launchpad,
              "Default MMF button actions use symbolic bindings")
        check(MouseActions.symbolicHotkey(for: "copy") == nil, "App commands retain their normal shortcuts")
        return checks
    }
}

import Foundation

/// Checks for the click / hold / drag engine. Pure state machine: no events, timers or permissions.
func buttonChecks(_ check: (Bool, String) -> Void) {
    typealias Rule = MouseConfig.ButtonRule
    typealias Effect = ButtonEngine.Effect
    func rule(click: String = "none", double: String = "none", triple: String = "none", hold: String = "none", drag: String = "none",
              scroll: String = "none") -> Rule {
        var r = Rule(); r.click = click; r.double = double; r.triple = triple; r.hold = hold; r.drag = drag; r.scroll = scroll
        return r
    }
    func runs(_ effects: [Effect]) -> [String] { effects.compactMap { if case let .run(a) = $0 { a } else { nil } } }
    func replays(_ effects: [Effect]) -> [Int] { effects.compactMap { if case let .replay(_, n) = $0 { n } else { nil } } }
    func freezes(_ effects: [Effect]) -> [Bool] { effects.compactMap { if case let .freezePointer(on) = $0 { on } else { nil } } }
    func timers(_ effects: [Effect]) -> [(ButtonEngine.Timer, Double?)] { effects.compactMap { if case let .timer(_, kind, after) = $0 { (kind, after) } else { nil } } }
    func scrolls(_ effects: [Effect]) -> [ButtonEngine.ScrollPhase] { effects.compactMap { if case let .scroll(_, _, phase) = $0 { phase } else { nil } } }
    let b: Int64 = 3

    // Rule levels.
    check(rule(click: "copy").maxLevel == 1 && rule(double: "paste").maxLevel == 2 && rule(triple: "back").maxLevel == 3, "Highest mapped click level")
    check(rule(click: "a", double: "b", triple: "c").action(level: 2) == "b" && rule(click: "a").action(level: 3) == "none", "Action by level")
    check(!Rule().isActive && rule(double: "x").isActive && rule(drag: "scroll").isActive, "A rule is active when anything is mapped")

    // A plain click fires on press and waits for nothing.
    var e = ButtonEngine()
    var out = e.press(b, rule: rule(click: "copy"))
    check(runs(out) == ["copy"], "A lone click action fires on press")
    check(runs(e.release(b)).isEmpty && !e.isActive(b), "...and the release does nothing more")

    // Click + double click: the single click waits for the window; the double fires on the second press.
    e = ButtonEngine()
    let both = rule(click: "copy", double: "paste")
    out = e.press(b, rule: both)
    check(runs(out).isEmpty && timers(out).contains { $0.0 == .level && $0.1 == ButtonEngine.levelWindow }, "With a double click mapped, the click waits")
    check(runs(e.release(b)).isEmpty, "Release alone does nothing yet")
    check(runs(e.timerFired(b, .level)) == ["copy"] && !e.isActive(b), "The window running out fires the single click")
    _ = e.press(b, rule: both); _ = e.release(b)
    out = e.press(b, rule: both)
    check(runs(out) == ["paste"], "A second press inside the window is the double click")
    check(runs(e.release(b)).isEmpty && runs(e.timerFired(b, .level)).isEmpty, "...and nothing fires afterwards")

    // Triple click, then the cycle starts over.
    e = ButtonEngine()
    let triple = rule(click: "a", double: "b", triple: "c")
    _ = e.press(b, rule: triple); _ = e.release(b)
    _ = e.press(b, rule: triple); _ = e.release(b)
    check(runs(e.press(b, rule: triple)) == ["c"], "The third press is the triple click")
    _ = e.release(b)
    check(runs(e.press(b, rule: triple)).isEmpty, "A fourth press starts over at a single click")
    _ = e.release(b)
    check(runs(e.timerFired(b, .level)) == ["a"], "...which fires when the window runs out")

    // A level with no action gives the clicks back; a mapped one fires.
    e = ButtonEngine()
    let onlyDouble = rule(double: "paste")
    _ = e.press(b, rule: onlyDouble); _ = e.release(b)
    check(replays(e.timerFired(b, .level)) == [1], "A single click with no action is given back")
    _ = e.press(b, rule: onlyDouble); _ = e.release(b)
    check(runs(e.press(b, rule: onlyDouble)) == ["paste"], "...but a double click runs its action")
    e = ButtonEngine()
    let skipping = rule(click: "a", triple: "c")
    _ = e.press(b, rule: skipping); _ = e.release(b); _ = e.press(b, rule: skipping); _ = e.release(b)
    check(replays(e.timerFired(b, .level)) == [2], "A double click with no action is given back as two clicks")

    // Hold: the click waits for the release; the hold fires after the delay and then nothing else does.
    e = ButtonEngine()
    let holding = rule(click: "copy", hold: "paste")
    out = e.press(b, rule: holding)
    check(runs(out).isEmpty && timers(out).contains { $0.0 == .hold && $0.1 == ButtonEngine.holdDelay }, "A button that holds waits to see")
    check(runs(e.release(b)) == ["copy"], "A quick release is the click")
    _ = e.press(b, rule: holding)
    check(runs(e.timerFired(b, .hold)) == ["paste"], "Holding runs the hold action")
    check(runs(e.release(b)).isEmpty && replays(e.release(b)).isEmpty && !e.isActive(b), "...and releasing after it does nothing")
    e = ButtonEngine()
    _ = e.press(b, rule: rule(hold: "paste"))
    check(replays(e.release(b)) == [1], "A quick click on a hold-only button is given back")

    // MMF always enters its held phase at 250 ms. An ambiguous click held longer
    // than that does not turn into a late single click when no hold action is mapped.
    e = ButtonEngine()
    _ = e.press(b, rule: both)
    check(runs(e.timerFired(b, .hold)).isEmpty, "Original MMF hold phase has no action when none is mapped")
    check(e.timerFired(b, .level).isEmpty, "The original hold transition invalidates the level deadline")
    check(runs(e.release(b)).isEmpty, "Original release-from-hold does not become an ambiguous single click")

    // Drag to Spaces: freezes the pointer, a click is still a click, a long drag fires once.
    e = ButtonEngine()
    let spaces = rule(drag: "spaces")
    out = e.press(b, rule: spaces)
    check(freezes(out) == [true], "A drag button freezes the pointer on press")
    out = e.release(b)
    check(replays(out) == [1] && freezes(out) == [false], "A click without dragging is given back and the pointer freed")
    _ = e.press(b, rule: spaces)
    check(e.drag(b, dx: 20, dy: 0).isEmpty, "Short drags do nothing")
    check(runs(e.drag(b, dx: 40, dy: 0)) == ["spaceLeft"], "Dragging right goes to the Space on the left")
    check(e.drag(b, dx: 200, dy: 0).isEmpty, "...once")
    out = e.release(b)
    check(freezes(out) == [false] && replays(out).isEmpty, "Releasing frees the pointer and gives no click")
    for (dx, dy, action) in [(-60.0, 0.0, "spaceRight"), (0.0, -60.0, "missionControl"), (0.0, 60.0, "appExpose")] {
        _ = e.press(b, rule: spaces)
        check(runs(e.drag(b, dx: dx, dy: dy)) == [action], "Drag direction picks \(action)")
        _ = e.release(b)
    }

    // Drag to scroll: starts after a few pixels, follows the drag, ends on release.
    e = ButtonEngine()
    let scrolling = rule(drag: "scroll")
    _ = e.press(b, rule: scrolling)
    check(scrolls(e.drag(b, dx: 0, dy: 3)).isEmpty, "A tiny drag doesn't scroll")
    check(scrolls(e.drag(b, dx: 0, dy: 6)) == [.began], "Past the threshold it starts scrolling")
    check(scrolls(e.drag(b, dx: 0, dy: 4)) == [.changed], "...and follows the drag")
    out = e.release(b)
    check(scrolls(out) == [.ended] && freezes(out) == [false] && replays(out).isEmpty, "Release ends the scroll and frees the pointer")

    // Pointer cleanup remains balanced across physical buttons. Click recognition
    // follows MMF's one active cycle, so another button cancels the first pending click.
    e = ButtonEngine()
    check(freezes(e.press(2, rule: spaces)) == [true] && freezes(e.press(4, rule: spaces)).isEmpty, "One freeze for two dragging buttons")
    check(freezes(e.release(2)).isEmpty, "Still frozen while the other is down")
    check(freezes(e.release(4)) == [false], "Freed with the last release")
    e = ButtonEngine()
    _ = e.press(2, rule: both)
    check(runs(e.press(4, rule: rule(click: "mute"))) == ["mute"], "A second button fires on its own")
    _ = e.release(2)
    check(runs(e.timerFired(2, .level)).isEmpty, "The original MMF recognizer cancelled the first button's pending click")

    // Drag as a live swipe: starts after a few pixels, locks its axis, follows the drag, ends (or cancels) cleanly.
    func swipes(_ effects: [Effect]) -> [(ButtonEngine.SwipeAxis, Double, Double, ButtonEngine.SwipePhase)] {
        effects.compactMap { if case let .swipe(axis, dx, dy, phase) = $0 { (axis, dx, dy, phase) } else { nil } }
    }
    e = ButtonEngine()
    let swiping = rule(drag: "swipe")
    _ = e.press(b, rule: swiping)
    check(swipes(e.drag(b, dx: 2, dy: 2)).isEmpty, "A tiny drag doesn't swipe")
    var began = swipes(e.drag(b, dx: 3, dy: 9))
    check(began.count == 1 && began[0].0 == .vertical && began[0].3 == .began && began[0].2 == 9, "Mostly vertical locks vertical, starting with that move")
    check(swipes(e.drag(b, dx: 50, dy: 1)).first.map { $0.0 == .vertical && $0.3 == .changed } == true, "The axis stays locked for the whole swipe")
    out = e.release(b)
    check(swipes(out).first.map { $0.3 == .ended } == true && freezes(out) == [false] && replays(out).isEmpty, "Release ends the swipe and frees the pointer")
    e = ButtonEngine()
    _ = e.press(b, rule: swiping)
    began = swipes(e.drag(b, dx: 12, dy: 2))
    check(began.first.map { $0.0 == .horizontal && $0.3 == .began } == true, "Mostly sideways locks horizontal")
    check(swipes(e.cancelAll()).first.map { $0.3 == .cancelled } == true, "Interrupting a swipe cancels it")

    // The wheel while a button is held: the button's own click waits for it and is spent when the wheel is used.
    e = ButtonEngine()
    let zooming = rule(scroll: "zoom")
    out = e.press(b, rule: zooming)
    check(replays(out).isEmpty && runs(out).isEmpty, "A wheel-effect button waits instead of clicking on press")
    let held = e.scrollWhileHeld()
    check(held?.mode == "zoom" && timers(held?.effects ?? []).count == 2, "Holding it makes the wheel zoom (and stops the click timers)")
    check(e.scrollWhileHeld()?.effects.isEmpty == true, "...and asking again is harmless")
    out = e.release(b)
    check(replays(out).isEmpty && runs(out).isEmpty && !e.isActive(b), "Using the wheel spends the click")
    _ = e.press(b, rule: zooming)
    check(replays(e.release(b)) == [1], "Without the wheel it is still a click")
    e = ButtonEngine()
    _ = e.press(b, rule: rule(click: "copy", scroll: "zoom"))
    check(runs(e.release(b)) == ["copy"], "A click that waited for a possible wheel turn fires on release")
    check(e.scrollWhileHeld() == nil, "Nothing is held afterwards")
    e = ButtonEngine()
    _ = e.press(b, rule: rule(click: "copy"))
    check(e.scrollWhileHeld() == nil, "A button without a wheel effect leaves the wheel alone")

    // Cancelling frees everything and leaves no half-finished presses behind.
    e = ButtonEngine()
    _ = e.press(2, rule: scrolling); _ = e.drag(2, dx: 0, dy: 20); _ = e.press(4, rule: spaces)
    out = e.cancelAll()
    check(freezes(out) == [false] && scrolls(out) == [.ended], "Cancel ends the scroll and frees the pointer")
    check(!e.isActive(2) && !e.isActive(4) && e.release(2).isEmpty && e.timerFired(4, .hold).isEmpty, "Nothing is left waiting")

    // Trackpad swipe bookkeeping.
    var swipeState = DockSwipeState()
    check(swipeState.update(delta: 0.2, phase: .began) && swipeState.origin == 0.2, "A swipe starts at its first move")
    swipeState.finish(delta: 0.2)
    check(swipeState.update(delta: 0.2, phase: .changed) && abs(swipeState.origin - 0.4) < 1e-12, "It accumulates")
    swipeState.finish(delta: 0.2)
    check(!swipeState.update(delta: 0, phase: .changed), "A change that moved nothing is skipped")
    check(swipeState.resolved(.ended) == .ended && swipeState.exitSpeed(for: .ended) == 20, "Heading on, it ends with the exit speed")
    _ = swipeState.update(delta: -0.05, phase: .changed)
    swipeState.finish(delta: -0.05)
    check(swipeState.resolved(.ended) == .cancelled, "Turning back at the end cancels the swipe")
    check(swipeState.resolved(.changed) == .changed && swipeState.exitSpeed(for: .changed) == 0, "Only ends are changed")
    check(abs(DockSwipe.Scale.horizontal(screenWidth: 1000, spaces: 1) - 2 / 1063) < 1e-12, "One or two Spaces: two screen widths of offset")
    check(abs(DockSwipe.Scale.horizontal(screenWidth: 1000, spaces: 3) - 1.5 / 1063) < 1e-12, "More Spaces: less offset each")
    check(abs(DockSwipe.Scale.vertical(screenHeight: 800) - 1.0 / 800) < 1e-12, "Vertical swipes scale with the screen height")

    // Presets and the new settings.
    let preset = MouseConfig.preset("mmf")
    check(MouseConfig.preset("nope") == nil && preset?.count == 3, "The MMF preset maps the middle, back and forward buttons")
    check(preset?["2"]?.double == "launchpad" && preset?["2"]?.hold == "showDesktop" && preset?["2"]?.drag == "swipe", "Middle: look up, Launchpad, desktop, swipe")
    check(preset?["3"]?.scroll == "pinch" && preset?["4"]?.scroll == "zoom" && preset?["4"]?.click == "smartZoom" && preset?["4"]?.drag == "scroll", "Back pinches, forward zooms")
    var config = MouseConfig()
    config.buttons = ["2": { var r = MouseConfig.ButtonRule(); r.scroll = "bogus"; r.drag = "bogus"; r.click = "bogus"; return r }()]
    config.zoomModifier = "bogus"
    config.normalize()
    check(config.buttons["2"] == MouseConfig.ButtonRule() && config.zoomModifier == "none", "Unknown choices fall back to nothing")
    check(MouseConfig().merging(["zoomModifier": "command"])?.zoomModifier == "command", "The zoom modifier merges through the bridge")
}

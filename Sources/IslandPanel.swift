import AppKit

// =====================================================================
// The window the island lives in.
//
// THE ONE BEHAVIOURAL REQUIREMENT THAT OUTRANKS EVERYTHING: this must
// never take focus. The user types in an editor all day; an island that
// grabs the keyboard is worse than no island at all. Concretely that
// means, and this list is load-bearing:
//
//   * `.nonactivatingPanel` in the styleMask — this is the ONLY way to
//     express "deliver the click to me without foregrounding my app".
//     A plain NSWindow cannot, which is why NotchDrop resorts to
//     NSApp.activate(ignoringOtherApps: true) and consequently steals
//     focus. We do not copy that.
//   * canBecomeMain is ALWAYS false. Main == app foreground.
//   * canBecomeKey is false: we host no text field, so we never need the
//     keyboard, so we never take it.
//   * order in with orderFrontRegardless(), NEVER makeKeyAndOrderFront().
//   * NSApp.activate is never called anywhere in this app. Not on hover,
//     not on click, not on a Space restore.
//   * hidesOnDeactivate = false — NSPanel can default to true, and for an
//     accessory app "deactivated" is the normal state, so leaving it
//     alone makes the island blink out constantly.
// =====================================================================

final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        // --- panel semantics ---
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        allowsToolTipsWhenApplicationIsInactive = true

        // --- transparency ---
        isOpaque = false
        backgroundColor = .clear
        // A window shadow is RECTANGULAR: it ignores the SwiftUI mask and
        // smears grey into the menu bar. The shadow is drawn in SwiftUI on
        // the masked shape instead.
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // The island is always dark, whatever the system theme is.
        appearance = NSAppearance(named: .darkAqua)

        // --- stays put ---
        isMovable = false
        isMovableByWindowBackground = false
        isRestorable = false
        isReleasedWhenClosed = false

        // .statusBar (25) + 8 = 33. Above the menu bar (24/25) and below
        // .screenSaver (1000) — at .screenSaver system drag sessions are
        // silently undeliverable, and CGShieldingWindowLevel() is the
        // screen-capture shield level, not an "always on top" level.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)

        collectionBehavior = [
            .canJoinAllSpaces,     // present on every Space
            .stationary,           // does not slide during Mission Control
            .fullScreenAuxiliary,  // survives another app going fullscreen;
                                   // without this the island vanishes there
            .ignoresCycle,         // out of Cmd-Tab and the window cycle
        ]

        acceptsMouseMovedEvents = true

        // ARCHITECTURE B (ping-island). `ignoresMouseEvents` is tri-state,
        // not a Bool: never assigning it gives per-pixel alpha hit testing,
        // but assigning it AT ALL — including `= false` — destroys that for
        // the window instance forever. Since this panel spans the full
        // screen width and is several hundred points tall, leaving it armed
        // would make the entire top strip of the screen unclickable. So we
        // arm it at creation and flip it off only while the pointer is
        // actually inside the island's hit rect (see IslandController).
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

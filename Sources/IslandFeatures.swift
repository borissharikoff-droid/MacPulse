import AppKit

// =====================================================================
// THE ONE FILE A NEW FEATURE EDITS.
//
// Everything else a section needs — its id, its chip, its body, its
// footer line — lives in the feature's own file. This is only the list of
// which features exist, so that adding one never means reading the
// router. See IslandSection.swift for the shape of a section and the
// rules its callbacks must obey.
//
// Registration order is RAIL ORDER, left to right. Память is registered
// by the registry itself and is always leftmost, because it is the only
// section that is always live and therefore the only sane fallback when
// whatever the user was looking at goes quiet.
//
// Priority note for whoever adds the collapsed-strip slot: the rail is
// not the strip. The rail lists everything that currently has state; the
// trailing wing shows exactly ONE thing, the highest-priority live one,
// and `IslandModel.setStripSlotSection` is how that choice reaches the
// panel as its default tab.
// =====================================================================

enum IslandFeatures {

    /// Called once, from `IslandModel.start()`, on the main thread.
    static func registerAll() {
        precondition(Thread.isMainThread)

        // >>> ADD YOUR SECTION HERE. One line. <<<

        // RAIL ORDER, AND WHY IT IS THIS ORDER.
        //
        // Память is leftmost and is registered by the registry itself.
        // Давление comes next because it is Память's own subject — the two
        // memory tabs sit together, and a rail that scattered them would
        // read as seven unrelated features rather than one app.
        //
        // Then the four that compete for the collapsed strip's single
        // slot, in exactly the priority `IslandModel.updateTrailingSlot`
        // uses: Печать, Встреча, Звук, Туннель. One ordering to learn, not
        // two — the chip a user reaches for first is the thing the strip
        // would have shown them.
        //
        // Буфер last: a history is the least urgent thing in the panel and
        // it is the only section here that is never a live condition.

        // The memory-pressure notifier. Mostly not a section at all: its
        // chip is absent unless it has actually warned the user in the
        // last 24 h, or the user has switched it off — see
        // IslandSectionPressure.swift.
        IslandSectionRegistry.register(.pressure)

        // Bambu P1S, read from the user's own loopback panel. Its chip is
        // absent unless a print is actually running — see
        // IslandSectionPrinter.swift.
        IslandSectionRegistry.register(.printer)

        // The next meeting. Its chip is absent unless there is a TIMED
        // event in the next 24 hours, and the engine behind it does not
        // touch EventKit at all until the user turns the feature on in
        // this app's own menu — see IslandSectionCalendar.swift.
        IslandSectionRegistry.register(.calendar)

        // Who has an audio output stream open, plus the transport keys.
        // Its chip is absent unless something is actually making sound —
        // see IslandSectionSound.swift.
        IslandSectionRegistry.register(.sound)

        // Who is carrying this machine's traffic. Its chip is absent
        // unless a tunnel is up AND is not the default route — see
        // IslandSectionTunnel.swift.
        IslandSectionRegistry.register(.tunnel)

        // Clipboard history, in memory only. Its chip is absent until
        // something has been copied RECENTLY, goes away again when that
        // copy goes stale, and it NEVER takes the collapsed strip's slot
        // — see IslandSectionClipboard.swift.
        IslandSectionRegistry.register(.clipboard)

        // IslandSectionRegistry.register(.shelf)

        // NOT A SECTION, ON PURPOSE: the mic/camera privacy rail. It is a
        // dot in the trailing wing plus a line in the panel footer, and it
        // gets no tab — a tab is something you navigate TO, and a safety
        // signal has to be legible without navigating anywhere. See
        // IslandPrivacyRail.swift.
    }
}

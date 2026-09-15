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
        // Then the four that compete for the collapsed strip's single slot,
        // in exactly the priority `IslandModel.updateTrailingSlot` uses:
        // Печать, Встреча, Звук, Туннель. One ordering to learn, not two —
        // the chip a user reaches for first is the thing the strip would
        // have shown them.
        //
        // TWO SECTIONS THAT USED TO BE REGISTERED HERE ARE NOT ANY MORE,
        // and neither of them lost its feature:
        //
        //   Давление  folded into Память. The user: "смысл между давлением
        //             и памятью — это как будто одни и те же вкладки, нахуя
        //             их разъединять". Two chips for one subject made him
        //             navigate between two halves of the same answer. The
        //             notifier still runs, still warns, still has its mute
        //             switch — at the bottom of Память, and only while it
        //             has something to say. See IslandPressureFold.swift.
        //
        //   Буфер     became the SHELF along the bottom of the panel, on
        //             screen whichever section is selected, with every
        //             entry draggable into another app. A tab is a place
        //             you navigate to, which is one gesture too many for a
        //             thing you reach for. See IslandShelf.swift.
        //
        // So the rail is five sections where it was seven.

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

        // NOT A SECTION, ON PURPOSE: the mic/camera privacy readout. It is
        // one clause in the panel footer and nothing else. It gets no tab
        // because a tab is something you navigate TO, and it no longer gets
        // a dot in the collapsed wing either, because macOS draws that
        // indicator in its own menu bar a few points away. What we say is
        // the part the system leaves out: WHICH app. See
        // IslandPrivacyLine.swift.
        //
        // ALSO NOT A SECTION: the clipboard shelf. `IslandRouter` draws it
        // below the body, outside the registry entirely — see
        // IslandShelf.swift for why that exception exists.
    }
}

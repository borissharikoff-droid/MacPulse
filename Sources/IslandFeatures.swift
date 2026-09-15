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

        // Bambu P1S, read from the user's own loopback panel. Its chip is
        // absent unless a print is actually running — see
        // IslandSectionPrinter.swift.
        IslandSectionRegistry.register(.printer)

        // IslandSectionRegistry.register(.shelf)
        // IslandSectionRegistry.register(.clipboard)
        // IslandSectionRegistry.register(.tunnel)

        // NOT A SECTION, ON PURPOSE: the mic/camera privacy rail. It is a
        // dot in the trailing wing plus a line in the panel footer, and it
        // gets no tab — a tab is something you navigate TO, and a safety
        // signal has to be legible without navigating anywhere. See
        // IslandPrivacyRail.swift.
    }
}

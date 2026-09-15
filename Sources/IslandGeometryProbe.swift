import AppKit

// =====================================================================
// `--wing-probe`: proof that the hit rect follows the drawn wing.
//
// The failure this exists to catch has no visible symptom until a user
// hits it: the island is DRAWN from `IslandMetrics.collapsedPlate` in
// SwiftUI and HIT-TESTED from the same function in AppKit, and if those
// two ever disagree the island silently stops opening over part of
// itself, or arms the panel over bare menu bar and swallows clicks meant
// for the menu bar extras. Neither shows up in a screenshot.
//
// So the invariants are checked numerically, against this machine's real
// screen, across the whole range of trailing-wing widths a feature can
// ask for — including widths the model is supposed to refuse.
//
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --wing-probe
//   ... --wing-probe --status-item-x 1031     (synthetic bound)
//
// Exit status is 0 only if every invariant held.
// =====================================================================

enum IslandGeometryProbe {

    static func run(arguments: [String]) -> Never {
        // Touching NSApplication.shared connects to the window server, so
        // NSScreen has something to report.
        _ = NSApplication.shared

        let screen = NSScreen.mp_islandScreen
        let metrics = screen.map { NotchMetrics.detect(screen: $0) }
            ?? NotchMetrics(notchSize: CGSize(width: 183, height: 32), hasPhysicalNotch: true)
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1470, height: 956)
        let midX = screenFrame.midX
        let notch = metrics.notchSize

        var statusItemX: CGFloat?
        if let i = arguments.firstIndex(of: "--status-item-x"), i + 1 < arguments.count {
            statusItemX = Double(arguments[i + 1]).map { CGFloat($0) }
        }

        print("screen           \(fmt(screenFrame.width)) x \(fmt(screenFrame.height))  midX \(fmt(midX))")
        print("notch            \(fmt(notch.width)) x \(fmt(notch.height))  "
              + "x \(fmt(midX - notch.width / 2)) ... \(fmt(midX + notch.width / 2))")
        print("leading wing     \(fmt(IslandMetrics.leadingWingWidth)) pt, FROZEN")
        let limit = IslandMetrics.trailingWingLimit(statusItemMinX: statusItemX,
                                                    screenMidX: midX,
                                                    notchWidth: notch.width)
        print("status item minX \(statusItemX.map(fmt) ?? "unknown (probe has no status item)")")
        print("trailing limit   \(fmt(limit)) pt "
              + "(ceiling \(fmt(IslandMetrics.maxTrailingWingWidth)) = the widest row the wing "
              + "can draw, clearance \(fmt(IslandMetrics.statusItemClearance)))")
        if statusItemX == nil {
            print("                 no --status-item-x, so the wing REFUSES TO GROW and stays")
            print("                 at the resting \(fmt(IslandMetrics.restingWingWidth)) pt. "
                  + "Pass --status-item-x 952 for this machine's real bound.")
        }
        print("")

        // A stand-in for the real geometry: the same maths NotchGeometry
        // does, without needing a live NSScreen on a headless run.
        func islandRect(_ plate: IslandMetrics.Plate) -> CGRect {
            CGRect(x: midX - plate.size.width / 2 + plate.centerOffsetX,
                   y: screenFrame.maxY - plate.size.height,
                   width: plate.size.width, height: plate.size.height)
        }

        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append(what) }
        }

        print(" requested  granted    plate x            width   notch-centre  hit rect x          fits")
        print(" ---------  -------  -------------------  ------  ------------  ------------------  ----")

        let requests: [CGFloat] = [0, 26, 40, 72, 100, 130, 156, 200, 400]
        var collapsedLeftEdge: CGFloat?

        for request in requests {
            // Exactly what IslandModel.requestTrailingWing does.
            let granted = min(max(request, IslandMetrics.restingWingWidth), limit)

            let plate = IslandMetrics.collapsedPlate(notch: notch,
                                                     leading: IslandMetrics.leadingWingWidth,
                                                     trailing: granted)
            let drawn = islandRect(plate)
            let hit = drawn.insetBy(dx: -10, dy: -6)

            // INVARIANT 1 — the camera housing is physical glass and does
            // not move. Whatever the wings do, the notch's centre inside
            // the plate has to stay on the screen's midX, or the island is
            // drawn off its own hole.
            let notchCentre = drawn.minX + plate.fillet
                + IslandMetrics.leadingWingWidth + notch.width / 2
            check(abs(notchCentre - midX) < 0.01,
                  "wing \(fmt(granted)): notch centre \(fmt(notchCentre)) != midX \(fmt(midX))")

            // INVARIANT 2 — the hit rect covers the whole drawn plate.
            // This is the one that silently kills the island.
            check(hit.contains(drawn),
                  "wing \(fmt(granted)): hit rect does not cover the drawn plate")

            // INVARIANT 3 — the left edge NEVER moves. The left wing is
            // frozen because it has 0.5 pt of clearance against the
            // frontmost app's menus; if growing the RIGHT wing moved the
            // left edge, that clearance would be gone.
            if let first = collapsedLeftEdge {
                check(abs(drawn.minX - first) < 0.01,
                      "wing \(fmt(granted)): left edge moved to \(fmt(drawn.minX)) from \(fmt(first))")
            } else {
                collapsedLeftEdge = drawn.minX
            }

            // INVARIANT 4 — the granted width never puts the plate under
            // our own status item.
            var fits = true
            if let statusItemX {
                fits = drawn.maxX <= statusItemX - IslandMetrics.statusItemClearance + 0.01
                check(fits, "wing \(fmt(granted)): right edge \(fmt(drawn.maxX)) is within "
                      + "\(fmt(IslandMetrics.statusItemClearance)) pt of the status item at \(fmt(statusItemX))")
            }

            // Built by hand: String(format:) with %s takes a C string, and
            // handing it a Swift String segfaults rather than complaining.
            print("  " + pad(fmt(request), 9) + "  " + pad(fmt(granted), 7)
                  + "  " + pad(fmt(drawn.minX), 8) + " ... " + pad(fmt(drawn.maxX), 8)
                  + "  " + pad(fmt(drawn.width), 6)
                  + "  " + pad(fmt(notchCentre), 12)
                  + "  " + pad(fmt(hit.minX), 8) + " ... " + pad(fmt(hit.maxX), 8)
                  + "  " + (statusItemX == nil ? "n/a" : (fits ? "yes" : "NO")))
        }

        // ---- what actually fits INSIDE the granted wing ----
        //
        // INVARIANT 5 — THE CEILING IS THE WIDEST ROW, exactly. It is
        // defined as the sum of the row's parts in IslandMetrics so it
        // cannot drift, and this re-adds the parts here so that a term
        // quietly dropped from the definition (which is what happened when
        // the privacy rail left: two terms went) is caught as a number
        // rather than noticed on screen.
        //
        // THERE IS NO PRIVACY-RAIL INVARIANT ANY MORE. The rail used to be
        // checked twice — that it fits the RESTING wing, and that it is
        // never truncated at any width the model can grant — because it was
        // a safety signal that must never lose a width negotiation. It is
        // not in the wing at all now (macOS draws that indicator itself;
        // see IslandPrivacyLine.swift), so there is nothing here to
        // squeeze. Both checks are DELETED rather than weakened: a check
        // that passes vacuously is worse than no check, because the comment
        // above it goes on claiming the old property.
        let widestRow = IslandMetrics.slotLeadingGap + IslandMetrics.ringDiameter
            + IslandMetrics.ringTextGap + IslandMetrics.slotTextWidth
        check(abs(IslandMetrics.maxTrailingWingWidth - widestRow) < 0.01,
              "ceiling (\(fmt(IslandMetrics.maxTrailingWingWidth)) pt) is not the widest "
              + "row the wing can draw (\(fmt(widestRow)) pt)")

        print("")
        print("  wing   print  lead  slot  slot-text  spent / wing")
        print("  -----  -----  ----  ----  ---------  ------------")
        // `slot: false` FIRST, because that is the commonest state this
        // feature is ever in — no print, no imminent meeting, wing at rest.
        for wing in [IslandMetrics.restingWingWidth, 40, 60, limit,
                     IslandMetrics.maxTrailingWingWidth] as [CGFloat] {
          for slot in [false, true] {
                let l = IslandMetrics.trailingLayout(wing: wing, slotVisible: slot)
                // `l.spent` and not a formula retyped here. A previous
                // version of this probe recomputed the sum by hand and
                // omitted the slot lead-in in exactly the same way the view
                // applied it unconditionally — so it printed "OK — every
                // invariant held" for a row that really drew 30 pt into a
                // 26 pt wing. A probe that re-derives what it is checking
                // can only ever catch the bugs it happens not to share.
                let spent = l.spent

                // INVARIANT 6 — the contents never draw wider than the
                // wing. Pixels outside the wing are pixels outside the hit
                // rect, where clicks go to the menu bar instead of to us.
                check(spent <= wing + 0.01,
                      "wing \(fmt(wing)) slot=\(slot): "
                      + "contents spend \(fmt(spent)) pt")

                // INVARIANT 7 — an empty wing spends NOTHING. With the rail
                // gone the resting wing draws no pixels at all, and a
                // lead-in reserved for a slot that is not there is exactly
                // the bug that pushed the rail off the plate before.
                if !slot {
                    check(spent == 0,
                          "wing \(fmt(wing)): no slot, yet \(fmt(spent)) pt is spent")
                }

                print("  " + pad(fmt(wing), 5)
                      + "  " + pad(slot ? "on" : "off", 5)
                      + "  " + pad(fmt(l.leadingGap), 4)
                      + "  " + pad(fmt(l.slotWidth), 4)
                      + "  " + pad(l.showsSlotText ? "yes" : "no", 9)
                      + "  " + pad(fmt(spent), 5) + " / " + fmt(wing))
          }
        }

        // The opened panel: 560 x 304, centred.
        let opened = IslandMetrics.openedPlate()
        let openedRect = islandRect(opened)
        print("")
        print("opened panel     \(fmt(opened.size.width)) x \(fmt(opened.size.height))  "
              + "x \(fmt(openedRect.minX)) ... \(fmt(openedRect.maxX))  offset \(fmt(opened.centerOffsetX))")
        check(abs(opened.size.width - (IslandMetrics.panelWidth + IslandMetrics.openedFillet * 2)) < 0.01,
              "opened plate is not 560 + 2 x 19 wide")
        check(abs(opened.size.height - IslandMetrics.panelHeight) < 0.01,
              "opened plate is not \(fmt(IslandMetrics.panelHeight)) tall")
        check(IslandMetrics.panelLayoutIsConsistent(stripHeight: notch.height),
              "panel rows (\(fmt(notch.height)) strip + \(fmt(IslandMetrics.panelContentHeight)) content) "
              + "do not add up to \(fmt(IslandMetrics.panelHeight))")
        print("panel rows       \(fmt(notch.height)) strip + \(fmt(IslandMetrics.railGap)) + "
              + "\(fmt(IslandMetrics.railHeight)) rail + \(fmt(IslandMetrics.bodyGap)) + "
              + "\(fmt(IslandMetrics.bodyHeight)) body + \(fmt(IslandMetrics.shelfGap)) + "
              + "\(fmt(IslandMetrics.shelfHeight)) shelf + \(fmt(IslandMetrics.footerGap)) + "
              + "\(fmt(IslandMetrics.footerHeight)) footer = "
              + "\(fmt(notch.height + IslandMetrics.panelContentHeight))")

        // THE SHELF. Five draggable clipboard chips along the bottom, on
        // screen whichever section is selected. How wide a chip is decides
        // how much preview it can show — which is the whole argument for
        // five rather than eight — so it is arithmetic here rather than a
        // look at the panel.
        let shelfContent = IslandMetrics.panelWidth - IslandRouter.gutter * 2
        let chip = IslandMetrics.shelfChipWidth(content: shelfContent)
        let spentShelf = chip * CGFloat(IslandMetrics.shelfSlots)
            + CGFloat(IslandMetrics.shelfSlots - 1) * IslandMetrics.shelfChipGap
        print("shelf            \(IslandMetrics.shelfSlots) chips x \(fmt(chip)) pt + "
              + "\(IslandMetrics.shelfSlots - 1) x \(fmt(IslandMetrics.shelfChipGap)) pt gaps = "
              + "\(fmt(spentShelf)) of \(fmt(shelfContent)) pt, "
              + "\(fmt(chip - ShelfChipMetrics.chrome)) pt of preview per chip")
        check(spentShelf <= shelfContent + 0.01,
              "the shelf row spends \(fmt(spentShelf)) pt of a \(fmt(shelfContent)) pt box")
        check(IslandMetrics.shelfChipHeight <= IslandMetrics.shelfHeight,
              "a \(fmt(IslandMetrics.shelfChipHeight)) pt chip does not fit a "
              + "\(fmt(IslandMetrics.shelfHeight)) pt shelf")
        // The number that made the count five. Below ~60 pt a preview stops
        // telling two entries apart, and picking the wrong chip on a shelf
        // you DRAG from means dropping the wrong file into somebody's chat.
        check(chip - ShelfChipMetrics.chrome >= 60,
              "\(IslandMetrics.shelfSlots) chips leaves only "
              + "\(fmt(chip - ShelfChipMetrics.chrome)) pt of preview")

        print("")
        if failures.isEmpty {
            print("OK — every invariant held.")
            exit(0)
        }
        for f in failures { print("FAIL — \(f)") }
        exit(1)
    }

    private static func fmt(_ v: CGFloat) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }
}

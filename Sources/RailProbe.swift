import AppKit

// =====================================================================
// «Рейка» — the router's own discipline check.
//
// THE QUESTION THIS ANSWERS, and it is the one question the router can
// fail silently: on a quiet machine, how many chips are in the rail?
//
// IslandSection.swift's second rule is that `hasState` must be FALSE when
// a feature has nothing to say, and nothing enforces it. A section whose
// chip is always present costs the user a tab they did not ask for, and
// seven such sections turn the router back into the dashboard it was
// built to replace. Every previous check of this was somebody looking at
// the panel and saying it looked fine; the screen is not always
// available, and "looked fine" is not a measurement.
//
// So this starts the REAL IslandModel — the same `start()` the app
// calls, the same registry, the same watchers — lets the feature sources
// settle, and then asks every registered section the same `hasState`
// closure the rail asks. What it prints is the rail, as the rail would
// be drawn.
//
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --rail-probe [20]
//
// It draws nothing and opens no panel, so the middle of it is a fair
// look at what the COLLAPSED island has decided — including which
// section owns the trailing wing's one slot, which is the other
// cross-feature question nobody can see from inside a single feature's
// file.
//
// The LAST stage marks the model open and clicks through every tab,
// waiting out a real tick under each one. That answers a different
// question — whether the router lets the user's click stand — and it is
// the only stage with an answer that does not depend on this machine,
// so it is the only one that sets an exit code.
// =====================================================================

enum RailProbe {

    static func run(arguments: [String]) -> Never {
        var seconds: TimeInterval = 20
        // Same finite range check as the other probes: `Double("1e400")` is
        // +infinity, passes `v > 0`, and traps on the way to an Int.
        if let i = arguments.firstIndex(of: "--rail-probe"), i + 1 < arguments.count,
           let v = Double(arguments[i + 1]), v.isFinite, v > 0, v <= 3600 {
            seconds = v
        }

        let model = IslandModel()
        print("=== MacPulse --rail-probe ===")
        print("Starting the real IslandModel and waiting \(Int(seconds)) s for every")
        print("feature source to have published at least once. The tunnel watcher")
        print("deliberately does nothing for its first 12 s, so anything under that")
        print("would be measuring the delay and not the feature.")
        print("")

        model.start()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))

        // EXACTLY what `IslandModel.refreshRouter()` asks, in registration
        // order, which is rail order.
        print("--- hasState, per registered section --------------------------")
        var live: [String] = []
        for section in IslandSectionRegistry.sections {
            let on = section.hasState(model)
            if on { live.append(section.chipTitle) }
            let footer = section.footerSummary(model)
            // Padded by hand: `String(format: "%-10@")` does not honour a
            // field width for %@ on Darwin, it just prints the string.
            print("  " + pad(section.id.rawValue, 10) + pad(on ? "LIVE" : "absent", 9)
                  + (footer.map { "footer: \($0)" } ?? ""))
        }
        print("")
        print("  rail: " + (live.isEmpty ? "(empty — impossible, Память is always live)"
                                         : live.joined(separator: " · ")))
        print("  chips: \(live.count) of \(IslandSectionRegistry.sections.count) registered")
        print("")

        // The rail is a plain HStack with no wrap and no scroll. With one
        // section that could not matter; with seven it can, and a rail
        // that overflows pushes its last chip off the 560 pt plate where
        // nothing can click it. Nobody can see this on a locked screen, so
        // it is arithmetic rather than a look.
        print("--- rail width, WORST CASE (every section live at once) -------")
        let available = IslandMetrics.panelWidth - IslandRouter.gutter * 2
        let count = IslandSectionRegistry.sections.count
        let padding = IslandRail.chipPadding(chips: count)
        print(String(format: "  %.0f chips -> %.0f pt of padding inside each one",
                     Double(count), padding))
        var total: CGFloat = 0
        for (i, section) in IslandSectionRegistry.sections.enumerated() {
            let w = chipWidth(section, padding: padding)
            total += w + (i > 0 ? 4 : 0)     // 4 pt is IslandRail's HStack spacing
            print("  " + pad(section.chipTitle, 12) + String(format: "%6.1f pt", w))
        }
        print(String(format: "  %@%6.1f pt of %.0f available", pad("TOTAL", 12),
                     total, available))
        print(total <= available
              ? String(format: "  fits, with %.1f pt to spare", available - total)
              : String(format: "  *** OVERFLOWS BY %.1f pt — the last chip is off the plate",
                       total - available))
        print("")

        print("--- the collapsed strip ---------------------------------------")
        print("  trailing wing   \(Int(model.trailingWingWidth)) pt"
              + "  (resting \(Int(IslandMetrics.restingWingWidth)),"
              + " ceiling \(Int(IslandMetrics.maxTrailingWingWidth)))")
        print("  slot section    \(model.stripSlotSection)"
              + "   <- the tab a click on the strip would open")
        // No longer drawn in the wing — macOS draws that indicator itself.
        // This is what the panel FOOTER would say.
        print("  privacy footer  \(PrivacyFooter.line(model.privacy) ?? "(quiet)")")
        print("")

        print("--- what each feature actually measured -----------------------")
        print("  printer         \(model.printer.map { $0.stage ?? "active" } ?? "nil (no print)")")
        print("  calendar        \(model.calendar.status)"
              + "  next=\(model.calendar.next == nil ? "none" : "yes")"
              + "  strip=\(model.calendarStrip ?? "nil")")
        print("  sound           "
              + (model.sound.apps.map { "\($0.count) output stream(s)" } ?? "nil (не измерено)"))
        // `deservesStripSlot` is itself an Optional Bool — nil there means
        // "could not measure", which is a third answer and not a false.
        print("  tunnel          "
              + (model.tunnel.map { m in
                     "deservesStripSlot=" + (m.deservesStripSlot.map(String.init) ?? "nil")
                 } ?? "nil (не измерено)"))
        // Also not a section any more: folded into Память, and drawn only
        // while `isQuiet` is false. Same condition that used to gate its
        // chip, so this line still answers the same question.
        print("  pressure fold   "
              + "history=\(model.pressureAlert.history.count) "
              + "muted=\(model.pressureAlert.isMuted) "
              + "onScreen=\(!model.pressureAlert.isQuiet)")
        // NOT a section any more, so it is not in the table above: the
        // clipboard is the shelf along the bottom of the panel. Printed
        // here because "what each feature measured" is still the question,
        // and a shelf with nothing on it is worth seeing.
        print("  clipboard shelf "
              + "entries=\(model.clipboard.entryCount) "
              + "chips=\(model.clipboard.items.count)/\(ClipboardShelfState.slots)"
              + (model.clipboard.isPaused ? " PAUSED" : ""))
        print("")
        print("A quiet machine should show ONE chip. Anything else is either a")
        print("real condition on this machine right now, or a section that broke")
        print("the second rule in IslandSection.swift.")
        print("")

        // -------------------------------------------------------------
        // Does a deliberate click SURVIVE the next refresh?
        //
        // For one build it did not. `refreshRouter()` reset the selection
        // to Память whenever the selected section was not live, and it
        // runs on every refresh of an open panel — so clicking a quiet
        // tab put you there and threw you back about a second later. The
        // user found it before any check here did: "жму другую табу,
        // проходит 1 сек и меня кидает обратно".
        //
        // Nothing above could have caught it. The rail this probe prints
        // was right the whole time; what was wrong was what happened one
        // tick after a click, and no instant assertion can see that. So
        // this waits.
        // -------------------------------------------------------------
        print("--- does a clicked tab survive the next refresh? --------------")
        model.setStatus(.opened)
        // Opening navigates to the strip slot on its own. Let that land
        // before measuring, or the first selection below races it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        var bounced: [String] = []
        for section in IslandSectionRegistry.sections {
            let id = section.id
            let live = section.hasState(model)
            model.select(id)
            guard model.selectedSection == id else {
                bounced.append(section.chipTitle)
                print("  " + pad(id.rawValue, 10) + pad(live ? "live" : "quiet", 7)
                      + "REFUSED — select() would not go there at all")
                continue
            }
            // Longer than the 1 Hz base tick, so at least two real
            // refreshes run underneath the selection.
            RunLoop.current.run(until: Date().addingTimeInterval(2.2))
            let held = model.selectedSection == id
            if !held { bounced.append(section.chipTitle) }
            print("  " + pad(id.rawValue, 10) + pad(live ? "live" : "quiet", 7)
                  + (held ? "holds" : "*** BOUNCED to \(model.selectedSection.rawValue)"))
        }
        model.setStatus(.closed)
        print("")
        print(bounced.isEmpty
              ? "  every tab holds, live or quiet"
              : "  *** the router overrode the user on: "
                + bounced.joined(separator: ", "))

        model.stop()
        print("")
        print("=== done ===")
        // This ONE check has a right answer that does not depend on the
        // machine, so it is the only thing here that sets an exit code.
        // How many chips are live is a reading; a tab that will not hold
        // is a defect.
        exit(bounced.isEmpty ? 0 : 1)
    }

    /// Mirrors `RailChip`'s layout exactly: the padding either side, a 4 pt
    /// gap, the SF Symbol at 9 pt semibold and the title at 10.5 pt.
    /// SEMIBOLD, because that is what the SELECTED chip uses and the
    /// selected chip is the wide one — measuring the regular weight would
    /// under-report the only case that can overflow. The padding comes
    /// from `IslandRail.chipPadding` and is not restated here, so this
    /// cannot drift from what is drawn.
    private static func chipWidth(_ section: IslandSection, padding: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        var width = padding * 2 + (section.chipTitle as NSString)
            .size(withAttributes: [.font: font]).width
        if !section.chipSymbol.isEmpty {
            let image = NSImage(systemSymbolName: section.chipSymbol,
                                accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            // 11 pt if the symbol could not be measured: wider than most
            // 9 pt glyphs, so an unmeasurable symbol errs towards saying
            // the rail is fuller than it is.
            width += 4 + (image?.size.width ?? 11)
        }
        return width
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }
}

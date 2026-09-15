import AppKit
import SwiftUI

// =====================================================================
// «Кадр» — render the SHIPPING island offscreen and count what is in it.
//
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --render-probe [dir]
//
// WHY THIS EXISTS, WHICH IS NOT "because screenshots are inconvenient".
//
// Two of this island's properties are claims about PIXELS, and until now
// the only way to check either was for a human to look at the screen:
//
//   1. THE COLLAPSED STRIP LIGHTS EXACTLY ONE DOT. That is the whole
//      point of removing the privacy rail — macOS already draws a mic
//      indicator a few points away, and two dots saying one thing is
//      worse than one. "Exactly one" is a countable fact and it should be
//      counted, not eyeballed.
//
//   2. NOTHING IN THE PANEL IS CLIPPED. `IslandRouter` frames each
//      section to `bodyHeight` and calls `.clipped()`, which fails
//      SILENTLY: a section whose rows add up to 190 in a 186 pt box loses
//      its last line and looks like a design choice.
//
// A screen capture cannot check either one when the screen is locked,
// asleep, on another Space, or being recorded by a process without the
// TCC grant — and on a locked screen `screencapture` hands back a frame
// of pure black with a zero exit status, which reads exactly like a
// correctly drawn dark island. This probe does not use the screen at all:
// it builds the REAL `IslandView` over the REAL `IslandModel`, rasterises
// it with `cacheDisplay`, writes the PNGs and prints a census of what is
// in them.
//
// WHAT IT IS NOT. It is not a screenshot, and it must never be described
// as one. It proves what the view tree DRAWS. It cannot prove the window
// is on screen, at the right level, over the right part of the menu bar,
// or that the compositor is showing it — those are the controller's and
// the window server's business, and `--wing-probe` covers the geometry
// half of them.
// =====================================================================

enum IslandRenderProbe {

    // MARK: - Colour census
    //
    // "A dot" is not a pixel, so counting coloured pixels answers the
    // wrong question. What is wanted is how many separate COLOURED THINGS
    // are drawn, so coloured pixels are grouped into clusters and the
    // clusters are counted.

    private struct Cluster {
        var minX: Int, maxX: Int, minY: Int, maxY: Int
        var count: Int
        var r: Double, g: Double, b: Double

        var centreX: Double { Double(minX + maxX) / 2 }
        var centreY: Double { Double(minY + maxY) / 2 }
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var hue: String {
            let maxC = max(r, max(g, b))
            if maxC <= 0.001 { return "чёрный" }
            if r > 0.55 && g > 0.35 && b < 0.35 { return "AMBER/ORANGE" }
            if g > 0.55 && r < 0.55 && b < 0.55 { return "GREEN" }
            if r > 0.6 && g < 0.5 && b < 0.5 { return "RED" }
            if b > 0.55 && r < 0.55 { return "BLUE" }
            return String(format: "rgb(%.2f %.2f %.2f)", r, g, b)
        }
    }

    /// Pixels that are genuinely COLOURED — not the black plate, not the
    /// greys every label on this island is drawn in. A dot is a saturated
    /// fill; text is not.
    private static func isColoured(_ c: NSColor) -> Bool {
        let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
        guard Double(c.alphaComponent) > 0.5 else { return false }
        let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
        guard maxC > 0.35 else { return false }             // not a dark plate
        return (maxC - minC) / maxC > 0.45                  // saturated
    }

    /// Group coloured pixels into things. `gap` is how far apart two
    /// coloured pixels may be and still count as one thing — 4 px at 2x,
    /// i.e. 2 pt, which joins a dot to its own halo and keeps two dots
    /// 4 pt apart separate.
    private static func clusters(in rep: NSBitmapImageRep,
                                 region: CGRect,
                                 gap: Int = 4) -> [Cluster] {
        var found: [Cluster] = []
        let x0 = Int(region.minX), x1 = min(Int(region.maxX), rep.pixelsWide)
        let y0 = Int(region.minY), y1 = min(Int(region.maxY), rep.pixelsHigh)
        guard x0 < x1, y0 < y1 else { return [] }

        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let c = rep.colorAt(x: x, y: y), isColoured(c) else { continue }
                let r = Double(c.redComponent), g = Double(c.greenComponent)
                let b = Double(c.blueComponent)
                var merged = false
                for i in found.indices {
                    if x >= found[i].minX - gap, x <= found[i].maxX + gap,
                       y >= found[i].minY - gap, y <= found[i].maxY + gap {
                        found[i].minX = min(found[i].minX, x); found[i].maxX = max(found[i].maxX, x)
                        found[i].minY = min(found[i].minY, y); found[i].maxY = max(found[i].maxY, y)
                        found[i].count += 1
                        // Running mean, so the reported colour is the
                        // thing's colour and not its last pixel's.
                        let n = Double(found[i].count)
                        found[i].r += (r - found[i].r) / n
                        found[i].g += (g - found[i].g) / n
                        found[i].b += (b - found[i].b) / n
                        merged = true
                        break
                    }
                }
                if !merged {
                    found.append(Cluster(minX: x, maxX: x, minY: y, maxY: y,
                                         count: 1, r: r, g: g, b: b))
                }
            }
        }
        // Two clusters can both be grown into contact after the fact.
        var settled = false
        while !settled {
            settled = true
            outer: for i in found.indices {
                for j in found.indices where j > i {
                    if found[i].minX - gap <= found[j].maxX, found[j].minX - gap <= found[i].maxX,
                       found[i].minY - gap <= found[j].maxY, found[j].minY - gap <= found[i].maxY {
                        found[i].minX = min(found[i].minX, found[j].minX)
                        found[i].maxX = max(found[i].maxX, found[j].maxX)
                        found[i].minY = min(found[i].minY, found[j].minY)
                        found[i].maxY = max(found[i].maxY, found[j].maxY)
                        found[i].count += found[j].count
                        found.remove(at: j)
                        settled = false
                        break outer
                    }
                }
            }
        }
        // Single stray pixels are antialiasing, not things.
        return found.filter { $0.count >= 8 }
    }

    // MARK: - Rendering

    /// Rasterise a SwiftUI view at 2x, the way the built-in display draws
    /// it. `cacheDisplay` and not a screen capture: nothing here depends
    /// on the window server, on a Space, or on the screen being awake.
    private static func render<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        // SwiftUI builds its tree on the main run loop, so it has to be
        // given one before anything can be drawn.
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to path: String) {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("    could not encode \(path)")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("    wrote \(path)  (\(rep.pixelsWide) x \(rep.pixelsHigh) px)")
    }

    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) {
        print("    \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    // MARK: - Run

    static func run(arguments: [String]) -> Never {
        var dir = FileManager.default.temporaryDirectory.path
        if let i = arguments.firstIndex(of: "--render-probe"), i + 1 < arguments.count,
           !arguments[i + 1].hasPrefix("--") {
            dir = arguments[i + 1]
        }
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)

        print("=== MacPulse --render-probe ===")
        print("")
        print("Rasterises the REAL IslandView offscreen. This is NOT a screenshot:")
        print("it proves what the view tree draws, not that a window is on screen.")
        print("")

        let model = IslandModel()
        model.start()
        // Long enough for the first metrics tick, so the pressure dot has a
        // real level rather than the grey "could not measure".
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        model.setGeometry(notchSize: CGSize(width: 183, height: 32), hasPhysicalNotch: true)

        // THE WORST CASE FOR THE ONE-DOT CLAIM: both sensors in use. If the
        // privacy rail were still in the wing this is the state that would
        // light it, so it is the state the count is taken in.
        model.setPrivacy(PrivacyState(micActive: true, micApps: ["zen", "Telegram"],
                                      cameraActive: true,
                                      cameraDevices: ["HD-камера FaceTime"]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // ---- the collapsed island -------------------------------------
        print("--- collapsed island, mic AND camera in use -------------------")
        let plate = IslandMetrics.collapsedPlate(notch: model.notchSize,
                                                 leading: model.leadingWingWidth,
                                                 trailing: model.trailingWingWidth)
        // The view lays out full-screen-width and centres the plate, the
        // same as in the app.
        let stripSize = CGSize(width: 1470, height: 60)
        guard let strip = render(IslandView(model: model), size: stripSize) else {
            print("could not render the collapsed island"); exit(1)
        }
        write(strip, to: dir + "/collapsed.png")

        let scale = Double(strip.pixelsWide) / stripSize.width
        let plateMinX = (stripSize.width - plate.size.width) / 2 + plate.centerOffsetX
        let notchMinX = plateMinX + plate.fillet + model.leadingWingWidth
        let notchMaxX = notchMinX + model.notchSize.width
        print(String(format: "    plate %.1f ... %.1f pt, camera housing %.1f ... %.1f pt",
                     plateMinX, plateMinX + plate.size.width, notchMinX, notchMaxX))

        let stripDots = clusters(in: strip,
                                 region: CGRect(x: 0, y: 0,
                                                width: Double(strip.pixelsWide),
                                                height: Double(strip.pixelsHigh)))
        for d in stripDots {
            let side = Double(d.centreX) / scale < notchMinX ? "LEADING wing"
                     : (Double(d.centreX) / scale > notchMaxX ? "TRAILING wing" : "over the housing")
            print(String(format: "    dot: %@  %d x %d px at x %.1f pt  (%@)",
                         d.hue, d.width, d.height, Double(d.centreX) / scale, side))
        }
        check(stripDots.count == 1,
              ">>> EXACTLY ONE coloured thing on the collapsed island "
              + "(counted \(stripDots.count))")
        if let only = stripDots.first {
            check(Double(only.centreX) / scale < notchMinX,
                  ">>> and it is in the LEADING wing — the memory-pressure dot")
        }
        let trailing = stripDots.filter { Double($0.centreX) / scale > notchMaxX }
        check(trailing.isEmpty,
              ">>> NOTHING in the trailing wing, with both sensors in use: "
              + "the privacy rail is gone, not merely hidden")
        print("")

        // ---- the expanded panel, with a shelf that has things on it ----
        print("--- expanded panel --------------------------------------------")
        // Real entries from a real engine, on a PRIVATE pasteboard. The
        // user's own clipboard is never touched — same rule as
        // --clipboard-probe, and for the same reason.
        let board = NSPasteboard(name: NSPasteboard.Name("com.local.macpulse.render-probe"))
        board.clearContents()
        let engine = ClipboardEngine(pasteboard: board)
        let queue = DispatchQueue(label: "com.local.macpulse.render-probe", qos: .utility)
        engine.start()
        func copy(_ write: () -> Void) {
            board.clearContents()
            write()
            let done = DispatchSemaphore(value: 0)
            queue.async { engine.poll(); done.signal() }
            done.wait()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        }
        copy { _ = board.setString("SELECT * FROM orders WHERE status = 'paid' LIMIT 50;",
                                   forType: .string) }
        copy { _ = board.writeObjects([URL(fileURLWithPath: "/etc/hosts") as NSURL]) }
        copy { _ = board.setString("https://github.com/anthropics/claude-code/releases",
                                   forType: .string) }
        // A REAL image, drawn rather than an empty NSImage: an empty one
        // has no TIFF representation, the copy never lands, and the shelf
        // quietly shows four chips instead of the five this is meant to
        // demonstrate — including the INERT one, which is the case worth
        // seeing.
        let shot = NSImage(size: NSSize(width: 64, height: 48))
        shot.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 48).fill()
        shot.unlockFocus()
        if let tiff = shot.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            copy {
                let item = NSPasteboardItem()
                item.setData(png, forType: NSPasteboard.PasteboardType(ClipboardTypes.png))
                _ = board.writeObjects([item])
            }
        }
        copy { _ = board.setString("Спасибо, до встречи в четверг!", forType: .string) }
        model.setClipboard(ClipboardFeature.state(engine.entries, engine.stats, paused: false))

        model.setStatus(.opened)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))

        let panelSize = CGSize(width: 1470, height: IslandMetrics.panelHeight + 20)
        guard let panel = render(IslandView(model: model), size: panelSize) else {
            print("could not render the panel"); exit(1)
        }
        write(panel, to: dir + "/expanded.png")
        print("    sections in the rail: "
              + model.visibleSections.map(\.rawValue).joined(separator: ", "))
        print("    selected: \(model.selectedSection)")
        print("    shelf: \(model.clipboard.items.count) chips of "
              + "\(ClipboardShelfState.slots) — "
              + model.clipboard.items.map { "\($0.preview)\($0.isLive ? "" : " (inert)")" }
                    .joined(separator: " | "))
        print("    footer: " + (model.footerLine.isEmpty ? "(empty)" : model.footerLine))
        check(model.clipboard.items.count <= ClipboardShelfState.slots,
              "the shelf never draws more chips than it has slots")
        check(!IslandSectionRegistry.sections.contains { $0.id.rawValue == "clipboard" },
              "«Буфер» is not in the registry")
        check(!IslandSectionRegistry.sections.contains { $0.id.rawValue == "pressure" },
              "«Давление» is not in the registry")
        print("")

        // ---- is anything CLIPPED? -------------------------------------
        //
        // `IslandRouter` frames each section to `bodyHeight` and clips it,
        // which fails silently. A section that overflows leaves ink hard
        // against the very last row of its box; a section that fits leaves
        // that row empty. Not a proof — a row of text can legitimately end
        // there — but it is the only automatic signal there is, and it
        // costs nothing.
        print("--- the bottom edge of each row -------------------------------")
        let panelScale = Double(panel.pixelsWide) / panelSize.width
        func inkFraction(yPoints: Double, height: Double = 2) -> Double {
            let y0 = Int(yPoints * panelScale), y1 = Int((yPoints + height) * panelScale)
            var lit = 0, total = 0
            let x0 = Int(((panelSize.width - IslandMetrics.panelWidth) / 2) * panelScale)
            let x1 = x0 + Int(IslandMetrics.panelWidth * panelScale)
            for y in max(0, y0)..<min(y1, panel.pixelsHigh) {
                for x in max(0, x0)..<min(x1, panel.pixelsWide) {
                    total += 1
                    guard let c = panel.colorAt(x: x, y: y) else { continue }
                    let l = 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent)
                          + 0.0722 * Double(c.blueComponent)
                    if l > 0.22 { lit += 1 }
                }
            }
            return total == 0 ? 0 : Double(lit) / Double(total)
        }
        var y = model.notchSize.height + IslandMetrics.railGap
        let rows: [(String, CGFloat)] = [
            ("rail", IslandMetrics.railHeight),
            ("body", IslandMetrics.bodyHeight),
            ("shelf", IslandMetrics.shelfHeight),
            ("footer", IslandMetrics.footerHeight),
        ]
        let gaps: [CGFloat] = [IslandMetrics.bodyGap, IslandMetrics.shelfGap,
                               IslandMetrics.footerGap, 0]
        for (i, row) in rows.enumerated() {
            let bottom = y + row.1
            print(String(format: "    %-7@ %6.1f ... %6.1f pt   ink in its last 2 pt: %.1f%%",
                         row.0 as NSString, y, bottom, inkFraction(yPoints: bottom - 2) * 100))
            y = bottom + gaps[i]
        }
        check(abs(y - IslandMetrics.panelHeight) < 0.01,
              "the rows end exactly at the bottom of the \(Int(IslandMetrics.panelHeight)) pt panel "
              + "(ended at \(y))")

        engine.remove(engine.observe { _, _ in })
        board.clearContents()
        model.stop()

        print("")
        if failures == 0 {
            print("=== все проверки пройдены ===")
            exit(0)
        }
        print("=== \(failures) проверок провалено ===")
        exit(1)
    }
}

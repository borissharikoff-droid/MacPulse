import AppKit
import SwiftUI

// =====================================================================
// «Плёнка» — the frames the README's animations are made of.
//
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --film-probe DIR
//
// WHY THIS EXISTS AND NOT A SCREEN RECORDING. The first attempt at these
// animations was `screencapture -v` over the notch, driven by a program
// that moved the pointer. It was abandoned on the first frame: the
// capture contained a video call, with other people's faces in it. A
// recording of somebody's screen carries whatever is on that screen, and
// no amount of cropping makes that a safe thing to do on a machine
// somebody is using.
//
// This draws the REAL `IslandView` over the REAL `IslandModel` offscreen,
// exactly as `--render-probe` does, and emits one PNG per state. Nothing
// is composited afterwards except a backdrop and the cross-fades between
// states — both cosmetic, neither inventing a state the app cannot be in.
//
// Which also means the honest caption for these animations is "renders of
// the shipping view tree", not "screen recordings". They show what the
// app draws. They cannot show that a window is on screen.
// =====================================================================

enum IslandFilmProbe {

    static func run(arguments: [String]) -> Never {
        var dir = FileManager.default.temporaryDirectory.path + "/macpulse-film"
        if let i = arguments.firstIndex(of: "--film-probe"), i + 1 < arguments.count,
           !arguments[i + 1].hasPrefix("--") {
            dir = arguments[i + 1]
        }
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)

        print("=== MacPulse --film-probe ===")
        print("Offscreen renders of the shipping view tree. No screen capture.")
        print("out: \(dir)")
        print("")

        let model = IslandModel()
        model.start()
        model.setGeometry(notchSize: CGSize(width: 183, height: 32), hasPhysicalNotch: true)
        // SIXTEEN SECONDS, and the number is not padding. The tunnel
        // watcher deliberately does nothing for its first 12 s, so a
        // shorter settle films a machine where the tunnel has simply not
        // been measured yet and calls it "quiet" — which is a different
        // statement, and a false one. Measured at 4 s: four of six
        // sections came out empty.
        RunLoop.main.run(until: Date().addingTimeInterval(16))

        let panelSize = CGSize(width: 1470, height: IslandMetrics.panelHeight + 20)

        // ---- the shelf, on a PRIVATE pasteboard -----------------------
        // Same rule as --render-probe and --clipboard-probe: the user's own
        // clipboard is never read and never appears in a published image.
        let board = NSPasteboard(name: NSPasteboard.Name("com.local.macpulse.film-probe"))
        board.clearContents()
        let engine = ClipboardEngine(pasteboard: board)
        let queue = DispatchQueue(label: "com.local.macpulse.film-probe", qos: .utility)
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
        copy { _ = board.setString("https://github.com/borissharikoff-droid/MacPulse",
                                   forType: .string) }
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

        // ---- film 1: shut, then open ---------------------------------
        print("--- open ------------------------------------------------------")
        shoot(model, size: panelSize, to: dir + "/open-0.png")
        model.setStatus(.opened)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        shoot(model, size: panelSize, to: dir + "/open-1.png")
        print("    2 frames")

        // ---- film 2: every tab ---------------------------------------
        print("--- tabs ------------------------------------------------------")
        // ONLY THE LIVE ONES, which is the product's own rule rather than
        // a flattering edit: a section exists in the rail always, but it
        // has something to say only sometimes. A film of empty states
        // would show the app having nothing to report and read as the app
        // being empty.
        let live = Set(model.visibleSections)
        let filmed = IslandSectionRegistry.sections.filter { live.contains($0.id) }
        print("    live: " + filmed.map { $0.id.rawValue }.joined(separator: ", "))
        print("    quiet, not filmed: "
              + IslandSectionRegistry.sections.filter { !live.contains($0.id) }
                    .map { $0.id.rawValue }.joined(separator: ", "))
        for (i, section) in filmed.enumerated() {
            model.select(section.id)
            // A real tick under each one — which is also what proved the
            // selection sticks, see RailProbe.
            RunLoop.main.run(until: Date().addingTimeInterval(1.1))
            let held = model.selectedSection == section.id
            shoot(model, size: panelSize,
                  to: String(format: "%@/tab-%02d-%@.png", dir, i, section.id.rawValue))
            print("    \(section.id.rawValue)" + (held ? "" : "  *** ОТСКОЧИЛА"))
        }

        // ---- film 3: the two-step «Закрыть остальные» ----------------
        //
        // SYNTHETIC ROWS, AND SAID SO — the same fixture --render-probe
        // uses, for the same reason: no real machine here has an app with
        // ten windows on demand. The VIEW is the shipping one, and the
        // thing being shown is real: the bulk action arms first and acts
        // only on a second click.
        print("--- windows ---------------------------------------------------")
        var rows: [AppWindowRow] = []
        for i in 0..<10 {
            let title: String = i == 0
                ? "Входящие — почта"
                : "Вкладка \(i) — очень длинный заголовок окна, который придётся обрезать"
            rows.append(AppWindowRow(id: i, title: title, isMain: i == 0,
                                     isMinimized: i == 7, isFullScreen: i == 8,
                                     canClose: true))
        }
        var procs: [MemberProcessRow] = []
        for i in 0..<12 {
            procs.append(MemberProcessRow(pid: pid_t(1000 + i),
                                          name: i == 0 ? "Браузер" : "Браузер Helper (Renderer)",
                                          footprintBytes: UInt64(900 - i * 60) * 1_048_576))
        }
        let scan = AppWindowScan(windows: rows, failure: nil)
        let popWidth = IslandMetrics.panelWidth - IslandRouter.gutter * 2
        let popSize = CGSize(width: popWidth, height: IslandMetrics.bodyHeight)
        let states: [(String, Int?)] = [("0", nil), ("1", scan.closableOthers.count)]
        for (label, armed) in states {
            let state = WindowPopoverState(pid: 1, appName: "Браузер", icon: nil,
                                           processes: procs, scan: scan,
                                           prompted: true, armedOthers: armed)
            guard let img = IslandRenderProbe.render(WindowPopover(state: state, model: model),
                                                     size: popSize) else {
                print("could not render the popover"); exit(1)
            }
            IslandRenderProbe.write(img, to: dir + "/win-\(label).png")
        }
        print("    2 frames, «Закрыть остальные (\(scan.closableOthers.count))» armed in the second")

        model.stop()
        print("")
        print("=== done ===")
        exit(0)
    }

    private static func shoot(_ model: IslandModel, size: CGSize, to path: String) {
        guard let img = IslandRenderProbe.render(IslandView(model: model), size: size) else {
            print("could not render \(path)"); exit(1)
        }
        IslandRenderProbe.write(img, to: path)
    }
}

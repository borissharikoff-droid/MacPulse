import AppKit
import SwiftUI

// =====================================================================
// THE CLIPBOARD SHELF — 28 pt along the bottom of the panel, five chips,
// and every one of them is something you can DRAG OUT.
//
// IT WAS A TAB. The user said what he wanted plainly: hover the island and
// see the last several things he copied, along the bottom, as things he
// can drag into whatever app he needs. A tab cannot be that. A tab is a
// place you navigate TO — open the panel, find the chip, click it, and by
// then the gesture is over. So «Буфер» is no longer a destination:
// `IslandSectionRegistry` has never heard of it, and the shelf is on
// screen whichever section is selected.
//
// WHAT THE SHELF IS NOT. It is not the old 560 x 186 list with a row per
// entry, counters, a security note and two buttons. All of that was words
// on a panel the user has twice said has too many. What survives is what
// you can act on: a glyph, a preview, and a drag. The counters, the pause
// switch and the clear button moved to a right-click on the shelf itself —
// zero pixels until you ask for them, and next to the thing they control.
//
// FIVE CHIPS, AND WHY FIVE: the arithmetic is in `IslandMetrics`, beside
// `shelfSlots`, because it is a width answer. Short version: a chip spends
// 28 pt on chrome before a single character, and at six chips the preview
// falls to ~10 characters, at which point two screenshots from consecutive
// days are the same chip. On a shelf you DRAG from, picking the wrong chip
// means dropping the wrong file into somebody's chat.
//
// ---------------------------------------------------------------------
// THE SECRET FILTER IS STILL THE REASON THIS FEATURE IS ALLOWED TO EXIST.
//
// `ClipboardEngine` refuses any item carrying `org.nspasteboard.ConcealedType`
// (and the other password-manager markers) WITHOUT EVER REQUESTING ITS
// BYTES — proved, not asserted, by `--clipboard-probe` step 2, with a data
// provider that records every request and never fires.
//
// A SHELF CHIP CANNOT LEAK WHAT THE HISTORY REFUSED TO STORE, and that is
// structural rather than a second check bolted on here: a refused item
// never becomes an entry, so it has no id, so there is no chip, so there
// is nothing for `draggingWriters` to be asked about. The probe checks
// that too. There is deliberately no "show it anyway" affordance of any
// kind.
//
// ---------------------------------------------------------------------
// WHAT A CHIP OFFERS A DROP. Built by `ClipboardEngine.draggingWriters`,
// which is where the per-kind table lives, because the payload is
// `fileprivate` to that file and must stay there. The shelf never sees a
// byte; it asks for a writer and hands it to AppKit.
//
//   text / rich text   `.string` (+ `.rtf` where there is formatting)
//   a link             `public.url` + `.string`
//   FILES              one `public.file-url` per file — a real file
//                      reference, so Finder copies it, Telegram attaches
//                      it and Figma imports it, instead of pasting a path
//   an image           NOTHING, and the chip is inert.
//
// THE IMAGE CASE IS AN HONEST REFUSAL, NOT AN OVERSIGHT. The engine never
// retains image bytes — a copied screenshot is measured inside an
// autoreleasepool and dropped, which is what keeps this whole feature's
// history under 2 MiB on an 8 GB machine. So there is no image data to
// offer. The chip shows the photo glyph and the pixel size that WAS
// measured, and it neither drags nor clicks, exactly as `canRecopy == false`
// rows already behaved. Inventing a thumbnail would mean retaining the
// bytes, which is a budget change and not a UI one.
//
// ---------------------------------------------------------------------
// DRAGGING OUT OF THIS PANEL WORKS, AND IT WAS SPIKED BEFORE IT WAS BUILT.
//
// The island lives in a borderless `.nonactivatingPanel` that has had
// `ignoresMouseEvents` ASSIGNED, sits at `.statusBar + 8`, and never
// becomes key. That is an unusual window to start a system drag from, so
// it was tested rather than assumed: the scratchpad probes
// (`p4_drag.swift`, `p5_draglive.swift`) put a source view in exactly that
// window configuration, drove a real `beginDraggingSession` with synthetic
// HID events, and logged the session beginning and ending. Two facts from
// those runs shape the code below:
//
//   * a drag session started from such a panel RUNS, and it survives the
//     controller flipping `ignoresMouseEvents` back to true when the
//     pointer leaves the island's hit rect mid-drag. That flag is input
//     hit-testing; it does not own a session already in flight.
//
//   * the panel must not sit at `.screenSaver` level, where system drag
//     sessions are silently undeliverable. It sits at `.statusBar + 8`,
//     and IslandPanel.swift already says why.
//
// One more thing makes this safe in practice: the first mouse-DOWN on the
// shelf reaches `IslandController.handleClick`, which PINS the panel. So
// by the time the drag threshold is crossed the panel is pinned and cannot
// fold away under the user's own gesture.
// =====================================================================

// MARK: - Published state
//
// Formatted the way `MemorySectionState` is formatted: as the STRINGS the
// view puts on screen, so two updates that would draw identical pixels
// compare equal and publish nothing. See the publishing rule at the top of
// IslandModel.swift.

/// One chip of the shelf, already formatted.
struct ClipboardShelfItem: Equatable, Identifiable {
    let id: UInt64
    /// SF Symbol for the kind.
    let symbol: String
    /// One short Russian word for the kind. NOT drawn on the chip — a chip
    /// has room for a glyph and a preview and nothing else — but it is in
    /// the tooltip, which is where detail belongs.
    let kind: String
    /// Already collapsed to one line and capped at 120 characters by
    /// `ClipboardFmt.oneLine` — see ClipboardEngine.swift, where that cap
    /// is part of the memory budget rather than of the presentation.
    let preview: String
    /// Size of what was copied. "—" when the engine could not measure it,
    /// never a fabricated 0.
    let size: String
    /// Wall clock, "14:32". ABSOLUTE rather than relative ("3 мин назад")
    /// on purpose: this state is republished only when the clipboard
    /// actually moves, so a relative age would sit on screen going stale.
    let time: String
    /// False for an image or an over-budget copy: the payload was never
    /// retained, so there is nothing to drag and nothing to put back.
    ///
    /// ONE BIT FOR BOTH AFFORDANCES, because `ClipboardEngine.recopy` and
    /// `ClipboardEngine.draggingWriters` refuse on exactly the same
    /// condition. A chip that cannot be dragged must not offer a click
    /// that silently does nothing either.
    let isLive: Bool
}

/// Everything the shelf draws, as drawn.
struct ClipboardShelfState: Equatable {

    /// How many chips fit. ONE number, in IslandMetrics, where the width
    /// arithmetic that produced it also lives.
    static var slots: Int { IslandMetrics.shelfSlots }

    /// How many entries the history holds. The shelf shows `slots` of
    /// them; the rest are still there, and the context menu says how many.
    var entryCount = 0
    /// Items refused because a secret marker was present. The only
    /// evidence the user has that the filter is real. It is in the context
    /// menu rather than on the panel: it is good news, and good news does
    /// not need a permanent badge.
    var skippedSecrets = 0
    var isPaused = false
    /// Newest first, at most `slots`.
    var items: [ClipboardShelfItem] = []
}

// MARK: - The bridge to the island

/// Main-thread glue between `ClipboardEngine` and `IslandModel`.
///
/// Mirrors `PrinterPoller`/`PrivacyWatcher`: the engine samples on
/// MetricsEngine's queue, this object formats on main and hands the model
/// ONE Equatable struct. It is a singleton rather than a model-owned
/// object only so that the shelf's chips and menu items can reach it
/// without widening `IslandModel`'s surface — re-copy, clear and pause are
/// one-shot actions on the engine, not model state.
///
/// EVENT-DRIVEN, NOT TICK-DRIVEN. The engine publishes only when
/// `changeCount` actually moves, which is a user copying something. On an
/// idle machine this object is never called at all, so the @Published
/// write it causes is not part of the idle cost — see the measurements at
/// the top of IslandModel.swift for why that distinction is the whole
/// ballgame.
///
/// THE TEN-MINUTE EXPIRY TIMER IS GONE, and so is `isLive` on the state.
/// Both existed for one reason: to retire the «Буфер» CHIP from the rail
/// ten minutes after the last copy, so a machine nobody was typing at had
/// a one-chip rail. There is no chip any more — the shelf is a fixed band
/// that is simply empty until something is copied — so there is nothing to
/// retire. That is one fewer main-queue work item armed on this machine at
/// any moment, and one fewer republish per copy.
final class ClipboardFeature {

    static let shared = ClipboardFeature()
    private init() {}

    private weak var model: IslandModel?
    private var token: ClipboardObserverToken?

    /// 24-hour, locale-independent: a chip whose tooltip says "14:32" must
    /// mean the same thing whatever the user's clock format is.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: Lifecycle

    /// Called once from `IslandModel.start()`, on the main thread.
    /// `ClipboardEngine.start()` only takes the `changeCount` baseline, so
    /// whatever is already on the clipboard at launch is NOT back-filled
    /// into history.
    func start(model: IslandModel) {
        precondition(Thread.isMainThread)
        guard token == nil else { return }
        self.model = model
        ClipboardEngine.shared.start()
        token = ClipboardEngine.shared.observe { [weak self] entries, stats in
            self?.push(entries, stats)
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        if let token { ClipboardEngine.shared.remove(token) }
        token = nil
        model = nil
    }

    // MARK: Actions the shelf calls

    /// A CLICK on a chip. The engine promotes the entry and publishes;
    /// nothing to do here on either outcome. A false return means the
    /// payload was never retained, and such chips are drawn inert in the
    /// first place.
    func recopy(_ id: UInt64) {
        precondition(Thread.isMainThread)
        ClipboardEngine.shared.recopy(id: id)
    }

    func clearHistory() {
        precondition(Thread.isMainThread)
        ClipboardEngine.shared.clearHistory()
    }

    func setPaused(_ paused: Bool) {
        precondition(Thread.isMainThread)
        ClipboardEngine.shared.isPaused = paused
        // `isPaused` is configuration, not history, so the engine does not
        // publish for it. Re-push from the engine's own main-thread copies
        // so the shelf follows the click instead of the next copy.
        push(ClipboardEngine.shared.entries, ClipboardEngine.shared.stats)
    }

    // MARK: Formatting

    private func push(_ entries: [ClipboardEntry], _ stats: ClipboardStats) {
        precondition(Thread.isMainThread)
        model?.setClipboard(Self.state(entries, stats,
                                       paused: ClipboardEngine.shared.isPaused))
    }

    /// Pure, so it can be exercised without an island.
    static func state(_ entries: [ClipboardEntry],
                      _ stats: ClipboardStats,
                      paused: Bool) -> ClipboardShelfState {
        var s = ClipboardShelfState()
        s.entryCount = stats.entryCount
        s.skippedSecrets = stats.skippedSecrets
        s.isPaused = paused
        s.items = entries.prefix(ClipboardShelfState.slots).map(item(for:))
        return s
    }

    private static func item(for e: ClipboardEntry) -> ClipboardShelfItem {
        let kind: String
        let symbol: String
        switch e.kind {
        case .text:     kind = "текст";    symbol = "textformat"
        case .richText: kind = "RTF";      symbol = "doc.richtext"
        case .url:      kind = "ссылка";   symbol = "link"
        case .fileURLs: kind = e.fileCount.map { "файлы · \($0)" } ?? "файлы"
                        symbol = "doc.on.doc"
        case .image:    kind = "картинка"; symbol = "photo"
        }

        // An image's preview IS its pixel size (the engine never retains
        // image bytes, so there is nothing else to show). When the header
        // could not be parsed the engine hands back an empty string — that
        // is "could not measure", and it renders as the dash, not as a
        // made-up dimension.
        let preview = e.preview.isEmpty ? "—" : e.preview

        return ClipboardShelfItem(id: e.id,
                                  symbol: symbol,
                                  kind: kind,
                                  preview: preview,
                                  size: UIFmt.bytes(e.byteCount.map(Double.init)),
                                  time: clock.string(from: e.capturedAt),
                                  isLive: e.canRecopy)
    }
}

/// Russian counting for "запись". Three forms, and getting it wrong is the
/// kind of thing that makes an interface look machine-translated.
enum ClipboardRu {
    static func entries(_ n: Int) -> String {
        let hundreds = n % 100
        if hundreds >= 11 && hundreds <= 14 { return "записей" }
        switch n % 10 {
        case 1:       return "запись"
        case 2, 3, 4: return "записи"
        default:      return "записей"
        }
    }
}

// MARK: - Chip geometry

/// What a chip spends before a single character of preview can appear.
///
/// Here rather than inline in the view because `--wing-probe` checks the
/// preview budget against it, and a chip whose padding had drifted from
/// the number the probe reasons about would be passing a check about a
/// layout that no longer exists.
enum ShelfChipMetrics {
    static let horizontalPadding: CGFloat = 5
    static let glyphWidth: CGFloat = 13
    static let glyphTextGap: CGFloat = 5
    /// 5 + 13 + 5 + 5 = 28.
    static let chrome: CGFloat =
        horizontalPadding + glyphWidth + glyphTextGap + horizontalPadding
    /// Rough advance of SF at 10.5 pt, for turning points of preview into
    /// "about this many characters". Used only to REPORT the budget in the
    /// probes; nothing lays out to it.
    static let approximateCharacterWidth: CGFloat = 5.5
}

// MARK: - The drag source
//
// AN NSView, NOT SwiftUI's `.onDrag`. Three reasons, in order of what they
// cost:
//
//   1. `.onDrag` hands AppKit an `NSItemProvider` and gives up control of
//      the session. This shelf has to decide PER CHIP whether a drag is
//      offered at all (an image has no retained bytes) and has to write
//      several `public.file-url` items for a multi-file copy. A provider
//      closure that returns an empty provider still starts a session,
//      which drops nothing and looks broken.
//   2. A click and a drag share one mouse-down here — click re-copies,
//      drag exports — and that threshold is ours to draw.
//   3. The scratchpad spike that proved dragging works out of this exact
//      panel drove `beginDraggingSession(with:event:source:)` on a plain
//      NSView. Reusing what was proved beats hoping a different API
//      behaves the same in a non-activating, never-key,
//      `ignoresMouseEvents`-assigned window.

private final class ShelfChipDragView: NSView, NSDraggingSource {

    var entryID: UInt64 = 0
    /// False for a chip with no retained payload. Such a chip neither
    /// drags nor clicks.
    var isLive = false
    var dragImage: NSImage?
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    /// How far the pointer must travel before a click becomes a drag.
    /// Below this a slightly shaky click would start exporting.
    private static let dragThreshold: CGFloat = 4

    private var mouseDownAt: NSPoint?
    private var didBeginDrag = false
    private var tracking: NSTrackingArea?

    // The panel never becomes key and never activates the app, so the
    // FIRST click has to work. Without this AppKit would treat it as an
    // activating click and the user would have to press twice.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // `.activeAlways`, not `.activeInKeyWindow`: this window is never
        // key and the app is never active — see IslandPanel.swift — so any
        // other option would mean a chip that never highlights.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        didBeginDrag = false
        // Deliberately NOT acted on yet: which gesture this is is not
        // knowable until the pointer either moves or comes back up.
    }

    override func mouseDragged(with event: NSEvent) {
        guard isLive, !didBeginDrag, let start = mouseDownAt else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        guard dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold else { return }
        didBeginDrag = true

        // ASK THE ENGINE AT DRAG TIME, not at build time: the entry can
        // have been evicted by the budget between the frame that drew the
        // chip and the gesture that drags it, and starting a session that
        // carries nothing is worse than not starting one.
        guard let writers = ClipboardEngine.shared.draggingWriters(id: entryID),
              !writers.isEmpty else { return }

        let items = writers.enumerated().map { index, writer -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: writer)
            // Fanned by 4 pt so a multi-file drag looks like several
            // things rather than one.
            let offset = CGFloat(index) * 4
            item.setDraggingFrame(bounds.offsetBy(dx: offset, dy: -offset),
                                  contents: dragImage)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDown = mouseDownAt != nil
        mouseDownAt = nil
        // A drag already happened: the gesture was an export, not a click,
        // and re-copying on top of it would also change the clipboard the
        // user just dragged out of.
        guard wasDown, !didBeginDrag, isLive else { return }
        onClick()
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // COPY, NEVER MOVE, in both contexts. `.move` invites the receiver
        // to tell us to delete the original, and the original here is the
        // user's own file on their own disk. MacPulse deletes nothing
        // outside ~/Library/Caches and ~/Library/Logs; offering an
        // operation whose contract is "and then remove it" would be the
        // first crack in that.
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        didBeginDrag = false
        mouseDownAt = nil
    }
}

private struct ShelfChipDragSurface: NSViewRepresentable {
    let item: ClipboardShelfItem
    let dragImage: NSImage?
    let onClick: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ShelfChipDragView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ShelfChipDragView else { return }
        apply(to: view)
    }

    private func apply(to view: ShelfChipDragView) {
        view.entryID = item.id
        view.isLive = item.isLive
        view.dragImage = dragImage
        view.onClick = onClick
        view.onHover = onHover
    }
}

// MARK: - One chip

private struct ShelfChip: View {
    let item: ClipboardShelfItem
    let width: CGFloat

    @State private var hovering = false

    /// The detail that does not fit on a 101 pt chip. A tooltip is not
    /// words on the panel: it costs nothing until the pointer stops.
    private var help: String {
        let head = "\(item.kind) · \(item.size) · \(item.time)\n\(item.preview)"
        return item.isLive
            ? head + "\n\nПеретащите в другое приложение. Нажмите — вернётся в буфер."
            : head + "\n\nСодержимое не сохранялось: картинки и копии больше 128 КБ "
                   + "остаются только описанием."
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(item.isLive ? (hovering ? 0.14 : 0.07) : 0.035))

            HStack(spacing: ShelfChipMetrics.glyphTextGap) {
                Image(systemName: item.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: item.isLive ? 0.62 : 0.32))
                    .frame(width: ShelfChipMetrics.glyphWidth)

                Text(item.preview)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(white: item.isLive ? 0.88 : 0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, ShelfChipMetrics.horizontalPadding)

            // ON TOP, and it is the only thing in here that takes the
            // mouse: mouse-down, the click/drag threshold and the hover
            // all live in one AppKit view, so they cannot disagree about
            // which gesture is in progress.
            ShelfChipDragSurface(item: item,
                                 dragImage: Self.dragImage(item, width: width),
                                 onClick: { ClipboardFeature.shared.recopy(item.id) },
                                 onHover: { hovering = $0 })
        }
        .frame(width: width, height: IslandMetrics.shelfChipHeight)
        .help(help)
    }

    /// What the user sees under the cursor while dragging: the chip
    /// itself. Drawn rather than snapshotted, so it looks the same
    /// whatever the panel happens to be compositing at that moment.
    private static func dragImage(_ item: ClipboardShelfItem, width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: IslandMetrics.shelfChipHeight)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.16, alpha: 0.96).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: 6, yRadius: 6)
            NSColor(white: 0.42, alpha: 1).setStroke()
            border.lineWidth = 1
            border.stroke()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor(white: 0.92, alpha: 1),
            ]
            let inset = ShelfChipMetrics.horizontalPadding
            let textRect = NSRect(x: inset,
                                  y: (rect.height - 13) / 2,
                                  width: max(0, rect.width - inset * 2),
                                  height: 13)
            (item.preview as NSString).draw(in: textRect, withAttributes: attributes)
            return true
        }
    }
}

// MARK: - The shelf

/// The 560 x 28 band between the section body and the footer.
///
/// ALWAYS PRESENT, whichever section is selected, and it keeps its height
/// when there is nothing in it. A band that came and went would move the
/// body up and down under the pointer, and the panel's rows are fixed
/// precisely so that nothing in it has to move.
struct ClipboardShelf: View {
    @ObservedObject var model: IslandModel

    private var contentWidth: CGFloat {
        IslandMetrics.panelWidth - IslandRouter.gutter * 2
    }

    var body: some View {
        let state = model.clipboard
        let chipWidth = IslandMetrics.shelfChipWidth(content: contentWidth)

        HStack(spacing: IslandMetrics.shelfChipGap) {
            if state.isPaused {
                // THE ONE STATE THE SHELF HAS TO SAY OUT LOUD. Paused
                // means nothing is being recorded, and a silently empty
                // shelf would look like a broken one.
                Text("ЗАПИСЬ НА ПАУЗЕ")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(IslandPalette.warning)
                    .padding(.horizontal, 7)
                    .frame(height: IslandMetrics.shelfChipHeight)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(IslandPalette.warning.opacity(0.13)))
            } else {
                ForEach(state.items) { item in
                    ShelfChip(item: item, width: chipWidth)
                }
            }
            Spacer(minLength: 0)
        }
        // The gutter is INSIDE the 560, exactly as in IslandRail: frame to
        // 532 and pad back out to 560.
        .frame(width: contentWidth,
               height: IslandMetrics.shelfHeight,
               alignment: .leading)
        .padding(.horizontal, IslandRouter.gutter)
        // EVERY CONTROL THIS FEATURE STILL HAS, and none of them costs a
        // pixel until it is asked for. The old «Буфер» tab spent an 18 pt
        // header row on two buttons and a counter, plus 22 pt on two lines
        // of prose about the secret filter, on a panel the user has twice
        // said has too many words.
        .contextMenu {
            Button(state.isPaused ? "Продолжить запись" : "Остановить запись") {
                ClipboardFeature.shared.setPaused(!state.isPaused)
            }
            Button("Очистить историю") {
                ClipboardFeature.shared.clearHistory()
            }
            Divider()
            // Informational. The skipped-secrets count is the only
            // evidence the user has that the filter is real, and it
            // survives «Очистить» — clearing the history is not a reason
            // to forget that three passwords went past untouched.
            Text(state.entryCount == 0
                 ? "История пуста"
                 : "\(state.entryCount) \(ClipboardRu.entries(state.entryCount))"
                   + " · показано \(min(state.entryCount, ClipboardShelfState.slots))")
            if state.skippedSecrets > 0 {
                Text("секретов пропущено: \(state.skippedSecrets)")
            }
        }
    }
}

// =====================================================================
// --clipboard-probe
//
// The behaviour proof, in the shipping binary, the same way
// --printer-probe and --privacy-probe are. It drives the REAL
// ClipboardEngine and the REAL ClipboardFeature.state, and prints what the
// 28 pt shelf would draw.
//
// IT NEVER TOUCHES THE USER'S CLIPBOARD. Everything happens on PRIVATE
// named pasteboards, which is what `ClipboardEngine.init(pasteboard:)`
// exists for. That is not fastidiousness: an earlier spike of this feature
// destroyed the contents of this machine's clipboard when its harness was
// killed mid-run, and the contents were not recoverable.
//
// THERE ARE NOW TWO HEADLINE CHECKS, not one:
//
//   STEP 2 — THE SECRET FILTER. Both the innocent item and the concealed
//   one hand their bytes over LAZILY, through an NSPasteboardItemDataProvider
//   that records every type anyone asks for. The concealed item's provider
//   must never fire: that is what "the secret was never read" means, and
//   it is checkable rather than merely asserted.
//
//   STEP 6 — WHAT A DROP ACTUALLY RECEIVES. The shelf's whole point is
//   dragging out, and "it has an NSDraggingSource" is not a proof that the
//   drop is correct. So the probe takes the very writers
//   `ShelfChipDragView` hands to `NSDraggingItem`, puts them on a second
//   private pasteboard, and READS THEM BACK the way a receiving app reads
//   `draggingInfo.draggingPasteboard` — a string for text, a real
//   `public.file-url` for a file, and nothing at all for an image.
// =====================================================================

/// Supplies pasteboard data on demand and remembers who asked. The whole
/// point is the times it is NOT called.
private final class ClipboardProbeProvider: NSObject, NSPasteboardItemDataProvider {
    private let lock = NSLock()
    private var asked: [String] = []
    private let payloads: [String: String]

    init(payloads: [String: String]) { self.payloads = payloads }

    /// Types anyone actually requested the bytes for.
    var requested: [String] { lock.lock(); defer { lock.unlock() }; return asked }

    func pasteboard(_ pasteboard: NSPasteboard?,
                    item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock(); asked.append(type.rawValue); lock.unlock()
        if let s = payloads[type.rawValue] { item.setString(s, forType: type) }
    }
}

enum ClipboardProbe {

    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        print("    \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    /// Let the engine's `DispatchQueue.main.async` publish land before we
    /// read the main-thread copies.
    private static func drain() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
    }

    /// What the shelf would draw, printed as the chips it would draw, at
    /// the REAL chip width so the truncation shown is the real one.
    private static func render(_ state: ClipboardShelfState) {
        let content = IslandMetrics.panelWidth - IslandRouter.gutter * 2
        let chip = IslandMetrics.shelfChipWidth(content: content)
        let chars = max(1, Int((chip - ShelfChipMetrics.chrome)
                               / ShelfChipMetrics.approximateCharacterWidth))
        func fit(_ s: String) -> String {
            s.count <= chars ? s + String(repeating: " ", count: chars - s.count)
                             : String(s.prefix(max(0, chars - 1))) + "…"
        }
        print("    ┌─ полка ─ 560 x \(Int(IslandMetrics.shelfHeight)) "
              + String(repeating: "─", count: 30))
        if state.isPaused {
            print("    │ [ЗАПИСЬ НА ПАУЗЕ]")
        } else if state.items.isEmpty {
            print("    │ (пусто)")
        } else {
            var line = "    │"
            for item in state.items {
                line += " [" + (item.isLive ? "⠿" : "×") + " " + fit(item.preview) + "]"
            }
            print(line)
        }
        print("    └ \(state.entryCount) \(ClipboardRu.entries(state.entryCount))"
              + (state.skippedSecrets > 0 ? " · секретов пропущено: \(state.skippedSecrets)" : "")
              + "   (счётчики, Пауза и Очистить — в контекстном меню полки)")
    }

    static func run() -> Never {
        print("=== MacPulse --clipboard-probe ===")
        print("")
        print("Drives the SHIPPING ClipboardEngine on a PRIVATE pasteboard.")
        print("The user's own clipboard is never read and never written.")
        print("")

        // A private named pasteboard. Not NSPasteboard.general, ever.
        let board = NSPasteboard(name: NSPasteboard.Name("com.local.macpulse.clipboard-probe"))
        board.clearContents()
        // A SECOND private board, standing in for the drag pasteboard a
        // real drop would read.
        let drop = NSPasteboard(name: NSPasteboard.Name("com.local.macpulse.clipboard-drop"))
        drop.clearContents()

        let engine = ClipboardEngine(pasteboard: board)
        // MetricsEngine's queue is a serial utility queue; this stands in
        // for it so `poll()` runs exactly where it will run in the app.
        let queue = DispatchQueue(label: "com.local.macpulse.clipboard-probe", qos: .utility)

        var pollOnMain = 0
        var callbacksOffMain = 0
        let token = engine.observe { _, _ in
            if !Thread.isMainThread { callbacksOffMain += 1 }
        }

        // `queue.async` + a semaphore, NOT `queue.sync`: Dispatch is
        // allowed to run a `sync` block on the CALLING thread, which would
        // put poll() on main and make the threading check below a lie. In
        // the app poll() is reached from MetricsEngine's own timer handler,
        // i.e. genuinely on the queue, and this reproduces that.
        func tick() {
            let done = DispatchSemaphore(value: 0)
            queue.async {
                if Thread.isMainThread { pollOnMain += 1 }
                engine.poll()
                done.signal()
            }
            done.wait()
            drain()
        }

        // The baseline, so whatever was on the board before is not
        // back-filled.
        engine.start()
        drain()
        let model = IslandModel()
        model.setClipboard(ClipboardFeature.state(engine.entries, engine.stats,
                                                  paused: engine.isPaused))

        print("--- step 0: nothing copied yet -------------------------------")
        check(engine.entries.isEmpty, "history empty")
        check(model.clipboard.items.isEmpty, "the shelf draws no chips")
        check(IslandSectionRegistry.section(IslandSectionID("clipboard")) == nil,
              "«Буфер» is NOT a registered section — the shelf replaced the tab")
        render(model.clipboard)
        print("")

        // ---- step 1: an ordinary string, supplied LAZILY ---------------
        print("--- step 1: copy a normal string ------------------------------")
        let plain = "MacPulse clipboard probe — обычная строка, которую можно вернуть."
        let plainProvider = ClipboardProbeProvider(payloads: [ClipboardTypes.utf8Text: plain])
        let plainItem = NSPasteboardItem()
        plainItem.setDataProvider(plainProvider,
                                  forTypes: [NSPasteboard.PasteboardType(ClipboardTypes.utf8Text)])
        board.clearContents()
        _ = board.writeObjects([plainItem])
        print("    wrote types: [\(ClipboardTypes.utf8Text)]")
        tick()
        model.setClipboard(ClipboardFeature.state(engine.entries, engine.stats,
                                                  paused: engine.isPaused))
        check(engine.entries.count == 1, "one entry recorded")
        check(engine.entries.first?.preview == plain, "preview is the copied string")
        check(engine.entries.first?.kind == .text, "kind == .text")
        check(engine.entries.first?.canRecopy == true, "canRecopy == true")
        check(engine.stats.captured == 1, "stats.captured == 1")
        check(plainProvider.requested == [ClipboardTypes.utf8Text],
              "the bytes WERE requested: \(plainProvider.requested)")
        check(model.clipboard.items.first?.isLive == true,
              "the chip is live -> it both drags and clicks")
        render(model.clipboard)
        print("")

        // ---- step 2: THE FIRST HEADLINE. A concealed item. -------------
        print("--- step 2: copy a ConcealedType (password-manager) item ------")
        let secret = "correct-horse-battery-staple"
        let secretProvider = ClipboardProbeProvider(payloads: [
            ClipboardTypes.utf8Text: secret,
            "org.nspasteboard.source": "1Password 7",
        ])
        let secretItem = NSPasteboardItem()
        // The exact four-type set the dossier observed for 1Password 7.
        let secretTypes = [ClipboardTypes.utf8Text,
                           "org.nspasteboard.ConcealedType",
                           "org.nspasteboard.source",
                           "com.agilebits.onepassword"]
        secretItem.setDataProvider(secretProvider,
                                   forTypes: secretTypes.map { NSPasteboard.PasteboardType($0) })
        board.clearContents()
        _ = board.writeObjects([secretItem])
        print("    wrote types: \(secretTypes)")
        let before = engine.entries.count
        tick()
        model.setClipboard(ClipboardFeature.state(engine.entries, engine.stats,
                                                  paused: engine.isPaused))
        check(secretProvider.requested.isEmpty,
              ">>> THE SECRET BYTES WERE NEVER REQUESTED: requested == \(secretProvider.requested)")
        check(engine.entries.count == before, "history unchanged (\(before) entries)")
        check(engine.stats.skippedSecrets == 1, "stats.skippedSecrets == 1")
        check(engine.stats.captured == 1, "stats.captured still 1")
        if case .concealed(let marker)? = engine.stats.lastSkipReason {
            check(marker == "org.nspasteboard.ConcealedType",
                  "blocked on the canonical marker: \(marker)")
        } else {
            check(false, "lastSkipReason is .concealed (got \(String(describing: engine.stats.lastSkipReason)))")
        }
        check(!engine.entries.contains { $0.preview.contains("horse") },
              "no entry anywhere contains the secret text")
        // AND THEREFORE NO CHIP CAN CARRY IT. Structural, not a second
        // filter: a refused item never becomes an entry, so there is no id
        // for the shelf to draw or for `draggingWriters` to be asked about.
        check(!model.clipboard.items.contains { $0.preview.contains("horse") },
              ">>> and no shelf chip exists for it, so nothing can be dragged out")
        render(model.clipboard)
        print("")

        // ---- step 3: click a chip -> re-copy ---------------------------
        print("--- step 3: click a chip -> re-copy ---------------------------")
        board.clearContents()
        _ = board.setString("что-то другое", forType: .string)
        tick()
        model.setClipboard(ClipboardFeature.state(engine.entries, engine.stats,
                                                  paused: engine.isPaused))
        check(engine.entries.count == 2, "the decoy copy landed, 2 entries")
        check(engine.entries.first?.preview == "что-то другое", "newest is the decoy")

        guard let target = engine.entries.first(where: { $0.preview == plain }) else {
            print("    FAIL could not find the original entry to re-copy"); exit(1)
        }
        let didWrite = engine.recopy(id: target.id)
        drain()
        model.setClipboard(ClipboardFeature.state(engine.entries, engine.stats,
                                                  paused: engine.isPaused))
        check(didWrite, "recopy() returned true")
        check(board.string(forType: .string) == plain,
              "the pasteboard now holds the entry again: \(String(describing: board.string(forType: .string)?.prefix(30)))")
        check(engine.entries.first?.id == target.id, "the re-copied chip is now newest")
        check(engine.entries.count == 2, "no duplicate entry was created")
        tick()   // our own write must be recognised, not re-ingested
        check(engine.stats.lastSkipReason == .selfWrite, "the next poll saw .selfWrite")
        check(engine.entries.count == 2, "still 2 entries after the poll")
        model.setClipboard(ClipboardFeature.state(engine.entries, engine.stats,
                                                  paused: engine.isPaused))
        render(model.clipboard)
        print("")

        // ---- step 4: an image is remembered but not retained -----------
        print("--- step 4: copy an image -------------------------------------")
        let image = NSImage(size: NSSize(width: 120, height: 80))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 120, height: 80)).fill()
        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            board.clearContents()
            let item = NSPasteboardItem()
            item.setData(png, forType: NSPasteboard.PasteboardType(ClipboardTypes.png))
            _ = board.writeObjects([item])
            tick()
            model.setClipboard(ClipboardFeature.state(engine.entries, engine.stats,
                                                      paused: engine.isPaused))
            check(engine.entries.first?.kind == .image, "kind == .image")
            check(engine.entries.first?.canRecopy == false,
                  "canRecopy == false -> the chip is inert: neither click nor drag")
            check(engine.recopy(id: engine.entries.first!.id) == false,
                  "recopy() refuses rather than pasting something truncated")
            check(engine.draggingWriters(id: engine.entries.first!.id) == nil,
                  ">>> draggingWriters() == nil: the engine never retained the pixels, "
                  + "so no image data is offered and none is invented")
            check((engine.entries.first?.retainedBytes ?? .max) < 64,
                  "retains \(engine.entries.first?.retainedBytes ?? -1) bytes, not the image")
            // Compare against the PNG's OWN header rather than against the
            // 120x80 NSImage size: `lockFocus` on a Retina display backs the
            // image at 2x, so the file really is 240x160 and the engine is
            // right to say so. Asserting the point size here would have been
            // asserting the probe's arithmetic, not the engine's.
            let truth = NSBitmapImageRep(data: png)
            check(engine.entries.first?.pixelWidth == truth?.pixelsWide
                  && engine.entries.first?.pixelHeight == truth?.pixelsHigh,
                  "pixel size matches the PNG header: "
                  + "\(engine.entries.first?.pixelWidth ?? -1)x\(engine.entries.first?.pixelHeight ?? -1)"
                  + " vs \(truth?.pixelsWide ?? -1)x\(truth?.pixelsHigh ?? -1)")
            render(model.clipboard)
        } else {
            check(false, "could not build a PNG for the image case")
        }
        print("")

        // ---- step 5: a FILE copy, the case the shelf exists for --------
        print("--- step 5: copy a file, as Finder does -----------------------")
        let filePath = "/etc/hosts"
        board.clearContents()
        _ = board.writeObjects([URL(fileURLWithPath: filePath) as NSURL])
        tick()
        model.setClipboard(ClipboardFeature.state(engine.entries, engine.stats,
                                                  paused: engine.isPaused))
        check(engine.entries.first?.kind == .fileURLs, "kind == .fileURLs")
        check(engine.entries.first?.fileCount == 1, "one file")
        check(model.clipboard.items.first?.preview == "hosts",
              "the chip shows the file NAME: "
              + (model.clipboard.items.first?.preview ?? "—"))
        check(model.clipboard.items.first?.isLive == true, "and it is draggable")
        render(model.clipboard)
        print("")

        // ---- step 6: THE SECOND HEADLINE. What a drop receives. --------
        print("--- step 6: what a DROP actually receives ---------------------")
        print("    The writers below are the ones ShelfChipDragView hands to")
        print("    NSDraggingItem. They go on a private pasteboard and are read")
        print("    back the way a receiving app reads draggingPasteboard.")
        print("")

        // A FILE chip must drop as a REAL FILE URL, not as the text of a
        // path. This is the whole reason the shelf exists.
        if let fileEntry = engine.entries.first(where: { $0.kind == .fileURLs }),
           let writers = engine.draggingWriters(id: fileEntry.id) {
            drop.clearContents()
            _ = drop.writeObjects(writers)
            let urls = drop.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            print("    file chip  -> types \(drop.types?.map(\.rawValue) ?? [])")
            check(drop.types?.contains(NSPasteboard.PasteboardType(ClipboardTypes.fileURL)) == true,
                  ">>> the drop carries public.file-url, so Finder / Telegram / Figma "
                  + "receive a FILE and not a path string")
            check(urls.map(\.path) == [filePath],
                  ">>> and reading it back gives the real file: \(urls.map(\.path))")
            check(FileManager.default.fileExists(atPath: urls.first?.path ?? ""),
                  "the dropped URL points at something that is really there")
        } else {
            check(false, "no file entry to build a drag from")
        }

        // A TEXT chip must drop as a string.
        if let textEntry = engine.entries.first(where: { $0.kind == .text && $0.preview == plain }),
           let writers = engine.draggingWriters(id: textEntry.id) {
            drop.clearContents()
            _ = drop.writeObjects(writers)
            print("    text chip  -> types \(drop.types?.map(\.rawValue) ?? [])")
            check(drop.string(forType: .string) == plain,
                  ">>> the drop carries the exact copied string: "
                  + String(describing: drop.string(forType: .string)?.prefix(30)))
        } else {
            check(false, "no text entry to build a drag from")
        }

        // AN IMAGE chip must offer nothing at all.
        if let imageEntry = engine.entries.first(where: { $0.kind == .image }) {
            check(engine.draggingWriters(id: imageEntry.id) == nil,
                  ">>> image chip -> no writers, so no drag session is ever started")
        }

        // AND AN ENTRY THAT IS NOT IN HISTORY offers nothing either — the
        // budget can evict a chip between the frame that drew it and the
        // gesture that drags it.
        check(engine.draggingWriters(id: 0) == nil,
              "an id that is not in history -> nil, not an empty session")
        drop.clearContents()
        print("")

        // ---- step 7: pause, and clear ----------------------------------
        print("--- step 7: пауза and очистить (both in the shelf's menu) -----")
        ClipboardEngine.shared.isPaused = false     // untouched; named to show it is a different object
        engine.isPaused = true
        board.clearContents()
        _ = board.setString("во время паузы", forType: .string)
        let pausedBefore = engine.entries.count
        tick()
        check(engine.entries.count == pausedBefore, "paused: nothing recorded")
        check(engine.stats.lastSkipReason == .paused, "lastSkipReason == .paused")
        model.setClipboard(ClipboardFeature.state(engine.entries, engine.stats, paused: true))
        check(model.clipboard.isPaused, "the shelf says so rather than looking broken")
        render(model.clipboard)
        engine.isPaused = false
        board.clearContents()
        _ = board.setString("после паузы", forType: .string)
        tick()
        check(engine.entries.first?.preview == "после паузы", "resumed: recording again")
        check(!engine.entries.contains { $0.preview == "во время паузы" },
              "and it did NOT back-fill what happened during the pause")

        let secretsBefore = engine.stats.skippedSecrets
        engine.clearHistory()
        drain()
        model.setClipboard(ClipboardFeature.state(engine.entries, engine.stats,
                                                  paused: engine.isPaused))
        check(engine.entries.isEmpty, "clearHistory() emptied the history")
        check(engine.stats.skippedSecrets == secretsBefore,
              "the skipped-secrets count survives a clear (\(secretsBefore))")
        check(board.string(forType: .string) == "после паузы",
              "clearHistory() did NOT touch the pasteboard")
        check(model.clipboard.items.isEmpty, "the shelf is empty again")
        render(model.clipboard)
        print("")

        // ---- the shelf's own arithmetic --------------------------------
        print("--- the shelf's width budget ----------------------------------")
        let content = IslandMetrics.panelWidth - IslandRouter.gutter * 2
        let chip = IslandMetrics.shelfChipWidth(content: content)
        print(String(format: "  %d chips x %.1f pt + %d x %.0f pt gaps = %.0f of %.0f pt",
                     IslandMetrics.shelfSlots, chip,
                     IslandMetrics.shelfSlots - 1, IslandMetrics.shelfChipGap,
                     chip * CGFloat(IslandMetrics.shelfSlots)
                        + CGFloat(IslandMetrics.shelfSlots - 1) * IslandMetrics.shelfChipGap,
                     content))
        print(String(format: "  chrome %.0f pt -> %.1f pt of preview, about %d characters",
                     ShelfChipMetrics.chrome, chip - ShelfChipMetrics.chrome,
                     Int((chip - ShelfChipMetrics.chrome)
                         / ShelfChipMetrics.approximateCharacterWidth)))
        print("")

        // ---- threading -------------------------------------------------
        print("--- threading -------------------------------------------------")
        check(pollOnMain == 0, "poll() never ran on the main thread")
        check(callbacksOffMain == 0, "every observer callback arrived on main")

        engine.remove(token)
        board.clearContents()

        print("")
        if failures == 0 {
            print("=== все проверки пройдены ===")
            exit(0)
        }
        print("=== \(failures) проверок провалено ===")
        exit(1)
    }
}

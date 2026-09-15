import AppKit
import SwiftUI

// =====================================================================
// «Буфер» — the clipboard-history section, and NOTHING in the collapsed
// strip.
//
// Registered through the router's documented extension point: an id, a
// section value, one line in IslandFeatures. Nothing in IslandRail.swift,
// IslandViews.swift or IslandRouter had to change to add it. The engine
// it draws is ClipboardEngine.swift, which knows nothing about any of
// this.
//
// THIS FEATURE NEVER TAKES THE TRAILING WING, AND THAT IS DELIBERATE.
// Per the architecture spike the collapsed strip shows exactly ONE thing
// and the wing is 77 pt, so a slot has to be earned by state whose cost
// of being missed is high — a print with an unrecoverable deadline
// earns it. "There are 12 things in your clipboard" does not: the user
// already knows what they copied, nothing expires, and nothing is lost by
// finding out a second later. So this file calls neither
// `requestTrailingWing` nor `setStripSlotSection`. One consequence worth
// knowing: `IslandModel.stripSlotSection` is therefore never `.clipboard`,
// so opening the island never LANDS on Буфер — the user clicks the chip.
// That is the right way round for a section you go to on purpose.
//
// AND `footerSummary` IS ALWAYS nil, for the same reason. The footer is
// one 18 pt line shown while some OTHER section is selected; "Буфер 12"
// there would be a number nobody can act on, printed under whatever the
// user actually came to look at. The router documents nil as "nothing
// worth a word", and this is what that is for.
//
// `hasState` IS RECENCY, NOT THE ENTRY COUNT. The chip appears with a
// copy and goes away ten minutes after the last one — see
// `ClipboardSectionState.isLive`, which is where that decision is
// written out. Keying it on the entry count instead would have produced a
// chip that arrives thirty seconds after launch and never leaves, because
// a history is never empty again once it has one thing in it. A chip that
// is always present is a chip the user did not ask for, and the user has
// twice asked for less in this panel.
//
// The history itself is NOT pruned by that window: clear it and it is
// gone, otherwise all 100 entries are still there behind the chip the
// next time you copy anything.
//
// WHAT THE UI IS ALLOWED TO CLAIM. The engine's headline property is that
// an item carrying a concealed marker is refused WITHOUT the bytes ever
// being requested — proved with a data provider that logged every request
// and never fired. It is NOT proved that the deny list is complete, and a
// real 1Password copy was never observed. So the panel states the
// mechanism ("видит метку скрытого типа и не читает байты") and then says
// out loud that a list of known markers is not a guarantee, and offers
// «Пауза» as the lever for that case. There is deliberately no "показать
// всё равно" affordance of any kind: the refusal is the reason this
// feature is allowed to exist.
//
// LAYOUT — 186 pt, and it adds up:
//    18  header   counters + "секретов пропущено" + Пауза + Очистить
//     6  gap
//     1  divider
//     6  gap
//   130  list     6 rows x 20 pt, 2 pt spacing
//     3  spacer   (flexible; takes the slack when the list is short)
//    22  note     two lines: the promise, then the caveat
//   ---
//   186
// =====================================================================

extension IslandSectionID {
    static let clipboard = IslandSectionID("clipboard")
}

// MARK: - Published state
//
// Formatted the way `MemorySectionState` is formatted: as the STRINGS the
// view puts on screen, so two updates that would draw identical pixels
// compare equal and publish nothing. See the publishing rule at the top of
// IslandModel.swift.

/// One row of the Буфер section, already formatted.
struct ClipboardRowState: Equatable, Identifiable {
    let id: UInt64
    /// SF Symbol for the kind.
    let symbol: String
    /// One short Russian word for the kind.
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
    /// actually moves, so a relative age would sit on screen going stale,
    /// and refreshing it would mean putting work back on the 1 Hz tick for
    /// a panel that is usually shut.
    let time: String
    /// False for an image or an over-budget copy: the payload was never
    /// retained, so there is nothing to put back. The row is drawn inert
    /// rather than offering a click that would silently do nothing.
    let canRecopy: Bool
}

/// Everything the Буфер section draws, as drawn.
struct ClipboardSectionState: Equatable {

    /// How many rows the 130 pt list can hold. The history itself is
    /// capped at 100 (`ClipboardEngine.Budget.maxEntries`); the header
    /// says how many there really are.
    static let visibleRows = 6

    /// How many entries the history holds. NOT what drives the chip —
    /// see `isLive` below.
    var entryCount = 0
    /// DRIVES `hasState`, and it is not `entryCount > 0`.
    ///
    /// THIS IS THE RAIL-DISCIPLINE RULE, and getting it wrong here is the
    /// easiest way to break the whole router. A history is never empty
    /// again after the first copy of the session, so a chip keyed on
    /// `entryCount` would appear about thirty seconds after launch and
    /// then stay for ever — which is precisely the always-present chip
    /// IslandSection.swift forbids. "The clipboard has things in it" is
    /// the clipboard equivalent of "the printer is configured".
    ///
    /// So the chip means "something was copied RECENTLY" — inside
    /// `ClipboardFeature.liveWindow` — which is the only window in which
    /// putting it back is a thing anyone wants to do. It is set at publish
    /// time and cleared by a single one-shot timer armed for the exact
    /// instant it expires; nothing is evaluated on a tick and the history
    /// itself is untouched, so the chip comes straight back with the next
    /// copy and all 100 entries are still behind it.
    ///
    /// `isPaused` also holds it true, for the same reason
    /// `PressureAlertState.isMuted` does: the switch back on lives inside
    /// this section, so hiding the chip while recording is off would leave
    /// the user with no way to turn it on again.
    var isLive = false
    /// "12 записей · 3.1 КБ в памяти · показано 6"
    var countLine = ""
    /// Items refused because a secret marker was present. The only
    /// evidence the user has that the filter is real, so it gets a badge
    /// rather than a log line.
    var skippedSecrets = 0
    var isPaused = false
    /// Newest first, at most `visibleRows`.
    var rows: [ClipboardRowState] = []
}

// MARK: - The bridge to the island

/// Main-thread glue between `ClipboardEngine` and `IslandModel`.
///
/// Mirrors `PrinterPoller`/`PrivacyWatcher`: the engine samples on
/// MetricsEngine's queue, this object formats on main and hands the model
/// ONE Equatable struct. It is a singleton rather than a model-owned
/// object only so that the section's buttons can reach it without widening
/// `IslandModel`'s surface — re-copy, clear and pause are one-shot actions
/// on the engine, not model state, and there is nothing for the model to
/// hold on their behalf.
///
/// EVENT-DRIVEN, NOT TICK-DRIVEN. The engine publishes only when
/// `changeCount` actually moves, which is a user copying something. On an
/// idle machine this object is never called at all, so the @Published
/// write it causes is not part of the idle cost — see the measurements at
/// the top of IslandModel.swift for why that distinction is the whole
/// ballgame.
final class ClipboardFeature {

    static let shared = ClipboardFeature()
    private init() {}

    /// How long after a copy the Буфер chip stays in the rail. Ten
    /// minutes: long enough to cover "copy, switch app, need it back",
    /// short enough that a machine nobody is typing at has an empty rail.
    /// The HISTORY is not pruned by this — only the chip.
    static let liveWindow: TimeInterval = 600

    private weak var model: IslandModel?
    private var token: ClipboardObserverToken?
    /// The one-shot that retires the chip. Main queue, cancelled and
    /// re-armed on every publish, so at most one exists at a time and an
    /// idle machine has none.
    private var expiry: DispatchWorkItem?

    /// 24-hour, locale-independent: a row that says "14:32" must mean the
    /// same thing whatever the user's clock format is, and the column is
    /// sized for four digits.
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
        expiry?.cancel()
        expiry = nil
        model = nil
    }

    // MARK: Actions the section's buttons call

    func recopy(_ id: UInt64) {
        precondition(Thread.isMainThread)
        // The engine promotes the entry and publishes; nothing to do here
        // on either outcome. A false return means the payload was never
        // retained, and such rows are drawn unclickable in the first place.
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
        // so the button follows the click instead of the next copy.
        push(ClipboardEngine.shared.entries, ClipboardEngine.shared.stats)
    }

    // MARK: Formatting

    private func push(_ entries: [ClipboardEntry], _ stats: ClipboardStats) {
        precondition(Thread.isMainThread)
        let now = Date()
        let paused = ClipboardEngine.shared.isPaused
        model?.setClipboard(Self.state(entries, stats, paused: paused, asOf: now))

        // Arm the retirement of the chip for the exact instant the newest
        // copy goes stale, and not one wake-up before it. Nothing polls
        // for this: with no copy there is no timer, and with a copy there
        // is exactly one, ten minutes out. Re-publishing at that instant
        // is the whole of the work — `setClipboard` compares first, so if
        // a later copy already moved the deadline the write is dropped.
        expiry?.cancel()
        expiry = nil
        guard !paused, let newest = entries.first?.capturedAt else { return }
        let deadline = newest.addingTimeInterval(Self.liveWindow).timeIntervalSince(now)
        guard deadline > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.token != nil else { return }
            self.model?.setClipboard(
                Self.state(ClipboardEngine.shared.entries,
                           ClipboardEngine.shared.stats,
                           paused: ClipboardEngine.shared.isPaused,
                           asOf: Date()))
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline, execute: work)
    }

    /// Pure, so it can be exercised without an island. `asOf` is a
    /// parameter for the same reason: `isLive` is a function of the clock
    /// and a function of the clock that reads the clock itself cannot be
    /// tested.
    static func state(_ entries: [ClipboardEntry],
                      _ stats: ClipboardStats,
                      paused: Bool,
                      asOf now: Date = Date()) -> ClipboardSectionState {
        var s = ClipboardSectionState()
        s.entryCount = stats.entryCount
        s.isLive = paused || entries.first.map {
            now.timeIntervalSince($0.capturedAt) < liveWindow
        } ?? false
        s.skippedSecrets = stats.skippedSecrets
        s.isPaused = paused
        s.rows = entries.prefix(ClipboardSectionState.visibleRows).map(row(for:))

        if stats.entryCount > 0 {
            var line = "\(stats.entryCount) \(ClipboardRu.entries(stats.entryCount))"
                + " · " + UIFmt.bytes(Double(stats.retainedBytes)) + " в памяти"
            if stats.entryCount > ClipboardSectionState.visibleRows {
                line += " · показано \(ClipboardSectionState.visibleRows)"
            }
            s.countLine = line
        }
        return s
    }

    private static func row(for e: ClipboardEntry) -> ClipboardRowState {
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

        return ClipboardRowState(id: e.id,
                                 symbol: symbol,
                                 kind: kind,
                                 preview: preview,
                                 size: UIFmt.bytes(e.byteCount.map(Double.init)),
                                 time: clock.string(from: e.capturedAt),
                                 canRecopy: e.canRecopy)
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

// MARK: - Rows

private struct ClipboardRow: View {
    let row: ClipboardRowState
    let onRecopy: () -> Void

    @State private var hovering = false

    private var help: String {
        row.canRecopy
            ? "Нажмите, чтобы снова положить это в буфер обмена."
            : "Содержимое не сохранялось: картинки и копии больше 128 КБ остаются только описанием. Возвращать нечего."
    }

    var body: some View {
        Button(action: onRecopy) {
            HStack(spacing: 7) {
                Image(systemName: row.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: row.canRecopy ? 0.55 : 0.3))
                    .frame(width: 13)

                Text(row.kind)
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.42))
                    .lineLimit(1)
                    .frame(width: 58, alignment: .leading)

                Text(row.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: row.canRecopy ? 0.88 : 0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(row.size)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Color(white: 0.5))
                    .frame(width: 54, alignment: .trailing)

                Text(row.time)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Color(white: 0.4))
                    .frame(width: 34, alignment: .trailing)

                // The affordance is a word, not an icon, the same way the
                // Память rows say «Завершить». A row that cannot be put
                // back says so BEFORE the click rather than swallowing it.
                Group {
                    if !row.canRecopy {
                        Text("не сохранено")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Color(white: 0.32))
                    } else if hovering {
                        Text("вернуть")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 62, alignment: .trailing)
            }
            .frame(height: 20)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(hovering && row.canRecopy ? 0.07 : 0))
            )
        }
        .buttonStyle(.plain)
        .disabled(!row.canRecopy)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - The 560 x 186 body

private struct ClipboardSectionView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let state = model.clipboard
        VStack(alignment: .leading, spacing: 0) {
            header(state)

            Spacer(minLength: 0).frame(height: 6)
            Divider().overlay(Color(white: 0.16))
            Spacer(minLength: 0).frame(height: 6)

            list(state)

            Spacer(minLength: 0)

            note
        }
        // The gutter is INSIDE the 560, exactly as in IslandRail and
        // IslandSectionMemory: frame to 532 and pad back out to 560.
        .frame(width: IslandMetrics.panelWidth - IslandRouter.gutter * 2,
               height: IslandMetrics.bodyHeight,
               alignment: .top)
        .padding(.horizontal, IslandRouter.gutter)
    }

    // MARK: header

    @ViewBuilder private func header(_ state: ClipboardSectionState) -> some View {
        HStack(spacing: 8) {
            Text(state.countLine)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Color(white: 0.5))
                .lineLimit(1)

            if state.skippedSecrets > 0 {
                // THE FILTER WORKING IS GOOD NEWS, so it is tinted like
                // good news and not like an error. The number is the only
                // proof the user gets, and it survives «Очистить» because
                // clearing the history is not a reason to forget that three
                // passwords went past untouched.
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                    Text("секретов пропущено: \(state.skippedSecrets)")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(IslandPalette.normal)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(IslandPalette.normal.opacity(0.13)))
                .help("Копии с меткой org.nspasteboard.ConcealedType и другими известными "
                      + "метками менеджеров паролей. Их содержимое у буфера обмена не запрашивалось.")
            }

            if state.isPaused {
                Text("ПАУЗА")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(IslandPalette.warning)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(IslandPalette.warning.opacity(0.14)))
            }

            Spacer(minLength: 8)

            SmallButton(title: state.isPaused ? "Продолжить" : "Пауза",
                        tint: state.isPaused ? IslandPalette.warning : Color(white: 0.85),
                        onTap: { ClipboardFeature.shared.setPaused(!state.isPaused) })
                .help("Пока запись на паузе, MacPulse следит за счётчиком буфера, но ничего не запоминает. "
                      + "Это и есть ответ на «список известных меток — не гарантия».")

            SmallButton(title: "Очистить",
                        tint: Color(white: 0.85),
                        onTap: { ClipboardFeature.shared.clearHistory() })
                .help("Стереть историю. Системный буфер обмена не трогаем — то, что у вас сейчас "
                      + "скопировано, останется скопированным.")
        }
        .frame(height: 18)
    }

    // MARK: list

    @ViewBuilder private func list(_ state: ClipboardSectionState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if state.rows.isEmpty {
                // Only reachable for the frame or two between the history
                // being cleared and the router dropping the chip.
                Text(state.isPaused ? "Запись на паузе." : "Пока ничего не скопировано.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.4))
                    .padding(.horizontal, 6)
            } else {
                ForEach(state.rows) { row in
                    ClipboardRow(row: row,
                                 onRecopy: { ClipboardFeature.shared.recopy(row.id) })
                }
            }
            Spacer(minLength: 0)
        }
        // Fixed, so the note below does not walk up and down the panel as
        // the history fills.
        .frame(height: 130, alignment: .top)
    }

    // MARK: note

    private var note: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 8.5))
                    .foregroundStyle(IslandPalette.normal)
                Text("Пароли не записываются: MacPulse видит метку скрытого типа и не читает байты.")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.52))
                    .lineLimit(1)
            }
            .frame(height: 11)

            Text("Известные метки — не гарантия. История только в памяти: на диск ничего не пишется.")
                .font(.system(size: 8.5))
                .foregroundStyle(Color(white: 0.34))
                .lineLimit(1)
                .frame(height: 11)
        }
        .frame(height: 22, alignment: .top)
    }
}

// MARK: - Registration

extension IslandSection {
    static let clipboard = IslandSection(
        id: .clipboard,
        chipTitle: "Буфер",
        chipSymbol: "doc.on.clipboard",
        // Cheap and pure: one Bool read off a @Published struct the bridge
        // already wrote. No syscall, no pasteboard call, no clock read, no
        // I/O — see the five rules in IslandSection.swift.
        //
        // NOT `entryCount > 0`. See `ClipboardSectionState.isLive` for why
        // that would have been an always-present chip.
        hasState: { $0.clipboard.isLive },
        // Always nil, on purpose. See the header: a clipboard count is not
        // a thing anyone can act on, and the footer is shown under the
        // section the user actually came to look at.
        footerSummary: { _ in nil },
        makeBody: { model in AnyView(ClipboardSectionView(model: model)) }
    )
}

// =====================================================================
// --clipboard-probe
//
// The behaviour proof, in the shipping binary, the same way
// --printer-probe and --privacy-probe are. It drives the REAL
// ClipboardEngine and the REAL ClipboardFeature.state / IslandSection
// callbacks, and prints what the 560 x 186 body would draw.
//
// IT NEVER TOUCHES THE USER'S CLIPBOARD. Everything happens on a PRIVATE
// named pasteboard, which is exactly what `ClipboardEngine.init(pasteboard:)`
// exists for. That is not fastidiousness: an earlier spike of this feature
// destroyed the contents of this machine's clipboard when its harness was
// killed mid-run, and the contents were not recoverable.
//
// THE CENTRAL CHECK is step 2. Both the innocent item and the concealed
// one hand their bytes over LAZILY, through an NSPasteboardItemDataProvider
// that records every type anyone asks for. The concealed item's provider
// must never fire: that is what "the secret was never read" means, and it
// is checkable rather than merely asserted.
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

    /// What the body would draw, printed as the rows it would draw.
    private static func render(_ state: ClipboardSectionState) {
        print("    ┌─ Буфер ─ 560 x 186 " + String(repeating: "─", count: 34))
        print("    │ " + (state.countLine.isEmpty ? "—" : state.countLine)
              + (state.skippedSecrets > 0 ? "   [🔒 секретов пропущено: \(state.skippedSecrets)]" : "")
              + (state.isPaused ? "   [ПАУЗА]" : ""))
        print("    ├" + String(repeating: "─", count: 53))
        if state.rows.isEmpty {
            print("    │ (пусто)")
        }
        func pad(_ s: String, _ n: Int, right: Bool = false) -> String {
            if s.count >= n { return String(s.prefix(n - 1)) + "…" }
            let fill = String(repeating: " ", count: n - s.count)
            return right ? fill + s : s + fill
        }
        for r in state.rows {
            print("    │ " + pad(r.kind, 11) + pad(r.preview, 24)
                  + pad(r.size, 9, right: true) + "  " + r.time + "  "
                  + (r.canRecopy ? "вернуть" : "не сохранено"))
        }
        print("    │ 🛡 Пароли не записываются: MacPulse видит метку скрытого типа и не читает байты.")
        print("    └" + String(repeating: "─", count: 53))
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
        check(IslandSection.clipboard.hasState(model) == false,
              "hasState == false  -> no chip in the rail")
        check(IslandSection.clipboard.footerSummary(model) == nil,
              "footerSummary == nil -> clipboard never takes a footer clause")
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
        check(IslandSection.clipboard.hasState(model), "hasState == true -> the chip appears")
        // RAIL DISCIPLINE, proved rather than asserted. Same history, same
        // entry count, clock moved past the window: the chip is gone and
        // the 1 entry is still there. `state` takes `asOf` precisely so
        // this can be checked without waiting ten minutes.
        let stale = ClipboardFeature.state(
            engine.entries, engine.stats, paused: false,
            asOf: Date().addingTimeInterval(ClipboardFeature.liveWindow + 1))
        check(stale.entryCount == 1, "ten minutes later the history still holds it")
        check(stale.isLive == false,
              "...and the chip is gone: hasState is recency, not the entry count")
        render(model.clipboard)
        print("")

        // ---- step 2: THE HEADLINE. A concealed item. -------------------
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
        render(model.clipboard)
        print("")

        // ---- step 3: re-copy puts it back ------------------------------
        print("--- step 3: click a row -> re-copy ----------------------------")
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
        check(engine.entries.first?.id == target.id, "the re-copied row is now newest")
        check(engine.entries.count == 2, "no duplicate row was created")
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
                  "canRecopy == false -> the row is drawn inert, the click is never offered")
            check(engine.recopy(id: engine.entries.first!.id) == false,
                  "recopy() refuses rather than pasting something truncated")
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

        // ---- step 5: pause, and clear ----------------------------------
        print("--- step 5: «Пауза» and «Очистить» ----------------------------")
        ClipboardEngine.shared.isPaused = false     // untouched; named to show it is a different object
        engine.isPaused = true
        board.clearContents()
        _ = board.setString("во время паузы", forType: .string)
        let pausedBefore = engine.entries.count
        tick()
        check(engine.entries.count == pausedBefore, "paused: nothing recorded")
        check(engine.stats.lastSkipReason == .paused, "lastSkipReason == .paused")
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
        check(IslandSection.clipboard.hasState(model) == false,
              "hasState == false again -> the chip goes away")
        render(model.clipboard)
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

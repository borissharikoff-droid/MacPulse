import AppKit
import Foundation

// =====================================================================
// «Буфер» — clipboard history. In memory, secret-filtered, bounded.
//
// This file is the ENGINE ONLY: it knows nothing about IslandModel, the
// router or SwiftUI, exactly like MemorySampler and ProcessSampler know
// nothing about them. The island half — the published state struct, the
// main-thread bridge, the 560 x 186 body and the registration — is in
// IslandSectionClipboard.swift.
//
// WHY POLLING. NSPasteboard has no change notification of any kind: no
// NSNotification, no KVO, no CFNotificationCenter, no distributed
// notification. The ONLY way to learn that the clipboard moved is to
// compare `NSPasteboard.general.changeCount` against the last value you
// saw. Every clipboard manager on macOS does this, and so does this one.
//
// WHAT IT COSTS, AND WHY IT IS ALLOWED ON THE 1 Hz TICK.
// RE-MEASURED HERE against this exact file (M2, macOS 26.6.2, swiftc -O,
// a private pasteboard, 200 000 calls per row):
//   changeCount alone                 1.09 us/call
//   poll(), clipboard has NOT moved   1.32 us/call  = 0.00013% of ONE CORE at 1 Hz
//   poll(), clipboard HAS moved      63.5  us       — a user copy, not a tick
//        (write+poll measured 203.1 us; the 139.6 us pasteboard write in
//         that figure is paid by the app the user copied FROM, not by us)
// The wave-2 spike measured 0.78 us and 69.5 us for the same two paths,
// and a 180 s live 1 Hz soak burned 0.0493 s of process CPU in total —
// including the soak program's own writer timer.
//
// Against MacPulse's idle budget of 0.475% of one core, the steady-state
// poll is 1/3600th of it. The cheap check IS `changeCount`: `poll()` reads
// one integer and returns. The 63.5 us path runs when the user copies
// something, which is an action, not a tick. That is why this hangs off
// MetricsEngine's existing queue with no cadence multiplier and no timer
// of its own — it is cheaper than a single SMC key read (0.28 ms), and it
// deliberately is NOT gated on the panel being open: a history that only
// records while you are looking at it is not a history.
//
// NO TCC PROMPT, NO "PASTED FROM" TOAST. Verified from a plain CLI and
// again from a signed, bundled LSUIElement app launched through
// LaunchServices: three separate reads of real payloads, no prompt, no
// banner, no com.apple.TCC log entries. `kTCCServicePasteboard` DOES
// exist in tccd's string table on macOS 26, so Apple has the plumbing to
// start enforcing this in a point release — which is why every read here
// degrades to "nothing captured" rather than assuming it will succeed.
//
// ---------------------------------------------------------------------
// THE PART THAT MATTERS: WE NEVER STORE A SECRET, AND WE NEVER EVEN
// ASK FOR THE BYTES.
//
// `NSPasteboardItem.types` is readable WITHOUT touching the payload. The
// filter therefore runs on the type list ALONE, and `poll()` returns
// before any `data(forType:)` call when a blocking marker is present.
// PROVED, not asserted: the spike drove a lazy NSPasteboardItemDataProvider
// that logs every request for the bytes. For a plain string the provider
// fired (requested=["public.utf8-plain-text"]) and the entry was recorded;
// for a 1Password-shaped item (public.utf8-plain-text +
// org.nspasteboard.ConcealedType + org.nspasteboard.source +
// com.agilebits.onepassword) the provider NEVER fired (requested=[]) and
// nothing was recorded. The secret was never materialised in this process.
// The union is taken across ALL pasteboard items, not just item[0], so a
// two-item write whose second item is concealed refuses the whole thing.
//
// WHAT WAS **NOT** PROVED — do not let any UI imply otherwise:
//   * A REAL 1Password copy. The evidence is a synthetic item carrying
//     the exact four-type set the dossier observed in the shipped
//     OnePasswordCommon binary. If a real copy's type set differs, the
//     deny list below needs updating.
//   * That the deny list is COMPLETE. It is a deny list. A manager that
//     ignores the nspasteboard.org convention lands in history. That is
//     structural and no amount of testing fixes it — `isPaused`,
//     `addBlockedTypes` and `setExcludedSourceApplications` are the
//     levers, and the panel says so in words.
//   * Real copies from real apps (Safari, Finder, Preview, Notes,
//     Terminal), HEIC/JPEG/GIF/WebP, public.rtfd, sleep/wake, or runs
//     longer than 180 s.
//
// THE CONTRACT THIS FILE HONOURS:
//   * no sudo, no privileged execution, no private APIs (none needed)
//   * NO NETWORKING. Nothing here opens a socket, resolves a host or
//     touches URLSession. A captured "URL" is an inert string: never
//     fetched, never validated, never previewed. Linking is unchanged —
//     AppKit + Foundation, both already in build.sh. No new -framework
//     flag, and `otool -L` stays free of CFNetwork / Network / Security.
//   * no file deletion, no process termination
//   * IN-MEMORY ONLY. Nothing here writes to disk. See the block at the
//     bottom of the file before adding any persistence.
//   * every measured value is Optional; nil means "could not measure"
//     and renders as a dash — never as a fabricated 0.
//   * sampling happens off the main thread; results are published to the
//     main thread. Nothing here blocks or sleeps.
//
// TRIMMED ON THE WAY IN, from the standalone version of this engine:
//   * `startStandalone`/`stopStandalone` — an alternative driver with its
//     own queue and timer, for a host that does not want to touch
//     MetricsEngine. This app DOES drive it from the existing 1 Hz tick,
//     and a second timer is a wakeup the idle budget would have to pay
//     for. Using both would also race two queues on the same state.
//   * `clearHistoryAndPasteboard()` — nothing surfaces it, and a control
//     that yanks what the user has in hand is not worth a button here.
//   * a `didUpdateNotification` post on every publish — `observe` is the
//     one subscriber this app has; posting to NotificationCenter as well
//     was work with no reader.
//   * the byte formatter and the English kind labels — the engine reports
//     NUMBERS (`byteCount`, `pixelWidth`, `pixelHeight`) and the island
//     formats them with `UIFmt`, the way every other metric is formatted.
// =====================================================================

// MARK: - Value types

/// What kind of thing the user copied. Deliberately coarse — the section
/// shows an icon and one short word per case, not a MIME type.
enum ClipboardItemKind: String, Sendable, CaseIterable {
    case text
    case richText
    case url
    case fileURLs
    case image
}

/// Why an observed clipboard change produced no history entry.
///
/// Carried for diagnostics and for the panel's "secrets skipped" badge.
/// It NEVER contains clipboard content — only the name of the marker type
/// that blocked it, which is a compile-time constant, not user data.
enum ClipboardSkipReason: Sendable, Equatable {
    /// A password-manager / secret marker was present. The payload was
    /// never read.
    case concealed(markerType: String)
    /// A transient or auto-generated marker was present (another clipboard
    /// manager's own scratch write, a text expander). Distinct from
    /// `.concealed` on purpose: not a secret, just not worth recording,
    /// and the UI must not report it as a password.
    case transient(markerType: String)
    /// `org.nspasteboard.source` named an application the user excluded.
    case excludedApplication(String)
    /// The item carried no type this engine knows how to represent.
    case unsupportedTypes
    /// Identical to an entry already in history; that entry was promoted
    /// to the front instead.
    case duplicate
    /// Capture is paused (`isPaused == true`).
    case paused
    /// The pasteboard reported a change but handed back no items, or the
    /// payload read returned nil. "Could not measure", not "empty".
    case unreadable
    /// We wrote the pasteboard ourselves (`recopy`), so the change is ours.
    case selfWrite
}

/// One remembered clipboard item. Immutable value type, safe to hold and
/// copy anywhere. The payload is `fileprivate`, so nothing outside this
/// file — including the section that draws it — can read the bytes back;
/// the UI gets `preview` and asks the engine to `recopy`.
struct ClipboardEntry: Sendable, Identifiable, Equatable {

    let id: UInt64
    let kind: ClipboardItemKind

    /// One line, whitespace-collapsed, at most
    /// `ClipboardEngine.Budget.previewCharacters` characters. Safe to put
    /// straight into a label.
    let preview: String

    /// Size of what the user actually copied, in bytes.
    /// `nil` = could not measure (the payload read failed), and the panel
    /// draws a dash. NEVER 0 for a failed read — an empty-but-present
    /// payload really is 0.
    let byteCount: Int?

    /// How many bytes THIS PROCESS is holding for the entry. Always
    /// measurable, because it is our own accounting, not a probe. For an
    /// image, or an oversized item, this is just the preview string — the
    /// payload was deliberately not retained.
    let retainedBytes: Int

    /// When it was captured (or last re-promoted by a duplicate copy or a
    /// `recopy`). Wall clock, because it is displayed to a human.
    let capturedAt: Date

    /// Provenance from the `org.nspasteboard.source` marker, e.g.
    /// "1Password 7". `nil` = the writer did not set the marker, which is
    /// the common case; it is not an error and not "unknown app".
    let sourceApplication: String?

    /// Pixel dimensions, images only. `nil` = not an image, or the header
    /// could not be parsed, or the data was over `Budget.imageInspectBytes`
    /// and we refused to touch it.
    let pixelWidth: Int?
    let pixelHeight: Int?

    /// Number of file URLs, `.fileURLs` only; `nil` otherwise.
    let fileCount: Int?

    /// False when the payload was not retained (an image, or an item over
    /// `Budget.payloadBytesPerEntry`). `recopy` on such an entry returns
    /// false rather than putting a truncated body on the pasteboard, and
    /// the row is drawn unclickable so the user is never offered a control
    /// that cannot work.
    let canRecopy: Bool

    /// The bytes. `fileprivate` on purpose — see the type comment.
    fileprivate let payload: ClipboardPayload
    /// Cheap content fingerprint used for de-duplication. Not a security
    /// primitive; see `ClipboardEngine.fingerprint`.
    fileprivate let fingerprint: UInt64

    static func == (a: ClipboardEntry, b: ClipboardEntry) -> Bool { a.id == b.id }
}

/// Counters for the whole session. Every field counts something we
/// actually did, so none of them is Optional — a zero here is a MEASURED
/// zero, which is exactly the distinction the rest of the app makes with
/// `nil`.
struct ClipboardStats: Sendable, Equatable {
    /// Entries currently in history.
    var entryCount: Int = 0
    /// Bytes this process is holding for the history, total.
    var retainedBytes: Int = 0
    /// changeCount transitions observed since start.
    var changesObserved: Int = 0
    /// Entries actually recorded.
    var captured: Int = 0
    /// Items refused because a SECRET marker was present. This is the
    /// number the panel shows: it is the only evidence the user has that
    /// the filter is real.
    var skippedSecrets: Int = 0
    /// Items refused because a transient / auto-generated marker was
    /// present. Counted separately so the UI never calls a text expander's
    /// scratch write a password.
    var skippedTransient: Int = 0
    /// Items refused because the source application was excluded.
    var skippedExcluded: Int = 0
    /// Items refused because no known type was present.
    var skippedUnsupported: Int = 0
    /// Repeat copies of something already in history.
    var deduplicated: Int = 0
    /// Entries dropped by the entry-count or byte budget.
    var evicted: Int = 0
    /// Last `changeCount` this engine consumed. `nil` before the first
    /// poll — we have genuinely not measured it yet.
    var lastChangeCount: Int?
    /// Why the most recent change produced no entry. `nil` if it was
    /// captured.
    var lastSkipReason: ClipboardSkipReason?
}

/// Opaque handle from `ClipboardEngine.observe`. Dropping it does NOT
/// unsubscribe — call `remove(_:)`. Same contract as `MetricsObserverToken`.
struct ClipboardObserverToken: Hashable, Sendable {
    fileprivate let id: UInt64
}

// MARK: - Payload (never leaves this file)

fileprivate enum ClipboardPayload: Sendable {
    case text(String)
    case richText(rtf: Data, plain: String)
    case url(String)
    case fileURLs([String])
    /// Nothing retained: an image, or an item over the per-entry cap. The
    /// entry exists and its metadata is real, but it cannot be put back.
    case notRetained

    var retainedBytes: Int {
        switch self {
        case .text(let s):            return s.utf8.count
        case .richText(let d, let p): return d.count + p.utf8.count
        case .url(let s):             return s.utf8.count
        case .fileURLs(let a):        return a.reduce(0) { $0 + $1.utf8.count + 8 }
        case .notRetained:            return 0
        }
    }
}

// MARK: - The engine

/// ============================================================================
/// THE ONE OBJECT THE ISLAND TALKS TO.
///
///     // once, from main, out of IslandModel.start():
///     ClipboardEngine.shared.start()
///
///     // from MetricsEngine's EXISTING serial queue, once per 1 Hz tick:
///     ClipboardEngine.shared.poll()
///
///     // main thread, from ClipboardFeature:
///     let token = ClipboardEngine.shared.observe { entries, stats in ... }
///     ClipboardEngine.shared.recopy(id: someID)
///     ClipboardEngine.shared.clearHistory()
///
/// `entries`, `stats`, `observe`, `remove`, `recopy` and `clearHistory`
/// are MAIN-THREAD-ONLY. `poll()` is SAMPLING-QUEUE-ONLY and was verified
/// never to run on main across every tick of a 180 s run.
///
/// The canonical history lives behind `lock`, not behind a queue, so the
/// engine can be driven by a queue it does NOT own (MetricsEngine's) while
/// still serving the main thread. Contention is nil in practice: one
/// ~30 us critical section per second, plus whatever the user clicks.
///
/// ONE KNOWN STALL RISK, stated rather than hidden: reading a payload the
/// owning app supplied LAZILY means a synchronous IPC round trip into that
/// app. If its main thread is wedged, our read blocks with it — and since
/// we share MetricsEngine's queue, that would delay a tick. It only
/// applies on a real copy, the samplers divide by their own measured dt so
/// a late tick self-corrects rather than lying, and the alternative (our
/// own queue) buys a permanent extra timer to insure against a rare event.
/// If it ever bites, the fix is a dedicated queue, not a cadence change.
/// ============================================================================
final class ClipboardEngine {

    static let shared = ClipboardEngine()

    // MARK: - Budget
    //
    // Two hard caps, because either one alone is exploitable.
    //
    //   entries only  -> 100 x a 40 MB copied log file = 4 GB.
    //   bytes only    -> 2 MB of 12-byte copies = 170 000 entries, whose
    //                    per-entry Swift overhead dwarfs the payload.
    //
    // Numbers, and why these numbers, on an 8 GB machine with chronic
    // memory pressure — which is the machine MacPulse exists to watch, so
    // the monitor must not become the problem it reports.
    enum Budget {
        /// 100 entries. The panel shows 6 rows; 100 is more history than
        /// anyone scrolls in a session, and at the typical ~200 byte text
        /// copy the whole history is ~20 KB.
        static let maxEntries = 100

        /// 2 MiB of retained payload, total. 0.025% of this machine's
        /// 8 GB, i.e. below the noise floor of the memory graph MacPulse
        /// itself draws. In normal use the byte cap never bites and the
        /// entry cap is what rules.
        static let maxRetainedBytes = 2 * 1024 * 1024        // 2_097_152

        /// 128 KiB per entry. ~131 000 characters, about 30 pages of
        /// prose — larger than any realistic "copy a snippet". Anything
        /// bigger is recorded as metadata + preview with the payload
        /// dropped, so ONE pathological copy can neither blow the total
        /// budget nor evict the whole history behind it.
        static let payloadBytesPerEntry = 128 * 1024          // 131_072

        /// Preview length. Bounds a dropped-payload entry to ~120 bytes,
        /// so even 100 of them cost ~12 KB.
        static let previewCharacters = 120

        /// De-dup fingerprint covers the length plus at most this many
        /// leading bytes. Hashing a 40 MB paste end to end at 1 Hz is
        /// pointless; a missed de-dup is a duplicate row, not a leak.
        static let fingerprintBytes = 1 * 1024 * 1024         // 1_048_576

        /// Refuse to even parse an image header above this. A 64 MiB
        /// screenshot is already absurd; above it the entry is recorded
        /// with `pixelWidth == nil` — "could not measure" — rather than
        /// spending the memory.
        static let imageInspectBytes = 64 * 1024 * 1024
    }

    // MARK: - The secret filter
    //
    // DENY LIST, NOT AN ALLOW LIST, and that is the known structural
    // weakness: a password manager that does not follow the
    // nspasteboard.org convention leaks into history. `isPaused`,
    // `addBlockedTypes` and `setExcludedSourceApplications` are the escape
    // hatches, and the panel says so in words rather than pretending the
    // list is complete.
    //
    // Everything in `concealedMarkerTypes` was observed in the spike, and
    // the four agilebits strings are present verbatim in the shipped
    // binary of the 1Password 7 installed on this machine
    // (OnePasswordCommon.framework), adjacent in the string table to
    // OPSecurePasteboard and beginTimerForClearingPasteboard.

    /// Presence of ANY of these means "this is a secret". The payload is
    /// never read.
    ///
    /// ORDERED, not a Set, and the order is load-bearing: it is the order
    /// the item is tested in, so `ClipboardSkipReason.concealed(markerType:)`
    /// names the same marker every time for the same item. A Set made that
    /// string depend on hash order, which turned a diagnostic into a coin
    /// flip. The canonical nspasteboard.org marker is first because it is
    /// the one worth showing a user.
    static let concealedMarkerTypes: [String] = [
        "org.nspasteboard.ConcealedType",       // the nspasteboard.org convention; 1Password 7 writes it
        "com.agilebits.onepassword",            // 1Password's own type
        "com.agilebits.onepassword.metadata",
        "com.agilebits.onepassword.entropy",
        "com.agilebits.onepassword.totp",
        "net.antelle.keeweb",                   // KeeWeb
        "com.apple.is-sensitive",               // Apple's own sensitivity marker
    ]

    /// Presence of ANY of these means "transient / machine-generated".
    /// Deliberately SEPARATE from the secret markers: a text expander's
    /// scratch write is not a password and the panel must not count it as
    /// one. Ordered for the same reason as above.
    static let transientMarkerTypes: [String] = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "de.petermaurer.TransientPasteboardType",   // legacy transient convention
        "Pasteboard generator type",                // legacy transient convention (yes, with spaces)
        "com.typeit4me.clipping",                   // TypeIt4Me
    ]

    /// The provenance marker. A plain string like "1Password 7". Read
    /// AFTER the secret filter has already passed, and only ever used for
    /// display and exclusion.
    fileprivate static let sourceMarkerType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    // MARK: - Main-thread state

    /// History, newest first. MAIN THREAD ONLY.
    private(set) var entries: [ClipboardEntry] = []
    /// Session counters. MAIN THREAD ONLY.
    private(set) var stats = ClipboardStats()

    private var observers: [ClipboardObserverToken: ([ClipboardEntry], ClipboardStats) -> Void] = [:]
    private var nextObserverID: UInt64 = 1
    /// Highest publish sequence already applied on main.
    private var appliedSequence: UInt64 = 0

    // MARK: - Shared state (behind `lock`)

    private let lock = NSLock()
    private var store: [ClipboardEntry] = []          // newest first
    private var liveStats = ClipboardStats()
    private var lastChangeCount: Int?
    /// changeCount produced by our own `recopy`, so the next poll does not
    /// re-ingest what we just wrote.
    private var suppressedChangeCount: Int?
    private var nextEntryID: UInt64 = 1
    private var paused = false
    private var extraBlockedTypes: Set<String> = []
    private var excludedSources: Set<String> = []     // lowercased
    /// Monotonic publish sequence. A snapshot handed to main from the
    /// sampling queue arrives asynchronously; a main-thread action
    /// (`clearHistory`, `recopy`) publishes synchronously. Without this
    /// counter an in-flight async snapshot taken BEFORE the clear would
    /// land AFTER it and resurrect the history on screen. Stale snapshots
    /// are dropped.
    private var publishSequence: UInt64 = 0

    private let pasteboard: NSPasteboard

    /// `shared` uses `NSPasteboard.general`. The initialiser takes a
    /// pasteboard so a harness can drive a PRIVATE named pasteboard
    /// instead of clobbering the user's real clipboard — that is not
    /// hypothetical tidiness: an earlier spike of this feature destroyed
    /// the contents of this machine's clipboard, and this parameter is how
    /// the behaviour proof avoids doing it again.
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    // MARK: - Lifecycle

    /// Take the baseline `changeCount` so the item already sitting on the
    /// clipboard at launch is NOT retroactively captured. Call from main.
    /// Idempotent.
    func start() {
        let current = pasteboard.changeCount
        lock.lock()
        if lastChangeCount == nil {
            lastChangeCount = current
            liveStats.lastChangeCount = current
        }
        let snapshot = refreshTotalsLocked()
        lock.unlock()
        publish(snapshot)
    }

    // MARK: - Configuration (any thread)

    /// Private mode. While true the engine still tracks `changeCount` (so
    /// it does not ingest a backlog when un-paused) but records nothing.
    /// This is the user-facing answer to "the deny list is a deny list".
    var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paused }
        set { lock.lock(); paused = newValue; lock.unlock() }
    }

    /// Extra pasteboard types to treat as secrets, on top of
    /// `concealedMarkerTypes`. For a manager whose marker we learn about
    /// without shipping a new build. Nothing calls it today; it is kept
    /// because deleting the lever would not make the deny list any less of
    /// a deny list.
    func addBlockedTypes(_ types: Set<String>) {
        lock.lock(); extraBlockedTypes.formUnion(types); lock.unlock()
    }

    /// Never record anything whose `org.nspasteboard.source` marker
    /// matches one of these (case-insensitive). The convention's only
    /// app-level lever — and it only fires for writers that set the marker
    /// at all, which the spike never observed a real app doing.
    func setExcludedSourceApplications(_ names: Set<String>) {
        let lowered = Set(names.map { $0.lowercased() })
        lock.lock(); excludedSources = lowered; lock.unlock()
    }

    // MARK: - THE SAMPLE PATH
    //
    // Call once per tick from ONE serial queue. Never from main.

    /// Returns true if this tick produced a new history entry.
    @discardableResult
    func poll() -> Bool {
        // 0.64 us. This is the WHOLE cost on the overwhelming majority of
        // ticks, because the clipboard has not moved.
        let change = pasteboard.changeCount

        lock.lock()
        let seen = lastChangeCount
        let suppressed = suppressedChangeCount
        let isPausedNow = paused
        // Built-ins first, in their declared order; user additions after,
        // sorted, so the reported marker is deterministic either way.
        let blocked = ClipboardEngine.concealedMarkerTypes + extraBlockedTypes.sorted()
        let excluded = excludedSources
        lock.unlock()

        // First poll before `start()`: adopt the baseline, capture nothing.
        guard let seen else {
            lock.lock()
            lastChangeCount = change
            liveStats.lastChangeCount = change
            let s = refreshTotalsLocked()
            lock.unlock()
            publish(s)
            return false
        }
        guard change != seen else { return false }

        if change == suppressed {
            finish(change, reason: .selfWrite, countChange: false)
            return false
        }
        if isPausedNow {
            finish(change, reason: .paused)
            return false
        }

        // ---- TYPES FIRST. The payload is not touched until this passes.
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            // A change with no items is "could not measure", not "the
            // clipboard is empty".
            finish(change, reason: .unreadable)
            return false
        }

        // Union across ALL items, not just the first. A multi-item write
        // where item[1] is the concealed one must still be refused.
        var typeNames = Set<String>()
        for item in items { for t in item.types { typeNames.insert(t.rawValue) } }

        if let marker = blocked.first(where: { typeNames.contains($0) }) {
            // >>> THE IMPORTANT LINE. We return here having called
            // >>> `types` and nothing else. `data(forType:)` was never
            // >>> invoked, so the secret never entered this process.
            finish(change, reason: .concealed(markerType: marker))
            return false
        }
        if let marker = ClipboardEngine.transientMarkerTypes.first(where: { typeNames.contains($0) }) {
            finish(change, reason: .transient(markerType: marker))
            return false
        }

        // Provenance marker: a short plain string, not a payload. Read
        // only after the item has already passed the secret filter.
        let source = items.first.flatMap { $0.string(forType: ClipboardEngine.sourceMarkerType) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let source, excluded.contains(source.lowercased()) {
            finish(change, reason: .excludedApplication(source))
            return false
        }

        // ---- Only now do we read anything.
        guard let candidate = readCandidate(items: items, typeNames: typeNames, source: source) else {
            finish(change, reason: .unsupportedTypes)
            return false
        }

        return insert(candidate, change: change)
    }

    // MARK: - Reading

    /// Everything needed to build an entry, built without retaining more
    /// than the budget allows.
    private struct Candidate {
        var kind: ClipboardItemKind
        var preview: String
        var byteCount: Int?
        var payload: ClipboardPayload
        var fingerprint: UInt64
        var source: String?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var fileCount: Int?
    }

    private func readCandidate(items: [NSPasteboardItem],
                               typeNames: Set<String>,
                               source: String?) -> Candidate? {

        // ORDER MATTERS. A Finder file copy also carries a string; a
        // Safari link copy carries public.url AND a string; a screenshot
        // carries tiff AND png. Most specific first.

        // --- files -------------------------------------------------------
        if typeNames.contains(ClipboardTypes.fileURL) {
            var paths: [String] = []
            for item in items {
                if let s = item.string(forType: NSPasteboard.PasteboardType(ClipboardTypes.fileURL)),
                   let url = URL(string: s) {
                    paths.append(url.path)          // never touches the filesystem
                }
            }
            guard !paths.isEmpty else { return nil }
            let names = paths.map { ($0 as NSString).lastPathComponent }
            let preview: String
            if names.count == 1 { preview = names[0] }
            else if names.count <= 3 { preview = names.joined(separator: ", ") }
            else { preview = names.prefix(2).joined(separator: ", ") + " + \(names.count - 2)" }
            let joined = paths.joined(separator: "\n")
            return Candidate(kind: .fileURLs,
                             preview: ClipboardFmt.oneLine(preview),
                             byteCount: joined.utf8.count,
                             payload: .fileURLs(paths),
                             fingerprint: ClipboardEngine.fingerprint(of: Data(joined.utf8)),
                             source: source,
                             pixelWidth: nil, pixelHeight: nil,
                             fileCount: paths.count)
        }

        // --- image -------------------------------------------------------
        // Pick the SMALLEST likely representation. A macOS screenshot puts
        // both public.png and public.tiff on the pasteboard and the TIFF is
        // routinely 8-20x the PNG (measured 62x on one real screenshot-
        // shaped image, 253x on another). Reading the PNG instead of the
        // TIFF is the difference between a 400 KB transient and an 8 MB one
        // on a machine with 8 GB.
        if let imageType = ClipboardTypes.imagePreferenceOrder.first(where: { typeNames.contains($0) }) {
            // The data is read, measured, and DROPPED at the end of this
            // autoreleasepool. It is never stored. This is the one place
            // the engine touches a large allocation, and it is transient by
            // construction.
            var result: Candidate?
            autoreleasepool {
                guard let data = items.first?.data(forType: NSPasteboard.PasteboardType(imageType)) else {
                    // Present in `types` but unreadable: record the fact,
                    // with byteCount nil = could not measure.
                    result = Candidate(kind: .image,
                                       preview: "",
                                       byteCount: nil,
                                       payload: .notRetained,
                                       fingerprint: 0,
                                       source: source,
                                       pixelWidth: nil, pixelHeight: nil, fileCount: nil)
                    return
                }
                var w: Int?
                var h: Int?
                if data.count <= Budget.imageInspectBytes {
                    // NSBitmapImageRep parses the header to answer
                    // pixelsWide/pixelsHigh. It is AppKit, so it adds NO
                    // framework to the link line — ImageIO/CGImageSource
                    // would have meant editing build.sh, which is not ours
                    // to edit.
                    if let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                        w = rep.pixelsWide
                        h = rep.pixelsHigh
                    }
                }
                // The preview is the DIMENSIONS only; the size column is
                // formatted from `byteCount` by the island, with `UIFmt`,
                // like every other byte count in the app.
                result = Candidate(kind: .image,
                                   preview: (w != nil && h != nil) ? "\(w!) x \(h!)" : "",
                                   byteCount: data.count,
                                   payload: .notRetained,     // <-- the whole point
                                   fingerprint: ClipboardEngine.fingerprint(of: data),
                                   source: source,
                                   pixelWidth: w, pixelHeight: h, fileCount: nil)
            }
            return result
        }

        // --- URL ---------------------------------------------------------
        if typeNames.contains(ClipboardTypes.url),
           let s = items.first?.string(forType: NSPasteboard.PasteboardType(ClipboardTypes.url)),
           !s.isEmpty {
            // Inert string. Never fetched. See the no-networking note at
            // the top of the file.
            return Candidate(kind: .url,
                             preview: ClipboardFmt.oneLine(s),
                             byteCount: s.utf8.count,
                             payload: retainable(s.utf8.count) ? .url(s) : .notRetained,
                             fingerprint: ClipboardEngine.fingerprint(of: Data(s.utf8)),
                             source: source,
                             pixelWidth: nil, pixelHeight: nil, fileCount: nil)
        }

        // --- rich text ---------------------------------------------------
        // RTF is flattened to plain text for the preview AND kept as RTF so
        // a re-copy preserves formatting. NOTE: public.html is deliberately
        // NOT parsed — NSAttributedString's HTML importer runs WebKit and
        // is main-thread-only, and this code runs on a sampling queue. An
        // HTML-only item falls through to plain text or to
        // `unsupportedTypes`.
        for rtfType in ClipboardTypes.richTextPreferenceOrder where typeNames.contains(rtfType) {
            guard let data = items.first?.data(forType: NSPasteboard.PasteboardType(rtfType)) else { continue }
            let plain: String?
            if rtfType == ClipboardTypes.rtfd {
                plain = NSAttributedString(rtfd: data, documentAttributes: nil)?.string
            } else {
                plain = NSAttributedString(rtf: data, documentAttributes: nil)?.string
            }
            guard let plain, !plain.isEmpty else { continue }
            let retained = retainable(data.count + plain.utf8.count)
            return Candidate(kind: .richText,
                             preview: ClipboardFmt.oneLine(plain),
                             byteCount: data.count,
                             payload: retained ? .richText(rtf: data, plain: plain) : .notRetained,
                             fingerprint: ClipboardEngine.fingerprint(of: data),
                             source: source,
                             pixelWidth: nil, pixelHeight: nil, fileCount: nil)
        }

        // --- plain text --------------------------------------------------
        for textType in ClipboardTypes.textPreferenceOrder where typeNames.contains(textType) {
            guard let s = items.first?.string(forType: NSPasteboard.PasteboardType(textType)) else { continue }
            let bytes = s.utf8.count
            // An empty string IS a measured zero, not a failure. It is also
            // not worth a history row.
            guard bytes > 0 else { continue }
            return Candidate(kind: .text,
                             preview: ClipboardFmt.oneLine(s),
                             byteCount: bytes,
                             payload: retainable(bytes) ? .text(s) : .notRetained,
                             fingerprint: ClipboardEngine.fingerprint(of: Data(s.utf8)),
                             source: source,
                             pixelWidth: nil, pixelHeight: nil, fileCount: nil)
        }

        return nil
    }

    private func retainable(_ bytes: Int) -> Bool { bytes <= Budget.payloadBytesPerEntry }

    // MARK: - Insert / evict

    private func insert(_ c: Candidate, change: Int) -> Bool {
        lock.lock()

        // De-duplication. Matching against the WHOLE history and PROMOTING
        // is a strict superset of "consecutive identical copies", and it is
        // also what makes `recopy` behave like every other clipboard
        // manager: the thing you just re-copied becomes the newest row, not
        // a second row.
        if c.fingerprint != 0,
           let idx = store.firstIndex(where: { $0.fingerprint == c.fingerprint && $0.kind == c.kind }) {
            var promoted = store.remove(at: idx)
            promoted = ClipboardEntry(id: promoted.id,
                                      kind: promoted.kind,
                                      preview: promoted.preview,
                                      byteCount: promoted.byteCount,
                                      retainedBytes: promoted.retainedBytes,
                                      capturedAt: Date(),
                                      sourceApplication: promoted.sourceApplication,
                                      pixelWidth: promoted.pixelWidth,
                                      pixelHeight: promoted.pixelHeight,
                                      fileCount: promoted.fileCount,
                                      canRecopy: promoted.canRecopy,
                                      payload: promoted.payload,
                                      fingerprint: promoted.fingerprint)
            store.insert(promoted, at: 0)
            liveStats.deduplicated += 1
            liveStats.changesObserved += 1
            lastChangeCount = change
            liveStats.lastChangeCount = change
            liveStats.lastSkipReason = .duplicate
            let snapshot = refreshTotalsLocked()
            lock.unlock()
            publish(snapshot)
            return false
        }

        let preview = String(c.preview.prefix(Budget.previewCharacters))
        let entry = ClipboardEntry(id: nextEntryID,
                                   kind: c.kind,
                                   preview: preview,
                                   byteCount: c.byteCount,
                                   retainedBytes: c.payload.retainedBytes + preview.utf8.count,
                                   capturedAt: Date(),
                                   sourceApplication: c.source,
                                   pixelWidth: c.pixelWidth,
                                   pixelHeight: c.pixelHeight,
                                   fileCount: c.fileCount,
                                   canRecopy: {
                                       if case .notRetained = c.payload { return false }
                                       return true
                                   }(),
                                   payload: c.payload,
                                   fingerprint: c.fingerprint)
        nextEntryID += 1
        store.insert(entry, at: 0)
        evictLocked()

        liveStats.captured += 1
        liveStats.changesObserved += 1
        lastChangeCount = change
        liveStats.lastChangeCount = change
        liveStats.lastSkipReason = nil
        let snapshot = refreshTotalsLocked()
        lock.unlock()
        publish(snapshot)
        return true
    }

    /// Oldest-out until BOTH caps hold. Must be called with `lock` held.
    /// MEASURED worst case: 100 forced max-size entries settle at 15
    /// entries / 1.9 MB retained.
    private func evictLocked() {
        while store.count > Budget.maxEntries {
            store.removeLast()
            liveStats.evicted += 1
        }
        var total = store.reduce(0) { $0 + $1.retainedBytes }
        while total > Budget.maxRetainedBytes, store.count > 1 {
            total -= store.removeLast().retainedBytes
            liveStats.evicted += 1
        }
    }

    /// Immutable hand-off to main.
    private struct Snapshot {
        let entries: [ClipboardEntry]
        let stats: ClipboardStats
        let sequence: UInt64
    }

    /// Recompute the derived totals and return a snapshot. `lock` held.
    private func refreshTotalsLocked() -> Snapshot {
        liveStats.entryCount = store.count
        liveStats.retainedBytes = store.reduce(0) { $0 + $1.retainedBytes }
        publishSequence += 1
        return Snapshot(entries: store, stats: liveStats, sequence: publishSequence)
    }

    /// Record a non-capturing outcome and publish.
    private func finish(_ change: Int, reason: ClipboardSkipReason, countChange: Bool = true) {
        lock.lock()
        lastChangeCount = change
        liveStats.lastChangeCount = change
        liveStats.lastSkipReason = reason
        if countChange { liveStats.changesObserved += 1 }
        switch reason {
        case .concealed:            liveStats.skippedSecrets += 1
        case .transient:            liveStats.skippedTransient += 1
        case .excludedApplication:  liveStats.skippedExcluded += 1
        case .unsupportedTypes:     liveStats.skippedUnsupported += 1
        default:                    break
        }
        let snapshot = refreshTotalsLocked()
        lock.unlock()
        publish(snapshot)
    }

    // MARK: - Publishing to main

    private func publish(_ snapshot: Snapshot) {
        let apply = { [weak self] in
            guard let self else { return }
            // Drop a snapshot taken before one we already applied.
            guard snapshot.sequence > self.appliedSequence else { return }
            self.appliedSequence = snapshot.sequence
            self.entries = snapshot.entries
            self.stats = snapshot.stats
            for block in self.observers.values { block(snapshot.entries, snapshot.stats) }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    // MARK: - Subscription (main thread)

    @discardableResult
    func observe(_ block: @escaping ([ClipboardEntry], ClipboardStats) -> Void) -> ClipboardObserverToken {
        precondition(Thread.isMainThread, "ClipboardEngine.observe must be called from the main thread")
        let token = ClipboardObserverToken(id: nextObserverID)
        nextObserverID += 1
        observers[token] = block
        block(entries, stats)          // don't make a new subscriber wait a tick
        return token
    }

    func remove(_ token: ClipboardObserverToken) {
        precondition(Thread.isMainThread)
        observers.removeValue(forKey: token)
    }

    // MARK: - Actions (main thread)

    /// Put an entry back on the pasteboard.
    ///
    /// Returns false — and writes NOTHING — when the payload was not
    /// retained (an image, or an item over the per-entry cap) or the entry
    /// is no longer in history. It deliberately never puts a truncated body
    /// on the clipboard: silently pasting half of something is worse than
    /// refusing. The section draws such rows unclickable so the refusal is
    /// visible before the click, not after it.
    ///
    /// The write bumps `changeCount`; that value is suppressed so the next
    /// poll does not re-ingest our own write. The entry is promoted to the
    /// front here, synchronously, instead.
    @discardableResult
    func recopy(id: UInt64) -> Bool {
        precondition(Thread.isMainThread, "ClipboardEngine.recopy must be called from the main thread")
        lock.lock()
        guard let idx = store.firstIndex(where: { $0.id == id }) else { lock.unlock(); return false }
        let payload = store[idx].payload
        lock.unlock()

        let written: Bool
        switch payload {
        case .notRetained:
            return false
        case .text(let s):
            pasteboard.clearContents()
            written = pasteboard.setString(s, forType: .string)
        case .url(let s):
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(s, forType: NSPasteboard.PasteboardType(ClipboardTypes.url))
            item.setString(s, forType: .string)
            written = pasteboard.writeObjects([item])
        case .richText(let rtf, let plain):
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(rtf, forType: .rtf)
            item.setString(plain, forType: .string)
            written = pasteboard.writeObjects([item])
        case .fileURLs(let paths):
            pasteboard.clearContents()
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            written = urls.isEmpty ? false : pasteboard.writeObjects(urls)
        }

        let produced = pasteboard.changeCount
        lock.lock()
        // ONLY the suppression marker. Deliberately NOT `lastChangeCount`:
        // poll() early-returns when `change == lastChangeCount`, so moving
        // it here would skip the `.selfWrite` branch and leave the
        // suppression marker armed for a later, unrelated change.
        suppressedChangeCount = produced
        if written, let i = store.firstIndex(where: { $0.id == id }) {
            var e = store.remove(at: i)
            e = ClipboardEntry(id: e.id, kind: e.kind, preview: e.preview, byteCount: e.byteCount,
                               retainedBytes: e.retainedBytes, capturedAt: Date(),
                               sourceApplication: e.sourceApplication,
                               pixelWidth: e.pixelWidth, pixelHeight: e.pixelHeight,
                               fileCount: e.fileCount, canRecopy: e.canRecopy,
                               payload: e.payload, fingerprint: e.fingerprint)
            store.insert(e, at: 0)
        }
        let snapshot = refreshTotalsLocked()
        lock.unlock()
        publish(snapshot)
        return written
    }

    /// Drop everything. The session counters survive — they are the honest
    /// record of what the engine did, and "3 secrets skipped" is not
    /// something clearing the history should erase.
    ///
    /// This does NOT touch the system clipboard: clearing MacPulse's
    /// history must not yank what the user has in hand.
    func clearHistory() {
        precondition(Thread.isMainThread, "ClipboardEngine.clearHistory must be called from the main thread")
        lock.lock()
        store.removeAll()
        liveStats.lastSkipReason = nil
        let snapshot = refreshTotalsLocked()
        lock.unlock()
        publish(snapshot)
    }

    // MARK: - Fingerprint

    /// FNV-1a over the length plus the first `Budget.fingerprintBytes`.
    ///
    /// NOT a security primitive and not meant to be one: it exists only so
    /// that copying the same thing twice does not produce two rows. It is
    /// also why no cryptographic framework is linked — CryptoKit would have
    /// meant a new `-framework` flag, and build.sh's otool assertion exists
    /// precisely to keep that link map short. A collision costs a missed
    /// history row and nothing else.
    fileprivate static func fingerprint(of data: Data) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x1000_0000_01b3
        // Fold the true length in first, so two different-length items
        // sharing a 1 MiB prefix still differ.
        var len = UInt64(data.count)
        for _ in 0..<8 { h = (h ^ (len & 0xff)) &* prime; len >>= 8 }
        let n = min(data.count, Budget.fingerprintBytes)
        data.prefix(n).withUnsafeBytes { raw in
            for b in raw { h = (h ^ UInt64(b)) &* prime }
        }
        return h == 0 ? 1 : h       // 0 is reserved for "no fingerprint"
    }
}

// MARK: - Pasteboard type names

/// Raw UTI strings, in one place. Written out rather than using the
/// `NSPasteboard.PasteboardType` constants because the filter compares
/// against `Set<String>` and half of these (public.jpeg,
/// com.compuserve.gif) have no AppKit constant anyway.
enum ClipboardTypes {
    static let utf8Text  = "public.utf8-plain-text"
    static let plainText = "public.plain-text"
    static let utf16Text = "public.utf16-external-plain-text"
    static let rtf       = "public.rtf"
    static let rtfd      = "public.rtfd"
    static let url       = "public.url"
    static let fileURL   = "public.file-url"
    static let tiff      = "public.tiff"
    static let png       = "public.png"
    static let jpeg      = "public.jpeg"
    static let gif       = "com.compuserve.gif"
    static let heic      = "public.heic"

    /// SMALLEST-FIRST. A macOS screenshot writes png AND tiff; the tiff is
    /// uncompressed and routinely 8-20x larger. Reading the png keeps the
    /// transient allocation small on an 8 GB machine. MEASURED on this
    /// machine, a 600x400 screenshot-like image: png 3,791 B vs tiff
    /// 960,144 B — 253x. Only png and tiff were ever exercised; jpeg, heic
    /// and gif are listed but untested, and webp is not listed at all.
    static let imagePreferenceOrder = [png, jpeg, heic, gif, tiff]
    /// Only public.rtf was exercised; public.rtfd is listed but untested.
    static let richTextPreferenceOrder = [rtf, rtfd]
    static let textPreferenceOrder = [utf8Text, plainText, utf16Text]
}

// MARK: - Preview sanitiser

/// The one formatting job that belongs to the ENGINE rather than to the
/// island: collapsing a copied blob to a bounded single line is what keeps
/// a dropped-payload entry down to ~120 bytes, so it is part of the budget,
/// not part of the presentation. Everything else — byte counts, times,
/// kind labels — is formatted by IslandSectionClipboard.swift with the
/// app's own `UIFmt`.
enum ClipboardFmt {

    /// Collapse a copied blob to one displayable line. Newlines, tabs and
    /// runs of spaces become a single space; the result is trimmed and
    /// truncated with a real ellipsis.
    static func oneLine(_ s: String, limit: Int = ClipboardEngine.Budget.previewCharacters) -> String {
        var out = String()
        out.reserveCapacity(min(s.count, limit + 1))
        var lastWasSpace = false
        for ch in s {
            let isSpace = ch.isWhitespace || ch.isNewline
            if isSpace {
                if !lastWasSpace && !out.isEmpty { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
            if out.count >= limit { return out.trimmingCharacters(in: .whitespaces) + "\u{2026}" }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

// =====================================================================
// WHY THERE IS NO PERSISTENCE HERE — read before adding any.
//
// This engine holds history in RAM and loses it on quit. That is a
// decision, not an omission. A clipboard-history FILE is a
// plaintext-secrets-at-rest artifact: every deny-list miss (see
// `concealedMarkerTypes` — it IS a deny list, so a password manager that
// ignores the nspasteboard.org convention WILL land in history) becomes
// permanent instead of dying with the process, and MacPulse's
// no-networking contract protects none of it, because the threat is
// anything that can read the user's home directory.
//
// If persistence is ever wanted, the minimum honest bar is:
//   1. Keys in the login Keychain (kSecClassGenericPassword,
//      kSecAttrAccessibleWhenUnlockedThisDeviceOnly), never in a file
//      beside the data. That means linking Security.framework — which
//      build.sh's otool assertion FORBIDS, so it is a contract change,
//      not a feature.
//   2. AEAD, not a cipher: CryptoKit ChaChaPoly/AES-GCM with a per-record
//      nonce. A second new framework, and a second contract change.
//   3. A retention policy with teeth (age-out AND count-out), a visible
//      wipe control, and wipe-on-lock.
//   4. 0600 in Application Support, excluded from Time Machine and from
//      any sync folder, and NOT in ~/Library/Caches — the one directory
//      this app is allowed to delete from, which is exactly why it is the
//      wrong place to put secrets.
// Until all four exist, in-memory is the safer product.
// =====================================================================

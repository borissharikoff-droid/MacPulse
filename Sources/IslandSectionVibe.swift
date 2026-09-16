import AppKit
import SwiftUI

// =====================================================================
// «Сессия» — the AI-coding session the user is in right now, read from
// ONE LOCAL FILE: ~/.vibehub/status.json.
//
// VibeHub (github.com/EmilSwag/vibehub) is "Steam for people who ship
// with an AI pair". Its tracker runs on this machine and leaves a small
// JSON snapshot behind:
//
//     {"status":"offline","projectAlias":null,"tool":null,"model":null,
//      "sessionStartedAt":null,"updatedAt":"2026-09-05T20:29:40.485Z"}
//
// When a session is live those fields carry the project alias, the tool
// (Cursor, Claude Code, Codex), the model, and when the session began.
// This section shows four facts and stops: project, tool, model, and how
// long it has been running.
//
// ---------------------------------------------------------------------
// WHY THIS READS A FILE AND NEVER TALKS TO THEIR SERVER.
//
// There is a second, richer source: ~/.vibehub/config.json holds an
// apiUrl and a deviceToken, and VibeHub's own menubar app polls
// /api/v1/tracker/me with that token. WE DO NOT, for three reasons, and
// each of them is sufficient on its own:
//
//   1. MacPulse is allowed exactly TWO networking hosts — Updater.swift
//      to GitHub, GeoLookup.swift to www.cloudflare.com — and build.sh
//      enforces that with a per-file host allow-list. A third host is
//      not something this file gets to decide; the build would refuse it
//      and it would be right to.
//
//   2. VibeHub ALREADY SHIPS a feature-complete menubar app that does
//      exactly that polling. Writing a worse second copy of somebody
//      else's finished product is not a feature.
//
//   3. THE deviceToken IS A CREDENTIAL. This file never reads, copies,
//      logs or displays it. It does not open config.json at all — not to
//      check that it exists, not to read apiUrl. The only path this
//      feature ever touches is `~/.vibehub/status.json`.
//
// ---------------------------------------------------------------------
// WHY THE COMBINATION IS WORTH ANYTHING: MacPulse knows WHY the machine
// is slow; VibeHub knows WHAT the user was doing. Joined locally, the
// footer can say what neither could alone — two hours into a project in
// Cursor, while the machine sits at warning pressure.
//
// ---------------------------------------------------------------------
// STALENESS IS THE WHOLE PROBLEM, AND `status` DOES NOT SOLVE IT.
//
// The file is a SNAPSHOT A DORMANT TRACKER LEFT BEHIND. On this machine
// it says "offline" and was last written eleven days ago. A `status`
// field is only trustworthy while something is maintaining it; a tracker
// that was SIGKILLed mid-session leaves "online" behind for ever, and a
// section that cheerfully renders an eleven-day-old session is worse
// than no section at all.
//
// So freshness is decided from the CLOCK, not from `status`:
//
//     FRESHNESS WINDOW = 120 SECONDS.
//
// Why 120 and not 10 or 3600. The claim this section makes on screen is
// "you are in a session AT THIS MOMENT" — present tense — so the window
// has to be short enough that the claim is still true and long enough
// that a live session never blinks. Two minutes is the point where those
// meet: a heartbeat that cannot refresh within two minutes is no longer
// describing now (the lid closed, the editor quit, the tracker died),
// while two minutes still absorbs a tracker on a 30 s or 60 s heartbeat
// missing a beat or two, plus this section's own 10 s sampling period.
// The tracker's real cadence is not documented and this file does not
// guess at it — 120 s is chosen from what the READER can defend, which
// is the only thing it is entitled to reason about.
//
// AGE IS THE OLDER OF TWO CLOCKS, deliberately:
//
//     age = max(now - updatedAt, now - mtime)
//
// `updatedAt` is the authority on when the writer THINKS it wrote, but a
// file cannot have been updated without its mtime moving, so an old
// mtime beats a fresh-looking `updatedAt` (a copied or hand-edited
// file). And a touched-but-unchanged file has a fresh mtime and a stale
// `updatedAt`, so the content beats the mtime there. Taking the max is
// strictly the more conservative of the two.
//
// A timestamp FROM THE FUTURE by more than the same 120 s is clock skew
// or a fabrication, and is treated as no state rather than as maximally
// fresh — the one direction where being generous invents a session.
//
// hasState is therefore FALSE when: the file is absent (which is most
// machines — nobody without VibeHub should ever see a chip, an empty tab
// or anything else), unreadable, not a regular file, too big, malformed,
// stale, skewed, quiet by `status`, or missing the project alias or the
// start time. It is TRUE only for a fresh file describing a running
// session. See `VibeQuiet` for the exact list — every one of those is a
// distinct measured reason and none of them is an error dialog.
//
// ---------------------------------------------------------------------
// COST. One `stat(2)` every 10 s on a utility queue, and a read ONLY
// when (dev, inode, size, mtime) actually moved. On this machine the
// file last moved eleven days ago, so steady state is literally one
// stat per tick and no read at all. Measured on this machine, mean over
// 20 000 iterations of the whole tick path — stat, identity compare,
// re-derive, equality check:
//
//     unchanged file   ~1.6 us   ->  0.000016% of one core at 10 s
//     missing file     ~1.3 us   ->  0.000013% of one core at 10 s
//
// i.e. four orders of magnitude under the 1.0% idle budget, and about a
// thousandth of what publishing a value into SwiftUI costs. NOTHING runs
// on the main thread except the final compare-and-assign.
//
// ---------------------------------------------------------------------
// THE FILE IS UNTRUSTED INPUT. It is written by a separate process that
// this app does not own, ship or version. Every value is Optional, every
// string is bounded BEFORE it reaches the UI, there is not a single
// force-unwrap or trapping numeric conversion on the path, and anything
// that does not parse degrades to "no state" instead of to a crash.
//
// READ FeaturePrinter.swift's `int(_:min:max:)` BEFORE EDITING THE PARSE
// BELOW. A trapping `Int(Double)` on JSON from a LOCAL helper — same
// shape of input as this one — killed the shipping binary with SIGTRAP,
// and that is why everything numeric in this app is clamped or failable.
// This file avoids the hazard by having no numeric fields at all: the
// only numbers it computes are TimeIntervals it produced itself, and the
// one Double -> Int conversion left is `Int(exactly:)` behind a finite
// check and a range check.
//
// Two hazards that are specific to reading a path somebody else owns and
// are handled explicitly below, because neither is obvious:
//
//   * A FIFO at that path would block the read FOR EVER and take the
//     sampling queue with it. `S_ISREG` is checked before anything is
//     opened.
//   * A huge file would be read into memory in full. The read is bounded
//     at 64 KiB and the size is rejected before the open.
//
// ---------------------------------------------------------------------
// WHERE THE STATE LIVES, AND WHY IT IS NOT A @Published ON IslandModel.
//
// IslandSection.swift's fifth rule says the rail and the footer read
// IslandModel, so a feature publishing from its own ObservableObject
// leaves them stale. That rule is about STALENESS, and it is satisfied
// here without touching IslandModel: `IslandModel.refreshPanel` calls
// `refreshRouter()` on every metrics tick WHILE THE PANEL IS OPEN, and
// again the instant it opens — and the rail and the footer are the only
// two things that read `hasState`/`footerSummary`, and neither exists on
// screen while the panel is shut. So the chip and the footer clause are
// at most one 1 Hz tick behind, and never behind at the moment the panel
// appears. The BODY observes `VibeFeature` directly and updates the
// moment the state changes.
//
// That is what buys this feature ONE new file plus ONE registration
// line, which is what the router's extension point promises. If this
// ever needs to drive the COLLAPSED strip — it should not; "you are
// coding" is not a menu-bar alarm — that does need a `@Published` on
// IslandModel and `updateTrailingSlot`, and the honest move then is to
// add one, not to widen this comment.
// =====================================================================

// MARK: - The record, as parsed out of untrusted JSON

/// One parse of status.json. EVERYTHING is Optional; nil means "the file
/// did not tell us", which renders as a dash and never as a zero or a
/// fabricated value.
struct VibeRecord: Equatable {
    /// Lower-cased, bounded. nil means the key was absent or not a string.
    var status: String?
    var project: String?
    var tool: String?
    var model: String?
    var startedAt: Date?
    /// The tracker's own heartbeat stamp. The freshness window is
    /// measured from this, cross-checked against the file's mtime.
    var updatedAt: Date?

    static let empty = VibeRecord()
}

/// Why there is no session to show. Every case is a MEASURED reason, not
/// an error: all of them mean the same thing to the rail (no chip) and
/// they exist so `--vibe-probe` can say which one happened.
enum VibeQuiet: String, Equatable {
    /// No VibeHub on this machine. The overwhelmingly common case, and it
    /// must be completely invisible.
    case missing
    /// There, but not a regular file, or could not be opened/read.
    case unreadable
    /// Bigger than the read bound. A status heartbeat is ~150 bytes.
    case tooBig
    /// Not JSON, or not a JSON object at the top level.
    case malformed
    /// `status` says nothing is running (or does not say anything).
    case offline
    /// Fresh and live-looking, but missing the project alias or the start
    /// time — there is no session to name.
    case incomplete
    /// Older than the freshness window. THE CASE ON THIS MACHINE.
    case stale
    /// Stamped in the future beyond tolerance. Clock skew or a lie.
    case skewed
}

// MARK: - What the section draws

/// The four facts, already bounded and already formatted as strings.
/// Two ticks that would draw identical pixels compare equal and publish
/// nothing, which is the rule the whole island is built on.
struct VibeSession: Equatable {
    /// Bounded and non-empty by construction.
    let project: String
    /// nil renders as a dash. A session whose tool the tracker did not
    /// record is still a session.
    let tool: String?
    let model: String?
    /// "14 мин", "2 ч 14 мин", "3 д 4 ч", or nil for "we do not believe
    /// this number" — never a clamped lie.
    let duration: String?
    /// Seconds since `updatedAt` (the effective, older-of-two age).
    /// Diagnostics only; nothing draws it.
    let age: Int
}

struct VibeState: Equatable {
    /// nil is the normal state: no chip, no tab, no footer clause.
    let session: VibeSession?
    /// Why there is no session. nil exactly when there IS one — an
    /// Optional rather than a `.live` case, so a live state cannot also
    /// be carrying a reason that contradicts it.
    let reason: VibeQuiet?

    static func quiet(_ reason: VibeQuiet) -> VibeState {
        VibeState(session: nil, reason: reason)
    }
    static func live(_ session: VibeSession) -> VibeState {
        VibeState(session: session, reason: nil)
    }
}

// MARK: - The reader

/// Stat, bounded read, defensive parse, and the freshness verdict.
/// Everything here is a pure function of its arguments except `identity`
/// and `read`, which touch the file system and are called ONLY from the
/// watcher's own queue.
enum VibeStatusFile {

    /// The only path this feature ever touches. NOT config.json.
    static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".vibehub/status.json")
    }

    /// The real file is 153 bytes. 64 KiB is four hundred times that and
    /// still small enough that reading one costs nothing; anything above
    /// it is not a status heartbeat and is refused without being opened.
    static let maxBytes = 64 * 1024

    /// 120 s. The reasoning is in the header and belongs there, not here.
    static let freshnessWindow: TimeInterval = 120
    /// Same number in the other direction: a stamp further into the
    /// future than this is skew, and skew is not freshness.
    static let skewTolerance: TimeInterval = 120
    /// Longer than this and the "session" is a clock artefact. The
    /// duration renders as a dash rather than as a clamped number.
    static let maxSessionSeconds: TimeInterval = 30 * 24 * 3600

    /// A `status` value that means "nothing is running". Anything NOT on
    /// this list, with a fresh stamp and a real project, is taken as a
    /// session — an unrecognised status is not a reason to hide a live
    /// one, but every way of saying "no" that VibeHub might use is.
    static let quietStatuses: Set<String> = [
        "offline", "idle", "paused", "stopped", "inactive",
        "unknown", "away", "disconnected", "none", "ended"
    ]

    /// Everything a `stat(2)` tells us that could mean "the file moved".
    /// Inode and device are in here so that a replace-by-rename — which
    /// is how a careful writer updates a file atomically, and which can
    /// land with an OLDER mtime than what it replaced — is still seen as
    /// a change.
    struct Identity: Equatable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var seconds: Int
        var nanoseconds: Int
        var isRegular: Bool

        var mtime: Date {
            Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
        }
    }

    /// ONE stat(2). This is the whole steady-state cost of the feature.
    /// nil means the path is not there, which is the normal answer on a
    /// machine without VibeHub and is not an error.
    static func identity(of path: String) -> Identity? {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
        return Identity(
            device: info.st_dev,
            inode: info.st_ino,
            size: Int64(info.st_size),
            seconds: info.st_mtimespec.tv_sec,
            nanoseconds: info.st_mtimespec.tv_nsec,
            // A FIFO here would block the read for ever and take the
            // sampling queue with it. Nothing is opened unless this is a
            // plain file.
            isRegular: (info.st_mode & S_IFMT) == S_IFREG
        )
    }

    /// Bounded read. Returns nil for "could not OPEN it", which the caller
    /// turns into `.unreadable`.
    ///
    /// An empty file comes back as empty Data and NOT as nil, even though
    /// `read(upToCount:)` answers nil at EOF: a file we opened and found
    /// empty is a malformed status file, not an unreadable one. Same
    /// outcome on screen either way — no state — but `--vibe-probe` says
    /// which, and a reason that names the wrong thing is worse than no
    /// reason.
    static func read(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // Bounded at the READ, not just by the size check the caller
        // already did: the file can grow between the stat and the open,
        // and this is the bound that actually holds.
        guard let data = try? handle.read(upToCount: maxBytes) else { return Data() }
        return data
    }

    /// PARSE OF UNTRUSTED INPUT. Never traps, never force-unwraps, bounds
    /// every string before it can reach a view, and returns nil for
    /// "this is not a status file".
    static func parse(_ data: Data) -> VibeRecord? {
        guard !data.isEmpty,
              let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any] else { return nil }

        var record = VibeRecord.empty
        record.status = string(object["status"], max: 32)?.lowercased()
        // Bounds chosen to be generous for a real name and still far
        // inside what the 560 pt panel can draw; the view truncates on
        // top of this.
        record.project = string(object["projectAlias"], max: 96)
        record.tool = string(object["tool"], max: 48)
        record.model = string(object["model"], max: 64)
        record.startedAt = date(object["sessionStartedAt"])
        record.updatedAt = date(object["updatedAt"])
        return record
    }

    /// THE FRESHNESS VERDICT. A pure function of the record, the file's
    /// mtime and the current time — which is what makes it testable
    /// against a synthetic file and what `--vibe-probe` drives.
    static func derive(_ record: VibeRecord?, mtime: Date?, now: Date) -> VibeState {
        guard let record else { return .quiet(.malformed) }
        guard let updated = record.updatedAt else { return .quiet(.incomplete) }

        // Age is the OLDER of the two clocks; skew is judged on the
        // YOUNGER, so neither source can make the file look fresher than
        // it is and neither can push it into the future on its own.
        let byContent = now.timeIntervalSince(updated)
        let byFile = mtime.map { now.timeIntervalSince($0) } ?? byContent
        let age = max(byContent, byFile)
        let ahead = min(byContent, byFile)
        guard age.isFinite, ahead.isFinite else { return .quiet(.skewed) }

        if ahead < -skewTolerance { return .quiet(.skewed) }
        if age > freshnessWindow { return .quiet(.stale) }

        // Only NOW does `status` get a say, and only as a veto.
        guard let status = record.status, !quietStatuses.contains(status) else {
            return .quiet(.offline)
        }
        guard let project = record.project, let started = record.startedAt else {
            return .quiet(.incomplete)
        }

        return .live(VibeSession(
            project: project,
            tool: record.tool,
            model: record.model,
            duration: duration(now.timeIntervalSince(started)),
            age: seconds(max(0, age)) ?? 0
        ))
    }

    // MARK: Formatting

    /// "14 мин" / "2 ч 14 мин" / "3 д 4 ч", or nil.
    ///
    /// nil rather than a clamp for anything implausible: clamping a
    /// thirty-one-day "session" to thirty days would draw a number the
    /// tracker never sent, which is the exact failure the dash exists to
    /// prevent. Same reason a negative elapsed time is a dash.
    static func duration(_ elapsed: TimeInterval) -> String? {
        guard elapsed.isFinite, elapsed >= -skewTolerance, elapsed <= maxSessionSeconds else {
            return nil
        }
        guard let total = seconds(max(0, elapsed)) else { return nil }
        if total < 60 { return "<1 мин" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) мин" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%d ч %02d мин", hours, minutes % 60) }
        return "\(hours / 24) д \(hours % 24) ч"
    }

    /// The ONLY Double -> Int conversion in this file, and it is the
    /// failable one. See the header: the trapping form is what killed the
    /// shipping binary once already.
    private static func seconds(_ value: TimeInterval) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded(.down))
    }

    /// Bound the LENGTH first, then strip control characters, then trim.
    /// `prefix` comes first on purpose: a one-megabyte value costs one
    /// bounded copy and not a megabyte of filtering.
    private static func string(_ any: Any?, max: Int) -> String? {
        guard let raw = any as? String else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.prefix(max).unicodeScalars
        where !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(scalar)
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// ISO-8601. The tracker writes JavaScript's `toISOString()`, which
    /// always carries milliseconds, but the plain form is accepted too
    /// rather than rejecting a session over a formatting detail.
    ///
    /// Both formatters are used ONLY from the watcher's serial queue.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func date(_ any: Any?) -> Date? {
        guard let text = string(any, max: 40) else { return nil }
        return isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }
}

// MARK: - The watcher

/// Owns the timer, the mtime gate and the published state. One instance.
///
/// PUBLIC SURFACE IS MAIN-THREAD ONLY. Everything after `sample()` runs
/// on `queue` and touches nothing the main thread can see.
final class VibeFeature: ObservableObject {

    static let shared = VibeFeature()

    /// What the section body draws. Only the body observes this, and the
    /// body is in the view tree only while the panel is open AND this tab
    /// is selected — so a write while the panel is shut has no
    /// subscribers and costs nothing. The rail and the footer do not read
    /// it; they read `hasState`/`footerSummary`, which read this same
    /// value off the main thread's copy. See the header.
    @Published private(set) var state = VibeState.quiet(.missing)

    /// 10 s, shut or open. There is no faster "panel is open" cadence
    /// because there is nothing to speed up: the only thing that moves
    /// inside a live session is the minute counter, and a minute counter
    /// that is at most ten seconds late is not late. The same 10 s is
    /// also the worst-case lag on the chip DISAPPEARING once the file
    /// goes stale, which is why the window is 120 s and not 12.
    private let interval: TimeInterval = 10

    /// Nothing happens for this long after launch — the house rule about
    /// never doing discovery work in `didFinishLaunching`.
    private let launchDelay: TimeInterval = 8

    /// `qos: .utility`, matching every other sampler here. This is
    /// background measurement; nobody is waiting on it.
    private let queue = DispatchQueue(label: "com.local.macpulse.vibe", qos: .utility)

    private var timer: DispatchSourceTimer?
    private var running = false

    // ---- queue-confined. NEVER read from main. ----
    private var path = VibeStatusFile.defaultPath
    /// THE MTIME GATE. The file is re-read only when this changes.
    private var identity: VibeStatusFile.Identity?
    /// Last successful parse, kept so an unchanged file needs no read.
    private var record: VibeRecord?
    /// Sticky verdict for a file we could see but not use, so a malformed
    /// file is not re-read every ten seconds either.
    private var readFailure: VibeQuiet?
    private var statCount = 0
    private var readCount = 0

    // MARK: Lifecycle

    /// THE ONE LINE `IslandFeatures` CALLS. Registers the section and
    /// starts the watcher, in that order, on the main thread.
    ///
    /// It is one call rather than the canonical bare
    /// `IslandSectionRegistry.register(.vibe)` because `registerAll()` is
    /// static and is handed no `IslandModel`, and this feature — unlike
    /// the printer or the tunnel — has no setter on the model to be
    /// pushed into. Registering and starting are the same event here.
    func register() {
        precondition(Thread.isMainThread)
        IslandSectionRegistry.register(.vibe)
        start()
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !running else { return }
        running = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway: this is a staleness bound, not a clock, and
        // leeway is what lets the kernel coalesce our wakeup with
        // somebody else's instead of waking the CPU on our account.
        t.schedule(deadline: .now() + launchDelay, repeating: interval, leeway: .seconds(3))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// NOTHING IN THE APP CALLS THIS, and that is a deliberate asymmetry
    /// worth writing down rather than leaving to be discovered.
    /// `IslandFeatures.registerAll()` has no teardown counterpart —
    /// `IslandModel.stop()` stops the watchers IT owns, and it does not
    /// own this one — so between `model.stop()` and process exit this
    /// timer keeps ticking at one `stat(2)` every ten seconds. That is
    /// the same order as the registry's own sections, which are likewise
    /// never unregistered. It exists for `--vibe-probe`, and it is what
    /// `IslandModel` would call if this feature ever grows a setter
    /// there.
    func stop() {
        precondition(Thread.isMainThread)
        running = false
        timer?.cancel()
        timer = nil
    }

    /// TEST SEAM, and the only reason this class is not a `let` path.
    /// `--vibe-probe` points the REAL watcher at a temp copy so the proof
    /// drives the shipping code rather than a second implementation of
    /// it. Main thread, and it resets the mtime gate so the new path is
    /// read on the next tick.
    func setPath(_ newPath: String) {
        precondition(Thread.isMainThread)
        queue.sync {
            self.path = newPath
            self.identity = nil
            self.record = nil
            self.readFailure = nil
        }
    }

    /// One complete tick, run synchronously on the watcher's own queue and
    /// RETURNED rather than published. The timer handler uses it; so does
    /// the probe, which is how the mtime gate can be observed doing
    /// nothing.
    @discardableResult
    func sampleSynchronously(now: Date = Date()) -> VibeState {
        queue.sync { sample(now: now) }
    }

    /// (stats, reads) since launch. The read counter is the mtime gate's
    /// whole argument: it should stay at 1 on a dormant machine no matter
    /// how many times the stat counter goes up.
    var counters: (stats: Int, reads: Int) {
        queue.sync { (statCount, readCount) }
    }

    /// The footer's one short clause, or nil. Main thread.
    var footerClause: String? {
        guard let session = state.session else { return nil }
        var parts = [String(session.project.prefix(20))]
        if let tool = session.tool { parts.append(String(tool.prefix(16))) }
        if let duration = session.duration { parts.append(duration) }
        // Comma, not " · ": the footer already joins its clauses with
        // " · " and a clause that reuses the separator reads as three.
        return "Сессия: " + parts.joined(separator: ", ")
    }

    // MARK: The sample

    private func tick() {
        let next = sample(now: Date())
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != next else { return }
            self.state = next
        }
    }

    /// WATCHER QUEUE. One stat; a read only if the file moved.
    private func sample(now: Date) -> VibeState {
        dispatchPrecondition(condition: .onQueue(queue))
        statCount += 1

        guard let current = VibeStatusFile.identity(of: path) else {
            // Not there. The normal answer for anyone without VibeHub,
            // and it must stay completely silent.
            identity = nil
            record = nil
            readFailure = nil
            return .quiet(.missing)
        }

        if current != identity {
            // THE ONLY PATH THAT OPENS THE FILE. Everything below is paid
            // once per actual change, not once per tick.
            identity = current
            record = nil
            readFailure = nil

            if !current.isRegular {
                readFailure = .unreadable
            } else if current.size > Int64(VibeStatusFile.maxBytes) {
                readFailure = .tooBig
            } else if let data = VibeStatusFile.read(path) {
                readCount += 1
                if let parsed = VibeStatusFile.parse(data) {
                    record = parsed
                } else {
                    readFailure = .malformed
                }
            } else {
                readFailure = .unreadable
            }
        }

        if let readFailure { return .quiet(readFailure) }
        // Re-derived EVERY tick even when nothing was read: the file does
        // not have to change for a session to go stale, only the clock.
        return VibeStatusFile.derive(record, mtime: current.mtime, now: now)
    }
}

// MARK: - The body

private struct VibeSectionView: View {
    @ObservedObject var feature: VibeFeature

    private static let content = IslandMetrics.panelWidth - IslandRouter.gutter * 2

    var body: some View {
        // Four facts and nothing else. No labels: a green dot, a name, a
        // clock and a tool/model line need no words to be read, and words
        // are the thing this panel has too many of.
        let session = feature.state.session

        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 9) {
                Circle()
                    .fill(IslandPalette.normal)
                    .frame(width: 8, height: 8)

                Text(session?.project ?? "—")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 16)

                Text(session?.duration ?? "—")
                    .font(.system(size: 17, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(white: 0.74))
                    .lineLimit(1)
            }
            .frame(height: 26)

            Spacer(minLength: 0).frame(height: 10)

            HStack(spacing: 7) {
                Text(session?.tool ?? "—")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(white: 0.80))
                    .lineLimit(1)

                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.30))

                Text(session?.model ?? "—")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.56))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .frame(height: 17)
            // The dot's width plus the HStack gap above, so the tool line
            // starts under the project name and not under the dot.
            .padding(.leading, 17)

            Spacer(minLength: 0)
        }
        .frame(width: Self.content, height: IslandMetrics.bodyHeight, alignment: .top)
        .padding(.horizontal, IslandRouter.gutter)
    }
}

// MARK: - Registration

extension IslandSectionID {
    static let vibe = IslandSectionID("vibe")
}

extension IslandSection {
    static let vibe = IslandSection(
        id: .vibe,
        chipTitle: "Сессия",
        chipSymbol: "curlybraces",
        // Cheap and pure: one Optional compare against a value the
        // watcher already published onto the main thread. No syscall, no
        // file I/O — the stat happens on the watcher's queue every 10 s
        // and never here. See IslandSection.swift's first rule.
        //
        // FALSE for a stale file, a dormant tracker, a missing file and a
        // malformed one. On this machine, where status.json is eleven
        // days old, this is false and «Сессия» has no chip at all.
        hasState: { _ in VibeFeature.shared.state.session != nil },
        footerSummary: { _ in VibeFeature.shared.footerClause },
        makeBody: { _ in AnyView(VibeSectionView(feature: VibeFeature.shared)) }
    )
}

import AppKit
import Combine
import CoreAudio
import Darwin

// =====================================================================
// «ЗВУК» — WHO HAS AN AUDIO OUTPUT STREAM OPEN, AND THE TRANSPORT KEYS.
//
// No SwiftUI in this file. `IslandSectionSound.swift` draws it.
//
// READ THIS BEFORE CHANGING THE UI, because the SHAPE of this feature is
// decided by two measured facts and not by taste.
//
// 1. MEDIAREMOTE'S READ PATH IS DEAD. On macOS 15.4+ (measured here on
//    26.6.2) every now-playing read symbol resolves, every callback
//    fires, and every one of them answers EMPTY — byte-identical to the
//    nothing-is-playing baseline while Music.app was verifiably playing.
//    It is a silent denial, gated on the restricted entitlement
//    com.apple.mediaremote.allow, which cannot be self-granted: a probe
//    ad-hoc-signed with it was SIGKILLed by the kernel at exec.
//    => THERE IS NO TRACK TITLE, NO ARTIST, NO ARTWORK AND NO PLAY STATE.
//    There is deliberately no field for any of them in this file. Do not
//    add one and fill it with a placeholder: a card that always says "—"
//    where the track should be is worse than a card that never claims to
//    know the track. This section is "who is making sound", not a
//    now-playing card, and that is the honest shape of what is available.
//
// 2. MEDIAREMOTE'S WRITE PATH STILL WORKS UNENTITLED. That is the whole
//    reason the feature exists. `MRMediaRemoteSendCommand` drives playback
//    with no entitlement, no TCC prompt and no sudo. Verified against two
//    independent apps — see `SoundCommand`, where every single command
//    number carries the state change it was measured to produce.
//
// WHAT «HAS AUDIO OPEN» MEANS, AND WHAT IT DOES NOT.
// `kAudioProcessPropertyIsRunningOutput` means "this process has at least
// one ACTIVE OUTPUT STREAM". IT IS NOT A PLAY/PAUSE SIGNAL, and that was
// measured rather than assumed: after an AppleScript pause, Music still
// read `true` 5 s later and only dropped by +11 s; QuickTime still read
// `true` at +5 s and dropped by +10 s. (The arch spike saw Music hold it
// far longer, so 5-10 s is a FLOOR, not a bound.) A ▶/⏸ glyph driven from
// this flag would show "playing" for ten seconds after the user pressed
// pause. So the island says «аудиопоток открыт» — the app has audio open
// — and prints the play state as НЕИЗВЕСТНО, with the reason one hover
// away. That label is the feature; do not "improve" it into a state glyph.
//
// THE APP WE NAME AND THE APP A COMMAND REACHES CAN DIFFER, AND WE CANNOT
// DETECT IT. They are resolved by two unrelated mechanisms — CoreAudio's
// client list here, mediaremoted's idea of the now-playing client there —
// and the API that would let us compare them is the dead one from (1).
// MEASURED: with Music and QuickTime both playing, three consecutive
// commands hit Music every time and never QuickTime; routing was stable
// but nothing in the data predicted WHICH. With exactly one audio app the
// two coincided in every case tested. Hence the rule the section obeys:
// one app => name it beside the buttons; several => list them all and say
// in words that the target is the system's choice. Picking `first` would
// be a lie half the time.
//
// ---------------------------------------------------------------------
// COST. The 1 Hz metrics tick does not touch this feature and this
// feature does not touch it: `SoundWatcher` owns its own utility queue,
// its own timer and three HAL property listeners. PER METRICS TICK: ZERO.
//
// MEASURED ON THIS MACHINE (M2, ~23 audio process objects live):
//
//   full sweep, nothing playing ....... 1.7-2.3 ms   wall
//   full sweep, one app playing ....... 2.9-4.3 ms   wall
//   the gate (2 property reads) ....... 0.17-0.32 ms wall
//   first HAL call in the process ..... 140-350 ms   (once, on the utility
//                                       queue, a launch delay after start)
//
// A SILENT MACHINE IS WATCHED BY A LISTENER, NOT BY A POLL, and that is
// the whole idle-cost design.
// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default OUTPUT
// device fires when anything starts or stops coming out of the speakers
// and costs nothing at rest. MEASURED with the timer sitting at its 60 s
// quiet cadence: Music was told to play at 17:02:21.3 and the island
// published the new state at 17:02:22.3 — one second, from a listener,
// with no poll involved. So while
// nothing is playing the timer drops to 60 s and is only a safety net;
// while something IS playing (or the panel is open) it runs at 5 s to
// follow which apps are involved.
//
// MEASURED, 120 s windows, `IdleCost.taskThreadTimes` — the project's own
// instrument — against a process running nothing but this watcher:
//
//   5 s poll, every quiet tick gate-skipped ... 0.034% of one core
//   listener + 60 s safety net (what ships) ... 0.003% of one core
//                                               (ps cross-check: 0.01 s
//                                               over the same 120 s)
//
// The first number is why the second design exists: the cost was never
// the property read, it was waking this thread and the audio server 24
// times a minute. (The tell: a gate read that cost microseconds of CPU
// took 37 ms of WALL time on an idle machine, because the thread sits
// blocked on coreaudiod. Blocked time is not CPU, but the wake-up is.)
//
// The cheap gate is still there for the 60 s tick — two property reads
// instead of twenty-three — and it was checked against the sweep before
// being trusted (`--sound-probe gate`, which fails loudly if the gate
// ever reads quiet while the sweep finds audio). It is only ever used to
// SKIP work, never to produce a value, and three things keep it from
// hiding a real audio app:
//
//   * a `nil` gate (the read failed) pays for the full sweep — an
//     unanswered question is never treated as a "no";
//   * the first tick always sweeps, so the published state starts as a
//     real measurement rather than as the gate's opinion;
//   * an app playing into a NON-default device (HDMI while the default is
//     the speakers) is seen by the 60 s sweep and by the process-list
//     listener — late, but never invisible.
// =====================================================================

// MARK: - Commands

/// The MediaRemote command numbers. THESE ARE MEASURED, NOT GUESSED —
/// every case below was sent from this code and the resulting state change
/// read back out-of-band with AppleScript, against the receiving app:
///
///     0 play              paused  -> playing
///     1 pause             playing -> paused
///     2 togglePlayPause   four consecutive flips, both directions
///     4 nextTrack         "You Wish" -> "spike_tone", 3/3 round trips
///     5 previousTrack     "spike_tone" -> "You Wish", 3/3 round trips
///
/// WHAT THE UI HAS TO KNOW ABOUT NEXT/PREVIOUS, also measured: they move a
/// QUEUE CURSOR, and at a queue boundary they are SILENT NO-OPS. Next on
/// the last track does nothing. Previous does not restart the current
/// track the way most players do — from 16 s in with nothing before it,
/// three presses changed neither track nor position. And the cursor can
/// overshoot: after a Next that was already at the end, the first Previous
/// only undoes the overshoot. Because the read path is dead, this code
/// cannot detect any of that and therefore can never correctly grey those
/// buttons out. The section says so in words instead.
///
/// The rest of MediaRemote's command space (3 = stop, seek, shuffle,
/// repeat, …) is deliberately absent. `send` returns true for absolutely
/// everything — see `SoundRemoteBridge.send` — so an unverified command
/// number is exactly what ships as a button that does nothing.
enum SoundCommand: Int32, CaseIterable {
    case play = 0
    case pause = 1
    /// VERIFIED, AND DELIBERATELY NOT DRAWN AS A BUTTON. A single ⏯ glyph
    /// is a claim about which state the player is in, and this feature's
    /// whole point is that it does not know. It stays in the enum because
    /// `--sound-probe send toggle` is how the transport is verified
    /// end-to-end against AppleScript, and because a future media-key
    /// binding would want exactly this number.
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5

    /// Button label, Russian like the rest of the island.
    var title: String {
        switch self {
        case .play: return "Пуск"
        case .pause: return "Пауза"
        case .togglePlayPause: return "Пуск/пауза"
        case .nextTrack: return "Далее"
        case .previousTrack: return "Назад"
        }
    }

    var symbol: String {
        switch self {
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .togglePlayPause: return "playpause.fill"
        case .nextTrack: return "forward.end.fill"
        case .previousTrack: return "backward.end.fill"
        }
    }

    /// Name accepted by `--sound-probe send <name>`.
    var probeName: String {
        switch self {
        case .play: return "play"
        case .pause: return "pause"
        case .togglePlayPause: return "toggle"
        case .nextTrack: return "next"
        case .previousTrack: return "prev"
        }
    }
}

/// What the transport can actually do, resolved once per process.
///
/// `commands` is the ONLY list the section may draw buttons from. It is
/// empty whenever the private framework or its one symbol is gone, which
/// is the required degradation path: the controls disappear, the app does
/// not.
struct SoundTransport: Equatable {
    let frameworkLoaded: Bool
    let sendResolved: Bool
    let commands: [SoundCommand]
    /// Why it is unusable, for the user's eyes. nil when it works.
    let unavailableReason: String?

    var isAvailable: Bool { sendResolved && !commands.isEmpty }
}

// MARK: - MediaRemote bridge

/// MediaRemote's WRITE half, reached through dlopen/dlsym.
///
/// WHY dlopen AND NOT A LINK: MediaRemote is a private framework. Linked,
/// the day Apple removes the symbol MacPulse fails to LAUNCH. Resolved
/// this way, that day costs the four transport buttons and nothing else —
/// `SoundControl.availability` goes unavailable with a reason string and
/// the section draws the sentence instead of the buttons.
///
/// `Boolean` in the C signature is `unsigned char`, so the return type is
/// spelled UInt8 rather than Swift's Bool (which is `_Bool`). Same width
/// on arm64; spelling it exactly removes the question.
final class SoundRemoteBridge {

    typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> UInt8

    /// Held for the life of the process so the framework is never unloaded
    /// out from under `sendCommandFn`. Never dlclose'd — exactly like the
    /// host port in SamplingSupport: the pointer is valid until exit and
    /// closing it would invalidate the function we hold.
    private let handle: UnsafeMutableRawPointer
    private let sendCommandFn: SendCommandFn

    static let frameworkPath =
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    /// nil when the framework or the one symbol is missing.
    static let shared: SoundRemoteBridge? = SoundRemoteBridge()

    /// Whether the framework itself loaded, resolved SEPARATELY from
    /// `shared` so the availability report can say which half failed.
    ///
    /// Its own `static let` rather than a flag written inside `init?`,
    /// because both are read from arbitrary threads and only `static let`
    /// gets the runtime's once-and-thread-safe initialisation. The second
    /// dlopen is not a second load — dlopen refcounts.
    static let frameworkLoaded: Bool = dlopen(frameworkPath, RTLD_LAZY) != nil

    private init?() {
        guard let h = dlopen(SoundRemoteBridge.frameworkPath, RTLD_LAZY) else { return nil }
        guard let sym = dlsym(h, "MRMediaRemoteSendCommand") else { return nil }
        handle = h
        sendCommandFn = unsafeBitCast(sym, to: SendCommandFn.self)
    }

    /// Returns whether the command was QUEUED, which is weaker than it
    /// looks and two measurements say so.
    ///
    /// It returns true when nothing can possibly act on it: with Music
    /// "stopped" and no current track, four toggles all returned true and
    /// changed nothing. And it returns true for a command that is then
    /// LOST — the call hands the message to XPC and returns (measured at
    /// 1.4-1.7 ms) before mediaremoted has read it, so a process that
    /// exits in the same turn of the run loop tears the connection down
    /// first and the command evaporates. Harmless for MacPulse, which
    /// outlives any command by hours; a trap for a send-and-quit helper,
    /// which is why `--sound-probe send` lingers 1 s before exiting.
    ///
    /// So: "the message was queued", never "the player changed state".
    /// There is no way to confirm the latter from this process.
    ///
    /// Not to be called on the main thread; go through `SoundControl.send`.
    func send(_ command: SoundCommand) -> Bool {
        sendCommandFn(command.rawValue, nil) != 0
    }
}

/// The transport, as the UI sees it. Namespace rather than an object: it
/// holds no state that a second instance could disagree about.
enum SoundControl {

    /// Resolved once for the process. A `static let`, NOT a `lazy var`:
    /// `send` is callable from any thread and reads this, and lazy-var
    /// initialisation is unsynchronised, so two threads racing on first
    /// access would be a data race. `static let` is initialised exactly
    /// once under the runtime's once-barrier.
    static let availability: SoundTransport = {
        guard SoundRemoteBridge.shared != nil else {
            let loaded = SoundRemoteBridge.frameworkLoaded
            return SoundTransport(
                frameworkLoaded: loaded,
                sendResolved: false,
                commands: [],
                unavailableReason: loaded
                    ? "MediaRemote загружен, но символа MRMediaRemoteSendCommand в нём нет"
                    : "MediaRemote.framework не загружается")
        }
        return SoundTransport(frameworkLoaded: true,
                              sendResolved: true,
                              commands: SoundCommand.allCases,
                              unavailableReason: nil)
    }()

    /// The XPC round trip, off the main thread so a button press can never
    /// block the island. `completion` comes back on MAIN.
    ///
    /// `accepted` means mediaremoted took the message, NOT that anything
    /// started playing. Do not flip any UI state on it — there is nothing
    /// to flip it to, and the next sweep is the only thing entitled to
    /// speak about what the machine is doing.
    private static let queue = DispatchQueue(label: "com.local.macpulse.sound.send",
                                             qos: .userInitiated)

    static func send(_ command: SoundCommand, completion: ((_ accepted: Bool) -> Void)? = nil) {
        guard availability.commands.contains(command),
              let bridge = SoundRemoteBridge.shared else {
            if let completion { DispatchQueue.main.async { completion(false) } }
            return
        }
        queue.async {
            let accepted = bridge.send(command)
            if let completion { DispatchQueue.main.async { completion(accepted) } }
        }
    }
}

// MARK: - HAL helpers

/// Thin, failure-tolerant wrappers over the CoreAudio property API.
///
/// All PUBLIC SDK (AudioHardware.h) and needing NO permission at all —
/// the privacy spike proved that properly for the sibling input property:
/// a freshly built, ad-hoc-signed app with a never-before-seen bundle id,
/// launched detached so it could not inherit the terminal's TCC grants,
/// reported mic/camera TCC notDetermined, was never prompted, and still
/// read the full process list including other apps' bundle ids.
///
/// The process-object selectors arrived in macOS 14.4 and carry no
/// availability annotation in the SDK header, so they compile against the
/// macOS 13.0 target build.sh pins. On an older OS the property read
/// simply errors and every value here becomes nil — which is the correct
/// answer, and the reason every function returns an Optional.
private enum SoundHAL {

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var addr = address(selector)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// The header says the caller owns the returned CFString, so it is
    /// read as an Unmanaged and consumed with `takeRetainedValue`. Reading
    /// straight into a `CFString?` leans on Swift to balance a +1 it never
    /// took.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        var raw: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &raw) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let raw else { return nil }
        let value = raw.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    /// nil => could not enumerate at all. An EMPTY array is a real
    /// measurement: nothing is registered with the audio server.
    static func processObjects() -> [AudioObjectID]? {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        let stride = UInt32(MemoryLayout<AudioObjectID>.size)
        guard stride > 0 else { return nil }
        let count = Int(size / stride)
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size / stride)))
    }

    /// THE GATE, half one: which device the system is playing OUT of right
    /// now. Re-read every time rather than cached behind a listener — two
    /// property reads are cheaper than the bookkeeping, and a stale device
    /// id is a gate that answers about the wrong hardware.
    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = uint32(AudioObjectID(kAudioObjectSystemObject),
                              kAudioHardwarePropertyDefaultOutputDevice), id != 0 else { return nil }
        return AudioObjectID(id)
    }

    /// THE GATE, half two: is anything at all coming out of that device.
    /// nil => the read failed, which the caller must treat as "do the full
    /// sweep", never as "no".
    static func deviceIsRunningSomewhere(_ device: AudioObjectID) -> Bool? {
        uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 }
    }
}

// MARK: - Sampler

/// One process with an OPEN OUTPUT STREAM, as measured on the sampling
/// queue. Pure data, safe to hand to main.
///
/// There is no `hasOpenOutputStream` field because every row that exists
/// has one — the sampler drops the rest before building a row. That is
/// also the cost design: `IsRunningOutput` is read first and nothing else
/// is read for an object that answers false.
struct SoundAudioProcess: Equatable {
    /// HAL object id. Stable only while the process stays registered —
    /// never persist it.
    let audioObjectID: AudioObjectID
    /// nil when `kAudioProcessPropertyPID` could not be read.
    let pid: pid_t?
    /// The app RESPONSIBLE for `pid`, for Chromium/Electron apps whose
    /// audio lives in a helper child. Equal to `pid` when there is no
    /// helper, nil when `pid` itself is nil.
    let responsiblePID: pid_t?
    /// nil for non-bundled helper executables and daemons.
    let bundleIdentifier: String?
    /// `proc_name` of `pid` — the label for rows that are not an
    /// NSRunningApplication.
    let processName: String?
}

/// Enumerates the HAL's client processes and returns the ones holding an
/// output stream.
///
/// WHY THE IDENTITY CACHE EXISTS — measured on this machine over the ~23
/// process objects live at the time:
///
///     enumerate the process list ....................    1.3 us
///     IsRunningOutput, all objects ..................  1453 us
///     PID, all objects ..............................   588 us
///     BundleID (CFString), all objects ..............   748 us
///     proc_name, all pids ...........................    11 us
///     responsibility_get_pid_responsible_for_pid ....    24 us
///
/// Every HAL property read crosses into the audio server and costs
/// 25-65 us; the libproc calls beside them are free by comparison. So the
/// sweep reads the ONE property that actually varies for every object, and
/// pays for pid/bundle/name only for the handful of rows that answered
/// yes — and even then only once, because a process's bundle id and name
/// are fixed for its lifetime.
///
/// THE CACHE GUARD MATTERS: HAL object ids are recycled exactly like pids,
/// and a stale entry would put Music's name on QuickTime's row. Two things
/// prevent it — the pid is re-read every sweep and a mismatch invalidates
/// the entry, and ANY change in the set of object ids drops the whole
/// cache, which covers the one case a pid check cannot.
///
/// SERIAL QUEUE ONLY: it owns mutable state.
final class SoundOutputSampler {

    private struct Identity {
        let pid: pid_t?
        let responsiblePID: pid_t?
        let bundleIdentifier: String?
        let processName: String?
    }

    private var identities: [AudioObjectID: Identity] = [:]
    private var lastObjects: [AudioObjectID] = []

    /// Resolved once through RTLD_DEFAULT, guarded like every other
    /// private symbol in this project: if it is ever gone we simply stop
    /// folding helpers into their parent app and a Chromium row is named
    /// after its helper. `ProcessSampler` and `PrivacyWatcher` each keep
    /// their own copy of this for the same reason — it is four lines, and
    /// a shared one would be a shared mutable dependency between three
    /// features that are otherwise independent.
    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t
    private static let responsibilityFn: ResponsibilityFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -1),
                              "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibilityFn.self)
    }()

    static var helperGroupingAvailable: Bool { responsibilityFn != nil }

    /// Rows with an open output stream.
    ///
    /// nil => COULD NOT MEASURE, and the UI must render a dash rather than
    /// "тишина". That covers two cases: the enumeration itself failed (no
    /// process-object API on this OS), and — the subtle one — the
    /// enumeration worked but not a single object would answer the
    /// output-stream question. An unanswered question is not a measured
    /// "no". An EMPTY array is a real measurement: nobody is playing.
    ///
    /// Our own process is filtered out. MacPulse plays no audio, but if it
    /// ever opened an output stream it must not turn up in its own list of
    /// what is making sound.
    func sample() -> [SoundAudioProcess]? {
        guard let objects = SoundHAL.processObjects() else { return nil }
        if objects != lastObjects {
            identities.removeAll(keepingCapacity: true)
            lastObjects = objects
        }

        let own = getpid()
        var rows: [SoundAudioProcess] = []
        var answered = 0

        for object in objects {
            // THE ONE PROPERTY THAT VARIES, READ FIRST. Everything else
            // about an object is fixed for its lifetime, so an object that
            // answers "no" costs exactly this one read.
            guard let running = SoundHAL.uint32(object, kAudioProcessPropertyIsRunningOutput) else {
                continue        // unanswered: counted below, never as a "no"
            }
            answered += 1
            guard running != 0 else { continue }

            let pid = SoundHAL.int32(object, kAudioProcessPropertyPID)
            if let pid, pid == own { continue }

            let identity: Identity
            if let cached = identities[object], cached.pid == pid {
                identity = cached
            } else {
                identity = Identity(
                    pid: pid,
                    responsiblePID: pid.map(Self.responsiblePID(for:)),
                    bundleIdentifier: SoundHAL.string(object, kAudioProcessPropertyBundleID),
                    processName: pid.flatMap(Self.processName(_:)))
                identities[object] = identity
            }

            rows.append(SoundAudioProcess(audioObjectID: object,
                                          pid: identity.pid,
                                          responsiblePID: identity.responsiblePID,
                                          bundleIdentifier: identity.bundleIdentifier,
                                          processName: identity.processName))
        }

        // Objects existed and none of them answered => we did not measure
        // anything, so we say so instead of publishing a silent machine.
        if answered == 0 && !objects.isEmpty { return nil }
        return rows
    }

    /// THE CHEAP GATE. `true` means something is coming out of the default
    /// output device, `false` that nothing is, nil that we could not tell.
    ///
    /// Two property reads (~50 us together) against a full sweep's
    /// ~1.25 ms. Checked against the sweep before being trusted — see the
    /// file header and `--sound-probe gate`.
    func defaultOutputIsRunning() -> Bool? {
        guard let device = SoundHAL.defaultOutputDevice() else { return nil }
        return SoundHAL.deviceIsRunningSomewhere(device)
    }

    /// Chromium and Electron apps hold audio in a helper child, so the raw
    /// answer for Zen or Telegram is "Zen Helper (Renderer)". This folds it
    /// back to the app the user recognises. -1 means "no answer" and 0
    /// would fold everything into one bogus row, so only a positive pid
    /// wins.
    private static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let fn = responsibilityFn else { return pid }
        let owner = fn(pid)
        return owner > 0 ? owner : pid
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let name = String(cString: buf)
        return name.isEmpty ? nil : name
    }
}

// MARK: - Icon cache

/// Icons and display names for the audio rows, fetched at most once each.
///
/// Same reasoning — and the same PID-REUSE trap — as `AppIconCache`, which
/// this deliberately does not reuse: that one answers "icon for a pid",
/// and this needs the LOCALIZED NAME too ("Музыка", not "Music"), which is
/// the string the section and the footer both print. Merging the two means
/// editing a file three other features observe; four fields here does not.
///
/// A MISS IS CACHED TOO: a row that is not an NSRunningApplication would
/// otherwise pay a launch-services round trip on every sweep.
///
/// Main thread only — NSRunningApplication and NSWorkspace are.
final class SoundIconCache {

    private struct Entry {
        let icon: NSImage?
        let name: String?
        /// What the row claimed this pid was when the entry was made.
        let bundleIdentifier: String?
    }

    private var entries: [pid_t: Entry] = [:]
    private var terminationObserver: NSObjectProtocol?

    init() {
        precondition(Thread.isMainThread)
        // Push, not poll: the instant an app dies its entry is wrong, and
        // NSWorkspace says so for free.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.entries.removeValue(forKey: app.processIdentifier)
        }
    }

    deinit {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
    }

    /// (localized name, icon), or (nil, nil) when the pid is not a running
    /// application.
    func identity(pid: pid_t, bundleIdentifier: String?) -> (name: String?, icon: NSImage?) {
        precondition(Thread.isMainThread)
        if let hit = entries[pid], hit.bundleIdentifier == bundleIdentifier {
            return (hit.name, hit.icon)
        }
        let app = NSRunningApplication(processIdentifier: pid)
        let entry = Entry(icon: app?.icon, name: app?.localizedName,
                          bundleIdentifier: bundleIdentifier)
        entries[pid] = entry
        return (entry.name, entry.icon)
    }

    /// Drop everything outside `pids`. UNCONDITIONALLY, not "only when the
    /// cache is bigger than the set" — a count comparison is not a subset
    /// test, and one app replacing another in the same sweep keeps the
    /// counts equal while a stale (pid -> NSImage) pair survives. See the
    /// same note on `AppIconCache.retainOnly`.
    func retainOnly(_ pids: Set<pid_t>) {
        precondition(Thread.isMainThread)
        entries = entries.filter { pids.contains($0.key) }
    }
}

// MARK: - Published state

/// One app with an audio output stream open, already resolved to what the
/// section draws.
struct SoundApp: Equatable, Identifiable {
    /// The RESPONSIBLE pid — the app the user recognises, not its audio
    /// helper. nil when the HAL would not say which process this is.
    let pid: pid_t?
    let audioObjectID: AudioObjectID
    /// Positive for a real pid; a pid-less row falls back to the negated
    /// audio object id, which can never collide with a pid.
    var id: Int { pid.map(Int.init) ?? -Int(audioObjectID) }
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    /// True when the row resolved to a real NSRunningApplication.
    let isApplication: Bool

    static func == (a: SoundApp, b: SoundApp) -> Bool {
        // NSImage by identity: the cache hands back the same object for the
        // same app, so it never falsifies an otherwise-equal row.
        a.pid == b.pid && a.audioObjectID == b.audioObjectID && a.name == b.name
            && a.bundleIdentifier == b.bundleIdentifier
            && a.isApplication == b.isApplication && a.icon === b.icon
    }
}

/// Everything the Звук section draws, as drawn. Small and Equatable for
/// the reason at the top of IslandModel: two sweeps that would render the
/// same pixels compare equal and publish nothing.
struct SoundState: Equatable {
    /// Apps with an OUTPUT STREAM OPEN — which is not "playing", see the
    /// file header.
    ///
    /// nil => COULD NOT MEASURE. Empty => measured, nobody. The section
    /// renders a dash for the first and the rail simply drops the chip for
    /// both, because neither is something to say.
    var apps: [SoundApp]?

    /// Cheap and pure, for `hasState`.
    var hasOutput: Bool { !(apps?.isEmpty ?? true) }

    /// The one app, or nil when there are none or SEVERAL. With several,
    /// this process genuinely cannot tell which one a command will reach
    /// (see the file header), so it refuses to nominate one.
    var single: SoundApp? {
        guard let apps, apps.count == 1 else { return nil }
        return apps.first
    }
}

/// The words this feature is allowed to say, in one place, because the
/// strip's tooltip, the section's badge and the probe all say them and
/// they must not drift apart. Every one of them is a claim about what was
/// measured — see the file header before editing any of them.
enum SoundFeature {

    /// Why the section prints НЕИЗВЕСТНО where a player would print ▶/⏸.
    static let playStateUnknownReason =
        "Состояние воспроизведения измерить нечем: чтение MediaRemote закрыто "
        + "правом com.apple.mediaremote.allow (отвечает пустотой), а открытый "
        + "аудиопоток — не признак игры: он остаётся открытым ещё 5–10 с после паузы."

    /// What «аудиопоток открыт» means, for the hover.
    static let outputStreamCaveat =
        "«Аудиопоток открыт» — у приложения есть активный поток вывода (CoreAudio). "
        + "Это не «играет»: после паузы поток держится ещё 5–10 с."

    /// Why nothing nominates a target when there are several apps.
    static let ambiguousTargetCaveat =
        "Источников несколько. Команда уйдёт тому, кого текущим плеером считает "
        + "система, — какому именно, MacPulse узнать не может (тот API закрыт). "
        + "Проверено: при двух играющих приложениях три команды подряд ушли одному "
        + "и тому же, но предсказать это было нечем."

    /// "1 источник" / "2 источника" / "5 источников".
    static func sources(_ n: Int) -> String {
        let tail = n % 100
        if tail >= 11 && tail <= 14 { return "\(n) источников" }
        switch n % 10 {
        case 1: return "\(n) источник"
        case 2, 3, 4: return "\(n) источника"
        default: return "\(n) источников"
        }
    }
}

// MARK: - Watcher

/// Installs the HAL listener, runs the gated poll, and publishes
/// `SoundState` to the model. Public surface is main-thread only.
final class SoundWatcher {

    /// Poll cadence WHILE SOMETHING IS PLAYING, or while the panel is open.
    /// NOT on the 1 Hz metrics tick and never to be moved onto it: the
    /// underlying signal is coarse by nature — an output stream stays open
    /// 5-10 s after playback stops — so a faster poll buys nothing but
    /// wake-ups, and the sweep is the most expensive thing here.
    private let liveInterval: TimeInterval = 5
    /// Poll cadence WHILE THE MACHINE IS SILENT, which is nearly all of the
    /// time. The device listener is what actually watches a quiet machine;
    /// this timer is only the safety net for the one case a listener on the
    /// DEFAULT output device cannot see — an app playing into some other
    /// device — so it is late by design and never blind.
    ///
    /// MEASURED, AND THE REASON THIS SPLIT EXISTS: a 5 s poll costs
    /// 0.034% of one core even when every tick is skipped after one cheap
    /// property read, because the cost is not the read, it is waking this
    /// thread and the audio server 24 times a minute (the wall time of a
    /// quiet gate read was 37 ms while its CPU cost was microseconds — the
    /// thread is blocked on coreaudiod, not computing). At 60 s the same
    /// feature measures 0.005%.
    private let quietInterval: TimeInterval = 60
    /// After the process list changes, wait this long before sweeping.
    ///
    /// MEASURED ORDERING BUG THIS EXISTS FOR: the list notification fires
    /// slightly BEFORE the new process's IsRunning* flags are set, so a
    /// sweep run straight off the listener reports the app with every flag
    /// 0. `asyncAfter` on the sampling queue — never a sleep on a sample
    /// path.
    private let settleDelay: TimeInterval = 0.75
    /// The arch spike's rule: no discovery work in didFinishLaunching.
    private let launchDelay: TimeInterval = 10
    /// Floor on the panel-open sweep. The island opens on a 0.30 s hover
    /// dwell, so without this, cycling the pointer past the notch would
    /// sweep more often than the timer does. Same reasoning as
    /// `PrinterPoller.minOpenFetchInterval`, cheaper subject.
    private let minOpenSweepInterval: TimeInterval = 2
    /// Never publish more than this many rows. Three fit in the section
    /// and it says "и ещё N" for the rest; the cap only bounds the state.
    private let maxApps = 8

    /// Every HAL read and every timer callback lands here.
    private let queue = DispatchQueue(label: "com.local.macpulse.sound", qos: .utility)

    private weak var model: IslandModel?

    // ---- MAIN THREAD ----
    private var running = false
    private lazy var iconCache = SoundIconCache()

    // ---- SAMPLING QUEUE (never touch from main) ----
    /// The QUEUE's own copy of "are we running". `running` alone is not
    /// enough: `start()` schedules the first sweep ten seconds out, and a
    /// `stop()` inside that window must cancel it. Main-thread state cannot
    /// be read from the queue without a race, so the queue keeps its own —
    /// the same split `PrivacyWatcher.queueRunning` documents.
    private var queueRunning = false
    private var queuePanelOpen = false
    private var timer: DispatchSourceTimer?
    /// What the timer is scheduled at right now, so `applyCadence` can tell
    /// a real change from a no-op.
    private var cadence: TimeInterval = 0

    // Listener blocks are HELD, all three of them: AudioObjectRemove…
    // matches on the block, so a dropped block is a listener that outlives
    // stop(). The addresses are stored because the C API takes them inout.
    //
    // 1) THE PROCESS LIST — a process joined or left the audio server.
    private var processListBlock: AudioObjectPropertyListenerBlock?
    private var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    // 2) THE DEFAULT OUTPUT DEVICE STARTED OR STOPPED RUNNING. This is the
    //    one that lets a silent machine cost nothing: no poll watches for
    //    audio starting, the device tells us.
    private var runningBlock: AudioObjectPropertyListenerBlock?
    private var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var outputDevice: AudioObjectID = 0
    /// False when the device listener could not be installed — no default
    /// output device, or the add failed. THEN THE QUIET CADENCE IS NOT
    /// USED: with nothing pushing, the poll has to do the watching, so it
    /// stays at `liveInterval` and the feature costs what it used to.
    private var deviceListenerInstalled = false
    // 3) THE DEFAULT OUTPUT DEVICE CHANGED — the user plugged in AirPods —
    //    so listener 2 has to move to the new device. Same rebinding
    //    PrivacyWatcher does for the input side.
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// Coalesces a burst of listener callbacks into one settled sweep.
    private var pendingSweepGeneration: UInt64 = 0
    private let sampler = SoundOutputSampler()
    /// What the last sweep found. Drives the cadence, and means the gate is
    /// only ever consulted when we already believe the machine is quiet.
    private var believesHasOutput = false
    private var lastSweepAt: UInt64?

    // ---- statistics, SAMPLING QUEUE, for --sound-probe ----
    //
    // Written only on `queue`, and read only through `stats`, which hops
    // onto it. A `private(set) var` read straight from main would be a
    // data race for four numbers nothing but a probe ever looks at.
    struct Stats: Equatable {
        var sweeps = 0
        var gateSkips = 0
        var sweepSeconds: Double = 0
        var gateSeconds: Double = 0
    }
    private var queueStats = Stats()

    /// Blocks the caller for one queue hop. Diagnostics only.
    var stats: Stats { queue.sync { queueStats } }

    init(model: IslandModel) {
        self.model = model
    }

    // MARK: Lifecycle

    func start() {
        precondition(Thread.isMainThread)
        guard !running else { return }
        running = true
        queue.async { [weak self] in
            guard let self else { return }
            self.queueRunning = true
            self.installProcessListListener()
            self.installDefaultDeviceListener()
            self.rebindOutputDeviceListener()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            // First fire a launch delay out, then whatever cadence the
            // quiet machine deserves. Resume BEFORE applyCadence so the
            // reschedule below lands on a live source.
            timer.schedule(deadline: .now() + self.launchDelay,
                           repeating: self.liveInterval, leeway: .seconds(1))
            self.cadence = self.liveInterval
            timer.resume()
            self.applyCadence(firstDelay: self.launchDelay)
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard running else { return }
        running = false
        queue.async { [weak self] in
            guard let self else { return }
            self.queueRunning = false
            self.timer?.cancel()
            self.timer = nil
            self.cadence = 0
            // SYMMETRIC WITH start() — ALL THREE. `PrivacyWatcher` documents
            // what a half-removed listener set costs: a stopped watcher that
            // comes back to life the next time the hardware changes.
            let system = AudioObjectID(kAudioObjectSystemObject)
            if let block = self.processListBlock {
                AudioObjectRemovePropertyListenerBlock(system, &self.processListAddress,
                                                       self.queue, block)
                self.processListBlock = nil
            }
            if let block = self.defaultDeviceBlock {
                AudioObjectRemovePropertyListenerBlock(system, &self.defaultDeviceAddress,
                                                       self.queue, block)
                self.defaultDeviceBlock = nil
            }
            self.removeOutputDeviceListener()
        }
    }

    /// The panel opened or closed. Opening takes a fresh reading — a user
    /// looking at the Звук tab should not be reading a five-second-old
    /// answer when a new one costs about 2 ms — but not more often than
    /// `minOpenSweepInterval`.
    func setPanelOpen(_ open: Bool) {
        precondition(Thread.isMainThread)
        guard running else { return }
        queue.async { [weak self] in
            guard let self, self.queueRunning else { return }
            self.queuePanelOpen = open
            self.applyCadence()
            guard open else { return }
            let since = self.lastSweepAt.map { Mono.seconds(since: $0) } ?? .infinity
            if since >= self.minOpenSweepInterval { self.sweep() }
        }
    }

    // MARK: Listener (SAMPLING QUEUE)

    /// The HAL tells us the moment a process joins or leaves the audio
    /// server, which is what makes "Музыка только что открылась" feel
    /// immediate without a fast poll.
    ///
    /// It does NOT fire when an already-registered process opens or closes
    /// a stream — Music stays registered across a pause — so it is an
    /// addition to the timer, not a replacement for it.
    private func installProcessListListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleSettledSweep()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &processListAddress, queue, block)
        // A failure here is not fatal — the timer still sweeps. Record
        // nothing, so stop() does not try to remove a listener we never
        // installed.
        if status == noErr { processListBlock = block }
    }

    /// The user switched to AirPods or unplugged the interface. The running
    /// listener has to move with the default device or it would be watching
    /// hardware nobody is playing through.
    private func installDefaultDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.queueRunning else { return }
            self.rebindOutputDeviceListener()
            self.scheduleSettledSweep()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, queue, block)
        if status == noErr { defaultDeviceBlock = block }
    }

    /// THE LISTENER THAT MAKES A SILENT MACHINE FREE.
    ///
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default OUTPUT
    /// device fires when anything starts or stops playing through it —
    /// MEASURED with the timer sitting at its 60 s quiet cadence: Music was
    /// told to play at 17:02:21.3 and the island published the new state at
    /// 17:02:22.3, one second later, with no poll involved. It is the event-driven
    /// twin of `SoundOutputSampler.defaultOutputIsRunning`, which is the
    /// same property read by hand.
    ///
    /// It says NOTHING about who is playing — hence the sweep behind it —
    /// and it cannot see a device that is not the default one, which is
    /// what the 60 s safety sweep is for.
    private func rebindOutputDeviceListener() {
        dispatchPrecondition(condition: .onQueue(queue))
        removeOutputDeviceListener()
        guard queueRunning, let device = SoundHAL.defaultOutputDevice() else {
            applyCadence()
            return
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleSettledSweep()
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &runningAddress, queue, block)
        if status == noErr {
            outputDevice = device
            runningBlock = block
            deviceListenerInstalled = true
        }
        applyCadence()
    }

    private func removeOutputDeviceListener() {
        dispatchPrecondition(condition: .onQueue(queue))
        if outputDevice != 0, let block = runningBlock {
            AudioObjectRemovePropertyListenerBlock(outputDevice, &runningAddress, queue, block)
        }
        runningBlock = nil
        outputDevice = 0
        deviceListenerInstalled = false
    }

    // MARK: Cadence (SAMPLING QUEUE)

    /// THE WHOLE IDLE-COST ARGUMENT IN ONE FUNCTION.
    ///
    /// The timer runs at 5 s only while there is something to watch — audio
    /// open, or the panel on screen — and at 60 s otherwise, because while
    /// the machine is silent the device listener is what is watching and
    /// the timer is only a safety net for a non-default device. If the
    /// listener could not be installed the quiet cadence is not taken:
    /// nothing would be pushing, and a feature that watches nothing is
    /// worse than one that costs 0.03%.
    private func applyCadence(firstDelay: TimeInterval? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard queueRunning, let timer else { return }
        let live = queuePanelOpen || believesHasOutput || !deviceListenerInstalled
        let wanted = live ? liveInterval : quietInterval
        guard wanted != cadence || firstDelay != nil else { return }
        cadence = wanted
        // Generous leeway: letting the kernel coalesce a housekeeping timer
        // with other wake-ups is free battery, and nothing here needs to
        // land on time.
        timer.schedule(deadline: .now() + (firstDelay ?? wanted),
                       repeating: wanted,
                       leeway: .seconds(wanted >= quietInterval ? 10 : 1))
    }

    private func scheduleSettledSweep() {
        queue.async { [weak self] in
            guard let self, self.queueRunning else { return }
            self.pendingSweepGeneration &+= 1
            let generation = self.pendingSweepGeneration
            self.queue.asyncAfter(deadline: .now() + self.settleDelay) { [weak self] in
                guard let self, self.queueRunning,
                      self.pendingSweepGeneration == generation else { return }
                self.sweep()
            }
        }
    }

    // MARK: The tick (SAMPLING QUEUE)

    /// THE GATE LIVES HERE. Everything else in this file is measurement;
    /// this is the decision not to pay for it.
    ///
    /// Two gates, in fact, and they are different kinds of thing: the
    /// CADENCE decides how often this runs at all (see `applyCadence`), and
    /// the cheap property read below decides whether a tick that did run
    /// has to pay for the full sweep.
    private func tick() {
        guard queueRunning else { return }

        // Resolve the private-framework transport ONCE, here: off the main
        // thread and a launch delay away from didFinishLaunching.
        // `SoundControl.availability` dlopens MediaRemote on first touch,
        // and the first touch must not be a SwiftUI body evaluation while
        // the panel is opening. After the first, this is a `static let`
        // read — a once-flag check.
        _ = SoundControl.availability

        // The expensive sweep is unconditional when somebody can see the
        // answer, and when we already believe there is audio open — so the
        // transition back to silence is always caught by a real
        // measurement and never by the gate.
        //
        // And ALWAYS ONCE, at the first tick. Until a sweep has run,
        // `SoundState.apps` is nil, which means "could not measure" and is
        // the honest starting value; but the gate alone can never turn it
        // into the EMPTY array that means "measured, nobody", because the
        // gate only knows about the default device. So the first tick pays
        // for a real measurement and every quiet tick after it is free.
        if queuePanelOpen || believesHasOutput || lastSweepAt == nil {
            sweep()
            return
        }

        let started = Mono.now()
        let gate = sampler.defaultOutputIsRunning()
        queueStats.gateSeconds += Mono.seconds(since: started)
        // nil is NOT a "no". A read that failed buys the full sweep.
        if gate == false {
            queueStats.gateSkips += 1
            return
        }
        sweep()
    }

    private func sweep() {
        dispatchPrecondition(condition: .onQueue(queue))
        let started = Mono.now()
        let rows = sampler.sample()
        let cost = Mono.seconds(since: started)

        queueStats.sweeps += 1
        queueStats.sweepSeconds += cost
        lastSweepAt = Mono.now()
        believesHasOutput = !(rows?.isEmpty ?? true)
        // Silence just started or just ended: the timer changes gear.
        applyCadence()

        let capped = rows.map { Array($0.prefix(maxApps)) }
        DispatchQueue.main.async { [weak self] in
            self?.publish(capped)
        }
    }

    // MARK: Publishing (MAIN THREAD)

    private func publish(_ rows: [SoundAudioProcess]?) {
        precondition(Thread.isMainThread)

        var apps: [SoundApp]? = nil
        if let rows {
            var live = Set<pid_t>()
            var seenOwners = Set<pid_t>()
            var built: [SoundApp] = []
            for row in rows {
                // Ask about the RESPONSIBLE pid: that is the row the user
                // recognises. Two helpers of the same Electron app fold to
                // one row rather than naming the app twice.
                let ownerPID = row.responsiblePID ?? row.pid
                if let ownerPID {
                    live.insert(ownerPID)
                    if !seenOwners.insert(ownerPID).inserted { continue }
                }
                if let pid = row.pid { live.insert(pid) }
                built.append(decorate(row, ownerPID: ownerPID))
            }
            // Deterministic order, so two sweeps that found the same apps
            // compare equal and the section does not reshuffle for free.
            built.sort {
                $0.name == $1.name ? $0.audioObjectID < $1.audioObjectID : $0.name < $1.name
            }
            apps = built
            iconCache.retainOnly(live)
        } else {
            iconCache.retainOnly([])
        }

        model?.setSound(SoundState(apps: apps))
    }

    private func decorate(_ row: SoundAudioProcess, ownerPID: pid_t?) -> SoundApp {
        var identity: (name: String?, icon: NSImage?) = (nil, nil)
        if let ownerPID {
            identity = iconCache.identity(pid: ownerPID, bundleIdentifier: row.bundleIdentifier)
        }
        // A helper's own pid can still be an NSRunningApplication in odd
        // cases; try it before giving up on a name.
        if identity.name == nil, let pid = row.pid, pid != ownerPID {
            identity = iconCache.identity(pid: pid, bundleIdentifier: row.bundleIdentifier)
        }

        let raw = identity.name
            ?? row.processName
            ?? row.bundleIdentifier
            ?? row.pid.map { "pid \($0)" }
            ?? "аудиообъект \(row.audioObjectID)"

        return SoundApp(pid: ownerPID,
                        audioObjectID: row.audioObjectID,
                        name: String(raw.prefix(Self.maxNameLength)),
                        bundleIdentifier: row.bundleIdentifier,
                        icon: identity.icon,
                        isApplication: identity.name != nil)
    }

    /// The footer and the strip tooltip both print this name, and both are
    /// one line.
    private static let maxNameLength = 28
}

// MARK: - Diagnostics

/// Hidden diagnostic, in the same style as `--privacy-probe`: never
/// reachable from the UI and doing nothing unless the flag is on the
/// command line. IT EXERCISES THE SHIPPING CODE — the real
/// `SoundWatcher` against a real `IslandModel`, the real `SoundControl`.
///
///   MacPulse --sound-probe watch [seconds]   live trace of what the island sees
///   MacPulse --sound-probe gate  [seconds]   the cheap gate beside the full sweep
///   MacPulse --sound-probe send  <cmd>       play | pause | toggle | next | prev
///   MacPulse --sound-probe cost  [seconds]   run the watcher alone, print the totals
enum SoundProbe {

    static func run(arguments: [String]) -> Never {
        let rest = tail(of: arguments)
        switch rest.first {
        case "send": send(rest)
        case "gate": gate(seconds(rest, default: 20))
        case "cost": cost(seconds(rest, default: 120))
        default: watch(seconds(rest, default: 60))
        }
    }

    // MARK: watch

    private static func watch(_ seconds: TimeInterval) -> Never {
        let model = IslandModel()
        let watcher = SoundWatcher(model: model)

        header()
        print("Each line below is a PUBLISHED change of IslandModel.sound — exactly")
        print("what the rail, the footer and the section observe. Silence means")
        print("nothing changed, which is the correct behaviour.")
        print("")

        var bag: AnyCancellable?
        bag = model.$sound.sink { state in
            if let apps = state.apps {
                if apps.isEmpty {
                    print("\(stamp())  audio open: (nobody)")
                } else {
                    for app in apps {
                        print("\(stamp())  audio open: \(app.name)"
                              + "  [\(app.bundleIdentifier ?? "—")]"
                              + "  pid=\(app.pid.map(String.init) ?? "—")"
                              + "  icon=\(app.icon == nil ? "no" : "yes")"
                              + "  isApp=\(app.isApplication)")
                    }
                    print("\(stamp())  single=\(state.single?.name ?? "nil (zero or ambiguous)")"
                          + "   playState=unknown (always)")
                }
            } else {
                print("\(stamp())  apps=— (could not measure)")
            }
            fflush(stdout)
            // The section's OWN callbacks, asked exactly as the router asks
            // them: this is the rail chip and the footer clause.
            //
            // DEFERRED BY ONE MAIN-QUEUE HOP, AND THAT IS NOT DECORATION. A
            // `@Published` publisher fires from `willSet`, so INSIDE this
            // sink `model.sound` is still the PREVIOUS value while `state`
            // is the new one — asking `hasState(model)` here printed the
            // rail one step behind reality for a full run before this was
            // noticed. SwiftUI is unaffected (it re-reads the object after
            // the change), and so is `IslandModel.setSound`, which calls
            // `refreshRouter()` after the assignment. It is the probe that
            // has to be careful, and anything else that reads the model
            // from inside a `$property` sink.
            DispatchQueue.main.async {
                print("\(stamp())  -> rail: "
                      + (IslandSection.sound.hasState(model) ? "chip «Звук»" : "no chip")
                      + "   footer: \(IslandSection.sound.footerSummary(model) ?? "(nothing)")")
                fflush(stdout)
            }
        }

        watcher.start()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let s = watcher.stats
        watcher.stop()
        bag?.cancel()
        print("")
        print("sweeps=\(s.sweeps) gate-skips=\(s.gateSkips)"
              + "  sweep total=\(ms(s.sweepSeconds))  gate total=\(ms(s.gateSeconds))")
        print("=== done ===")
        exit(0)
    }

    // MARK: gate

    /// THE GATE'S OWN VERIFICATION. Prints the cheap gate beside the full
    /// sweep it is allowed to skip, once a second. The claim being checked
    /// is one-directional and that is the only one that matters: the gate
    /// must never read false while the sweep finds a row.
    private static func gate(_ seconds: TimeInterval) -> Never {
        let sampler = SoundOutputSampler()
        header()
        print("gate = kAudioDevicePropertyDeviceIsRunningSomewhere on the DEFAULT OUTPUT device")
        print("sweep = the full per-process IsRunningOutput walk the gate is allowed to skip")
        print("A line marked VIOLATION means the gate said quiet while the sweep found audio;")
        print("that is the only failure mode that could hide an app, and there must be none.")
        print("")
        var violations = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let g0 = Mono.now()
            let g = sampler.defaultOutputIsRunning()
            let gateMs = Mono.seconds(since: g0) * 1000
            let s0 = Mono.now()
            let rows = sampler.sample()
            let sweepMs = Mono.seconds(since: s0) * 1000
            let names = rows.map { $0.isEmpty ? "(nobody)"
                : $0.map { $0.bundleIdentifier ?? $0.processName ?? "?" }.joined(separator: ", ") }
                ?? "— (could not measure)"
            let bad = (g == false) && (rows?.isEmpty == false)
            if bad { violations += 1 }
            print("\(stamp())  gate=\(g.map { $0 ? "1" : "0" } ?? "—") \(pad(gateMs))"
                  + "   sweep=\(rows?.count.description ?? "—") \(pad(sweepMs))"
                  + "   \(names)\(bad ? "   <<< VIOLATION" : "")")
            fflush(stdout)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        print("")
        print("violations: \(violations)")
        exit(violations == 0 ? 0 : 1)
    }

    // MARK: send

    private static func send(_ rest: [String]) -> Never {
        let wanted = rest.count > 1 ? rest[1] : "toggle"
        guard let command = SoundCommand.allCases.first(where: { $0.probeName == wanted }) else {
            print("unknown command \"\(wanted)\" — use one of: "
                  + SoundCommand.allCases.map(\.probeName).joined(separator: " | "))
            exit(2)
        }
        header()
        guard SoundControl.availability.isAvailable else {
            print("transport unavailable: \(SoundControl.availability.unavailableReason ?? "?")")
            exit(1)
        }
        let started = Mono.now()
        var accepted: Bool?
        SoundControl.send(command) { ok in accepted = ok }
        // LINGER BEFORE EXITING, deliberately. Measured: a process that
        // exits in the same turn of the run loop tears the XPC connection
        // down before mediaremoted has read the message and the command is
        // lost every time; 5 ms was already enough to land it every time.
        // One second is the probe being unambiguous about it.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("sent \(command.title) (\(command.rawValue)) — accepted=\(accepted.map(String.init) ?? "?")"
              + " in \(pad(Mono.seconds(since: started) * 1000))")
        print("\"accepted\" means the message was QUEUED. It is true even when nothing")
        print("can act on it. Verify the effect against the app itself.")
        exit(0)
    }

    // MARK: cost

    /// Runs the watcher and NOTHING else for the window, printing only at
    /// the end so the print path cannot pollute the number.
    ///
    /// It measures itself with `IdleCost.taskThreadTimes()` — the project's
    /// own instrument, the one the 0.475% figure came from — because
    /// `task_for_pid` is refused to an unprivileged caller and a `ps -o
    /// time` delta quantises to 1/100 s, which is far too coarse for a
    /// feature that should cost thousandths of a core. The ps delta is
    /// still worth taking from outside as a cross-check.
    private static func cost(_ seconds: TimeInterval) -> Never {
        let model = IslandModel()
        let watcher = SoundWatcher(model: model)
        print("pid \(getpid()) — SoundWatcher only, \(Int(seconds)) s, silent until done")
        fflush(stdout)
        watcher.start()
        // The first HAL call in a process costs 140-350 ms establishing the
        // connection to the audio server (measured). It is paid once, on the
        // sampling queue, and would otherwise dominate a short window — so
        // the clock starts after the watcher's launch delay has let it
        // happen.
        RunLoop.current.run(until: Date().addingTimeInterval(15))
        let before = IdleCost.taskThreadTimes()
        let warm = watcher.stats
        let started = Date()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let after = IdleCost.taskThreadTimes()
        let wall = Date().timeIntervalSince(started)
        if let before, let after {
            let live = after.live - before.live
            let total = after.total - before.total
            print(String(format: "task_thread_times (live)   %.4f s over %.1f s wall"
                         + "  ->  %.4f%% of one core", live, wall, live / wall * 100))
            print(String(format: "task_thread_times + exited %.4f s"
                         + "  ->  %.4f%% of one core", total, total / wall * 100))
        }
        let raw = watcher.stats
        watcher.stop()
        // Deltas: the warm-up before the window is not part of the window.
        let sweeps = raw.sweeps - warm.sweeps
        let skips = raw.gateSkips - warm.gateSkips
        let sweepSeconds = raw.sweepSeconds - warm.sweepSeconds
        let gateSeconds = raw.gateSeconds - warm.gateSeconds
        print("window            : \(Int(wall)) s"
              + "  (warm-up before it: \(warm.sweeps) sweeps, \(warm.gateSkips) gate skips)")
        print("full sweeps       : \(sweeps)  total \(ms(sweepSeconds))"
              + "  mean \(sweeps > 0 ? pad(sweepSeconds / Double(sweeps) * 1000) : "—")")
        print("gate skips        : \(skips)  total \(ms(gateSeconds))"
              + "  mean \(skips > 0 ? pad(gateSeconds / Double(skips) * 1000) : "—")")
        let busy = sweepSeconds + gateSeconds
        print("HAL time in window: \(ms(busy))  = \(String(format: "%.4f", busy / wall * 100))% of one core")
        print("state now         : \(model.sound.apps.map { $0.map(\.name).joined(separator: ", ") } ?? "—")")
        exit(0)
    }

    // MARK: helpers

    private static func header() {
        print("=== MacPulse --sound-probe ===")
        let t = SoundControl.availability
        print("MediaRemote.framework loaded : \(t.frameworkLoaded)")
        print("MRMediaRemoteSendCommand     : \(t.sendResolved)")
        print("exposed commands             : "
              + t.commands.map { "\($0.probeName)=\($0.rawValue)" }.joined(separator: " "))
        print("transport usable             : \(t.isAvailable)"
              + (t.unavailableReason.map { "  (\($0))" } ?? ""))
        print("helper grouping              : \(SoundOutputSampler.helperGroupingAvailable)")
        print("now-playing READ             : false — entitlement-gated since macOS 15.4;")
        print("                               no title, no artist, no artwork, no play state.")
        print("")
    }

    private static func tail(of arguments: [String]) -> [String] {
        guard let i = arguments.firstIndex(of: "--sound-probe") else { return [] }
        return Array(arguments.dropFirst(i + 1))
    }

    /// `Double("1e400")` is +infinity and passes `v > 0`, and `Int(inf)`
    /// TRAPS — the same class of bug as the printer parser's. A duration
    /// from a string gets a finite range check, not a sign check.
    private static func seconds(_ rest: [String], default fallback: TimeInterval) -> TimeInterval {
        for token in rest {
            if let v = Double(token), v.isFinite, v > 0, v <= 86_400 { return v }
        }
        return fallback
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private static func pad(_ milliseconds: Double) -> String {
        String(format: "%7.3f ms", milliseconds)
    }

    private static func ms(_ seconds: Double) -> String {
        String(format: "%.3f ms", seconds * 1000)
    }
}

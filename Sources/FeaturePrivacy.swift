import AppKit
import CoreAudio
import CoreMediaIO
import Darwin

// =====================================================================
// THE PRIVACY RAIL'S DATA SOURCE: who is holding the microphone, and is
// the camera on.
//
// No SwiftUI in this file. `IslandPrivacyRail.swift` draws it.
//
// WHY THIS IS THE ONE FEATURE THAT CANNOT BE PREEMPTED. Everything else
// on the island is a convenience. This one answers "is something
// listening to me right now", on a machine that runs Zoom, Telegram and a
// voice recorder that launches at login. A safety signal that yields its
// pixels to a progress ring is not a safety signal.
//
// ---------------------------------------------------------------------
// MICROPHONE — public API, unprivileged, exact, event-driven.
//
// macOS 14 added process-level audio objects to the PUBLIC CoreAudio
// header AudioHardware.h: kAudioHardwarePropertyProcessObjectList ('prs#')
// and, per object, kAudioProcessPropertyPID ('ppid'),
// kAudioProcessPropertyBundleID ('pbid') and
// kAudioProcessPropertyIsRunningInput ('piri'). They hand you the PID of
// every process with a live input stream.
//
// NO PERMISSION AT ALL. The spike proved this properly rather than
// assuming it: a freshly built, ad-hoc-signed app with a never-before-seen
// bundle ID, launched detached via `open` so it was its own TCC
// responsible process and could not inherit the terminal's grants,
// reported mic TCC = notDetermined and camera TCC = notDetermined, was
// never prompted, and still read the process list and other apps'
// identities. No entitlement, no TCC, no sudo, no Accessibility.
//
// DEPLOYMENT TARGET. MacPulse builds against macOS 13.0 and these
// selectors are macOS 14+. They are plain FourCC enum constants, so they
// compile on a 13.0 target; on a 13.x machine the property query simply
// returns an error and the mic dot degrades to the device-level signal
// below, which has existed forever. Nothing is version-gated by hand.
//
// HONEST LABELLING — READ THIS BEFORE CHANGING THE TOOLTIP.
// `IsRunningInput` means "this process has an ACTIVE INPUT STREAM", not
// "this process is recording you this instant". The spike found the
// sibling property IsRunningOutput lagged play/pause by tens of seconds,
// so the same caution was owed here and was measured (see the report):
// the INPUT flag is prompt on the way up and on the way down, but it is
// still a stream-lifetime signal. An app that keeps the input device open
// while muted will light this dot. That is the SAFE direction to be wrong
// in — a false "something has the mic" costs a glance; a false "nothing
// has the mic" is the failure that matters — but the tooltip says
// "держит микрофон" (holds the microphone), never "записывает" (is
// recording), and it must keep saying that.
//
// ---------------------------------------------------------------------
// CAMERA — detection only, per device, and NOT attributed to an app.
//
// CoreMediaIO's kCMIODevicePropertyDeviceIsRunningSomewhere ('gone') is
// unprivileged, works on macOS 26, and is per-device, which usefully
// separates the built-in FaceTime camera from Continuity Camera.
//
// WHAT IS DELIBERATELY NOT SHIPPED: the name of the app holding the
// camera. There is no per-process camera API — the spike grepped every
// CoreMediaIO header. lsof cannot work (macOS has no /dev/video* nodes;
// cameras are IOKit user clients). The system log redacts every
// identifying field as <private> and un-redacting needs an admin logging
// profile, which the no-sudo contract forbids. The only route that names
// camera apps is walking the Control Center Accessibility popover, which
// needs an Accessibility grant, visibly flashes the panel open, merges
// mic and camera into ONE list so it cannot say which app uses which
// sensor, and lingers after apps stop. Shipping that would mean showing
// the user a name that might be wrong about a privacy question. So the
// camera dot says the camera is on and names the DEVICE; it never claims
// to name an app.
//
// ---------------------------------------------------------------------
// COST. Zero steady-state: these are property LISTENERS, not polls. The
// only measurable work is the first CMIO device enumeration (~70 ms),
// which is why it happens on a background queue five seconds after launch
// and never in applicationDidFinishLaunching.
// =====================================================================

/// What the rail draws. Bounded and already resolved to display strings.
struct PrivacyState: Equatable {
    /// At least one process has a live input stream, or the default input
    /// device reports itself running.
    var micActive = false
    /// Display names of the apps holding it. May be empty even when
    /// `micActive` is true — the device-level signal has no attribution.
    var micApps: [String] = []
    /// At least one video device reports itself running.
    var cameraActive = false
    /// DEVICE names ("HD-камера FaceTime"), never app names. See above.
    var cameraDevices: [String] = []

    var isQuiet: Bool { !micActive && !cameraActive }
}

/// Installs the listeners and publishes `PrivacyState` to the model.
/// Public surface is main-thread only.
final class PrivacyWatcher {

    /// Never show more than this many names; a machine in a video call
    /// can have four processes on the input device and the tooltip has to
    /// stay readable.
    private static let maxNames = 4
    private static let maxNameLength = 28

    /// The arch spike's rule: the first CMIO enumeration costs ~70 ms, so
    /// it happens well after launch and off the main thread.
    private let enumerateDelay: TimeInterval = 5

    /// Listener callbacks land here, and so does every scan.
    private let queue = DispatchQueue(label: "com.local.macpulse.privacy", qos: .utility)

    private weak var model: IslandModel?
    private var running = false

    // ---- CoreAudio ----
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var inputDevice: AudioObjectID = 0
    private var inputDeviceListener: AudioObjectPropertyListenerBlock?

    // ---- CoreMediaIO ----
    private var cameraDevices: [CMIOObjectID] = []
    private var cameraListeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var cameraListListener: CMIOObjectPropertyListenerBlock?

    /// Coalesces a burst of listener callbacks into one scan.
    private var scanPending = false

    init(model: IslandModel) {
        self.model = model
    }

    // MARK: - Lifecycle

    func start() {
        precondition(Thread.isMainThread)
        guard !running else { return }
        running = true
        queue.async { [weak self] in self?.installAudioListeners() }
        queue.asyncAfter(deadline: .now() + enumerateDelay) { [weak self] in
            self?.installCameraListeners()
            self?.scan()
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard running else { return }
        running = false
        queue.async { [weak self] in
            self?.removeAudioListeners()
            self?.removeCameraListeners()
        }
    }

    // MARK: - CoreAudio listeners

    private func installAudioListeners() {
        // The process list changes when any app opens or closes a stream.
        addSystemListener(kAudioHardwarePropertyProcessObjectList)
        // The user can switch to AirPods or a USB interface mid-session;
        // the device-level listener has to follow.
        addSystemListener(kAudioHardwarePropertyDefaultInputDevice)
        rebindInputDevice()
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if selector == kAudioHardwarePropertyDefaultInputDevice {
                self.rebindInputDevice()
            }
            self.requestScan()
        }
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        // A listener that could not be installed is not fatal: the dot
        // simply stops being live-updating for that signal. Never trap.
        if err == noErr { systemListeners.append((address, block)) }
    }

    /// Move the `IsRunningSomewhere` listener to whatever the default
    /// input device is now.
    private func rebindInputDevice() {
        var running = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        if inputDevice != 0, let old = inputDeviceListener {
            AudioObjectRemovePropertyListenerBlock(inputDevice, &running, queue, old)
            inputDeviceListener = nil
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size, &device)
        inputDevice = (err == noErr) ? device : 0
        guard inputDevice != 0 else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.requestScan()
        }
        if AudioObjectAddPropertyListenerBlock(inputDevice, &running, queue, block) == noErr {
            inputDeviceListener = block
        }
    }

    private func removeAudioListeners() {
        for (addr, block) in systemListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
        }
        systemListeners.removeAll()
        if inputDevice != 0, let block = inputDeviceListener {
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(inputDevice, &a, queue, block)
        }
        inputDeviceListener = nil
        inputDevice = 0
    }

    // MARK: - CoreMediaIO listeners

    private func installCameraListeners() {
        removeCameraListeners()
        cameraDevices = Self.videoDevices()
        for device in cameraDevices {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.requestScan()
            }
            if CMIOObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
                cameraListeners[device] = block
            }
        }

        // Continuity Camera and USB webcams come and go; re-enumerate when
        // the device list itself changes.
        guard cameraListListener == nil else { return }
        var listAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async {
                self.installCameraListeners()
                self.scan()
            }
        }
        if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject),
                                              &listAddress, queue, block) == noErr {
            cameraListListener = block
        }
    }

    private func removeCameraListeners() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        for (device, block) in cameraListeners {
            CMIOObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        cameraListeners.removeAll()
    }

    // MARK: - Scanning

    /// Coalesce. A single app starting a capture session emits several
    /// callbacks in a row, and the dossier found an ORDERING RACE: the
    /// process-list event fires slightly BEFORE the new process's
    /// IsRunningInput flag is set, so a scan on that first event reports
    /// "nobody". Hence two scans — one prompt, one late enough to have
    /// caught up.
    private func requestScan() {
        guard !scanPending else { return }
        scanPending = true
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.scanPending = false
            self.scan()
        }
        queue.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.scan()
        }
    }

    /// UTILITY QUEUE. Reads the hardware, then hands raw identities to
    /// main, which resolves display names (NSRunningApplication is a
    /// main-thread API).
    private func scan() {
        let holders = Self.inputHolders()
        let deviceRunning = Self.deviceIsRunning(inputDevice)
        let cameras = Self.runningCameras(cameraDevices)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            var state = PrivacyState()
            state.micActive = !holders.isEmpty || deviceRunning
            state.micApps = Self.displayNames(for: holders)
            state.cameraActive = !cameras.isEmpty
            state.cameraDevices = cameras
            self.model?.setPrivacy(state)
        }
    }

    // MARK: - CoreAudio reads

    private struct Holder {
        let pid: pid_t
        let bundleID: String?
    }

    /// Every process object whose `IsRunningInput` is 1.
    private static func inputHolders() -> [Holder] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr,
              size > 0, size < 64 * 1024 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }

        var out: [Holder] = []
        for id in ids {
            guard uint32Property(id, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            let pid = uint32Property(id, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) } ?? -1
            out.append(Holder(pid: pid, bundleID: stringProperty(id, kAudioProcessPropertyBundleID)))
        }
        return out
    }

    private static func uint32Property(_ object: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func stringProperty(_ object: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        // The header is explicit that the caller owns the returned
        // CFString; taking it as an unmanaged +1 reference and letting ARC
        // release it is how that ownership is honoured.
        let err = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let cf = value else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
    }

    private static func deviceIsRunning(_ device: AudioObjectID) -> Bool {
        guard device != 0 else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value == 1
    }

    // MARK: - CoreMediaIO reads

    static func videoDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject),
                                            &address, 0, nil, &size) == noErr,
              size > 0, size < 64 * 1024 else { return [] }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),
                                        &address, 0, nil, size, &used, &ids) == noErr
        else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    /// Names of the video devices that are running right now.
    static func runningCameras(_ devices: [CMIOObjectID]) -> [String] {
        var out: [String] = []
        for device in devices where cameraIsRunning(device) {
            out.append(cameraName(device) ?? "камера")
        }
        return out
    }

    static func cameraIsRunning(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil,
                                        UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
        else { return false }
        return value == 1
    }

    static func cameraName(_ device: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: CFString? = nil
        var used: UInt32 = 0
        let err = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            CMIOObjectGetPropertyData(device, &address, 0, nil,
                                      UInt32(MemoryLayout<CFString?>.size), &used, ptr)
        }
        guard err == noErr, let cf = value else { return nil }
        let s = (cf as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(maxNameLength))
    }

    // MARK: - Names (MAIN THREAD)

    /// PID -> something a human recognises.
    ///
    /// Electron and Chromium apps hold audio in a HELPER child process, so
    /// a naive lookup shows "Telegram Helper (Renderer)". The same private
    /// symbol ProcessSampler uses for its app grouping maps the helper
    /// back to its responsible app; when it is unavailable we fall back
    /// through NSRunningApplication, then the CoreAudio bundle ID, then
    /// libproc's process name — never to a raw pid on screen.
    private static func displayNames(for holders: [Holder]) -> [String] {
        precondition(Thread.isMainThread)
        var seen = Set<String>()
        var out: [String] = []
        for holder in holders {
            guard let name = displayName(for: holder) else { continue }
            guard seen.insert(name).inserted else { continue }
            out.append(name)
            if out.count >= maxNames { break }
        }
        return out
    }

    private static func displayName(for holder: Holder) -> String? {
        var pid = holder.pid
        if pid > 0, let fn = responsibilityFn {
            let owner = fn(pid)
            if owner > 0 { pid = owner }
        }
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return String(name.prefix(maxNameLength))
        }
        if let bundle = holder.bundleID {
            // com.apple.QuickTimePlayerX -> QuickTimePlayerX. Better than
            // a reverse-DNS string in a 22 pt tooltip.
            let tail = bundle.split(separator: ".").last.map(String.init) ?? bundle
            return String(tail.prefix(maxNameLength))
        }
        if holder.pid > 0, let name = processName(holder.pid) {
            return String(name.prefix(maxNameLength))
        }
        return nil
    }

    /// Diagnostics only (`--privacy-probe`): the RAW holders, before and
    /// after the responsible-process walk, so a verification run can show
    /// that the detector found the actual recording process rather than
    /// merely "something".
    static func describeHoldersForProbe() -> [String] {
        precondition(Thread.isMainThread)
        return inputHolders().map { h in
            let owner = (h.pid > 0 ? responsibilityFn?(h.pid) : nil) ?? h.pid
            let ownerName = owner > 0
                ? (NSRunningApplication(processIdentifier: owner)?.localizedName ?? "?")
                : "?"
            return "pid=\(h.pid) bundle=\(h.bundleID ?? "(none)") "
                + "proc=\(processName(h.pid) ?? "?") -> responsible pid=\(owner) (\(ownerName))"
                + "  => shown as \"\(displayName(for: h) ?? "?")\""
        }
    }

    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t
    private static let responsibilityFn: ResponsibilityFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -1),
                              "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibilityFn.self)
    }()

    private static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let name = String(cString: buf)
        return name.isEmpty ? nil : name
    }
}

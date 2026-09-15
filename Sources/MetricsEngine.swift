import Foundation
import AppKit

/// Opaque handle returned by `MetricsEngine.observe`. Keep it alive for as
/// long as you want the callback; dropping it does NOT unsubscribe — call
/// `remove(_:)`.
public struct MetricsObserverToken: Hashable, Sendable {
    fileprivate let id: UInt64
}

/// ============================================================================
/// THE ONE OBJECT THE UI TALKS TO.
///
///     MetricsEngine.shared.start()                       // once, from main
///     let token = MetricsEngine.shared.observe { snap in  // MAIN THREAD
///         label.stringValue = Fmt.rate(snap.memory?.rates?.decompressionBytesPerSec)
///     }
///     MetricsEngine.shared.latest      // most recent snapshot, may be nil
///     MetricsEngine.shared.history     // up to 60 snapshots, oldest first
///
/// All sampling happens on a dedicated serial DispatchQueue. Every piece of
/// delta state (previous CPU ticks, previous IOReport sample, previous
/// vm_statistics64, previous disk/network counters, previous per-PID rusage)
/// lives behind that queue and is never touched from main. Snapshots are
/// immutable value types handed across.
///
/// `latest`, `history`, `observe` and `remove` are MAIN-THREAD-ONLY.
/// ============================================================================
public final class MetricsEngine {

    public static let shared = MetricsEngine()

    // MARK: - Configuration

    /// Base tick. Sub-samplers run at multiples of this (see `Cadence`).
    public var interval: TimeInterval = 1.0

    /// How many snapshots the rolling history keeps. 60 at a 1 s tick is one
    /// minute of sparkline.
    public var historyLimit = 60

    /// Something that can actually display the expensive metrics. While
    /// this set is empty NOTHING ON SCREEN reads them — see `Cadence`.
    public enum DetailConsumer: Hashable, Sendable {
        /// The island's expanded panel (per-app rows, coverage line).
        case islandPanel
        /// The status item's menu (its header names the top app).
        case statusMenu
        /// `--probe`, which prints every metric and must see all of them.
        case probe
    }

    // =====================================================================
    // CADENCE — and read this before changing any of it, because the BASE
    // TICK IS NOT NEGOTIABLE and none of these numbers touch it.
    //
    // `interval` stays 1.0 s. Memory, CPU and network are sampled on EVERY
    // tick, always, whatever else is going on: memory and CPU are what the
    // status item's two bars and the island's pressure dot draw, and the
    // network counters the kernel exposes are 32-BIT, so skipping a tick
    // risks a wrap that would be read as a 4 GB burst.
    //
    // The rest is sampled at a multiple of the base tick, and the multiple
    // depends on whether anything can display the answer. Nothing in this
    // app draws power, temperature, disk, battery or the per-app table
    // while the panel and the menu are both shut — grep the UI: the
    // collapsed island reads `strip.pressure` and the status item reads
    // cpu.overall.busy / memory.usedFraction, and that is the entire
    // closed-state readout. Sampling IOReport and walking 397 PIDs once a
    // second to fill a struct that nothing reads is the definition of work
    // that is not worth its watts.
    //
    // MEASURED HERE (30 s `sample` on the live app, 1.28 ms per sample,
    // shares of one core):
    //     ProcessSampler.sample     397-PID proc_pid_rusage walk   0.60%
    //     PowerSampler.sample       IOReport + per-channel strings 0.52%
    //     SMCSampler.temperatures   ~42 ioctls, every 5th tick     0.23%
    //     DiskSampler.refreshCapacity  one call, every 30th tick   0.14%
    //     everything else on the queue                             0.13%
    // i.e. the queue was 1.62% of a core on its own, and 1.26% of that was
    // being spent on values that were not on screen.
    //
    // THE LAST MEASURED VALUE IS CARRIED FORWARD on a skipped tick, exactly
    // as the SMC temperatures and the battery already were. That is a real
    // measurement a few seconds old, not a fabricated one — and
    // `MetricsSnapshot.refreshed` still names only the metrics that were
    // genuinely re-read this tick, so nothing downstream can mistake a
    // carried value for a fresh one.
    // =====================================================================
    private enum Cadence {
        /// SMC is one ioctl per sensor key (~0.28 ms each, ~42 keys here), so
        /// an SMC tick costs ~12 ms against ~3 ms for a normal one. Silicon
        /// temperature does not move meaningfully in 5 s, so pay it at 1/5 the
        /// rate: amortized that is under 5 ms per tick, on a utility queue.
        static let smcTicks = 5
        /// ...and it moves no faster when nobody is reading it.
        static let smcIdleTicks = 15

        static let batteryTicks = 5
        /// A battery percentage that changed inside 30 s is a battery on
        /// fire. Nothing displays it while the panel is shut in any case.
        static let batteryIdleTicks = 30

        /// Free space barely moves and the query is the most expensive one
        /// here — measured at ~42 ms, because `volumeAvailableCapacityFor…`
        /// goes all the way into CacheDelete and walks the APFS volume
        /// roles. Every 30 s while somebody is looking; every 10 minutes
        /// otherwise.
        static let diskCapacityTicks = 30
        static let diskCapacityIdleTicks = 600

        /// The per-app table: one `proc_pid_rusage` syscall for every PID on
        /// the machine. Only the open panel and the menu header show it.
        static let processTicks = 1
        static let processIdleTicks = 5

        /// IOReport "Energy Model". Nothing draws watts while the panel is
        /// shut; sampled at 1/5 the rate the delta simply covers 5 s, which
        /// is a true average over that window rather than an estimate.
        static let powerTicks = 1
        static let powerIdleTicks = 5

        /// SAFETY NET ONLY for the pid -> app-name map. That map is rebuilt
        /// when NSWorkspace says an app launched or quit, which is the only
        /// way it can change; this is the floor in case a notification is
        /// ever missed (fast user switching, a wake that drops one).
        ///
        /// It used to be every 2 ticks. Measured with `sample` on the live
        /// app: `pushAppIdentities` was 63 ms of main-thread CPU in a 20 s
        /// window — 0.32% of one core, the single largest cost left in the
        /// app and larger than the whole sampling queue's process walk.
        /// `NSWorkspace.runningApplications` is a cross-process query and
        /// it was being asked, thirty times a minute, a question whose
        /// answer had not changed.
        static let appIdentityFloorTicks = 60
    }

    // MARK: - Main-thread state

    /// Most recent snapshot. Main thread only.
    public private(set) var latest: MetricsSnapshot?
    /// Rolling buffer, oldest first, capped at `historyLimit`. Main thread only.
    public private(set) var history: [MetricsSnapshot] = []
    /// Posted on the main thread after `latest`/`history` are updated.
    /// `notification.object` is the `MetricsSnapshot`.
    public static let didUpdateNotification = Notification.Name("MacPulse.MetricsDidUpdate")

    private var observers: [MetricsObserverToken: (MetricsSnapshot) -> Void] = [:]
    private var nextObserverID: UInt64 = 1
    private var isRunning = false
    /// Both notification tokens are held so `stop()` can remove them. A token
    /// that is dropped on the floor is an observer that lives until the
    /// process exits and keeps firing after stop().
    private var thermalObserver: NSObjectProtocol?
    private var powerStateObserver: NSObjectProtocol?
    /// NSWorkspace launch/terminate observers, held so `stop()` can remove
    /// them — a dropped token is a subscription that outlives stop().
    private var appObservers: [NSObjectProtocol] = []
    /// Last map handed to the sampling queue, so an unchanged one is not
    /// handed over again.
    private var lastAppIdentities: [pid_t: AppIdentity] = [:]
    private var appIdentityRefreshScheduled = false
    /// Who is currently able to SEE the expensive metrics. Main thread.
    private var detailConsumers: Set<DetailConsumer> = []

    // MARK: - Sampling-queue state (NEVER touch from main)

    private let queue = DispatchQueue(label: "com.local.macpulse.metrics", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?

    private let memorySampler = MemorySampler()
    private let cpuSampler = CPUSampler()
    private let processSampler = ProcessSampler()
    private let networkSampler = NetworkSampler()
    private let diskSampler = DiskSampler()
    private lazy var powerSampler: PowerSampler? = PowerSampler()
    private lazy var smcSampler: SMCSampler? = SMCSampler()
    private lazy var gpuSampler: GPUSampler? = GPUSampler()

    private var tickCount = 0
    private var lastSnapshotAt: UInt64?
    /// Queue-side mirror of `detailConsumers`. Never read from main.
    private var detailed = false
    /// Ticks since each slow sampler last actually ran. Counters rather than
    /// `tickCount % n`, because `n` changes when the panel opens and a
    /// modulo would then skip or double-fire at the boundary. Seeded high
    /// so every one of them runs on the first tick.
    private var ticksSinceProcesses = Int.max / 2
    private var ticksSincePower = Int.max / 2
    private var ticksSinceSMC = Int.max / 2
    private var ticksSinceBattery = Int.max / 2
    private var ticksSinceDiskCapacity = Int.max / 2
    /// Carried forward between ticks for the slow-cadence samplers.
    private var lastThermal: ThermalMetrics?
    private var lastBattery: BatteryMetrics?
    private var lastProcesses: ProcessMetrics?
    private var lastIOReportPower: PowerMetrics?
    private var lastSMCTemps: (perf: Double?, eff: Double?, gpu: Double?, battery: Double?, peak: Double?)?
    private var lastSMCPower: (system: Double?, adapter: Double?, battery: Double?)?
    /// Mirrored from ProcessInfo's notification so the sample path never has
    /// to poll it.
    private var thermalState: ThermalPressure = .nominal
    private var lowPowerMode = false

    private init() {}

    // MARK: - Lifecycle

    /// Start sampling. Call from the main thread. Idempotent.
    public func start() {
        precondition(Thread.isMainThread, "MetricsEngine.start() must be called from the main thread")
        guard !isRunning else { return }
        isRunning = true

        observeThermalState()
        observeAppLaunches()
        pushAppIdentities()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()

        // The kernel tells us the moment pressure changes; take an immediate
        // extra sample instead of waiting up to a full interval to notice.
        // Rate-limited: on a machine that sits in .warning these events can
        // arrive in bursts, and every extra tick shortens the dt of the next
        // one, which makes the churn rate noisier for no benefit.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if let last = self.lastSnapshotAt, Mono.seconds(since: last) < 0.5 { return }
            self.tick()
        }
        self.pressureSource = source
        source.resume()
    }

    public func stop() {
        precondition(Thread.isMainThread, "MetricsEngine.stop() must be called from the main thread")
        guard isRunning else { return }
        isRunning = false
        timer?.cancel(); timer = nil
        pressureSource?.cancel(); pressureSource = nil
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
        for token in appObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        appObservers.removeAll()
    }

    // MARK: - Subscription

    /// Register a callback invoked on the MAIN THREAD after every snapshot.
    @discardableResult
    public func observe(_ block: @escaping (MetricsSnapshot) -> Void) -> MetricsObserverToken {
        precondition(Thread.isMainThread, "MetricsEngine.observe must be called from the main thread")
        let token = MetricsObserverToken(id: nextObserverID)
        nextObserverID += 1
        observers[token] = block
        if let latest { block(latest) }   // don't make a new subscriber wait a tick
        return token
    }

    public func remove(_ token: MetricsObserverToken) {
        precondition(Thread.isMainThread)
        observers.removeValue(forKey: token)
    }

    /// Map the history buffer to a sparkline series, dropping samples where
    /// the value was unavailable.
    public func series<T>(_ transform: (MetricsSnapshot) -> T?) -> [T] {
        precondition(Thread.isMainThread)
        return history.compactMap(transform)
    }

    /// Force an out-of-band sample (e.g. the menu is about to open). The
    /// snapshot still arrives asynchronously through the normal path.
    public func refreshNow() {
        queue.async { [weak self] in self?.tick() }
    }

    /// Say whether something that can DISPLAY the expensive metrics is on
    /// screen. Balanced calls: whoever passes `true` must pass `false`.
    ///
    /// This does not change the base tick — memory, CPU and network are
    /// sampled every second either way. It changes how often the metrics
    /// that nothing can currently show are re-read. See `Cadence`.
    ///
    /// Turning detail ON does not force an immediate tick, on purpose: an
    /// extra tick milliseconds after the last one gives every delta-based
    /// metric a near-zero dt and prints a garbage first number at exactly
    /// the moment the user looks. Instead the slow samplers are marked due,
    /// so the next ordinary tick — at most one second away — refreshes all
    /// of them. Until it lands the panel shows the carried-forward values,
    /// which are real measurements a few seconds old, never blanks.
    public func setDetail(_ consumer: DetailConsumer, needed: Bool) {
        precondition(Thread.isMainThread)
        let wasNeeded = !detailConsumers.isEmpty
        if needed { detailConsumers.insert(consumer) } else { detailConsumers.remove(consumer) }
        let isNeeded = !detailConsumers.isEmpty
        guard wasNeeded != isNeeded else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.detailed = isNeeded
            guard isNeeded else { return }
            self.ticksSinceProcesses = Int.max / 2
            self.ticksSincePower = Int.max / 2
            self.ticksSinceSMC = Int.max / 2
            self.ticksSinceBattery = Int.max / 2
            self.ticksSinceDiskCapacity = Int.max / 2
        }
    }

    // MARK: - The tick (SAMPLING QUEUE)

    /// True on the tick a slow sampler is due, and resets its counter.
    private func due(_ ticksSince: inout Int, every n: Int) -> Bool {
        ticksSince += 1
        guard ticksSince >= max(1, n) else { return false }
        ticksSince = 0
        return true
    }

    private func tick() {
        dispatchPrecondition(condition: .onQueue(queue))
        let started = Mono.now()
        tickCount += 1
        var refreshed = Set<MetricKind>()
        let detailed = self.detailed

        // Clipboard history. MEASURED 1.32 us when the clipboard has not
        // moved, which is >99% of ticks — the cheap check IS `changeCount`,
        // one integer read, and 1.32 us at 1 Hz is 0.00013% of one core.
        // The 63.5 us capture path runs on a user copy, not on a tick, so
        // this needs no cadence multiplier and no `detailed` gate: it is
        // cheaper than a single SMC key read (0.28 ms). Nothing here can
        // block on a lock the main thread holds. See ClipboardEngine.swift.
        //
        // It stays at the TOP of the tick and OUTSIDE `due(...)`: a
        // clipboard history that only records while the panel is open is
        // not a history. This is the ONLY line the second wave of features
        // added to this tick — the other four are driven by their own
        // watchers and MetricsEngine never learns they exist.
        ClipboardEngine.shared.poll()

        // --- EVERY tick, unconditionally ---
        //
        // Memory and CPU are the closed-state readout (the status item's two
        // bars, the island's pressure dot). Network is here because the
        // kernel's per-interface byte counters are 32-BIT: this sampler
        // reconstructs the delta modulo 2^32, which is only sound while the
        // sampling interval is short enough that no interface can move 4 GB
        // between two reads. Slowing it down would turn a fast transfer into
        // a wrapped, silently wrong rate. It costs 0.055% of a core.
        let memory = memorySampler.sample()
        if memory != nil { refreshed.insert(.memory) }

        let cpu = cpuSampler.sample()
        if cpu != nil { refreshed.insert(.cpu) }

        let network = networkSampler.sample()
        if network != nil { refreshed.insert(.network) }

        let gpu = gpuSampler?.sample()
        if gpu != nil { refreshed.insert(.gpu) }

        // --- slow cadences: resample, else carry the previous value forward ---
        //
        // The per-app table is one syscall PER PID — 397 of them on this
        // machine, 0.60% of a core at 1 Hz — and only the open panel and the
        // menu header ever show it.
        if due(&ticksSinceProcesses,
               every: detailed ? Cadence.processTicks : Cadence.processIdleTicks)
            || lastProcesses == nil {
            if let fresh = processSampler.sample() {
                lastProcesses = fresh
                refreshed.insert(.processes)
            }
        }
        let processes = lastProcesses

        if due(&ticksSinceSMC, every: detailed ? Cadence.smcTicks : Cadence.smcIdleTicks)
            || lastSMCTemps == nil {
            if let smc = smcSampler {
                lastSMCTemps = smc.temperatures()
                lastSMCPower = (smc.systemWatts(), smc.adapterWatts(), smc.batteryWatts())
                refreshed.insert(.thermal)
            }
        }

        if due(&ticksSinceBattery, every: detailed ? Cadence.batteryTicks : Cadence.batteryIdleTicks)
            || lastBattery == nil {
            lastBattery = BatterySampler.sample()
            if lastBattery != nil { refreshed.insert(.battery) }
        }

        if due(&ticksSinceDiskCapacity,
               every: detailed ? Cadence.diskCapacityTicks : Cadence.diskCapacityIdleTicks) {
            diskSampler.refreshCapacity()
        }
        let disk = diskSampler.sample()
        if disk != nil { refreshed.insert(.disk) }

        // --- power: IOReport on its own cadence, SMC totals from the cache ---
        //
        // Skipping a tick does NOT skip any energy: IOReport counters are
        // cumulative and the sampler divides by its own measured dt, so a
        // reading taken every fifth tick is the true average over those five
        // seconds rather than a sample of one of them.
        if due(&ticksSincePower, every: detailed ? Cadence.powerTicks : Cadence.powerIdleTicks)
            || lastIOReportPower == nil {
            if let fresh = powerSampler?.sample() {
                lastIOReportPower = fresh
                refreshed.insert(.power)
            }
        }
        var power = lastIOReportPower
        let smcPower = lastSMCPower
        if let existing = power {
            power = existing.mergingSMC(system: smcPower?.system,
                                        adapter: smcPower?.adapter,
                                        battery: smcPower?.battery)
        } else if let smcPower {
            // IOReport gone, but the SMC still knows the whole-machine draw.
            power = PowerMetrics.smcOnly(system: smcPower.system,
                                         adapter: smcPower.adapter,
                                         battery: smcPower.battery)
            if power != nil { refreshed.insert(.power) }
        }

        let temps = lastSMCTemps
        let thermal = ThermalMetrics(
            state: thermalState,
            lowPowerMode: lowPowerMode,
            cpuPerformanceCelsius: temps?.perf,
            cpuEfficiencyCelsius: temps?.eff,
            gpuCelsius: temps?.gpu,
            batteryCelsius: temps?.battery ?? lastBattery?.temperatureCelsius,
            cpuPeakCelsius: temps?.peak
        )
        lastThermal = thermal

        let now = Mono.now()
        let elapsed = lastSnapshotAt.map { Mono.seconds(from: $0, to: now) } ?? 0
        lastSnapshotAt = now

        let snapshot = MetricsSnapshot(
            date: Date(),
            interval: elapsed,
            sampleCostMs: Mono.seconds(since: started) * 1000,
            refreshed: refreshed,
            memory: memory,
            cpu: cpu,
            processes: processes,
            power: power,
            thermal: thermal,
            gpu: gpu,
            battery: lastBattery,
            disk: disk,
            network: network
        )

        DispatchQueue.main.async { [weak self] in self?.publish(snapshot) }

        if tickCount % Cadence.appIdentityFloorTicks == 0 {
            DispatchQueue.main.async { [weak self] in self?.pushAppIdentities() }
        }
    }

    // MARK: - Publishing (MAIN THREAD)

    private func publish(_ snapshot: MetricsSnapshot) {
        latest = snapshot
        history.append(snapshot)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        for block in observers.values { block(snapshot) }
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: snapshot)
    }

    /// NSWorkspace is a main-thread API, so the pid -> app-name map is built
    /// here and pushed to the sampling queue as an immutable value.
    ///
    /// PUSH, NOT POLL. The map can only change when an app launches or
    /// quits, and NSWorkspace says so; polling it every two seconds cost
    /// 0.32% of one core to rebuild an identical dictionary (measured with
    /// `sample` on the live app: 63 ms of main-thread CPU in 20 s, the
    /// largest single cost in the process). `Cadence.appIdentityFloorTicks`
    /// is the safety net, not the mechanism.
    ///
    /// Also compared before it is handed over: an app quitting changes one
    /// key, and there is no reason for the sampling queue to take a new
    /// dictionary when nothing in it differs.
    private func pushAppIdentities() {
        precondition(Thread.isMainThread)
        var map: [pid_t: AppIdentity] = [:]
        map.reserveCapacity(lastAppIdentities.count + 8)
        for app in NSWorkspace.shared.runningApplications {
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
            map[app.processIdentifier] = AppIdentity(name: name, bundleIdentifier: app.bundleIdentifier)
        }
        guard map != lastAppIdentities else { return }
        lastAppIdentities = map
        queue.async { [weak self] in self?.processSampler.updateAppIdentities(map) }
    }

    /// Rebuild the identity map the moment the set of running apps can have
    /// changed, and never in between. Coalesced onto the next main-queue
    /// turn: launching an app emits several notifications in a row and
    /// walking `runningApplications` once per notification would put the
    /// poll back with extra steps.
    private func observeAppLaunches() {
        let wc = NSWorkspace.shared.notificationCenter
        let schedule = { [weak self] (_: Notification) in
            guard let self, !self.appIdentityRefreshScheduled else { return }
            self.appIdentityRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.appIdentityRefreshScheduled = false
                self.pushAppIdentities()
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(wc.addObserver(forName: name, object: nil, queue: .main, using: schedule))
        }
    }

    private func observeThermalState() {
        let apply = { [weak self] in
            let info = ProcessInfo.processInfo
            let state = ThermalPressure(rawValue: info.thermalState.rawValue) ?? .nominal
            let lowPower = info.isLowPowerModeEnabled
            self?.queue.async {
                self?.thermalState = state
                self?.lowPowerMode = lowPower
            }
        }
        apply()
        // BOTH tokens are stored. addObserver(forName:) returns an opaque
        // observer object that NotificationCenter owns until it is removed;
        // discarding the return value leaves a subscription that cannot be
        // cancelled and that keeps calling `apply` after stop().
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { _ in apply() }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main) { _ in apply() }
    }

    // MARK: - Availability report (for diagnostics and the probe)

    public struct Availability: Sendable {
        public let ioReportLoaded: Bool
        public let powerSubscription: Bool
        public let smcOpen: Bool
        public let smcSensorCount: Int
        public let smcDiscoveryMs: Double
        public let gpuAccelerator: String?
        public let helperGrouping: Bool
        public let pageSize: UInt64
        public let clusterLayout: String
        /// Every IOReport "Energy Model" channel with its reported unit label
        /// and the watts we derive from it. Diagnostics only.
        public let powerChannels: [(name: String, unit: String, watts: Double?)]
    }

    /// Synchronous; safe from any thread. Spins up the lazy samplers if they
    /// have not been created yet.
    public func availability() -> Availability {
        queue.sync {
            let smc = smcSampler
            let sensors = (smc?.performanceKeys.count ?? 0) + (smc?.efficiencyKeys.count ?? 0)
                        + (smc?.gpuKeys.count ?? 0) + (smc?.batteryKeys.count ?? 0)
            let kinds = HostInfo.shared.coreClusterKinds
            return Availability(
                ioReportLoaded: IOReportLib.shared != nil,
                powerSubscription: powerSampler != nil,
                smcOpen: smc != nil,
                smcSensorCount: sensors,
                smcDiscoveryMs: smc?.discoveryMs ?? 0,
                gpuAccelerator: gpuSampler?.name,
                helperGrouping: dlsym(UnsafeMutableRawPointer(bitPattern: -1),
                                      "responsibility_get_pid_responsible_for_pid") != nil,
                pageSize: HostInfo.shared.pageSize,
                clusterLayout: kinds.map { $0.rawValue }.joined(),
                powerChannels: powerSampler?.channelInventory() ?? []
            )
        }
    }
}

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

    private enum Cadence {
        /// SMC is one ioctl per sensor key (~0.28 ms each, ~42 keys here), so
        /// an SMC tick costs ~12 ms against ~3 ms for a normal one. Silicon
        /// temperature does not move meaningfully in 5 s, so pay it at 1/5 the
        /// rate: amortized that is under 5 ms per tick, on a utility queue.
        static let smcTicks = 5
        static let batteryTicks = 5
        /// Free space barely moves and the query is the most expensive one here.
        static let diskCapacityTicks = 30
        /// Refresh the pid -> NSRunningApplication name map.
        static let appIdentityTicks = 2
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
    private var thermalObserver: NSObjectProtocol?

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
    /// Carried forward between ticks for the slow-cadence samplers.
    private var lastThermal: ThermalMetrics?
    private var lastBattery: BatteryMetrics?
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

    // MARK: - The tick (SAMPLING QUEUE)

    private func tick() {
        dispatchPrecondition(condition: .onQueue(queue))
        let started = Mono.now()
        tickCount += 1
        var refreshed = Set<MetricKind>()

        // --- every tick ---
        let memory = memorySampler.sample()
        if memory != nil { refreshed.insert(.memory) }

        let cpu = cpuSampler.sample()
        if cpu != nil { refreshed.insert(.cpu) }

        let processes = processSampler.sample()
        if processes != nil { refreshed.insert(.processes) }

        let network = networkSampler.sample()
        if network != nil { refreshed.insert(.network) }

        let gpu = gpuSampler?.sample()
        if gpu != nil { refreshed.insert(.gpu) }

        // --- slow cadences: resample, else carry the previous value forward ---
        if tickCount % Cadence.smcTicks == 1 || lastSMCTemps == nil {
            if let smc = smcSampler {
                lastSMCTemps = smc.temperatures()
                lastSMCPower = (smc.systemWatts(), smc.adapterWatts(), smc.batteryWatts())
                refreshed.insert(.thermal)
            }
        }

        if tickCount % Cadence.batteryTicks == 1 || lastBattery == nil {
            lastBattery = BatterySampler.sample()
            if lastBattery != nil { refreshed.insert(.battery) }
        }

        if tickCount % Cadence.diskCapacityTicks == 1 {
            diskSampler.refreshCapacity()
        }
        let disk = diskSampler.sample()
        if disk != nil { refreshed.insert(.disk) }

        // --- power: IOReport every tick, SMC totals merged from the cache ---
        var power = powerSampler?.sample()
        if power != nil { refreshed.insert(.power) }
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

        if tickCount % Cadence.appIdentityTicks == 0 {
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
    private func pushAppIdentities() {
        var map: [pid_t: AppIdentity] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
            map[app.processIdentifier] = AppIdentity(name: name, bundleIdentifier: app.bundleIdentifier)
        }
        queue.async { [weak self] in self?.processSampler.updateAppIdentities(map) }
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
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { _ in apply() }
        NotificationCenter.default.addObserver(
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

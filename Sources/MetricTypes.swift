import Foundation

// =====================================================================
// MacPulse metrics — the PUBLIC API SURFACE.
//
// Everything in this file is an immutable value type. A `MetricsSnapshot`
// is produced on MetricsEngine's private serial queue and handed to the
// main thread; it is safe to hold, copy and read from anywhere.
//
// DESIGN RULE THAT MATTERS: every metric is Optional and degrades
// INDEPENDENTLY. `nil` means "we could not measure this" and is never the
// same thing as a measured 0.0. Do not substitute 0 for nil in the UI —
// render "—" instead. ANE power really is 0.000 W when idle; that is a
// Double(0), not a nil.
// =====================================================================

// MARK: - Memory

/// Authoritative kernel memory pressure, from
/// `sysctl kern.memorystatus_vm_pressure_level`.
/// This is the signal the kernel actually makes decisions on — use it to
/// drive COLOR. (Do not use `vm.memory_pressure`; it returns ~190 and means
/// something else entirely.)
public enum MemoryPressureLevel: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

/// Derivative (per-second) memory counters. `nil` on the very first tick,
/// because a rate needs two samples.
public struct MemoryRates: Sendable {
    /// Wall-clock seconds actually elapsed between the two samples these
    /// rates were derived from. Never assume it equals the nominal interval.
    public let interval: TimeInterval

    // ---- THE HEADLINE METRIC ----
    /// Pages compressed per second by the VM compressor.
    public let compressionsPerSec: Double
    /// Pages decompressed per second (a page being faulted back in).
    public let decompressionsPerSec: Double
    /// `compressionsPerSec * pageSize`.
    public let compressionBytesPerSec: Double
    /// `decompressionsPerSec * pageSize`. Sustained >50 MB/s is the exact
    /// moment this machine "feels slow", and no shipping tool displays it.
    public let decompressionBytesPerSec: Double

    // ---- swap ----
    public let swapInsPerSec: Double
    public let swapOutsPerSec: Double
    public let swapInBytesPerSec: Double
    public let swapOutBytesPerSec: Double

    // ---- paging ----
    public let pageInsPerSec: Double
    public let pageOutsPerSec: Double
    public let pageInBytesPerSec: Double
    public let pageOutBytesPerSec: Double
    public let faultsPerSec: Double

    /// Total compressor traffic in bytes/s (in + out) — a single number for a
    /// one-line readout.
    public var compressorChurnBytesPerSec: Double {
        compressionBytesPerSec + decompressionBytesPerSec
    }
}

public struct MemoryMetrics: Sendable {
    /// 16384 on Apple silicon, NOT 4096. Every rate above is already
    /// converted to bytes using this.
    public let pageSize: UInt64
    public let totalBytes: UInt64

    /// active + inactive + speculative + wired + compressed − purgeable − external.
    /// This is what Stats and macmon both compute, and it tracks Activity
    /// Monitor / `top`'s "used" closely.
    public let usedBytes: UInt64
    public let freeBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let speculativeBytes: UInt64
    public let wiredBytes: UInt64
    /// Size of the compressor pool itself (compressor_page_count × pageSize).
    public let compressedBytes: UInt64
    public let purgeableBytes: UInt64
    /// File-backed (clean, reclaimable) pages.
    public let externalBytes: UInt64

    /// usedBytes − wired − compressed. Activity Monitor's "App Memory".
    public let appBytes: UInt64
    /// purgeable + external. Activity Monitor's "Cached Files".
    public let cacheBytes: UInt64

    /// Logical bytes currently stored inside the compressor pool before
    /// compression. `uncompressedInCompressorBytes / compressedBytes` is the
    /// achieved compression ratio.
    public let uncompressedInCompressorBytes: UInt64
    public var compressionRatio: Double? {
        guard compressedBytes > 0 else { return nil }
        return Double(uncompressedInCompressorBytes) / Double(compressedBytes)
    }

    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    /// nil if the sysctl failed or returned a level we don't recognise.
    public let pressureLevel: MemoryPressureLevel?
    /// The widely-copied `(wired + compressed) / total` heuristic, 0...1.
    /// Good for a BAR HEIGHT. It is NOT Apple's formula — Apple documents the
    /// factors, never the expression — so never label it "Activity Monitor's
    /// memory pressure". Color must come from `pressureLevel`.
    public let pressureHeuristic: Double

    // ---- swap size (sysctl vm.swapusage) ----
    public let swapTotalBytes: UInt64?
    public let swapUsedBytes: UInt64?
    public let swapFreeBytes: UInt64?
    public let swapEncrypted: Bool?

    /// nil on the first tick only.
    public let rates: MemoryRates?
}

// MARK: - CPU

public struct CPULoad: Sendable {
    /// All fractions 0...1 of the interval.
    public let user: Double
    public let system: Double
    public let nice: Double
    public let idle: Double
    /// 1 − idle.
    public var busy: Double { max(0, min(1, 1 - idle)) }
}

public enum CPUClusterKind: String, Sendable {
    case performance = "P"
    case efficiency = "E"
    case other = "?"
}

public struct CPUCluster: Sendable {
    public let name: String          // "P-cores" / "E-cores"
    public let kind: CPUClusterKind
    public let coreCount: Int
    public let load: CPULoad
    /// Logical CPU indices in this cluster, in `cores` order.
    public let coreIndices: [Int]
}

public struct CPUMetrics: Sendable {
    public let interval: TimeInterval
    /// Whole-machine average across all logical CPUs.
    public let overall: CPULoad
    /// P and E aggregated. Empty only if topology detection failed entirely.
    public let clusters: [CPUCluster]
    /// Per-logical-core, index-aligned with the kernel's ordering.
    public let cores: [CPULoad]
    public let loadAverage1: Double
    public let loadAverage5: Double
    public let loadAverage15: Double

    public var performance: CPUCluster? { clusters.first { $0.kind == .performance } }
    public var efficiency: CPUCluster? { clusters.first { $0.kind == .efficiency } }
}

// MARK: - Processes

/// One row of the per-app memory table. Helper processes are already folded
/// into their responsible app, so Cursor's 6 helpers are ONE row.
public struct AppUsage: Sendable, Identifiable {
    /// The responsible PID — pass this to `NSRunningApplication(processIdentifier:)`
    /// on the main thread to get `.icon`.
    public let pid: pid_t
    public var id: pid_t { pid }
    public let name: String
    public let bundleIdentifier: String?
    /// `ri_phys_footprint`, summed over the group. This is the same kernel
    /// ledger Activity Monitor's "Memory" column and `top`'s MEM use.
    /// NEVER use RSS: measured 40× wrong here (Telegram 44 MB RSS vs
    /// 1780 MB phys_footprint).
    public let footprintBytes: UInt64
    /// Sum of `ri_lifetime_max_phys_footprint` over the group's members — i.e.
    /// the sum of each process's own high-water mark. That is an UPPER BOUND on
    /// what the group ever held at one instant, not a measurement of it: the
    /// members do not all peak simultaneously. Label it "peak (max of each)",
    /// never "this app once used N".
    public let peakFootprintBytes: UInt64
    /// Percent of ONE core (top-style; can exceed 100). nil on first tick.
    public let cpuPercent: Double?
    /// Bytes/s written to disk by this group. nil on first tick.
    public let diskWriteBytesPerSec: Double?
    /// Every PID folded into this row, responsible PID first.
    public let memberPIDs: [pid_t]
    /// True when the responsible PID is a real NSRunningApplication (so the
    /// UI can offer Quit and show an icon).
    public let isApplication: Bool
}

public struct ProcessMetrics: Sendable {
    public let interval: TimeInterval
    /// Sorted by `footprintBytes` descending.
    public let apps: [AppUsage]
    /// PIDs `proc_listpids` reported.
    public let pidCount: Int
    /// PIDs we could actually read. UNPRIVILEGED WE CAN ONLY SEE OUR OWN
    /// UID — measured 258 of 442. Do not label this list "all processes";
    /// label it "your apps".
    public let introspectedCount: Int
    /// Sum of footprints over the rows we could see.
    public let totalFootprintBytes: UInt64
    /// Sum of per-app disk write rates. nil on first tick.
    public let totalDiskWriteBytesPerSec: Double?
    /// False when `responsibility_get_pid_responsible_for_pid` could not be
    /// resolved; rows are then per-process rather than per-app.
    public let helperGroupingAvailable: Bool
}

// MARK: - Power

public struct PowerMetrics: Sendable {
    public let interval: TimeInterval
    /// All values in WATTS. Each is nil when its IOReport channel is absent
    /// on this chip, or when its unit label was not one we recognise.
    /// A present 0.0 is a real zero (ANE idles at exactly 0 W).
    public let cpuWatts: Double?
    public let gpuWatts: Double?
    public let aneWatts: Double?
    public let dramWatts: Double?
    public let gpuSRAMWatts: Double?
    /// cpu + gpu + ane, over whichever of those are present. nil if none are.
    public let packageWatts: Double?
    /// Whole-machine draw from SMC key `PSTR`. IOReport cannot produce this.
    public let systemWatts: Double?
    /// SMC `PDTR` — power coming in from the charger.
    public let adapterWatts: Double?
    /// SMC `PPBR` — battery draw (negative when charging on some machines).
    public let batteryWatts: Double?
}

// MARK: - Thermal / sensors

public enum ThermalPressure: Int, Sendable {
    case nominal = 0, fair = 1, serious = 2, critical = 3
    public var label: String {
        ["Nominal", "Fair", "Serious", "Critical"][rawValue]
    }
}

public struct ThermalMetrics: Sendable {
    public let state: ThermalPressure
    public let lowPowerMode: Bool
    /// Degrees Celsius, averaged over the SMC sensors in each family.
    /// nil when the SMC is unreachable or that family has no keys.
    public let cpuPerformanceCelsius: Double?
    public let cpuEfficiencyCelsius: Double?
    public let gpuCelsius: Double?
    public let batteryCelsius: Double?
    /// Max over every CPU sensor — the number to show as "CPU temp".
    public let cpuPeakCelsius: Double?
}

// MARK: - GPU

public struct GPUMetrics: Sendable {
    public let name: String?
    /// 0...1. From IOAccelerator "Device Utilization %".
    public let utilization: Double?
    public let rendererUtilization: Double?
    public let tilerUtilization: Double?
    public let allocatedBytes: UInt64?
}

// MARK: - Battery

public struct BatteryMetrics: Sendable {
    /// 0...1.
    public let charge: Double?
    public let isCharging: Bool?
    public let isOnAC: Bool?
    /// Seconds. nil = unknown or not applicable (on AC / still calculating).
    public let timeToEmpty: TimeInterval?
    public let timeToFull: TimeInterval?
    public let cycleCount: Int?
    /// AppleRawMaxCapacity / DesignCapacity, 0...1.
    public let health: Double?
    public let designCapacitymAh: Int?
    public let currentCapacitymAh: Int?
    public let voltage: Double?      // volts
    public let amperage: Double?     // amps, negative = discharging
    public let temperatureCelsius: Double?
    public let conditionLabel: String?
}

// MARK: - Disk

public struct DiskMetrics: Sendable {
    public let volumeName: String?
    public let totalBytes: UInt64?
    /// `.volumeAvailableCapacityForImportantUsageKey` — the number Finder and
    /// "About This Mac" show. It is ~3 GB HIGHER than `statfs f_bavail` here
    /// because of APFS purgeable space. Do not use statfs.
    public let availableBytes: UInt64?
    /// The conservative figure; exposed so nobody confuses the two.
    public let availableOpportunisticBytes: UInt64?
    /// System-wide, from IOBlockStorageDriver. nil on first tick.
    public let readBytesPerSec: Double?
    public let writeBytesPerSec: Double?

    public var usedBytes: UInt64? {
        guard let t = totalBytes, let a = availableBytes, t >= a else { return nil }
        return t - a
    }
}

// MARK: - Network

public struct NetworkInterfaceMetrics: Sendable {
    public let name: String
    public let bytesInPerSec: Double
    public let bytesOutPerSec: Double
    /// Bytes since MacPulse started, accumulated from wrap-corrected deltas.
    ///
    /// NOT a since-boot total, and deliberately so: MEASURED ON THIS MACHINE,
    /// `NET_RT_IFLIST2`'s `if_data64.ifi_ibytes` is truncated to 32 bits by the
    /// kernel. en0 read 2,276,886,528 through the sysctl while `netstat -ibn`
    /// reported 6,571,854,278 for the same counter in the same second —
    /// exactly 2^32 apart. utun6 was two wraps out. The per-second RATES are
    /// exact (we diff in 32-bit space), but any "since boot" figure from this
    /// interface is not trustworthy, so we don't publish one.
    public let bytesInSinceStart: UInt64
    public let bytesOutSinceStart: UInt64
}

public struct NetworkMetrics: Sendable {
    public let interval: TimeInterval
    /// Summed over every non-loopback interface.
    public let bytesInPerSec: Double
    public let bytesOutPerSec: Double
    /// Sorted by activity, busiest first.
    public let interfaces: [NetworkInterfaceMetrics]
    /// The interface currently carrying the most traffic, if any.
    public let primaryInterface: String?
}

// MARK: - The snapshot

/// One complete, immutable reading. Handed to observers on the main thread.
public struct MetricsSnapshot: Sendable {
    /// When this snapshot was produced.
    public let date: Date
    /// Monotonic seconds actually elapsed since the previous snapshot.
    public let interval: TimeInterval
    /// Wall-clock cost of producing this snapshot, in milliseconds. Watch it.
    public let sampleCostMs: Double
    /// Which samplers ran this tick (some run at a slower cadence and their
    /// values are carried forward from the previous snapshot).
    public let refreshed: Set<MetricKind>

    public let memory: MemoryMetrics?
    public let cpu: CPUMetrics?
    public let processes: ProcessMetrics?
    public let power: PowerMetrics?
    public let thermal: ThermalMetrics?
    public let gpu: GPUMetrics?
    public let battery: BatteryMetrics?
    public let disk: DiskMetrics?
    public let network: NetworkMetrics?
}

public enum MetricKind: String, Sendable, CaseIterable {
    case memory, cpu, processes, power, thermal, gpu, battery, disk, network
}

// MARK: - Formatting helpers (shared by the UI and the probe)

public enum Fmt {
    public static func bytes(_ v: UInt64?, _ digits: Int = 2) -> String {
        guard let v else { return "—" }
        return bytes(Double(v), digits)
    }

    public static func bytes(_ v: Double?, _ digits: Int = 2) -> String {
        guard let v else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var x = abs(v), i = 0
        while x >= 1024, i < units.count - 1 { x /= 1024; i += 1 }
        return String(format: "%.\(i == 0 ? 0 : digits)f %@", v < 0 ? -x : x, units[i])
    }

    public static func rate(_ v: Double?) -> String {
        guard let v else { return "—" }
        return bytes(v, 1) + "/s"
    }

    public static func pct(_ v: Double?, _ digits: Int = 1) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f%%", v * 100)
    }

    public static func watts(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.3f W", v)
    }

    public static func celsius(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f°C", v)
    }

    public static func duration(_ v: TimeInterval?) -> String {
        guard let v, v > 0 else { return "—" }
        let m = Int(v / 60)
        return m >= 60 ? String(format: "%dh%02dm", m / 60, m % 60) : "\(m)m"
    }
}

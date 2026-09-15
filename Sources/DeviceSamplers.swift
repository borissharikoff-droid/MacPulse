import Foundation
import IOKit
import IOKit.ps

// =====================================================================
// GPU · Battery · Disk · Network. All public IOKit / sysctl, all unprivileged.
// =====================================================================

/// GPU utilization from IOAccelerator's PerformanceStatistics dictionary.
///
/// The io_registry_entry is resolved once and kept; each tick reads ONE
/// property instead of building the whole (large) property dictionary.
final class GPUSampler {
    private var entry: io_registry_entry_t = 0
    private(set) var name: String?

    init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            if entry == 0 {
                entry = candidate      // keep the first accelerator; do not release it
                var buf = [CChar](repeating: 0, count: 256)
                if IORegistryEntryGetName(candidate, &buf) == KERN_SUCCESS {
                    name = String(cString: buf)
                }
                if let cls = IORegistryEntryCreateCFProperty(candidate, "IOClass" as CFString,
                                                             kCFAllocatorDefault, 0)?
                                .takeRetainedValue() as? String {
                    name = cls
                }
            } else {
                IOObjectRelease(candidate)
            }
        }
        guard entry != 0 else { return nil }
    }

    deinit { if entry != 0 { IOObjectRelease(entry) } }

    func sample() -> GPUMetrics? {
        guard entry != 0,
              let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                          kCFAllocatorDefault, 0)?
                            .takeRetainedValue() as? [String: Any] else {
            return nil
        }
        func fraction(_ key: String) -> Double? {
            guard let n = stats[key] as? NSNumber else { return nil }
            return min(max(n.doubleValue / 100, 0), 1)
        }
        let device = fraction("Device Utilization %")
        let renderer = fraction("Renderer Utilization %")
        let tiler = fraction("Tiler Utilization %")
        let allocated = (stats["Alloc system memory"] as? NSNumber)?.uint64Value
        guard device != nil || renderer != nil || tiler != nil else { return nil }
        return GPUMetrics(name: name, utilization: device,
                          rendererUtilization: renderer, tilerUtilization: tiler,
                          allocatedBytes: allocated)
    }
}

// MARK: - Battery

/// IOPS for charge/charging/time-remaining, AppleSmartBattery for the things
/// IOPS does not expose (cycle count, raw capacities, temperature).
enum BatterySampler {
    static func sample() -> BatteryMetrics? {
        var charge: Double?
        var isCharging: Bool?
        var isOnAC: Bool?
        var timeToEmpty: TimeInterval?
        var timeToFull: TimeInterval?
        var condition: String?

        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                        as? [String: Any] else { continue }
                if let current = desc[kIOPSCurrentCapacityKey] as? Int,
                   let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    charge = Double(current) / Double(max)
                }
                isCharging = desc[kIOPSIsChargingKey] as? Bool
                if let state = desc[kIOPSPowerSourceStateKey] as? String {
                    isOnAC = (state == kIOPSACPowerValue)
                }
                // These are minutes; -1 means "still calculating".
                if let m = desc[kIOPSTimeToEmptyKey] as? Int, m > 0 { timeToEmpty = TimeInterval(m * 60) }
                if let m = desc[kIOPSTimeToFullChargeKey] as? Int, m > 0 { timeToFull = TimeInterval(m * 60) }
                condition = desc["BatteryHealth"] as? String
                break
            }
        }

        var cycleCount: Int?
        var health: Double?
        var design: Int?
        var currentCapacity: Int?
        var voltage: Double?
        var amperage: Double?
        var temperature: Double?

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = propsRef?.takeRetainedValue() as? [String: Any] {
                cycleCount = props["CycleCount"] as? Int
                design = props["DesignCapacity"] as? Int
                currentCapacity = props["AppleRawCurrentCapacity"] as? Int
                if let raw = props["AppleRawMaxCapacity"] as? Int, let d = design, d > 0 {
                    health = Double(raw) / Double(d)
                }
                if let mv = props["Voltage"] as? Int { voltage = Double(mv) / 1000 }
                if let ma = props["Amperage"] as? Int { amperage = Double(ma) / 1000 }
                // Reported in hundredths of a degree Celsius.
                if let t = props["Temperature"] as? Int { temperature = Double(t) / 100 }
            }
        }

        // No battery at all (desktop Mac) -> nil rather than a row of zeros.
        guard charge != nil || cycleCount != nil else { return nil }

        return BatteryMetrics(
            charge: charge, isCharging: isCharging, isOnAC: isOnAC,
            timeToEmpty: timeToEmpty, timeToFull: timeToFull,
            cycleCount: cycleCount, health: health,
            designCapacitymAh: design, currentCapacitymAh: currentCapacity,
            voltage: voltage, amperage: amperage,
            temperatureCelsius: temperature, conditionLabel: condition
        )
    }
}

// MARK: - Disk

/// Free space from URL resource keys (NOT statfs) plus system-wide throughput
/// from IOBlockStorageDriver.
///
/// statfs f_bavail measured 47.04 GB here while Finder showed 50.05 GB — a
/// 3.01 GB gap that is APFS purgeable space.
/// `.volumeAvailableCapacityForImportantUsageKey` is the number the user sees
/// everywhere else in the OS, so it is the one we report.
final class DiskSampler {
    private var previousIO: (read: UInt64, write: UInt64, at: UInt64)?
    private var cachedCapacity: (total: UInt64?, available: UInt64?, opportunistic: UInt64?, name: String?)?

    /// Capacity changes slowly and the query is comparatively expensive; the
    /// engine refreshes it on a long cadence and we serve the cache in between.
    func refreshCapacity() {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeNameKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }
        cachedCapacity = (
            values.volumeTotalCapacity.map { UInt64($0) },
            values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) },
            values.volumeAvailableCapacityForOpportunisticUsage.map { UInt64(max(0, $0)) },
            values.volumeName
        )
    }

    func sample() -> DiskMetrics? {
        if cachedCapacity == nil { refreshCapacity() }
        let capacity = cachedCapacity

        var readRate: Double?
        var writeRate: Double?
        if let io = Self.blockStorageTotals() {
            let now = Mono.now()
            if let previous = previousIO {
                let dt = Mono.seconds(from: previous.at, to: now)
                readRate = perSecond(io.read, previous.read, over: dt)
                writeRate = perSecond(io.write, previous.write, over: dt)
            }
            previousIO = (io.read, io.write, now)
        }

        guard capacity != nil || readRate != nil else { return nil }
        return DiskMetrics(
            volumeName: capacity?.name,
            totalBytes: capacity?.total,
            availableBytes: capacity?.available,
            availableOpportunisticBytes: capacity?.opportunistic,
            readBytesPerSec: readRate,
            writeBytesPerSec: writeRate
        )
    }

    private static func blockStorageTotals() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0, found = false
        while case let drive = IOIteratorNext(iterator), drive != 0 {
            defer { IOObjectRelease(drive) }
            guard let stats = IORegistryEntryCreateCFProperty(drive, "Statistics" as CFString,
                                                              kCFAllocatorDefault, 0)?
                                .takeRetainedValue() as? [String: Any] else { continue }
            if let r = stats["Bytes (Read)"] as? NSNumber { read &+= r.uint64Value; found = true }
            if let w = stats["Bytes (Write)"] as? NSNumber { write &+= w.uint64Value; found = true }
        }
        return found ? (read, write) : nil
    }
}

// MARK: - Network

/// Throughput from `sysctl NET_RT_IFLIST2` → `if_msghdr2`.
///
/// Do not use getifaddrs: its `if_data` counters are 32-bit *and* it gives you
/// no clean way to tell a wrap from a reset.
///
/// MEASURED CORRECTION TO THE COMMON ADVICE: `if_msghdr2` carries `if_data64`,
/// whose byte counters are declared 64-bit — but on this machine the kernel
/// fills them with 32-bit-truncated values. en0 reported 2,276,886,528 bytes
/// in through this sysctl while `netstat -ibn` reported 6,571,854,278 in the
/// same second (exactly 2^32 apart); utun6 was two wraps out. Every other
/// field in the struct lines up perfectly, so this is the kernel, not our
/// layout. So: diff in 32-BIT SPACE (correct whether the counter is really 32-
/// or 64-bit, as long as an interval carries less than 4 GB), and accumulate
/// our own 64-bit totals rather than republishing a wrong since-boot number.
final class NetworkSampler {
    private var previous: [String: (inBytes: UInt64, outBytes: UInt64)] = [:]
    private var previousAt: UInt64?
    /// Our own 64-bit since-start totals, per interface name.
    ///
    /// PRUNED EVERY TICK to the interfaces that still exist. utun*/awdl0 come
    /// and go constantly (a VPN reconnect, AirDrop, a Personal Hotspot each
    /// mint a fresh name), so an unpruned map gains an entry for every
    /// interface name ever seen and never gives one back — unbounded growth in
    /// a process expected to run for weeks. An interface that disappears and
    /// returns under the same name starts its totals again, which is the
    /// honest answer: it is a different interface.
    private var accumulated: [String: (inBytes: UInt64, outBytes: UInt64)] = [:]

    func sample() -> NetworkMetrics? {
        guard let current = Self.interfaceCounters() else { return nil }
        let now = Mono.now()
        defer { previous = current; previousAt = now }

        guard let previousAt else { return nil }     // first tick has no rate
        let dt = Mono.seconds(from: previousAt, to: now)
        guard dt > 0.0001 else { return nil }

        // Retire interfaces that are gone from this sample BEFORE accumulating
        // into the map, so its size is bounded by the number of interfaces the
        // machine has right now, not by the number it has ever had.
        // (Unconditionally, not only when the map is bigger than the current
        // set: one interface vanishing while another appears in the same tick
        // keeps the counts equal while leaving a stale entry behind. Filtering
        // ~15 entries once a second costs nothing.)
        accumulated = accumulated.filter { current[$0.key] != nil }

        var interfaces: [NetworkInterfaceMetrics] = []
        var totalIn = 0.0, totalOut = 0.0
        for (name, counters) in current {
            guard name != "lo0" else { continue }
            // A missing previous entry means the interface was just created
            // (utun*, awdl0 churn constantly) — no rate for it this tick.
            guard let old = previous[name] else { continue }
            let inDelta = UInt64(UInt32(truncatingIfNeeded: counters.inBytes)
                              &- UInt32(truncatingIfNeeded: old.inBytes))
            let outDelta = UInt64(UInt32(truncatingIfNeeded: counters.outBytes)
                               &- UInt32(truncatingIfNeeded: old.outBytes))
            // An interface that was torn down and recreated restarts at 0, and
            // the 32-bit wrap of that looks like a ~4 GB burst. Discard it.
            let sane = inDelta < 2_000_000_000 && outDelta < 2_000_000_000
            guard sane else { continue }

            var running = accumulated[name] ?? (0, 0)
            running.inBytes &+= inDelta
            running.outBytes &+= outDelta
            accumulated[name] = running

            let inRate = Double(inDelta) / dt
            let outRate = Double(outDelta) / dt
            totalIn += inRate
            totalOut += outRate
            if inRate > 0 || outRate > 0 || running.inBytes > 0 || running.outBytes > 0 {
                interfaces.append(NetworkInterfaceMetrics(
                    name: name, bytesInPerSec: inRate, bytesOutPerSec: outRate,
                    bytesInSinceStart: running.inBytes, bytesOutSinceStart: running.outBytes))
            }
        }
        interfaces.sort { ($0.bytesInPerSec + $0.bytesOutPerSec) > ($1.bytesInPerSec + $1.bytesOutPerSec) }

        return NetworkMetrics(
            interval: dt,
            bytesInPerSec: totalIn,
            bytesOutPerSec: totalOut,
            interfaces: interfaces,
            primaryInterface: interfaces.first(where: { $0.bytesInPerSec + $0.bytesOutPerSec > 0 })?.name
        )
    }

    private static func interfaceCounters() -> [String: (inBytes: UInt64, outBytes: UInt64)]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }

        var result: [String: (UInt64, UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self)
                let messageLength = Int(header.pointee.ifm_msglen)
                if messageLength <= 0 { break }
                if header.pointee.ifm_type == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let header2 = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self)
                    let dl = base.advanced(by: offset + MemoryLayout<if_msghdr2>.size)
                                 .assumingMemoryBound(to: sockaddr_dl.self)
                    let nameLength = Int(dl.pointee.sdl_nlen)
                    if nameLength > 0, nameLength < 32 {
                        var chars = [CChar](repeating: 0, count: nameLength + 1)
                        withUnsafeBytes(of: dl.pointee.sdl_data) { bytes in
                            for i in 0..<nameLength { chars[i] = CChar(bitPattern: bytes[i]) }
                        }
                        let name = String(cString: chars)
                        if !name.isEmpty {
                            result[name] = (header2.pointee.ifm_data.ifi_ibytes,
                                            header2.pointee.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += messageLength
            }
        }
        return result.isEmpty ? nil : result
    }
}

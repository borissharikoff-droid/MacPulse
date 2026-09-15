import Foundation

/// Tier-S memory sampling: pressure level, compressor churn, swap rate,
/// page-in rate, and a correctly-computed "used".
///
/// THREADING: owns delta state (`previous`). Must only ever be driven from
/// MetricsEngine's serial sampling queue.
final class MemorySampler {

    /// The last reading whose COUNTERS actually differed from the one before
    /// it — not simply the last reading. See `countersAdvanced` for why.
    private var previous: (stats: vm_statistics64, at: UInt64)?
    /// Carried forward while the kernel's counters are frozen.
    private var lastRates: MemoryRates?

    /// If nothing has moved for this long, the rate really is zero.
    private static let stallBeforeZero: TimeInterval = 3.0

    /// nil means host_statistics64 itself failed — the whole memory metric is
    /// then unavailable rather than silently zero.
    func sample() -> MemoryMetrics? {
        guard let vm = Self.vmStatistics64() else { return nil }
        let now = Mono.now()
        let pageSize = HostInfo.shared.pageSize
        let ps = Double(pageSize)

        func bytes(_ pages: UInt32) -> UInt64 { UInt64(pages) * pageSize }
        func bytes64(_ pages: UInt64) -> UInt64 { pages &* pageSize }

        let active = bytes(vm.active_count)
        let inactive = bytes(vm.inactive_count)
        let speculative = bytes(vm.speculative_count)
        let wired = bytes(vm.wire_count)
        let compressed = bytes(vm.compressor_page_count)
        let purgeable = bytes(vm.purgeable_count)
        let external = bytes(vm.external_page_count)
        let free = bytes(vm.free_count)

        // The formula Stats and macmon both use, and the one that tracks
        // Activity Monitor. Signed math first: on a transient the subtractions
        // can momentarily exceed the additions, and UInt64 would wrap to
        // ~18 exabytes.
        let usedSigned = Int64(active) + Int64(inactive) + Int64(speculative)
                       + Int64(wired) + Int64(compressed)
                       - Int64(purgeable) - Int64(external)
        let used = UInt64(max(0, usedSigned))
        let appSigned = usedSigned - Int64(wired) - Int64(compressed)

        // ---- rates ----
        //
        // MEASURED ON THIS MACHINE: two consecutive host_statistics64 calls
        // from an unprivileged task can return BIT-IDENTICAL counters for up
        // to ~1 second. Polling `decompressions` at 50 ms showed it advancing
        // every tick for stretches and then freezing for 0.59–0.97 s, while
        // `vm_stat` (a fresh process each time) saw it climbing by thousands
        // in the same window.
        //
        // Naively dividing by the nominal dt during a freeze yields 0 pages/s,
        // which is indistinguishable from a genuinely quiet machine — exactly
        // the false zero this engine exists to avoid. So: only recompute when
        // the counters have actually ADVANCED (dt then spans the real gap and
        // the rate is correct), carry the previous rate forward while frozen,
        // and fall back to a true zero once nothing has moved for 3 s.
        var rates: MemoryRates?
        if let prev = previous, !Self.countersAdvanced(from: prev.stats, to: vm) {
            let stalled = Mono.seconds(from: prev.at, to: now)
            rates = stalled >= Self.stallBeforeZero ? Self.zeroRates(interval: stalled) : lastRates
            // Deliberately do NOT move `previous` — the next real advance must
            // be measured against the last reading that actually changed.
        } else if let prev = previous {
            let dt = Mono.seconds(from: prev.at, to: now)
            let old = prev.stats
            if dt > 0.0001,
               let comp = perSecond(vm.compressions, old.compressions, over: dt),
               let decomp = perSecond(vm.decompressions, old.decompressions, over: dt),
               let swapIn = perSecond(vm.swapins, old.swapins, over: dt),
               let swapOut = perSecond(vm.swapouts, old.swapouts, over: dt),
               let pageIn = perSecond(vm.pageins, old.pageins, over: dt),
               let pageOut = perSecond(vm.pageouts, old.pageouts, over: dt),
               let faults = perSecond(vm.faults, old.faults, over: dt) {
                rates = MemoryRates(
                    interval: dt,
                    compressionsPerSec: comp,
                    decompressionsPerSec: decomp,
                    compressionBytesPerSec: comp * ps,
                    decompressionBytesPerSec: decomp * ps,
                    swapInsPerSec: swapIn,
                    swapOutsPerSec: swapOut,
                    swapInBytesPerSec: swapIn * ps,
                    swapOutBytesPerSec: swapOut * ps,
                    pageInsPerSec: pageIn,
                    pageOutsPerSec: pageOut,
                    pageInBytesPerSec: pageIn * ps,
                    pageOutBytesPerSec: pageOut * ps,
                    faultsPerSec: faults
                )
            }
            previous = (vm, now)
            lastRates = rates ?? lastRates
        } else {
            previous = (vm, now)      // very first reading
        }

        let swap = Self.swapUsage()
        let total = HostInfo.shared.physicalMemoryBytes

        return MemoryMetrics(
            pageSize: pageSize,
            totalBytes: total,
            usedBytes: used,
            freeBytes: free,
            activeBytes: active,
            inactiveBytes: inactive,
            speculativeBytes: speculative,
            wiredBytes: wired,
            compressedBytes: compressed,
            purgeableBytes: purgeable,
            externalBytes: external,
            appBytes: UInt64(max(0, appSigned)),
            cacheBytes: purgeable + external,
            uncompressedInCompressorBytes: bytes64(vm.total_uncompressed_pages_in_compressor),
            pressureLevel: Self.pressureLevel(),
            pressureHeuristic: total > 0 ? Double(wired + compressed) / Double(total) : nil,
            swapTotalBytes: swap?.total,
            swapUsedBytes: swap?.used,
            swapFreeBytes: swap?.free,
            swapEncrypted: swap?.encrypted,
            rates: rates
        )
    }

    /// True when at least one of the counters we differentiate has moved.
    /// If none have, the kernel simply has not refreshed its rollup yet.
    private static func countersAdvanced(from old: vm_statistics64, to new: vm_statistics64) -> Bool {
        new.compressions != old.compressions
            || new.decompressions != old.decompressions
            || new.swapins != old.swapins
            || new.swapouts != old.swapouts
            || new.pageins != old.pageins
            || new.pageouts != old.pageouts
            || new.faults != old.faults
    }

    private static func zeroRates(interval: TimeInterval) -> MemoryRates {
        MemoryRates(interval: interval,
                    compressionsPerSec: 0, decompressionsPerSec: 0,
                    compressionBytesPerSec: 0, decompressionBytesPerSec: 0,
                    swapInsPerSec: 0, swapOutsPerSec: 0,
                    swapInBytesPerSec: 0, swapOutBytesPerSec: 0,
                    pageInsPerSec: 0, pageOutsPerSec: 0,
                    pageInBytesPerSec: 0, pageOutBytesPerSec: 0,
                    faultsPerSec: 0)
    }

    // MARK: - Raw sources

    /// THE authoritative pressure signal.
    ///
    /// `kern.memorystatus_vm_pressure_level` → 1 normal / 2 warn / 4 critical.
    /// Do NOT use `vm.memory_pressure`: it returns ~190 on this machine and is
    /// a completely different quantity, despite what most blog posts say.
    static func pressureLevel() -> MemoryPressureLevel? {
        guard let raw = Sysctl.int32("kern.memorystatus_vm_pressure_level") else { return nil }
        return MemoryPressureLevel(rawValue: Int(raw))
    }

    static func vmStatistics64() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                // MachHost.port, never mach_host_self(): the latter takes a
                // fresh send right on every call and this runs once a second
                // forever. See MachHost in SamplingSupport.swift.
                host_statistics64(MachHost.port, HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    static func swapUsage() -> (total: UInt64, used: UInt64, free: UInt64, encrypted: Bool)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_total, usage.xsu_used, usage.xsu_avail, usage.xsu_encrypted != 0)
    }

    /// State-free convenience for callers that just want free RAM and must not
    /// touch the engine's delta state (e.g. the optimize action).
    static func currentFreeBytes() -> UInt64? {
        guard let vm = vmStatistics64() else { return nil }
        return UInt64(vm.free_count) * HostInfo.shared.pageSize
    }
}

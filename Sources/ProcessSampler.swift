import Foundation
import Darwin

/// Lightweight, Sendable identity for a running app, harvested from
/// NSRunningApplication on the main thread and handed to the sampling queue.
struct AppIdentity: Sendable {
    let name: String
    let bundleIdentifier: String?
}

/// Per-app memory by `ri_phys_footprint`, with helper processes folded into
/// their responsible app.
///
/// WHY NOT RSS: measured on this machine, Telegram reported 44 MB resident but
/// 1780 MB phys_footprint — 40× off. `ri_resident_size` excludes compressed
/// and IOKit/Metal pages, which on a memory-pressured machine is most of the
/// footprint. `ri_phys_footprint` is the ledger the kernel jetsams on, and the
/// one Activity Monitor's "Memory" column and `top`'s MEM show.
///
/// COVERAGE CEILING: unprivileged we can only introspect our OWN uid's
/// processes — measured 258 of 442 PIDs. `/usr/bin/top` sees everything only
/// because it is setuid root. Present this as "your apps", never as a
/// whole-system process list.
///
/// THREADING: owns all delta state. Serial sampling queue only, except
/// `updateAppIdentities` which is called from the queue with a value captured
/// on main.
final class ProcessSampler {

    private struct PIDSample {
        let footprint: UInt64
        let peakFootprint: UInt64
        let cpuNanos: UInt64
        let diskWritten: UInt64
    }

    private var previous: [pid_t: PIDSample] = [:]
    private var previousAt: UInt64?
    /// responsibility lookups are stable for the life of a PID, so cache them.
    private var responsibleCache: [pid_t: pid_t] = [:]
    private var nameCache: [pid_t: String] = [:]
    private var appIdentities: [pid_t: AppIdentity] = [:]

    /// Max rows returned. The UI shows fewer; this just bounds the name
    /// resolution work.
    var maxRows = 40

    func updateAppIdentities(_ identities: [pid_t: AppIdentity]) {
        appIdentities = identities
    }

    func sample() -> ProcessMetrics? {
        guard let pids = Self.allPIDs() else { return nil }
        let now = Mono.now()
        let dt = previousAt.map { Mono.seconds(from: $0, to: now) }
        let haveDelta = (dt ?? 0) > 0.0001

        var current: [pid_t: PIDSample] = [:]
        current.reserveCapacity(pids.count)

        // group key = responsible pid
        var groups: [pid_t: (footprint: UInt64, peak: UInt64, cpuNanos: Double, diskRate: Double, members: [pid_t], haveRates: Bool)] = [:]

        for pid in pids where pid > 0 {
            guard let usage = Self.rusage(pid) else { continue }   // not our uid — skip silently
            let sample = PIDSample(
                footprint: usage.ri_phys_footprint,
                peakFootprint: usage.ri_lifetime_max_phys_footprint,
                cpuNanos: usage.ri_user_time &+ usage.ri_system_time,
                diskWritten: usage.ri_diskio_byteswritten
            )
            current[pid] = sample

            let owner = responsiblePID(for: pid)

            var cpuNanosDelta = 0.0
            var diskRate = 0.0
            var haveRates = false
            if haveDelta, let dt, let old = previous[pid] {
                if let cpuPerSec = perSecond(sample.cpuNanos, old.cpuNanos, over: dt) {
                    cpuNanosDelta = cpuPerSec
                    haveRates = true
                }
                if let w = perSecond(sample.diskWritten, old.diskWritten, over: dt) {
                    diskRate = w
                }
            }

            if var existing = groups[owner] {
                existing.footprint &+= sample.footprint
                existing.peak &+= sample.peakFootprint
                existing.cpuNanos += cpuNanosDelta
                existing.diskRate += diskRate
                existing.members.append(pid)
                existing.haveRates = existing.haveRates || haveRates
                groups[owner] = existing
            } else {
                groups[owner] = (sample.footprint, sample.peakFootprint, cpuNanosDelta, diskRate,
                                 [pid], haveRates)
            }
        }

        previous = current
        previousAt = now
        // Prune caches so a long-running app doesn't accumulate dead PIDs.
        if responsibleCache.count > current.count * 3 {
            responsibleCache = responsibleCache.filter { current[$0.key] != nil }
            nameCache = nameCache.filter { current[$0.key] != nil }
        }

        let totalFootprint = groups.values.reduce(UInt64(0)) { $0 &+ $1.footprint }
        let totalDiskRate = groups.values.reduce(0.0) { $0 + $1.diskRate }

        let sorted = groups.sorted { $0.value.footprint > $1.value.footprint }.prefix(maxRows)
        let rows: [AppUsage] = sorted.map { owner, g in
            let identity = appIdentities[owner]
            // Put the responsible PID first so the UI can trust members[0].
            var members = g.members
            if let idx = members.firstIndex(of: owner), idx != 0 {
                members.swapAt(0, idx)
            }
            return AppUsage(
                pid: owner,
                name: identity?.name ?? processName(owner) ?? processName(g.members[0]) ?? "pid \(owner)",
                bundleIdentifier: identity?.bundleIdentifier,
                footprintBytes: g.footprint,
                peakFootprintBytes: g.peak,
                // ri_*_time are nanoseconds; a rate of 1e9 ns/s == one full core.
                cpuPercent: g.haveRates ? g.cpuNanos / 1_000_000_000 * 100 : nil,
                diskWriteBytesPerSec: haveDelta ? g.diskRate : nil,
                memberPIDs: members,
                isApplication: identity != nil
            )
        }

        return ProcessMetrics(
            interval: dt ?? 0,
            apps: rows,
            pidCount: pids.count,
            introspectedCount: current.count,
            totalFootprintBytes: totalFootprint,
            totalDiskWriteBytesPerSec: haveDelta ? totalDiskRate : nil,
            helperGroupingAvailable: Self.responsibilityFn != nil
        )
    }

    // MARK: - Helper grouping

    /// `responsibility_get_pid_responsible_for_pid` is the private symbol that
    /// maps "Cursor Helper (Renderer)" back to "Cursor". Stats dlsym's it for
    /// exactly this. Resolved once through RTLD_DEFAULT; if it is ever gone we
    /// degrade to per-process rows (and say so via
    /// `ProcessMetrics.helperGroupingAvailable`) rather than crashing.
    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t
    private static let responsibilityFn: ResponsibilityFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -1),
                              "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibilityFn.self)
    }()

    private func responsiblePID(for pid: pid_t) -> pid_t {
        if let cached = responsibleCache[pid] { return cached }
        guard let fn = Self.responsibilityFn else {
            responsibleCache[pid] = pid
            return pid
        }
        let owner = fn(pid)
        // -1 means "no answer"; 0 would fold everything into one bogus group.
        let resolved = (owner > 0) ? owner : pid
        responsibleCache[pid] = resolved
        return resolved
    }

    // MARK: - Raw libproc

    private func processName(_ pid: pid_t) -> String? {
        if let cached = nameCache[pid] { return cached }
        var buf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let name = String(cString: buf)
        guard !name.isEmpty else { return nil }
        nameCache[pid] = name
        return name
    }

    private static func allPIDs() -> [pid_t]? {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, needed)
        guard got > 0 else { return nil }
        let count = Int(got) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count))
    }

    /// Fails (returns nil) for PIDs owned by another uid. That is expected and
    /// is not an error worth logging 184 times a second.
    private static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info : nil
    }
}

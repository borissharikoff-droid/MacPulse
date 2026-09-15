import Foundation

/// Per-CLUSTER CPU load (P vs E), not 8 anonymous per-core bars.
///
/// THREADING: owns `previousTicks`. Serial sampling queue only.
final class CPUSampler {

    /// Per-core cumulative tick counters from the previous sample:
    /// [core][user, system, idle, nice].
    private var previousTicks: [[UInt32]]?
    private var previousAt: UInt64?

    func sample() -> CPUMetrics? {
        guard let current = Self.processorTicks() else { return nil }
        let now = Mono.now()
        defer { previousTicks = current; previousAt = now }

        guard let previous = previousTicks, let previousAt,
              previous.count == current.count else {
            return nil  // first tick: a load is a delta, and we have none yet
        }
        let dt = Mono.seconds(from: previousAt, to: now)
        guard dt > 0.0001 else { return nil }

        // Index-aligned with the kernel's core ordering, so a core whose
        // counters did not advance is a nil HOLE, not a fabricated idle core.
        let cores: [CPULoad?] = (0..<current.count).map { i in
            Self.load(from: previous[i], to: current[i])
        }

        // Cluster aggregation sums the raw ticks rather than averaging the
        // per-core percentages, so a cluster with one busy and three idle
        // cores reports 25%, not "some average of ratios".
        let kinds = HostInfo.shared.coreClusterKinds
        var clusters: [CPUCluster] = []
        if kinds.count == current.count {
            for kind in [CPUClusterKind.performance, .efficiency, .other] {
                let indices = (0..<current.count).filter { kinds[$0] == kind }
                guard !indices.isEmpty else { continue }
                var prevSum = [UInt32](repeating: 0, count: 4)
                var curSum = [UInt32](repeating: 0, count: 4)
                for i in indices {
                    for s in 0..<4 {
                        prevSum[s] = prevSum[s] &+ previous[i][s]
                        curSum[s] = curSum[s] &+ current[i][s]
                    }
                }
                // No ticks at all for the whole cluster means we could not
                // measure it. Omit the cluster rather than publish a 0% one.
                guard let clusterLoad = Self.load(from: prevSum, to: curSum) else { continue }
                clusters.append(CPUCluster(
                    name: kind == .performance ? "P-cores" : kind == .efficiency ? "E-cores" : "Cores",
                    kind: kind,
                    coreCount: indices.count,
                    load: clusterLoad,
                    coreIndices: indices
                ))
            }
        }

        var overallPrev = [UInt32](repeating: 0, count: 4)
        var overallCur = [UInt32](repeating: 0, count: 4)
        for i in 0..<current.count {
            for s in 0..<4 {
                overallPrev[s] = overallPrev[s] &+ previous[i][s]
                overallCur[s] = overallCur[s] &+ current[i][s]
            }
        }

        // getloadavg() can fail (it returns the number of samples it filled in,
        // -1 on error). A failure means the load averages are UNKNOWN; zeros
        // would read as "the machine is idle", which is a different claim.
        var loads = [Double](repeating: 0, count: 3)
        let gotLoadAvg = getloadavg(&loads, 3) == 3

        // If the whole machine's counters did not advance, there is no load to
        // report at all — the entire CPU metric is unavailable this tick.
        guard let overall = Self.load(from: overallPrev, to: overallCur) else { return nil }

        return CPUMetrics(
            interval: dt,
            overall: overall,
            clusters: clusters,
            cores: cores,
            loadAverage1: gotLoadAvg ? loads[0] : nil,
            loadAverage5: gotLoadAvg ? loads[1] : nil,
            loadAverage15: gotLoadAvg ? loads[2] : nil
        )
    }

    /// nil when no ticks at all elapsed between the two readings — i.e. the
    /// load could not be MEASURED. Per the design rule in MetricTypes.swift
    /// that is not the same as a measured 0% busy, so it must not be reported
    /// as `idle: 1`.
    private static func load(from old: [UInt32], to new: [UInt32]) -> CPULoad? {
        let user = wrappingDelta(new[0], old[0])
        let system = wrappingDelta(new[1], old[1])
        let idle = wrappingDelta(new[2], old[2])
        let nice = wrappingDelta(new[3], old[3])
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return CPULoad(user: user / total, system: system / total, nice: nice / total, idle: idle / total)
    }

    /// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
    ///
    /// The kernel vm_allocates the result array for us. It must be handed back
    /// with vm_deallocate or a menu-bar app leaks a few hundred bytes every
    /// second, forever.
    private static func processorTicks() -> [[UInt32]]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        // MachHost.port, never mach_host_self() — see MachHost in
        // SamplingSupport.swift.
        guard host_processor_info(MachHost.port, PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let array = info else { return nil }

        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: array)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        // `array` is a raw pointer with no bounds checking whatsoever, and
        // cpuCount and infoCount are two INDEPENDENT out-parameters: trusting
        // cpuCount to describe the buffer's length is an out-of-bounds read
        // waiting for the day the kernel returns fewer entries than cores.
        // The buffer must hold cpuCount * CPU_STATE_MAX integer_t.
        //
        // Computed in Int, not in the 32-bit out-parameter types, so the
        // multiplication cannot wrap. The defer above still runs, so a bail
        // here does not leak the kernel's allocation.
        let stride = Int(CPU_STATE_MAX)
        guard stride > 0, cpuCount > 0, Int(infoCount) >= Int(cpuCount) * stride else { return nil }
        var out: [[UInt32]] = []
        out.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * stride
            out.append([
                UInt32(bitPattern: array[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: array[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: array[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: array[base + Int(CPU_STATE_NICE)])
            ])
        }
        return out
    }
}

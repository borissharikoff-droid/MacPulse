import Foundation
import IOKit

// =====================================================================
// Small shared primitives for the samplers. Everything here is
// queue-agnostic and free of state unless noted.
// =====================================================================

/// Monotonic clock. Used for EVERY dt in the engine.
///
/// `Date()` is wall-clock: NTP steps, sleep/wake and DST can move it
/// backwards, which would turn a wattage or a churn rate into a wild spike
/// or a negative. `DispatchTime.uptimeNanoseconds` never goes backwards.
enum Mono {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func seconds(since start: UInt64) -> Double {
        Double(now() &- start) / 1_000_000_000
    }

    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end &- start) / 1_000_000_000
    }
}

/// Differentiate a monotonically-increasing kernel counter.
///
/// Returns nil — NOT 0 — when the delta is nonsense (counter reset because a
/// device was torn down and recreated, or the process re-execed). A nil
/// propagates up into an absent metric; a 0 would be a lie.
func perSecond(_ new: UInt64, _ old: UInt64, over dt: Double) -> Double? {
    guard dt > 0.0001 else { return nil }
    let delta = new &- old
    // Counters here are all well under 2^62 in any realistic interval; a
    // huge value means `new < old`, i.e. the counter went backwards.
    guard delta < (UInt64(1) << 62) else { return nil }
    return Double(delta) / dt
}

/// Same, for 32-bit tick counters (host_processor_info), which really do wrap.
func wrappingDelta(_ new: UInt32, _ old: UInt32) -> Double {
    Double(new &- old)
}

// MARK: - sysctl helpers

enum Sysctl {
    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // NOTE: Stats reads memorystatus_vm_pressure_level into an 8-byte Int
        // with a 4-byte size. That happens to work on little-endian; don't
        // copy it. The kernel type here is a 4-byte int, so declare Int32.
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else {
            return nil
        }
        return value
    }

    static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

// MARK: - Host facts that never change

/// Immutable machine facts, resolved once. Safe to read from any thread.
struct HostInfo {
    static let shared = HostInfo()

    /// 16384 on Apple silicon. Hardcoding 4096 makes every memory rate 4×
    /// too small — the single most common bug in vm_stat parsers.
    let pageSize: UInt64
    let physicalMemoryBytes: UInt64
    let logicalCoreCount: Int
    /// logical CPU index -> cluster kind, resolved from the device tree.
    let coreClusterKinds: [CPUClusterKind]
    let machineModel: String?

    private init() {
        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        pageSize = ps == 0 ? 16384 : UInt64(ps)

        physicalMemoryBytes = Sysctl.uint64("hw.memsize") ?? 0
        let ncpu = Int(Sysctl.int32("hw.logicalcpu") ?? Sysctl.int32("hw.ncpu") ?? 0)
        logicalCoreCount = ncpu
        machineModel = Sysctl.string("hw.model")
        coreClusterKinds = HostInfo.resolveClusterKinds(logicalCoreCount: ncpu)
    }

    /// Which logical CPU index is a P-core and which is an E-core.
    ///
    /// The authoritative answer is in the device tree: every `IODeviceTree:/cpus`
    /// child carries `cluster-type` ("E"/"P") and `logical-cpu-id`. Verified on
    /// this M2: cpu0–3 are E, cpu4–7 are P.
    ///
    /// The sysctl fallback is deliberately second-choice because
    /// `hw.perflevel0` is the *Performance* tier (confirmed:
    /// `hw.perflevel0.name` == "Performance"), which is the opposite of what
    /// the name suggests, and the sysctls give counts but never an index map.
    private static func resolveClusterKinds(logicalCoreCount: Int) -> [CPUClusterKind] {
        guard logicalCoreCount > 0 else { return [] }

        if let fromTree = clusterKindsFromDeviceTree(expecting: logicalCoreCount) {
            return fromTree
        }

        // Fallback: perflevel counts. macOS on Apple silicon enumerates the
        // efficiency cluster first, so E-cores occupy the low indices.
        let levels = Int(Sysctl.int32("hw.nperflevels") ?? 1)
        guard levels >= 2 else {
            return Array(repeating: .other, count: logicalCoreCount)
        }
        let perfCount = Int(Sysctl.int32("hw.perflevel0.logicalcpu") ?? 0)   // Performance
        let effCount = Int(Sysctl.int32("hw.perflevel1.logicalcpu") ?? 0)    // Efficiency
        guard perfCount > 0, effCount > 0, perfCount + effCount == logicalCoreCount else {
            return Array(repeating: .other, count: logicalCoreCount)
        }
        return Array(repeating: .efficiency, count: effCount)
             + Array(repeating: .performance, count: perfCount)
    }

    private static func clusterKindsFromDeviceTree(expecting count: Int) -> [CPUClusterKind]? {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIODeviceTreePlane, &children) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(children) }

        var kinds = [Int: CPUClusterKind]()
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(child, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any] else { continue }

            // cluster-type is a 1-byte CFData holding the ASCII 'E' or 'P'.
            guard let typeData = props["cluster-type"] as? Data, let first = typeData.first else { continue }
            let kind: CPUClusterKind = (first == UInt8(ascii: "P")) ? .performance
                                     : (first == UInt8(ascii: "E")) ? .efficiency
                                     : .other

            let index: Int
            if let n = props["logical-cpu-id"] as? Int {
                index = n
            } else if let d = props["logical-cpu-id"] as? Data, d.count >= 4 {
                index = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            } else if let d = props["cpu-id"] as? Data, d.count >= 4 {
                index = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            } else {
                continue
            }
            kinds[index] = kind
        }

        guard kinds.count == count else { return nil }
        return (0..<count).map { kinds[$0] ?? .other }
    }
}

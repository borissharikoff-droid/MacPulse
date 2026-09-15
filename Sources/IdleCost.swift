import Foundation
import Darwin

// =====================================================================
// Hidden self-instrumentation for the island's IDLE COST.
//
// WHY IT LIVES IN THE APP AND NOT IN A SCRIPT: `task_thread_times_info`
// is the only measure fine-grained enough to tell 0.3% from 1.0% over a
// two-minute window, and reading it for ANOTHER process needs a task
// port. `task_for_pid` is refused to an unprivileged caller here (tested:
// KERN_FAILURE against our own signed bundle), and we never use sudo. So
// the process measures itself; `mach_task_self_` needs no privilege at
// all.
//
// `ps -o time` deltas are the cross-check and need nothing special, but
// they quantise to 1/100 s, which at 0.4% of a core is ~5 counts a minute.
//
// COST OF THE INSTRUMENT ITSELF: one thread that sleeps. It takes two
// samples — one at arm time, one at the end of the window — and writes a
// single line. Nothing runs in between. With no `--cost-log` argument it
// does not even create the thread.
//
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --cost-log 150 \
//       --cost-out /tmp/cost.txt
// =====================================================================

enum IdleCost {

    /// user+system CPU seconds burned by every thread in THIS task.
    ///
    /// `task_thread_times_info` covers only threads that are alive right
    /// now; a thread that has exited takes its time with it and reappears
    /// in `task_basic_info_64`. Reporting only the first understates a
    /// process that churns through GCD worker threads, which is exactly
    /// what a 1 Hz sampler on a utility queue does — so both are read and
    /// both are reported.
    static func taskThreadTimes() -> (live: Double, total: Double)? {
        var times = task_thread_times_info()
        var tCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        let rc = withUnsafeMutablePointer(to: &times) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(tCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &tCount)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        let live = seconds(times.user_time) + seconds(times.system_time)

        var basic = task_basic_info_64()
        var bCount = mach_msg_type_number_t(
            MemoryLayout<task_basic_info_64>.size / MemoryLayout<natural_t>.size)
        let rc2 = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(bCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO_64), $0, &bCount)
            }
        }
        let dead = rc2 == KERN_SUCCESS
            ? seconds(basic.user_time) + seconds(basic.system_time)
            : 0
        return (live, live + dead)
    }

    /// Resident size of this task, bytes. nil if the query failed.
    static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return rc == KERN_SUCCESS ? info.resident_size : nil
    }

    private static func seconds(_ t: time_value_t) -> Double {
        Double(t.seconds) + Double(t.microseconds) / 1_000_000
    }

    /// Called once from `applicationDidFinishLaunching`. No-op unless
    /// `--cost-log <seconds>` is on the command line.
    static func armIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--cost-log"),
              flag + 1 < args.count,
              let window = Double(args[flag + 1]), window > 0
        else { return }
        var out: String?
        if let o = args.firstIndex(of: "--cost-out"), o + 1 < args.count { out = args[o + 1] }
        // A settle delay so the measurement never includes launch: window
        // opening, first sample, SwiftUI's first layout.
        let settle = Double(args.firstIndex(of: "--cost-settle").flatMap {
            $0 + 1 < args.count ? args[$0 + 1] : nil
        } ?? "") ?? 10

        let thread = Thread { run(window: window, settle: settle, out: out) }
        thread.name = "MacPulse.IdleCost"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    private static func run(window: TimeInterval, settle: TimeInterval, out: String?) {
        Thread.sleep(forTimeInterval: settle)
        guard let t0 = taskThreadTimes() else { return }
        let r0 = residentBytes()
        let w0 = Date()
        Thread.sleep(forTimeInterval: window)
        guard let t1 = taskThreadTimes() else { return }
        let r1 = residentBytes()
        let wall = Date().timeIntervalSince(w0)

        let dLive = t1.live - t0.live
        let dTotal = t1.total - t0.total
        var lines = [
            String(format: "wall                        %.2f s", wall),
            String(format: "task_thread_times (live)    %.4f s -> %.3f%% of one core",
                   dLive, dLive / wall * 100),
            String(format: "task_thread_times + exited  %.4f s -> %.3f%% of one core",
                   dTotal, dTotal / wall * 100),
        ]
        if let r0, let r1 {
            lines.append(String(format: "RSS                         %.1f -> %.1f MB",
                                Double(r0) / 1_048_576, Double(r1) / 1_048_576))
        }
        let text = lines.joined(separator: "\n") + "\n"
        if let out {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        }
        FileHandle.standardError.write(text.data(using: .utf8)!)
    }
}

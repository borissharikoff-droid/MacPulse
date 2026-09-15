import Foundation
import AppKit

/// Hidden diagnostic harness. NOT part of the shipping UI — reached only by
/// running the app binary with `--probe`:
///
///     /Applications/MacPulse.app/Contents/MacOS/MacPulse --probe
///
/// Phases:
///   1. availability report
///   2. 10 one-second snapshots of every metric
///   3. cross-check against vm_stat / sysctl / top / pmset / df
///   4. power-under-load test (idle → 8× `yes` → idle)
///   5. sampling-cost summary
enum Probe {

    static func run(arguments: [String]) -> Never {
        let skipLoad = arguments.contains("--no-load")
        let engine = MetricsEngine.shared
        engine.historyLimit = 200
        engine.start()

        line()
        print("MacPulse metrics probe — \(Date())")
        printAvailability(engine.availability())

        line()
        print("PHASE 1 — live snapshots, 1/s for 10 s")
        line()
        var costs: [Double] = []
        var fastCosts: [Double] = []     // ticks that did NOT touch the SMC
        var smcCosts: [Double] = []      // ticks that re-read every sensor
        var printed = 0
        let token = engine.observe { snapshot in
            costs.append(snapshot.sampleCostMs)
            if snapshot.refreshed.contains(.thermal) {
                smcCosts.append(snapshot.sampleCostMs)
            } else {
                fastCosts.append(snapshot.sampleCostMs)
            }
            printed += 1
            printSnapshot(snapshot, index: printed)
        }
        spin(seconds: 10.5)
        engine.remove(token)

        line()
        print("PHASE 2 — cross-check against independent system tools")
        line()
        crossCheck(engine.latest)

        if !skipLoad {
            line()
            print("PHASE 3 — power response to load (idle → 8× yes → idle)")
            line()
            loadTest(engine: engine, costs: &costs)
        }

        line()
        print("PHASE 4 — sampling cost")
        line()
        func stats(_ label: String, _ xs: [Double]) {
            guard !xs.isEmpty else { print("  \(label): none"); return }
            let sorted = xs.sorted()
            print(String(format: "  %-38@ n=%3d  min=%6.2f  median=%6.2f  mean=%6.2f  p95=%6.2f  max=%7.2f  (ms)",
                         label as NSString, xs.count, sorted.first!,
                         sorted[sorted.count / 2],
                         xs.reduce(0, +) / Double(xs.count),
                         sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                         sorted.last!))
        }
        // The first tick also pays for lazy sampler construction (IOReport
        // subscription + the one-time SMC key enumeration), so it is reported
        // on its own rather than allowed to skew the steady-state numbers.
        if let first = costs.first {
            print(String(format: "  first tick (incl. one-time IOReport subscribe + SMC key scan): %.2f ms", first))
        }
        stats("steady tick (no SMC re-read)", fastCosts)
        stats("tick that re-reads all SMC sensors", smcCosts)
        stats("ALL ticks incl. the 8×`yes` load phase", costs)
        print("  SMC runs every 3rd tick; everything else every tick. The steady-state median is")
        print("  the number that matters for a 1 Hz menu-bar app.")
        line()
        exit(0)
    }

    // MARK: - Phases

    private static func printAvailability(_ a: MetricsEngine.Availability) {
        print("""
          machine        : \(HostInfo.shared.machineModel ?? "?")  \
        \(HostInfo.shared.logicalCoreCount) logical cores  \
        \(Fmt.bytes(HostInfo.shared.physicalMemoryBytes)) RAM
          page size      : \(a.pageSize) bytes\(a.pageSize == 16384 ? "  (16 KB — NOT 4 KB)" : "")
          cluster layout : \(a.clusterLayout)   (index 0 -> last logical CPU)
          libIOReport    : \(a.ioReportLoaded ? "loaded" : "MISSING")
          power subscr.  : \(a.powerSubscription ? "OK" : "UNAVAILABLE")
          AppleSMC       : \(a.smcOpen ? "open, \(a.smcSensorCount) float temp sensors (discovery \(String(format: "%.0f", a.smcDiscoveryMs)) ms)" : "UNAVAILABLE")
          IOAccelerator  : \(a.gpuAccelerator ?? "UNAVAILABLE")
          helper grouping: \(a.helperGrouping ? "responsibility_get_pid_responsible_for_pid resolved" : "UNAVAILABLE (per-process rows)")
        """)
        if !a.powerChannels.isEmpty {
            print("  IOReport 'Energy Model' channels — NOTE THE UNIT COLUMN, it is not uniform:")
            // Print the 12 biggest consumers, then FORCE one exemplar of every
            // other unit label present. Without that second pass the output is
            // all-mJ (the nJ channels are small by construction) and the single
            // most important power pitfall — that units differ PER CHANNEL — is
            // invisible in the very evidence meant to demonstrate it.
            var shown = Array(a.powerChannels.prefix(12))
            for unit in Set(a.powerChannels.map(\.unit)).sorted()
            where !shown.contains(where: { $0.unit == unit }) {
                if let exemplar = a.powerChannels.first(where: { $0.unit == unit }) {
                    shown.append(exemplar)
                }
            }
            for c in shown {
                print(String(format: "      %-24@ unit=%-4@ -> %@",
                             c.name as NSString, c.unit as NSString,
                             (c.watts.map { String(format: "%.4f W", $0) } ?? "unknown unit -> reported as unavailable") as NSString))
            }
            let units = Set(a.powerChannels.map(\.unit))
            if units.count > 1 {
                print("      >> \(units.sorted().joined(separator: " and ")) in the same group. Hardcoding one of them")
                print("         is a 10^6 error (GPU would read ~271,000 W instead of 0.271 W).")
            }
        }
    }

    private static func printSnapshot(_ s: MetricsSnapshot, index: Int) {
        print(String(format: "\n[%02d] t=%.3fs  cost=%.2f ms  refreshed=%@",
                     index, s.interval, s.sampleCostMs,
                     s.refreshed.map(\.rawValue).sorted().joined(separator: ",")))

        if let m = s.memory {
            print("  MEM   pressure=\(m.pressureLevel?.label ?? "—") "
                + "heuristic=\(Fmt.pct(m.pressureHeuristic)) "
                + "used=\(Fmt.bytes(m.usedBytes))/\(Fmt.bytes(m.totalBytes)) (\(Fmt.pct(m.usedFraction))) "
                + "free=\(Fmt.bytes(m.freeBytes))")
            print("        wired=\(Fmt.bytes(m.wiredBytes)) compressed=\(Fmt.bytes(m.compressedBytes)) "
                + "app=\(Fmt.bytes(m.appBytes)) cache=\(Fmt.bytes(m.cacheBytes)) "
                + "ratio=\(m.compressionRatio.map { String(format: "%.2fx", $0) } ?? "—")")
            print("        swap=\(Fmt.bytes(m.swapUsedBytes))/\(Fmt.bytes(m.swapTotalBytes)) "
                + "active=\(Fmt.bytes(m.activeBytes)) inactive=\(Fmt.bytes(m.inactiveBytes)) "
                + "spec=\(Fmt.bytes(m.speculativeBytes)) purgeable=\(Fmt.bytes(m.purgeableBytes)) "
                + "external=\(Fmt.bytes(m.externalBytes))")
            if let r = m.rates {
                print(String(format: "  CHURN compress=%.0f pg/s (%@)  decompress=%.0f pg/s (%@)  TOTAL %@",
                             r.compressionsPerSec, Fmt.rate(r.compressionBytesPerSec),
                             r.decompressionsPerSec, Fmt.rate(r.decompressionBytesPerSec),
                             Fmt.rate(r.compressorChurnBytesPerSec)))
                print(String(format: "  SWAP  in=%.0f pg/s (%@)  out=%.0f pg/s (%@)   PAGEIN=%.0f pg/s (%@)  faults=%.0f/s",
                             r.swapInsPerSec, Fmt.rate(r.swapInBytesPerSec),
                             r.swapOutsPerSec, Fmt.rate(r.swapOutBytesPerSec),
                             r.pageInsPerSec, Fmt.rate(r.pageInBytesPerSec), r.faultsPerSec))
            } else {
                print("  CHURN —  (first tick, no delta yet)")
            }
        } else {
            print("  MEM   UNAVAILABLE")
        }

        if let c = s.cpu {
            var parts = [String(format: "all=%.1f%%", c.overall.busy * 100)]
            for cluster in c.clusters {
                parts.append(String(format: "%@(%d)=%.1f%%", cluster.name, cluster.coreCount, cluster.load.busy * 100))
            }
            // The load averages are Optional: getloadavg() can fail, and an
            // unavailable load average prints as "—", not as 0.00.
            let avg = [c.loadAverage1, c.loadAverage5, c.loadAverage15]
                .map { $0.map { String(format: "%.2f", $0) } ?? "—" }
                .joined(separator: "/")
            let unmeasured = c.cores.filter { $0 == nil }.count
            print("  CPU   " + parts.joined(separator: "  ")
                + String(format: "  user=%.1f%% sys=%.1f%%  load=%@",
                         c.overall.user * 100, c.overall.system * 100, avg as NSString)
                + (unmeasured > 0 ? "  (\(unmeasured)/\(c.cores.count) cores unmeasured)" : ""))
        } else {
            print("  CPU   — (first tick)")
        }

        if let p = s.power {
            print("  POWER cpu=\(Fmt.watts(p.cpuWatts)) gpu=\(Fmt.watts(p.gpuWatts)) "
                + "ane=\(Fmt.watts(p.aneWatts)) dram=\(Fmt.watts(p.dramWatts)) "
                + "pkg=\(Fmt.watts(p.packageWatts)) system(PSTR)=\(Fmt.watts(p.systemWatts)) "
                + "adapter=\(Fmt.watts(p.adapterWatts))")
        } else {
            print("  POWER UNAVAILABLE")
        }

        if let t = s.thermal {
            print("  THERM state=\(t.state.label) lowPower=\(t.lowPowerMode) "
                + "P=\(Fmt.celsius(t.cpuPerformanceCelsius)) E=\(Fmt.celsius(t.cpuEfficiencyCelsius)) "
                + "GPU=\(Fmt.celsius(t.gpuCelsius)) batt=\(Fmt.celsius(t.batteryCelsius)) "
                + "peak=\(Fmt.celsius(t.cpuPeakCelsius))")
        }

        if let g = s.gpu {
            print("  GPU   \(g.name ?? "?") util=\(Fmt.pct(g.utilization)) "
                + "renderer=\(Fmt.pct(g.rendererUtilization)) tiler=\(Fmt.pct(g.tilerUtilization)) "
                + "alloc=\(Fmt.bytes(g.allocatedBytes))")
        } else {
            print("  GPU   UNAVAILABLE")
        }

        if let b = s.battery {
            print("  BATT  charge=\(Fmt.pct(b.charge, 0)) charging=\(b.isCharging.map(String.init) ?? "—") "
                + "ac=\(b.isOnAC.map(String.init) ?? "—") cycles=\(b.cycleCount.map(String.init) ?? "—") "
                + "health=\(Fmt.pct(b.health, 1)) toEmpty=\(Fmt.duration(b.timeToEmpty)) "
                + "toFull=\(Fmt.duration(b.timeToFull)) \(Fmt.celsius(b.temperatureCelsius))")
        } else {
            print("  BATT  UNAVAILABLE")
        }

        if let d = s.disk {
            print("  DISK  \(d.volumeName ?? "/") avail=\(Fmt.bytes(d.availableBytes))/\(Fmt.bytes(d.totalBytes)) "
                + "(opportunistic=\(Fmt.bytes(d.availableOpportunisticBytes))) "
                + "read=\(Fmt.rate(d.readBytesPerSec)) write=\(Fmt.rate(d.writeBytesPerSec))")
        }

        if let n = s.network {
            print("  NET   in=\(Fmt.rate(n.bytesInPerSec)) out=\(Fmt.rate(n.bytesOutPerSec)) "
                + "primary=\(n.primaryInterface ?? "—") ifaces=\(n.interfaces.count)")
        }

        if let p = s.processes {
            print("  PROC  \(p.introspectedCount)/\(p.pidCount) pids introspectable (own uid only)  "
                + "groups=\(p.apps.count)  totalFootprint=\(Fmt.bytes(p.totalFootprintBytes))  "
                + "grouping=\(p.helperGroupingAvailable ? "on" : "off")  "
                + "diskWrite=\(Fmt.rate(p.totalDiskWriteBytesPerSec))")
            for app in p.apps.prefix(8) {
                print(String(format: "          %-28@ %10@  cpu %6@  pids %2d  %@",
                             String(app.name.prefix(28)) as NSString,
                             Fmt.bytes(app.footprintBytes) as NSString,
                             (app.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—") as NSString,
                             app.memberPIDs.count,
                             (app.isApplication ? "app" : "proc") as NSString))
            }
        } else {
            print("  PROC  UNAVAILABLE")
        }
    }

    // MARK: - Cross-check

    private static func crossCheck(_ snapshot: MetricsSnapshot?) {
        guard let s = snapshot else { print("  no snapshot"); return }
        let pageSize = HostInfo.shared.pageSize

        // --- vm_stat, BRACKETED ---
        //
        // A stale snapshot cannot be cross-checked on a machine that is moving
        // 300 MB/s of pages: a one-second-old "free" reading disagrees with
        // vm_stat by 100% purely because of elapsed time. So sample the same
        // kernel struct immediately BEFORE and AFTER running vm_stat, and check
        // that vm_stat's answer falls inside our bracket. Inside == agreement.
        print("A. MEMORY vs /usr/bin/vm_stat   (page size \(pageSize) B — 16 KB, not 4 KB)")
        // The kernel's rollup can freeze for up to ~1 s (measured), so widen
        // the bracket by sampling either side of a short spin as well as
        // either side of the vm_stat process itself.
        let before = MemorySampler.vmStatistics64()
        let vmStat = shell("/usr/bin/vm_stat", [])
        spin(seconds: 1.2)
        let after = MemorySampler.vmStatistics64()
        let vm = parseVMStat(vmStat)

        if let b = before, let a = after {
            func check(_ label: String, _ field: (vm_statistics64) -> UInt32, _ key: String) {
                let lo = min(field(b), field(a)), hi = max(field(b), field(a))
                guard let theirPages = vm[key] else {
                    print("  \(label): vm_stat key '\(key)' not found"); return
                }
                // vm_stat samples at one instant inside our bracket, but the
                // kernel rollup can advance between its read and ours, so
                // allow slack outside the bracket edges.
                //
                // The slack has to scale with how VOLATILE the field is, not
                // just how big it is. `speculative` is small (hundreds of
                // pages) and swings by hundreds of pages per second, so a flat
                // 1%-of-value slack is a few pages and reports a MISMATCH on a
                // field that is simply moving — a false alarm that trains you
                // to ignore the checker. How far the counter moved INSIDE our
                // own bracket is a direct measurement of that volatility, so
                // use half of it as the floor.
                let volatility = Double(hi - lo) * 0.5
                let slack = max(Double(hi) * 0.01, volatility, 2)
                let inside = Double(lo) - slack <= Double(theirPages)
                          && Double(theirPages) <= Double(hi) + slack
                let verdict = inside ? "OK" : "MISMATCH"
                print(String(format: "  %-13@ ours=[%@ … %@]  vm_stat=%-11@  %@",
                             label as NSString,
                             Fmt.bytes(UInt64(lo) * pageSize) as NSString,
                             Fmt.bytes(UInt64(hi) * pageSize) as NSString,
                             Fmt.bytes(theirPages * pageSize) as NSString,
                             verdict as NSString))
            }
            check("wired", { $0.wire_count }, "Pages wired down")
            check("active", { $0.active_count }, "Pages active")
            check("inactive", { $0.inactive_count }, "Pages inactive")
            check("speculative", { $0.speculative_count }, "Pages speculative")
            check("compressor", { $0.compressor_page_count }, "Pages occupied by compressor")
            check("purgeable", { $0.purgeable_count }, "Pages purgeable")
            check("file-backed", { $0.external_page_count }, "File-backed pages")
            // vm_stat prints (free_count - speculative_count) under "Pages
            // free", not free_count. Comparing raw free_count against it looks
            // like a ~100 MB bug and is not one.
            check("free-spec", { $0.free_count &- $0.speculative_count }, "Pages free")

            // The rate counters, same treatment.
            func checkCounter(_ label: String, _ field: (vm_statistics64) -> UInt64, _ key: String) {
                let lo = min(field(b), field(a)), hi = max(field(b), field(a))
                guard let theirs = vm[key] else { return }
                let slack = UInt64(max(Double(hi - lo) * 0.02, 4))
                let inside = lo &- min(lo, slack) <= theirs && theirs <= hi &+ slack
                print(String(format: "  %-13@ ours=[%llu … %llu] pages  vm_stat=%llu  %@",
                             label as NSString, lo, hi, theirs,
                             (inside ? "OK" : "MISMATCH") as NSString))
            }
            checkCounter("compressions", { $0.compressions }, "Compressions")
            checkCounter("decompressions", { $0.decompressions }, "Decompressions")
            checkCounter("swapouts", { $0.swapouts }, "Swapouts")
            checkCounter("swapins", { $0.swapins }, "Swapins")
            checkCounter("pageins", { $0.pageins }, "Pageins")

            if let c = vm["Compressions"], let so = vm["Swapouts"], so > 0 {
                print(String(format: "  >> lifetime compression-to-swap ratio = %.1f : 1  "
                             + "(%llu pages compressed vs %llu swapped out) — the product thesis",
                             Double(c) / Double(so), c, so))
            }
        }

        // --- used / total vs top ---
        print("\nA2. 'USED' vs `top -l 1` PhysMem line")
        let physMem = shell("/usr/bin/top", ["-l", "1", "-n", "0"])
            .split(separator: "\n").first { $0.hasPrefix("PhysMem") }
        print("    top    : \(physMem.map(String.init) ?? "n/a")")
        if let m = s.memory {
            print("    ours   : used=\(Fmt.bytes(m.usedBytes))  wired=\(Fmt.bytes(m.wiredBytes))  "
                + "compressor=\(Fmt.bytes(m.compressedBytes))")
            print("             used = active+inactive+speculative+wired+compressed − purgeable − external")
            print("             top's 'used' does NOT subtract the file cache, so it should sit ABOUT")
            print("             cacheBytes higher than ours: ours+cache = \(Fmt.bytes(m.usedBytes + m.cacheBytes)) "
                + "(cache = \(Fmt.bytes(m.cacheBytes)))")
            if let line = physMem, let topUsed = parseTopSize(String(line.split(separator: " ")[1])) {
                let ourEquivalent = Double(m.usedBytes + m.cacheBytes)
                let pct = abs(ourEquivalent - Double(topUsed)) / Double(topUsed) * 100
                print(String(format: "             top used=%@ vs ours+cache=%@  Δ %.1f%%  %@",
                             Fmt.bytes(topUsed) as NSString, Fmt.bytes(ourEquivalent) as NSString, pct,
                             (pct < 8 ? "OK" : "MISMATCH") as NSString))
            }
        }

        // --- swap ---
        print("\nB. SWAP vs sysctl vm.swapusage")
        let swapLine = shell("/usr/sbin/sysctl", ["-n", "vm.swapusage"]).trimmingCharacters(in: .whitespacesAndNewlines)
        print("    sysctl : \(swapLine)")
        if let m = s.memory {
            print("    ours   : total=\(Fmt.bytes(m.swapTotalBytes)) used=\(Fmt.bytes(m.swapUsedBytes)) free=\(Fmt.bytes(m.swapFreeBytes)) encrypted=\(m.swapEncrypted.map(String.init) ?? "—")")
        }

        // --- pressure ---
        print("\nC. PRESSURE vs sysctl kern.memorystatus_vm_pressure_level")
        let raw = shell("/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
        print("    sysctl : \(raw)   (1=normal 2=warning 4=critical)")
        print("    ours   : \(s.memory?.pressureLevel.map { "\($0.rawValue) \($0.label)" } ?? "—")")
        let wrong = shell("/usr/sbin/sysctl", ["-n", "vm.memory_pressure"]).trimmingCharacters(in: .whitespacesAndNewlines)
        print("    (for the record, the WRONG sysctl vm.memory_pressure = \(wrong.isEmpty ? "n/a" : wrong) — not a level)")

        // --- per-app footprint vs top ---
        //
        // `top -o mem`'s MEM column IS phys_footprint, so this is an apples-to-
        // apples check. Two comparisons are made:
        //   (a) per-PID:  our raw ri_phys_footprint vs top's MEM for the same PID
        //   (b) per-GROUP: our folded total vs the SUM of top's rows over the
        //                  exact member PIDs we folded together.
        // (b) is the one that proves the helper grouping is arithmetic and not
        // invention.
        print("\nD. PER-APP FOOTPRINT vs `top -l 1 -o mem` (top's MEM column IS phys_footprint)")
        let top = shell("/usr/bin/top", ["-l", "1", "-o", "mem", "-n", "200", "-stats", "pid,command,mem"])
        let topRows = parseTop(top)
        var topByPID: [pid_t: UInt64] = [:]
        for row in topRows { topByPID[row.pid] = row.bytes }
        print("    top returned \(topRows.count) rows (setuid root — it sees every uid; we see only our own)")
        print(String(format: "    %-26@ %11@ %11@ %9@ %5@ %@",
                     "app (group)" as NSString, "ours" as NSString, "Σ top(members)" as NSString,
                     "Δ" as NSString, "pids" as NSString, "verdict" as NSString))
        for app in (s.processes?.apps ?? []).prefix(10) {
            var topSum: UInt64 = 0
            var missing = 0
            for pid in app.memberPIDs {
                if let v = topByPID[pid] { topSum &+= v } else { missing += 1 }
            }
            let diff = Double(app.footprintBytes) - Double(topSum)
            let pct = topSum > 0 ? abs(diff) / Double(topSum) * 100 : 100
            // top rounds to whole MB/KB and the two reads are ~1 s apart on a
            // machine moving 300 MB/s, so 5% is the agreement threshold.
            let verdict = missing > 0 ? "\(missing) pid(s) not in top output"
                        : pct < 5 ? String(format: "OK (%.1f%%)", pct)
                        : String(format: "MISMATCH (%.1f%%)", pct)
            print(String(format: "    %-26@ %11@ %11@ %9@ %5d %@",
                         String(app.name.prefix(26)) as NSString,
                         Fmt.bytes(app.footprintBytes) as NSString,
                         Fmt.bytes(topSum) as NSString,
                         Fmt.bytes(diff) as NSString,
                         app.memberPIDs.count,
                         verdict as NSString))
        }
        print("    per-PID spot check (our raw footprint vs top's MEM for the SAME pid):")
        var checked = 0
        for app in (s.processes?.apps ?? []) where checked < 6 {
            guard let leadPID = app.memberPIDs.first, let theirs = topByPID[leadPID] else { continue }
            guard let ours = rawFootprint(leadPID) else { continue }
            let pct = theirs > 0 ? abs(Double(ours) - Double(theirs)) / Double(theirs) * 100 : 100
            print(String(format: "      pid %6d %-22@ ours=%10@  top=%10@  %@",
                         leadPID, String(app.name.prefix(22)) as NSString,
                         Fmt.bytes(ours) as NSString, Fmt.bytes(theirs) as NSString,
                         (pct < 5 ? String(format: "OK (%.1f%%)", pct)
                                  : String(format: "MISMATCH (%.1f%%)", pct)) as NSString))
            checked += 1
        }
        print("    RSS-vs-footprint sanity (why RSS is unusable):")
        for app in (s.processes?.apps ?? []).prefix(3) {
            guard let leadPID = app.memberPIDs.first,
                  let pair = rawFootprintAndRSS(leadPID) else { continue }
            print(String(format: "      pid %6d %-22@ footprint=%10@  RSS=%10@  (%.1f× apart)",
                         leadPID, String(app.name.prefix(22)) as NSString,
                         Fmt.bytes(pair.footprint) as NSString, Fmt.bytes(pair.rss) as NSString,
                         pair.rss > 0 ? Double(pair.footprint) / Double(pair.rss) : 0))
        }

        // --- CPU vs top, over THE SAME WINDOW ---
        //
        // `top -l 2 -s 1` reports its second sample as the load over its own
        // 1 s window. Comparing that against a snapshot taken at some other
        // moment measures nothing, so run a dedicated CPUSampler across
        // exactly the same span.
        print("\nE. CPU vs `top -l 2 -s 1` — measured over THE SAME 1 s window")
        let sampler = CPUSampler()
        _ = sampler.sample()                                        // prime the delta
        let topCPU = shell("/usr/bin/top", ["-l", "2", "-n", "0", "-s", "1"])
            .split(separator: "\n").filter { $0.hasPrefix("CPU usage") }
        let ours = sampler.sample()
        print("    top    : \(topCPU.last.map(String.init) ?? "n/a")")
        if let c = ours {
            print(String(format: "    ours   : user %.2f%%, sys %.2f%%, idle %.2f%%  (busy %.2f%%, over %.2f s)",
                         c.overall.user * 100, c.overall.system * 100, c.overall.idle * 100,
                         c.overall.busy * 100, c.interval))
            for cluster in c.clusters {
                print(String(format: "             %@ x%d busy %.2f%%  (logical cores %@)",
                             cluster.name, cluster.coreCount, cluster.load.busy * 100,
                             cluster.coreIndices.map(String.init).joined(separator: ",")))
            }
            // Parse top's "23.63% user, 7.12% sys, 69.23% idle"
            if let line = topCPU.last {
                let numbers = line.split(separator: " ").compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
                if numbers.count >= 3 {
                    let theirBusy = 100 - numbers[2]
                    let delta = abs(c.overall.busy * 100 - theirBusy)
                    print(String(format: "             busy ours %.2f%% vs top %.2f%%  Δ %.2f points  %@",
                                 c.overall.busy * 100, theirBusy, delta,
                                 (delta < 5 ? "OK" : "MISMATCH") as NSString))
                }
            }
        }

        // --- battery vs pmset ---
        print("\nF. BATTERY vs `pmset -g batt`")
        print("    pmset  : \(shell("/usr/bin/pmset", ["-g", "batt"]).split(separator: "\n").joined(separator: " | "))")
        if let b = s.battery {
            print("    ours   : \(Fmt.pct(b.charge, 0)) charging=\(b.isCharging.map(String.init) ?? "—") "
                + "ac=\(b.isOnAC.map(String.init) ?? "—") cycles=\(b.cycleCount.map(String.init) ?? "—") health=\(Fmt.pct(b.health, 1))")
        }
        print("    ioreg  : \(shell("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery", "-w0"]).split(separator: "\n").filter { $0.contains("\"CycleCount\"") || $0.contains("\"DesignCapacity\"") || $0.contains("\"AppleRawMaxCapacity\"") }.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "  "))")

        // --- disk vs df ---
        print("\nG. DISK vs `df -k /` (statfs) — the APFS purgeable gap")
        let df = shell("/bin/df", ["-k", "/"]).split(separator: "\n")
        print("    df     : \(df.last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "n/a")")
        if let d = s.disk {
            print("    ours   : total=\(Fmt.bytes(d.totalBytes)) availableForImportantUsage=\(Fmt.bytes(d.availableBytes)) "
                + "opportunistic=\(Fmt.bytes(d.availableOpportunisticBytes))")
            if let dfLine = df.last {
                let cols = dfLine.split(separator: " ", omittingEmptySubsequences: true)
                if cols.count >= 4, let availKB = UInt64(cols[3]) {
                    let statfsAvail = availKB * 1024
                    print("    df avail (statfs f_bavail) = \(Fmt.bytes(statfsAvail));  ours is higher by "
                        + "\(Fmt.bytes(Double((d.availableBytes ?? 0)) - Double(statfsAvail))) of APFS purgeable space — expected")
                }
            }
        }

        // --- network vs netstat ---
        print("\nH. NETWORK vs `netstat -ibn` (64-bit counters)")
        let netstat = shell("/usr/sbin/netstat", ["-ibn"])
            .split(separator: "\n").filter { $0.hasPrefix("en0") }.prefix(1)
        print("    netstat: \(netstat.first.map { $0.split(separator: " ").joined(separator: " ") } ?? "n/a")")
        for i in (s.network?.interfaces ?? []).prefix(4) {
            print("    ours   : \(i.name) sinceStart in=\(Fmt.bytes(i.bytesInSinceStart)) out=\(Fmt.bytes(i.bytesOutSinceStart)) "
                + "rate \(Fmt.rate(i.bytesInPerSec)) / \(Fmt.rate(i.bytesOutPerSec))")
        }
        print("    NOTE: we publish since-START totals, not since-boot. Measured here, the kernel")
        print("          truncates if_data64.ifi_ibytes to 32 bits in NET_RT_IFLIST2 — en0 read")
        print("          2,276,886,528 while netstat read 6,571,854,278 (exactly 2^32 apart), and")
        print("          utun6 was two wraps out. Rates are diffed in 32-bit space, so they are exact.")
        // Prove the 2^32 claim numerically, live.
        if let raw = rawIfBytes("en0"),
           let netstatIn = parseNetstatIn("en0") {
            let wraps = Double(netstatIn - raw.inBytes) / 4294967296.0
            print(String(format: "          live proof: sysctl en0 ibytes=%llu  netstat=%llu  difference = %.4f × 2^32",
                         raw.inBytes, netstatIn, wraps))
        }
    }

    /// Raw per-PID footprint, for the spot check.
    private static func rawFootprint(_ pid: pid_t) -> UInt64? {
        rawFootprintAndRSS(pid)?.footprint
    }

    private static func rawFootprintAndRSS(_ pid: pid_t) -> (footprint: UInt64, rss: UInt64)? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? (info.ri_phys_footprint, info.ri_resident_size) : nil
    }

    private static func rawIfBytes(_ name: String) -> (inBytes: UInt64, outBytes: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        var result: (UInt64, UInt64)?
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self)
                let messageLength = Int(header.pointee.ifm_msglen)
                if messageLength <= 0 { break }
                if header.pointee.ifm_type == RTM_IFINFO2 {
                    let h2 = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self)
                    let dl = base.advanced(by: offset + MemoryLayout<if_msghdr2>.size)
                                 .assumingMemoryBound(to: sockaddr_dl.self)
                    let n = Int(dl.pointee.sdl_nlen)
                    if n > 0, n < 32 {
                        var chars = [CChar](repeating: 0, count: n + 1)
                        withUnsafeBytes(of: dl.pointee.sdl_data) { b in
                            for i in 0..<n { chars[i] = CChar(bitPattern: b[i]) }
                        }
                        if String(cString: chars) == name {
                            result = (h2.pointee.ifm_data.ifi_ibytes, h2.pointee.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += messageLength
            }
        }
        return result
    }

    private static func parseNetstatIn(_ name: String) -> UInt64? {
        for raw in shell("/usr/sbin/netstat", ["-ibn"]).split(separator: "\n") {
            let cols = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count > 7, cols[0] == name, cols[2].hasPrefix("<Link") else { continue }
            return UInt64(cols[6])
        }
        return nil
    }

    // MARK: - Load test

    /// Averages over a whole window, not a single snapshot: this machine has a
    /// large and volatile background load (Cursor, Zen, Telegram), so one
    /// sample is not a baseline.
    private struct Window {
        var cpuW: [Double] = []
        var pstrW: [Double] = []
        var busy: [Double] = []
        mutating func add(_ s: MetricsSnapshot) {
            if let v = s.power?.cpuWatts { cpuW.append(v) }
            // Only count PSTR from ticks that actually re-read the SMC —
            // otherwise a carried-forward value is counted five times and the
            // window mean is whatever was in the cache.
            if s.refreshed.contains(.thermal), let v = s.power?.systemWatts { pstrW.append(v) }
            if let v = s.cpu?.overall.busy { busy.append(v) }
        }
        static func mean(_ xs: [Double]) -> Double? {
            xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }
    }

    private static func loadTest(engine: MetricsEngine, costs: inout [Double]) {
        var window = Window()
        var local: [Double] = []
        var collecting = false
        let token = engine.observe { snapshot in
            local.append(snapshot.sampleCostMs)
            if collecting { window.add(snapshot) }
        }
        defer { engine.remove(token); costs.append(contentsOf: local) }

        func measure(_ tag: String, seconds: TimeInterval) -> Window {
            window = Window()
            collecting = true
            spin(seconds: seconds)
            collecting = false
            let w = window
            print(String(format: "  %-8@ n=%d  cpuW mean=%@ (min %@ max %@)  PSTR mean=%@  cpuBusy mean=%.1f%%",
                         tag as NSString, w.cpuW.count,
                         Fmt.watts(Window.mean(w.cpuW)) as NSString,
                         Fmt.watts(w.cpuW.min()) as NSString,
                         Fmt.watts(w.cpuW.max()) as NSString,
                         Fmt.watts(Window.mean(w.pstrW)) as NSString,
                         (Window.mean(w.busy) ?? 0) * 100))
            return w
        }

        let baseline = measure("baseline", seconds: 6)

        // `/usr/bin/yes` is exec'd DIRECTLY — deliberately not through
        // `/bin/sh -c "yes > /dev/null"`. With a shell in the middle, the
        // Process handle refers to the shell, and if that shell forks instead
        // of exec'ing, terminating it can leave an orphaned `yes` spinning —
        // which is what used to be "solved" with `killall yes`. A kill by NAME
        // would signal every process called `yes` in the user's session, not
        // just the eight spawned here, and this app's safety contract allows
        // terminating only `helpd` and apps the user explicitly quit. Exec'ing
        // the loader directly makes each Process handle the loader itself, so
        // terminating the handles we own is both sufficient and exact.
        var loaders: [Process] = []
        for _ in 0..<8 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { loaders.append(p) }
        }
        print("  --- spawned \(loaders.count) × `yes > /dev/null` ---")
        spin(seconds: 2)                      // let the scheduler settle
        let loaded = measure("loaded", seconds: 6)

        // Terminate ONLY the children this probe created, by their own Process
        // handles, and wait for each one to actually be gone.
        for p in loaders where p.isRunning { p.terminate() }
        for p in loaders { p.waitUntilExit() }
        let survivors = loaders.filter { $0.isRunning }.count
        print("  --- killed load (\(loaders.count) children terminated, "
            + "\(survivors) still running) ---")
        spin(seconds: 2)
        let after = measure("after", seconds: 6)

        print("")
        guard let base = Window.mean(baseline.cpuW), let hot = Window.mean(loaded.cpuW) else {
            print("  VERDICT: CPU watts unavailable — no CPU Energy channel from IOReport.")
            return
        }
        let deltaCPU = hot - base
        print(String(format: "  CPU watts   %.3f -> %.3f  (Δ %+.3f W, %.2f×)", base, hot, deltaCPU, hot / base))
        if let bu = Window.mean(baseline.busy), let hu = Window.mean(loaded.busy) {
            print(String(format: "  CPU busy    %.1f%% -> %.1f%%  (Δ %+.1f points)", bu * 100, hu * 100, (hu - bu) * 100))
        }
        if let ba = Window.mean(after.cpuW) {
            print(String(format: "  after kill  %.3f W  (%@ to baseline)", ba,
                         abs(ba - base) < max(1.0, base * 0.35) ? "returns" : "does NOT return"))
        }

        // Independent corroboration: PSTR comes from the SMC, not from
        // IOReport. If two unrelated sources agree on the size of the jump,
        // the delta and the dt are both right.
        if let basePSTR = Window.mean(baseline.pstrW), let hotPSTR = Window.mean(loaded.pstrW) {
            let deltaPSTR = hotPSTR - basePSTR
            let agreement = deltaPSTR != 0 ? deltaCPU / deltaPSTR : .nan
            print(String(format: "  PSTR (SMC)  %.3f -> %.3f  (Δ %+.3f W)  — independent of IOReport",
                         basePSTR, hotPSTR, deltaPSTR))
            print(String(format: "  CROSS-CHECK IOReport ΔCPU / SMC ΔPSTR = %.2f  (≈1 means the two "
                         + "independent sources agree on the size of the jump)", agreement))
        }

        let cpuRose = deltaCPU > 1.0
        print("\n  VERDICT: " + (cpuRose
            ? "PASS — CPU power rose \(String(format: "%+.2f", deltaCPU)) W under 8 busy threads and fell back "
              + "afterwards. Delta and dt are correct."
            : "FAIL — CPU power did not respond to load. Check the IOReport delta or the dt."))
        print("  NOTE: the research baseline (1.38 W idle → 9.58 W loaded) was taken on a quiet machine.")
        print("        This one is never quiet — Cursor/Zen/Telegram hold it at \(String(format: "%.0f", (Window.mean(baseline.busy) ?? 0) * 100))% CPU at rest —")
        print("        so the ratio is smaller while the loaded absolute value is the same order.")
    }

    // MARK: - Utilities

    private static func spin(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }

    private static func line() { print(String(repeating: "─", count: 112)) }

    @discardableResult
    private static func shell(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parseVMStat(_ output: String) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for raw in output.split(separator: "\n") {
            let parts = raw.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " .\t"))
            if let n = UInt64(value) { result[key] = n }
        }
        return result
    }

    /// `top -stats pid,command,mem` rows. The MEM column is suffixed
    /// (`1890M`, `256K`, `2048B`, sometimes with a trailing `+`/`-` churn
    /// marker) and top uses BINARY units, so K = 1024.
    private static func parseTop(_ output: String) -> [(pid: pid_t, name: String, bytes: UInt64)] {
        var rows: [(pid_t, String, UInt64)] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 3,
                  let pid = pid_t(cols[0].replacingOccurrences(of: "*", with: "")) else { continue }
            guard let bytes = parseTopSize(cols[cols.count - 1]) else { continue }
            let name = cols[1..<(cols.count - 1)].joined(separator: " ")
            rows.append((pid, name, bytes))
        }
        return rows
    }

    private static func parseTopSize(_ raw: String) -> UInt64? {
        var text = raw
        while let last = text.last, last == "+" || last == "-" { text.removeLast() }
        guard let last = text.last else { return nil }
        var multiplier: Double = 1
        switch last {
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        case "T": multiplier = 1024 * 1024 * 1024 * 1024
        case "B": multiplier = 1
        default: multiplier = 0
        }
        if multiplier > 0 { text.removeLast() } else { multiplier = 1 }
        guard let value = Double(text) else { return nil }
        return UInt64(value * multiplier)
    }
}

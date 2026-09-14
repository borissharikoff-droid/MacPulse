import Foundation

/// CPU / GPU / ANE / DRAM power in watts from IOReport's "Energy Model" group.
///
/// THREE THINGS THAT WILL BITE ANYONE WHO REWRITES THIS:
///
///  1. UNIT LABELS ARE NOT UNIFORM. On this M2 / macOS 26.6 the GPU Energy
///     channel reports nJ while CPU/ANE/DRAM report mJ. Hardcoding mJ produced
///     271,087 W for the GPU instead of 0.271 W. Always divide by the value
///     from IOReportChannelGetUnitLabel FOR THAT CHANNEL. An unrecognised unit
///     yields nil, never a guess.
///  2. SUBSCRIBING TO ALL CHANNELS COSTS 75 ms PER SAMPLE. Filtering to just
///     "Energy Model" costs 0.88 ms — 80× cheaper. Never call
///     IOReportCopyAllChannels on the sample path.
///  3. NEVER SLEEP INSIDE THE SAMPLE PATH, NEVER SAMPLE ON MAIN. We keep a
///     persistent baseline and delta it on the engine's existing tick, then
///     divide by the MEASURED dt. Using the nominal interval biased every
///     wattage by ~1.5% in the research measurements.
///
/// Channel NAMES are the fragile part across chip generations (Ultra prefixes
/// "DIE_0_", M5 relabels the tiers), so every match is prefix/suffix based and
/// every output is Optional.
///
/// THREADING: owns the subscription and the baseline. Serial queue only.
final class PowerSampler {

    private let lib: IOReportLib
    private let channels: CFMutableDictionary
    private let subscription: IOReportSubscriptionRef
    private var previousSample: CFDictionary?
    private var previousAt: UInt64 = 0

    /// nil when libIOReport is unavailable or the subscription is refused.
    init?() {
        guard let lib = IOReportLib.shared else { return nil }
        self.lib = lib

        // Energy Model only. That is everything we need for watts and it is
        // the cheap channel set.
        guard let group = lib.copyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0) else { return nil }
        let chans = group.takeRetainedValue()
        self.channels = chans

        var subscriptionDict: Unmanaged<CFMutableDictionary>?
        guard let sub = lib.createSubscription(nil, chans, &subscriptionDict, 0, nil) else { return nil }
        self.subscription = sub

        // Baseline immediately so the first real tick already has a delta.
        guard let first = lib.createSamples(sub, chans, nil) else { return nil }
        previousSample = first.takeRetainedValue()
        previousAt = Mono.now()
    }

    /// SMC-sourced whole-system numbers are merged in by MetricsEngine; this
    /// returns only the IOReport half.
    func sample() -> PowerMetrics? {
        guard let previousSample else { return nil }
        guard let nowSample = lib.createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return nil
        }
        let now = Mono.now()
        let dt = Mono.seconds(from: previousAt, to: now)
        defer { self.previousSample = nowSample; self.previousAt = now }

        guard dt > 0.0001,
              let delta = lib.createSamplesDelta(previousSample, nowSample, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else {
            return nil
        }

        var cpu: Double?, gpu: Double?, ane: Double?, dram: Double?, gpuSRAM: Double?

        for item in items {
            let channel = item as CFDictionary
            guard cfString(lib.channelGetGroup(channel)) == "Energy Model" else { continue }
            let name = cfString(lib.channelGetChannelName(channel))
            let unit = cfString(lib.channelGetUnitLabel(channel)).trimmingCharacters(in: .whitespaces)

            // Per-channel divisor. Unknown unit -> skip the channel entirely
            // rather than invent a number.
            let joulesPerCount: Double
            switch unit {
            case "mJ": joulesPerCount = 1e-3
            case "uJ", "µJ": joulesPerCount = 1e-6
            case "nJ": joulesPerCount = 1e-9
            case "J": joulesPerCount = 1
            default: continue
            }
            let watts = Double(lib.simpleGetIntegerValue(channel, 0)) * joulesPerCount / dt
            guard watts.isFinite, watts >= 0 else { continue }

            // Order matters: check the most specific names first.
            if name.contains("GPU SRAM") {
                gpuSRAM = (gpuSRAM ?? 0) + watts
            } else if name.hasSuffix("CPU Energy") {          // "CPU Energy", "DIE_0_CPU Energy"
                cpu = (cpu ?? 0) + watts
            } else if name.hasSuffix("GPU Energy") {          // "GPU Energy", "DIE_0_GPU Energy"
                gpu = (gpu ?? 0) + watts
            } else if name.contains("ANE") {                  // "ANE", "ANE0", "ANE0_1"
                ane = (ane ?? 0) + watts
            } else if name.contains("DRAM") {
                dram = (dram ?? 0) + watts
            }
        }

        var package: Double?
        for value in [cpu, gpu, ane] {
            if let value { package = (package ?? 0) + value }
        }

        // All four nil means the channel names on this chip are not ones we
        // recognise — report the whole metric as unavailable.
        if cpu == nil && gpu == nil && ane == nil && dram == nil { return nil }

        return PowerMetrics(
            interval: dt,
            cpuWatts: cpu, gpuWatts: gpu, aneWatts: ane,
            dramWatts: dram, gpuSRAMWatts: gpuSRAM,
            packageWatts: package,
            systemWatts: nil, adapterWatts: nil, batteryWatts: nil
        )
    }

    /// Diagnostics only: every Energy Model channel with the unit label the
    /// system reports for it, and the watts we derive.
    ///
    /// This is the evidence that the units are handled per-channel. On this M2
    /// "GPU Energy" comes back as nJ while everything else is mJ; assuming mJ
    /// for all of them turns 0.271 W into 271,087 W.
    func channelInventory() -> [(name: String, unit: String, watts: Double?)] {
        guard let previousSample,
              let nowSample = lib.createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return []
        }
        let dt = Mono.seconds(since: previousAt)
        guard dt > 0.0001,
              let delta = lib.createSamplesDelta(previousSample, nowSample, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return [] }
        // Deliberately does NOT advance the baseline — diagnostics must not
        // perturb the metric the engine is publishing.
        var out: [(String, String, Double?)] = []
        for item in items {
            let channel = item as CFDictionary
            let name = cfString(lib.channelGetChannelName(channel))
            let unit = cfString(lib.channelGetUnitLabel(channel)).trimmingCharacters(in: .whitespaces)
            let scale: Double? = unit == "mJ" ? 1e-3 : unit == "uJ" || unit == "µJ" ? 1e-6
                               : unit == "nJ" ? 1e-9 : unit == "J" ? 1 : nil
            let watts = scale.map { Double(lib.simpleGetIntegerValue(channel, 0)) * $0 / dt }
            out.append((name, unit, watts))
        }
        return out.sorted { ($0.2 ?? -1) > ($1.2 ?? -1) }
    }

    private func cfString(_ value: Unmanaged<CFString>?) -> String {
        value.map { $0.takeUnretainedValue() as String } ?? ""
    }
}

extension PowerMetrics {
    /// Merge the SMC-only whole-machine figures into an IOReport reading.
    /// `PSTR` is the honest "how many watts is this laptop pulling" number and
    /// IOReport genuinely cannot produce it.
    func mergingSMC(system: Double?, adapter: Double?, battery: Double?) -> PowerMetrics {
        PowerMetrics(
            interval: interval,
            cpuWatts: cpuWatts, gpuWatts: gpuWatts, aneWatts: aneWatts,
            dramWatts: dramWatts, gpuSRAMWatts: gpuSRAMWatts,
            packageWatts: packageWatts,
            systemWatts: system, adapterWatts: adapter, batteryWatts: battery
        )
    }

    static func smcOnly(system: Double?, adapter: Double?, battery: Double?) -> PowerMetrics? {
        guard system != nil || adapter != nil || battery != nil else { return nil }
        return PowerMetrics(
            interval: 0,
            cpuWatts: nil, gpuWatts: nil, aneWatts: nil, dramWatts: nil, gpuSRAMWatts: nil,
            packageWatts: nil,
            systemWatts: system, adapterWatts: adapter, batteryWatts: battery
        )
    }
}

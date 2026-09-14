import Foundation
import IOKit

/// AppleSMC reader: temperatures and whole-system power.
///
/// Works completely unprivileged — `IOServiceOpen(AppleSMC)` returns
/// KERN_SUCCESS as a normal user (verified), which is why we do not need
/// powermetrics or a privileged helper.
///
/// TWO LANDMINES:
///
///  1. THE 80-BYTE REQUEST IS A C STRUCT, AND SWIFT STRUCT LAYOUT IS NOT C
///     STRUCT LAYOUT. Declaring a Swift `struct SMCKeyData` compiles and
///     IOServiceOpen still succeeds, but every call comes back with a failed
///     result byte. Drive it as a raw [UInt8] of count 80 with explicit
///     offsets, which is what this file does.
///  2. FourCC KEYS ARE EASY TO BYTE-SWAP ONE TIME TOO MANY. The key field read
///     back out of the response as a little-endian UInt32 is already correct —
///     do not apply `.byteSwapped`. The tell-tale symptom is `#KEY` reading
///     back as `YEK#`.
///
/// THREADING: `connection` is not thread-safe. Serial sampling queue only.
final class SMCSampler {

    // Offsets into the 80-byte SMCKeyData C struct.
    private static let structSize = 80
    private static let offKey = 0
    private static let offKeyInfoSize = 28
    private static let offKeyInfoType = 32
    private static let offKeyInfoAttr = 36
    private static let offResult = 40
    private static let offData8 = 42
    private static let offData32 = 44
    private static let offBytes = 48

    private static let selectorCall: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdGetKeyFromIndex: UInt8 = 8
    private static let cmdGetKeyInfo: UInt8 = 9

    private struct KeyInfo { let size: UInt32; let type: UInt32; let attributes: UInt8 }

    private var connection: io_connect_t = 0
    private var infoCache: [String: KeyInfo] = [:]

    /// Discovered once at init by walking the key index, so we never guess at
    /// sensor names. On this M2: Tp00..Tp0s (P-cores), Te04..Te06 (E-cores),
    /// Tg0e..Tg0r (GPU), TB0T..TB2T (battery) — all type 'flt '.
    private(set) var performanceKeys: [String] = []
    private(set) var efficiencyKeys: [String] = []
    private(set) var gpuKeys: [String] = []
    private(set) var batteryKeys: [String] = []
    /// How long the one-time key enumeration took, for the record.
    private(set) var discoveryMs: Double = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS, connection != 0 else {
            return nil
        }
        let start = Mono.now()
        discoverTemperatureKeys()
        discoveryMs = Mono.seconds(since: start) * 1000
        if performanceKeys.isEmpty && efficiencyKeys.isEmpty && gpuKeys.isEmpty && batteryKeys.isEmpty {
            // The SMC opened but exposes nothing we recognise — still usable
            // for PSTR, so don't fail the whole sampler.
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Public reads

    /// Reads every sensor EXACTLY ONCE. (Reading them twice — once for the
    /// average, once for the peak — doubled the cost of the SMC tick.)
    ///
    /// The averages are the numbers to display. `peak` is honest but alarming:
    /// this M2 carries three sensors per P-core and the third is a hot-spot
    /// sensor that runs ~10-25 °C above its siblings (measured: Tp00 87.8,
    /// Tp01 93.9, Tp02 109.7 in the same instant). Label it "hot spot", never
    /// "CPU temperature".
    func temperatures() -> (perf: Double?, eff: Double?, gpu: Double?, battery: Double?, peak: Double?) {
        var perfSum = 0.0, perfN = 0, peak: Double?
        for key in performanceKeys {
            guard let v = plausibleCelsius(float(key)) else { continue }
            perfSum += v; perfN += 1; peak = max(peak ?? v, v)
        }
        var effSum = 0.0, effN = 0
        for key in efficiencyKeys {
            guard let v = plausibleCelsius(float(key)) else { continue }
            effSum += v; effN += 1; peak = max(peak ?? v, v)
        }
        return (perfN > 0 ? perfSum / Double(perfN) : nil,
                effN > 0 ? effSum / Double(effN) : nil,
                average(gpuKeys),
                average(batteryKeys),
                peak)
    }

    /// A disconnected sensor reads 0 or a wild value; excluding both stops one
    /// dead sensor from halving the reported temperature.
    private func plausibleCelsius(_ v: Double?) -> Double? {
        guard let v, v > 1, v < 150 else { return nil }
        return v
    }

    /// `PSTR` — total system power in watts (~17.5 W measured here). IOReport
    /// has no equivalent channel.
    func systemWatts() -> Double? { plausibleWatts(float("PSTR")) }
    /// `PDTR` — power arriving from the charger.
    func adapterWatts() -> Double? { plausibleWatts(float("PDTR")) }
    /// `PPBR` — battery power.
    func batteryWatts() -> Double? { plausibleWatts(float("PPBR")) }

    private func plausibleWatts(_ v: Double?) -> Double? {
        guard let v, v.isFinite, abs(v) < 1000 else { return nil }
        return v
    }

    private func average(_ keys: [String]) -> Double? {
        var sum = 0.0, n = 0
        for key in keys {
            if let v = plausibleCelsius(float(key)) { sum += v; n += 1 }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    // MARK: - Key discovery

    private func discoverTemperatureKeys() {
        guard let countBytes = readKey("#KEY"), countBytes.count >= 4 else { return }
        // '#KEY' is a ui32 in SMC (big-endian) byte order.
        let count = UInt32(countBytes[0]) << 24 | UInt32(countBytes[1]) << 16
                  | UInt32(countBytes[2]) << 8 | UInt32(countBytes[3])
        guard count > 0, count < 10_000 else { return }

        for i in 0..<count {
            guard let name = keyName(atIndex: i) else { continue }
            guard name.hasPrefix("T") else { continue }
            guard let info = keyInfo(name), fourCCString(info.type) == "flt ", info.size == 4 else { continue }
            if name.hasPrefix("Tp") { performanceKeys.append(name) }
            else if name.hasPrefix("Te") { efficiencyKeys.append(name) }
            else if name.hasPrefix("Tg") { gpuKeys.append(name) }
            else if name.hasPrefix("TB") && name.hasSuffix("T") { batteryKeys.append(name) }
        }
    }

    private func keyName(atIndex index: UInt32) -> String? {
        var request = [UInt8](repeating: 0, count: Self.structSize)
        request[Self.offData8] = Self.cmdGetKeyFromIndex
        write32(&request, Self.offData32, index)
        guard let response = call(request), response[Self.offResult] == 0 else { return nil }
        // Already correct as a little-endian load. Do NOT byteSwap.
        return fourCCString(read32(response, Self.offKey))
    }

    // MARK: - Raw SMC plumbing

    private func keyInfo(_ key: String) -> KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var request = [UInt8](repeating: 0, count: Self.structSize)
        write32(&request, Self.offKey, fourCC(key))
        request[Self.offData8] = Self.cmdGetKeyInfo
        guard let response = call(request), response[Self.offResult] == 0 else { return nil }
        let info = KeyInfo(size: read32(response, Self.offKeyInfoSize),
                           type: read32(response, Self.offKeyInfoType),
                           attributes: response[Self.offKeyInfoAttr])
        infoCache[key] = info
        return info
    }

    /// One ioctl per read once the key's info is cached.
    private func readKey(_ key: String) -> [UInt8]? {
        guard let info = keyInfo(key), info.size > 0, info.size <= 32 else { return nil }
        var request = [UInt8](repeating: 0, count: Self.structSize)
        write32(&request, Self.offKey, fourCC(key))
        write32(&request, Self.offKeyInfoSize, info.size)
        write32(&request, Self.offKeyInfoType, info.type)
        request[Self.offKeyInfoAttr] = info.attributes
        request[Self.offData8] = Self.cmdReadBytes
        guard let response = call(request), response[Self.offResult] == 0 else { return nil }
        return Array(response[Self.offBytes..<(Self.offBytes + Int(info.size))])
    }

    /// SMC 'flt ' values are little-endian Float32.
    private func float(_ key: String) -> Double? {
        guard let info = keyInfo(key), fourCCString(info.type) == "flt ",
              let raw = readKey(key), raw.count == 4 else { return nil }
        let value = raw.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
        return value.isFinite ? Double(value) : nil
    }

    private func call(_ request: [UInt8]) -> [UInt8]? {
        guard connection != 0 else { return nil }
        var response = [UInt8](repeating: 0, count: Self.structSize)
        var outSize = Self.structSize
        let rc = request.withUnsafeBytes { input -> kern_return_t in
            response.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, Self.selectorCall,
                                          input.baseAddress!, Self.structSize,
                                          output.baseAddress!, &outSize)
            }
        }
        return rc == KERN_SUCCESS ? response : nil
    }

    private func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
    }

    private func fourCCString(_ v: UInt32) -> String {
        let bytes = [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
                     UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private func write32(_ buf: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buf[offset] = UInt8(truncatingIfNeeded: value)
        buf[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        buf[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        buf[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func read32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buf[offset]) | UInt32(buf[offset + 1]) << 8
        | UInt32(buf[offset + 2]) << 16 | UInt32(buf[offset + 3]) << 24
    }
}

import AppKit

// Hidden diagnostic entry point. Never reachable from the UI; the shipping
// app always takes the NSApplication path below.
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --probe
if CommandLine.arguments.contains("--probe") {
    Probe.run(arguments: CommandLine.arguments)
}

// Numeric check that the DRAWN island and the HIT-TESTED island are the
// same rectangle at every trailing-wing width the model will grant, and
// that the camera housing stays centred while the wing moves. See
// IslandGeometryProbe. Exits non-zero if any invariant breaks.
if CommandLine.arguments.contains("--wing-probe") {
    IslandGeometryProbe.run(arguments: CommandLine.arguments)
}

// One real loopback fetch through the shipping PultLink, printed beside
// the values PrinterFeature.parse made of it. See FeatureProbes.swift.
if CommandLine.arguments.contains("--printer-probe") {
    PrinterProbe.run(arguments: CommandLine.arguments)
}

// Replays every payload that is known to have broken the printer parser —
// starting with the five that killed the shipping binary with SIGTRAP —
// through the real PrinterFeature.parse. Exits non-zero if any of them
// stops behaving. See FeatureProbes.swift.
if CommandLine.arguments.contains("--printer-fuzz") {
    PrinterFuzz.run()
}

// Live trace of the mic/camera rail: one line per published change, so a
// real recording can be started and stopped against it.
//   ... --privacy-probe 60
if CommandLine.arguments.contains("--privacy-probe") {
    PrivacyProbe.run(arguments: CommandLine.arguments)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon, no app switcher entry for itself
app.run()

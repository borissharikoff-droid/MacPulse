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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon, no app switcher entry for itself
app.run()

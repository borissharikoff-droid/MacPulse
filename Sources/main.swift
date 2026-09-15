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

// One real routing-table reading through the shipping TunnelSampler, printed
// as the 560 x 186 section's own lines. Reads only; toggles nothing.
//   ... --tunnel-probe [--cost 200]
if CommandLine.arguments.contains("--tunnel-probe") {
    TunnelProbe.run(arguments: CommandLine.arguments)
}

// Live trace of the mic/camera rail: one line per published change, so a
// real recording can be started and stopped against it.
//   ... --privacy-probe 60
if CommandLine.arguments.contains("--privacy-probe") {
    PrivacyProbe.run(arguments: CommandLine.arguments)
}

// Reads the calendar through the shipping CalendarEngine and prints what the
// section would draw. Never prompts unless explicitly asked to.
//   ... --calendar-probe [watch 60 | cost]
if CommandLine.arguments.contains("--calendar-probe") {
    CalendarProbe.run(arguments: CommandLine.arguments)
}

// Live trace of «Звук»: what the island publishes, the cheap gate beside
// the full sweep it skips, and one real transport command. See
// FeatureSound.swift.
//   ... --sound-probe watch 60 | gate 20 | send toggle | cost 120
if CommandLine.arguments.contains("--sound-probe") {
    SoundProbe.run(arguments: CommandLine.arguments)
}

// Drives the real ClipboardEngine on a PRIVATE pasteboard: records a
// normal copy, refuses a ConcealedType item without ever asking for its
// bytes, and puts an entry back. The user's own clipboard is untouched.
// See IslandSectionClipboard.swift.
if CommandLine.arguments.contains("--clipboard-probe") {
    ClipboardProbe.run()
}

// Rasterises the REAL IslandView offscreen and counts what is in it: how
// many coloured dots the collapsed strip lights (the answer must be ONE),
// what the shelf holds, and whether the panel's rows end exactly at the
// bottom of the plate. NOT a screenshot — it needs no screen at all, which
// is the point: a locked screen hands `screencapture` a frame of pure
// black with a zero exit status. See IslandRenderProbe.swift.
//   ... --render-probe [output-directory]
if CommandLine.arguments.contains("--render-probe") {
    IslandRenderProbe.run(arguments: CommandLine.arguments)
}

// Rail discipline: start the real IslandModel, let every feature source
// settle, and print which sections report hasState == true. A quiet machine
// should show ONE chip. See RailProbe.swift.
//   ... --rail-probe [20]
if CommandLine.arguments.contains("--rail-probe") {
    RailProbe.run(arguments: CommandLine.arguments)
}

// The self-updater's own check: version-comparison and host allow-list
// tables, the REAL validator run against a zip you built by hand, or one
// real GitHub round trip that installs nothing. See UpdateProbe.swift.
//   ... --update-probe [validate <zip> | check]
if CommandLine.arguments.contains("--update-probe") {
    UpdateProbe.run(arguments: CommandLine.arguments)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon, no app switcher entry for itself
app.run()

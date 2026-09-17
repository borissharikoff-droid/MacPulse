# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · versioning: [SemVer](https://semver.org/).

## 1.0.0

First public release.

### Memory and pressure

- Measures **memory compressor churn** — compressions plus decompressions in bytes per second, derived from `vm_statistics64` counters using the real page size (16,384 B on Apple Silicon). The rate is recomputed only when the kernel's counters actually move: two consecutive `host_statistics64` samples can return bit-identical values for up to ~1 s, and dividing by the nominal interval would report a false zero at exactly the moments that matter.
- Memory pressure level from `kern.memorystatus_vm_pressure_level` — it colours the dot in the notch and titles the panel.
- Memory warnings: 45 s of sustained pressure, at most 3 times a day. Over six hours of 1 Hz samples at level 2, the naive `level >= 2` rule would have fired 21,600 times; the detector fired once.
- Apps listed by `phys_footprint`, each with a Quit button: a polite `terminate()` first, and a forced kill only on a second deliberate click and only after the polite one failed.

### Island sections

The rail lights only what has something to say right now:

- **Print** — Bambu P1S job status, read from the user's own local panel on `127.0.0.1:8787`. Read-only; the printer is never sent a command.
- **Sound** — which apps hold an open audio stream, plus transport buttons via MediaRemote.
- **Tunnel** — which interface actually carries traffic out: one `RTM_GET` for a public address over a `PF_ROUTE` socket, rather than reading the default route (which reports `en0` on a fully tunnelled machine). No packet is sent to that address.
- **Clipboard** — clipboard history, in memory, with a secret filter.
- **Meeting** — time until the next event. Off by default.
- **Privacy line** — who holds the microphone and whether the camera is on.

### Updates

- Self-update from GitHub Releases: one check 45 s after launch, then every 6 hours with a 30-minute tolerance so the timer never wakes the machine on its own. A silent check reports nothing on failure — a laptop being offline is a normal state, not an incident. A manual check always answers, in the menu item's own title.
- The downloaded archive is checked with `codesign --verify --deep --strict`. That proves **integrity** — the file was not truncated and was not modified after signing. It does not prove **provenance**: an ad-hoc signature carries no identity. Provenance rests on TLS to GitHub and on nothing else, which is what this says instead of the word "verified".
- An update never asks for a password: if the installed bundle sits somewhere the user cannot write, the update is abandoned.

### Installing

- **One-command install** — `curl … install.sh | bash`. Fetches the release, verifies the signature and the architecture, installs to Applications and launches it. Not one Gatekeeper dialog: quarantine is applied by whatever downloads the file, and `curl` does not apply it. For an ad-hoc signed app that is decisive — since macOS 15, Finder will not open such an app at all, the Control-click bypass having been removed.
- The installer copies the new version alongside the old one and swaps it in with a rename, so the window in which no app exists is one `mv` long. It refuses a foreign bundle, a truncated archive, and a build with no slice for your CPU — and in each of those cases the installed copy is left untouched.
- `install.sh --uninstall` removes the app, the login-item registration and its settings.
- **Universal binary: Apple Silicon and Intel** in one file. The build used to be arm64-only, and an arm64 bundle on an Intel Mac does not say "unsupported architecture" — Finder says the app is damaged, which sends the person looking for the wrong problem. The Intel slice is not assumed to work: the probes are run against it under Rosetta.
- A `.dmg` is still attached to every release for anyone who prefers dragging.

### Everything else

- The island lives in the notch; on Macs without one it falls back to a pill in the menu bar.
- Launch at login via `SMAppService`. The checkmark shows what macOS answered, not what the user wished for: if registration failed — the copy is outside Applications, or running from a disk image — the switch says so out loud, and the state "registered but switched off in Login Items" is drawn as a dash and leads to the right Settings pane.
- The selected tab stays selected. The router no longer sends you back to Memory when the section you picked has nothing to show: a quiet section draws its own empty state, and that is a real answer.
- Cleaning `~/Library/Caches` and `~/Library/Logs`, labelled honestly as something that frees disk and does nothing for memory pressure.
- A build contract checked before and after compiling: `URLSession` is permitted in exactly two of ~61 files (`Updater.swift`, `GeoLookup.swift`), each may name only its own hosts, and no host is ever assembled at runtime. Beyond those, the only things that can put a byte on a wire are a loopback socket in `PultLink.swift` and a read-only `PF_ROUTE` query in `TunnelSampler.swift`. `Network.framework` is absent from the link map.

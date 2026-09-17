# How this project is put together

No Xcode, no SPM, not a single dependency: ~60 flat `.swift` files and one `swiftc` call.

```bash
git clone https://github.com/borissharikoff-droid/MacPulse.git
cd MacPulse
./build.sh              # 2–4 minutes
```

Command Line Tools are the only requirement: `xcode-select --install`.

## Three rules that break silently

**1. `Sources/` stays flat.** The glob in `build.sh` does not descend into subdirectories. A file at `Sources/Foo/Bar.swift` is simply never compiled, and the error points at the *caller* — "cannot find X in scope" in a file that is perfectly correct. `build.sh` checks this first and refuses to build.

**2. A section appears only when it has something to say.** `IslandSection.hasState` must return `false` when a feature has nothing to show. A section whose chip is always present costs the user a tab they did not ask for, and seven of those turn the router back into the dashboard it was written to replace. Checked by `MacPulse --rail-probe 14`.

**3. A `@Published` write redraws every observer.** Measured: walking all 441 processes costs 0.059% of a core; telling SwiftUI about it at 1 Hz costs 0.316%. Sampling the machine is nearly free — reporting it is what costs. Hence `if old != new` before every assignment, and that is not a micro-optimisation.

**A fourth one that breaks even more quietly: long `+` chains.** `+` is one of the most heavily overloaded operators in Swift, and the solver explores those overloads combinatorially across a chain. A tooltip built from four `+` with an `Optional.map` in the middle cost 872 ms of type-checking and dragged its whole `body` getter to 2213 ms — and on the Swift in Xcode 15.4 it did not compile at all: *"unable to type-check this expression in reasonable time"*, which is an error, not a warning. It built on one machine and nowhere else. Build strings with interpolation. To find candidates:

```bash
swiftc -target arm64-apple-macos13.0 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk -typecheck \
  -Xfrontend -warn-long-expression-type-checking=200 \
  -Xfrontend -warn-long-function-bodies=400 Sources/*.swift
```

There is deliberately no threshold in `build.sh`: milliseconds measure the machine, not the code, and a build that fails on a slow runner only teaches people to ignore it.

And for the same reason, **a clean run of that command proves nothing about anyone else's compiler.** Verified twice the hard way: zero slow expressions locally while Xcode 15.4 refused to build. Its solver is slower and gives up at a limit the newer one never reaches. The only real answer to "does this build somewhere other than here" comes from CI on a different compiler. Locally, hunt by *shape*: a single expression carrying four or more `+` and `??` mixed with calls is a candidate regardless of the stopwatch.

## The network contract

`build.sh` checks it before and after compiling and refuses to build on a violation. In short:

- `URLSession` is allowed in exactly two files — `Updater.swift` and `GeoLookup.swift`;
- each may name only its own hosts, and those strings are never assembled at runtime;
- `Network.framework` is forbidden outright: `NWConnection` opens a connection to anywhere, and that cannot be checked by grep;
- raw sockets exist only in `PultLink.swift` (loopback) and `TunnelSampler.swift` (`PF_ROUTE`, reading the routing table).

Deleting a guard is how a property dies. If a property changes on purpose, the contract text at the top of `build.sh` changes with it — not just the code. See [SECURITY.md](SECURITY.md).

## Probes, instead of "I looked at it and it seemed fine"

Each one starts the real classes the app uses, not a copy of the logic:

```
MacPulse --rail-probe 14          live sections, rail width, and whether a click sticks
MacPulse --render-probe DIR       renders the island off-screen and counts the pixels
MacPulse --login-probe roundtrip  launch-at-login: enable, read back, restore
MacPulse --wing-probe             island geometry against the notch
MacPulse --update-probe           the updater's version and host tables
```

A probe that went stale after a behaviour change is a lie shaped like a check. Fix it in the same commit.

## Commits

The subject says what is true now, not what was done: "A clicked tab stays clicked", not "fix router bug". The body says why the previous behaviour was reasonable, and what changed in the world so that it stopped being reasonable.

# Security

## Reporting

Open a [private advisory](https://github.com/borissharikoff-droid/MacPulse/security/advisories/new). If that is not available to you, open a normal issue without the details and say you need a private channel.

## What this app can and cannot do

MacPulse reads system counters. It has no entitlements, no helper tool, no privileged execution, and it never calls `sudo`. The boundaries below are enforced by `./build.sh`, which greps the sources before compiling and inspects the link map afterwards, and **fails the build** rather than warning.

**Network.** Four things can put a byte on a wire, and nothing else compiles:

| Where | To | Why |
|---|---|---|
| `Updater.swift` | `api.github.com`, `github.com`, `objects.githubusercontent.com` | checking for and downloading updates |
| `GeoLookup.swift` | `www.cloudflare.com/cdn-cgi/trace` | your public IP and country, for the Tunnel section |
| `PultLink.swift` | `127.0.0.1:8787` | the local 3D-printer panel, loopback only |
| `TunnelSampler.swift` | nothing — a `PF_ROUTE` socket | asks the kernel which interface carries traffic; sends no packet |

`URLSession` is permitted in exactly two files. Every host is a literal that can be grepped; none is assembled at runtime, and the build guard fails on any interpolation between `://` and the first `/`. `Network.framework` is absent from the link map, because `NWConnection` would reach any host and port with nothing to grep for.

**Redirects are not host-checked.** The allow-list covers the URL we are handed; after that URLSession follows GitHub's chain wherever it goes. This is written down rather than papered over — see the note at the top of `Sources/Updater.swift`.

**Files.** Deletion is confined to the contents of `~/Library/Caches` and `~/Library/Logs`, plus the updater's own staging directory, with symlinks resolved on both sides before anything is unlinked.

**Processes.** Termination is confined to what you clicked.

**Clipboard.** History lives in memory and is never written to disk. Entries marked `org.nspasteboard.ConcealedType` — what password managers set — are never recorded, and their bytes are never requested. Copied images spool to a per-launch temporary directory that is wiped at startup.

**MCP.** `MacPulse --mcp` speaks over stdio; there is no port and no listener. Its six tools are read-only and expose no clipboard contents, no window titles and no file paths.

## Signing

Releases are **ad-hoc signed** — there is no paid Apple Developer ID behind them, and macOS will tell you so.

`codesign --verify --deep --strict` proves **integrity**: the bundle was not truncated in transit and has not been modified since it was signed. Both the installer and the self-updater run it and refuse the bundle if it fails.

It does not prove **provenance**. An ad-hoc signature carries no identity. Provenance here rests on one thing only: TLS to GitHub. That is the honest description, and it is why this file says it instead of the word "verified".

## Supported versions

Fixes go into the next release from `main`. Older releases are not patched.

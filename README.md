<div align="center">

<img src="docs/banner.svg" width="820" alt="MacPulse — a system monitor that lives in the MacBook notch">

[![build](https://github.com/borissharikoff-droid/MacPulse/actions/workflows/build.yml/badge.svg)](https://github.com/borissharikoff-droid/MacPulse/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/borissharikoff-droid/MacPulse?color=0a0a0a&labelColor=0a0a0a)](https://github.com/borissharikoff-droid/MacPulse/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-0a0a0a?logo=apple&logoColor=white&labelColor=0a0a0a)
![universal](https://img.shields.io/badge/universal-arm64%20%2B%20x86__64-0a0a0a?labelColor=0a0a0a)
![dependencies 0](https://img.shields.io/badge/dependencies-0-2ea44f?labelColor=0a0a0a)

<br>

<img src="docs/expanded.png" width="740" alt="The expanded panel: memory pressure, apps by footprint, clipboard shelf">

</div>

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/borissharikoff-droid/MacPulse/main/install.sh | bash
```

Ten seconds, no dialogs. macOS 13+, Apple Silicon and Intel.

> [!NOTE]
> **The interface is in Russian.** Everything below describes it in English, but the app itself is not translated.

<details>
<summary>Why a terminal command and not the .dmg</summary>

<br>

MacPulse is ad-hoc signed — no paid Apple Developer ID. Since macOS 15, Finder refuses to open such an app at all: the old Control-click ▸ Open bypass is gone, leaving System Settings ▸ Privacy & Security ▸ "Open Anyway", three steps in a place nobody looks, after a dialog claiming the app is damaged. It is not damaged.

Quarantine is applied by whatever downloads the file, and `curl` does not apply it — so an installer that fetches the app itself lands a working copy with no dialog. Same trick as `brew install --cask --no-quarantine`.

The installer verifies the bundle identifier, the code signature and that a slice for your CPU is actually present; it refuses on any of the three and leaves whatever you already have untouched. It never uses `sudo`. Read it first if you like — `curl -O` the URL, then `less install.sh`.

A `.dmg` is attached to [every release](https://github.com/borissharikoff-droid/MacPulse/releases/latest) for anyone who would rather drag and take the Settings trip.

**Uninstall:** `curl -fsSL …/install.sh | bash -s -- --uninstall`

</details>

## What it measures that others don't

Since Mavericks, macOS does not swap unused pages to disk — it **compresses** them in RAM. So "free memory" means almost nothing, and the thing that actually makes a Mac feel slow is not a number any monitor displays: it is the **compressor working**. Every touch of a compressed page is a decompression on the page-fault path, and that is what you feel as a stuttering cursor and a Safari tab reloading itself.

MacPulse reads `compressions` and `decompressions` from `vm_statistics64` and reports the sum in bytes per second. On an 8 GB Apple Silicon Mac that is the real "you are about to lag" signal.

It also refuses to ship a "free memory" button. RAM cleaners throw away cache the system re-reads and re-compresses a second later — that is extra work, not freed memory. The only action that lowers pressure is quitting the app causing it, so there is a Quit button on each row, and nowhere else.

## The panel

Collapsed, the island is **one dot**, coloured by the kernel's pressure verdict. Hovering expands it. The rail lists every section, but only the ones with something to say right now are lit.

| Section | What's in it |
|---|---|
| **Memory** | Pressure level, used-of-total, swap, your apps by `phys_footprint` — each with a Quit button, and a badge that opens that app's real window list |
| **Print** | Bambu P1S job status, if you run the same local panel on `127.0.0.1:8787` |
| **Meeting** | Time until your next event — off by default, opt-in from the menu |
| **Sound** | Which apps hold an open audio stream, with transport buttons |
| **Tunnel** | Which interface actually carries your traffic out, plus public IP and country |
| **Session** | An active [VibeHub](https://github.com/EmilSwag/vibehub) coding session, if you happen to run one |

Along the bottom: a **clipboard shelf** — last five entries, drag any chip straight into another app. In memory only, nothing written to disk, and anything marked concealed by a password manager is never even read.

## What it costs

A monitor that eats the machine is pointless, so MacPulse measures itself from the inside (`task_thread_times_info`, via `--cost-log`):

| | % of one core |
|---|---|
| Measured idle | **0.27** |
| Walking all 441 processes | 0.059 |
| Polling the clipboard at 1 Hz | 0.00013 |
| Update check, amortised over 6 h | ~0.0002 |

The measurement that shaped the whole UI: **sampling the machine is nearly free — telling SwiftUI about it is what costs.** One `@Published` write per second into a trivial view cost 0.316% of a core, against 0.059% for the full process walk.

## Permissions

**None are requested at launch.** Three are possible, each only after you click something:

- **Calendar** — only if you tick "show next meeting". Reads the start time; titles are never stored or sent.
- **Notifications** — only if you enable memory alerts.
- **Accessibility** — only the first time you click the grey process badge on a memory row, to list that app's windows. Refuse it and the row says so in one line while everything else keeps working.

Network access is two files wide and checked at build time: HTTPS to three GitHub hosts for updates, one request to `cloudflare.com/cdn-cgi/trace` for your public IP, a loopback socket for the printer, and a read-only `PF_ROUTE` query for the tunnel. `Network.framework` is absent from the link map, and `./build.sh` fails if that stops being true.

## For AI agents

```bash
/Applications/MacPulse.app/Contents/MacOS/MacPulse --mcp
```

A read-only MCP server over stdio — no port, no listener. Six tools, including the compressor churn no other monitor reports. It exposes no clipboard contents, no window titles and no file paths.

## Build from source

```bash
git clone https://github.com/borissharikoff-droid/MacPulse.git
cd MacPulse && ./build.sh
```

Command Line Tools and nothing else — no Xcode, no SPM, no dependencies. ~60 flat `.swift` files and one `swiftc` call.

## More

[Full documentation (Russian)](docs/README.ru.md) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Releasing (RU)](RELEASING.md)

<br>

<div align="center"><sub>MIT · built for an 8 GB M2 MacBook Air that kept stuttering</sub></div>

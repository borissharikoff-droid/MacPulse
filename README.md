<div align="center">

<img src="docs/banner.svg" width="820" alt="MacPulse — a system monitor that lives in the MacBook notch">

[![build](https://github.com/borissharikoff-droid/MacPulse/actions/workflows/build.yml/badge.svg)](https://github.com/borissharikoff-droid/MacPulse/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/borissharikoff-droid/MacPulse?color=0a0a0a&labelColor=0a0a0a)](https://github.com/borissharikoff-droid/MacPulse/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-0a0a0a?logo=apple&logoColor=white&labelColor=0a0a0a)
![universal](https://img.shields.io/badge/universal-arm64%20%2B%20x86__64-0a0a0a?labelColor=0a0a0a)
![dependencies 0](https://img.shields.io/badge/dependencies-0-2ea44f?labelColor=0a0a0a)

</div>

```bash
curl -fsSL https://raw.githubusercontent.com/borissharikoff-droid/MacPulse/main/install.sh | bash
```

<sup>macOS 13+ · Apple Silicon and Intel · no Gatekeeper dialogs · **the app's UI is in Russian**</sup>

<details><summary>Why a terminal command and not the .dmg</summary><br>

Ad-hoc signed, so since macOS 15 Finder will not open it at all. Quarantine is set by whatever downloads the file, and `curl` does not set it — so this lands a working copy with no dialog. The installer checks the bundle id, the signature and your CPU's slice, never uses `sudo`, and leaves what you have untouched if any check fails. A `.dmg` is attached to [every release](https://github.com/borissharikoff-droid/MacPulse/releases/latest).

**Uninstall:** `curl -fsSL …/install.sh | bash -s -- --uninstall`

</details>

---

### Hover the notch

<img src="docs/gif/open.gif" width="760" alt="The collapsed dot expands into the panel">

### One click per section

<img src="docs/gif/sections.gif" width="760" alt="Switching between the live sections">

### Close windows, not processes

<img src="docs/gif/windows.gif" width="760" alt="The window list, and the two-step close-others button">

---

<div align="center">
<sub>Offscreen renders of the shipping view tree — not screen recordings.</sub><br><br>
<sub><a href="docs/README.ru.md">Docs (RU)</a> · <a href="CHANGELOG.md">Changelog</a> · <a href="CONTRIBUTING.md">Contributing</a> · <a href="SECURITY.md">Security</a> · MIT</sub>
</div>

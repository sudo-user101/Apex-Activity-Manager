<div align="center">

<img src="Resources/apex_icon.png" width="128" alt="Apex Activity Manager icon" />

# Apex Activity Manager

**A native activity manager for macOS, by CyberNet Labs.**

See what your Mac is doing, understand why, and fix it, in a light app that
feels at home on macOS and borrows the conveniences power users expect.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white)
![Apple silicon + Intel](https://img.shields.io/badge/arch-Apple%20silicon%20%2B%20Intel-555)
![License](https://img.shields.io/badge/license-PolyForm%20Strict-blue)

</div>

<p align="center">
  <img src="docs/images/drive.png" width="860" alt="A plugged-in drive's page: live read/write graph, connection, health and storage tools" />
</p>

## Why Apex

- **Native and light.** SwiftUI + AppKit, under 10 MB. System numbers come
  straight from the kernel and IOKit; no tools are spawned every tick, and
  sampling stops completely when the window is hidden.
- **Explains, not just measures.** Diagnostics come with the evidence, what it
  means, and steps to fix it, and never claim something is fixed unless Apex
  can check it.
- **Honest numbers.** When macOS doesn't expose something (per-accessory power,
  GPU power without admin rights), Apex says so instead of guessing.

## Features

**Processes**
- Apps with their helper processes grouped, background and system processes,
  filter and search, an inspector with security details (signature,
  notarization) and the command line.
- End, End Tree, Pause / Resume, priority, and **Optimize**: keep an app
  running at background priority on efficiency cores, hidden, until restored.

**Performance**
- CPU (per core, P/E cores), Memory (pressure, breakdown, swap), Disk,
  Network, GPU, Energy and Sensors, each with a 1–10 minute graph and an
  advanced graph with exact values on hover.
- **Memory:** Free Up Memory with Optimize, Quit (and **Reopen** later, with
  each app's windows), or clear the file cache.
- **Network:** local IP per interface (private vs public), router and host
  names, per-app traffic and connections, listening ports.
- **GPU:** utilisation, rendering and geometry load, memory, temperature,
  top GPU processes, and the share used by local AI runtimes.
- **Energy:** per-app power, battery health and history, connected
  accessories (USB devices behind hubs, Bluetooth batteries).

**Drives**
- A page for every plugged-in drive, added and removed live, with the USB
  standard it's running at.
- **Drive Doctor:** findings with evidence, severity and confidence, steps in
  order, read-only First Aid, and a remaining-life estimate only when the
  drive's own wear data supports one.
- **Storage:** Optimize, Analyze (folder by folder) and Clean for the startup
  drive; Analyze, drive Trash and hidden helper files for external drives.
  Everything is reviewed before anything is removed.
- **Transfers:** a live icon while files copy onto a drive, with progress,
  Cancel, and Move / Trash for a copy that went to the wrong place.
- **Bootable Media Creator:** a guided Image → Drive → Customise → Review →
  Create flow for Windows, Linux and macOS installers. For Windows 11 it can
  add an answer file: skip the TPM / Secure Boot / RAM checks, set up offline
  with a local account, use your region, and install apps at first sign-in.

**Battery** (MacBooks)
- Charge limit (50–100 %), Charge to 100% Now, weekly schedules, and night
  charging (hold lower overnight, full by morning). Enforced by a small
  privileged helper, so it keeps working with Apex closed.

**Also**
- History (30-day app usage, alert events with the reason each fired),
  notifications for sustained CPU, memory, swap, heat and disk problems,
  Startup items, Users, Services, Local AI runtimes, and a menu bar monitor.

<p align="center">
  <img src="docs/images/energy.png" width="860" alt="Energy: whole-Mac power draw, battery history, charge limit and battery health" />
</p>

## Install

1. Download **Apex Activity Manager 1.0.0.dmg** from
   [Releases](https://github.com/sudo-user101/Apex-Activity-Manager/releases).
2. Open it and drag **Apex Activity Manager** onto **Applications**.
3. The first time, macOS may say it can't check the app (it isn't notarized
   yet): open **System Settings › Privacy & Security** and click **Open Anyway**.

Requires macOS 14 Sonoma or later, on Apple silicon or Intel.

## Build from source

```bash
./build.sh                       # dist/Apex Activity Manager.app for this Mac
./build.sh --universal --dmg     # Apple silicon + Intel, plus the installer .dmg
swift test                       # unit tests
```

Needs Xcode or the Command Line Tools (Swift 5.10+). Building into a
temporary folder keeps the source tree clean (`BUILD_DIR=/path ./build.sh`).

## Project structure

| Path | What's there |
|---|---|
| `Sources/TaskManager/App` | App state and sampling loop, alerts, history, memory guard |
| `Sources/TaskManager/Sampling` | CPU, memory, disk, network, GPU and per-process samplers, device hot-plug |
| `Sources/TaskManager/System` | Battery, sensors, drive health and tools, storage, accessories, transfers, startup items |
| `Sources/TaskManager/Diagnostics` | The diagnostic model and Drive Doctor rules |
| `Sources/TaskManager/BootMedia` | Image inspection, Windows answer files, the media-creation job |
| `Sources/TaskManager/Views` | One file per page or panel |
| `Sources/DetectionCore` | Pure alert rules (samples in, events out) |
| `Sources/FanControlCore` | Pure fan, charge-limit, schedule and night-charging logic |
| `Sources/ApexFanHelper` | The privileged helper (installed only when you turn on charge or fan control) |
| `Tests/TaskManagerTests` | Unit tests |

More: [Architecture](docs/ARCHITECTURE.md) · [Where every number comes from](docs/DATA-SOURCES.md) · [AI diagnostics design](docs/AI-DIAGNOSTICS.md) · [Changelog](CHANGELOG.md)

## Status and roadmap

Verified on an Apple silicon MacBook running macOS 15. Fan control is built
and unit-tested but not yet tested on a Mac with fans; the Bootable Media
Creator has been tested on disk images.

Next: a native Windows edition, AI-assisted explanations (your own key, a
local model, or an Apex subscription; see the design doc), and a Developer
ID-signed, notarized release.

## License

Source-available under the [PolyForm Strict License 1.0.0](LICENSE):
you may read, build and use Apex for personal and other noncommercial
purposes, but not modify, redistribute or use it commercially.
For other uses, contact CyberNet Labs through the repository's issues.

© 2026 CyberNet Labs. "Apex Activity Manager" and "CyberNet Labs" are names
of CyberNet Labs.

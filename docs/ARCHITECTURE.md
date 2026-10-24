# Architecture

Apex is a Swift package with three libraries and two executables.

| Target | Kind | Role |
|---|---|---|
| `TaskManager` | app | UI (SwiftUI + AppKit), samplers, system actions |
| `DetectionCore` | library | Alert rules: samples in, events out. No AppKit, no clock, no I/O |
| `FanControlCore` | library | Fan curves, charge limit, schedules and night charging; shared with the helper |
| `ApexFanHelper` | executable | Root LaunchDaemon `com.apex.fanhelper`, installed on request; talks to the SMC |
| `TaskManagerTests` | tests | XCTest for all of the above |

## Data flow

- `Sampler` runs one coalescing timer on a background queue and builds a
  `Snapshot` from `SystemSampler` (Mach, sysctl, IOKit), `ProcessSampler`
  (libproc) and `DeviceScanner` (drives and network adapters, hot-plug).
- `AppModel.apply(_:)` feeds the 10-minute history, alerts
  (`DetectionCore` → `EventLog`), drive health, app usage history and
  transfers, then publishes to the UI only while a window is visible.
- Hidden window: sampling drops to every 10 s (or stops), caches are dropped
  and freed memory is handed back (`MemoryGuard`).

## Principles

- Pure logic (alert rules, diagnostics, charge rules, answer files, parsers)
  lives in testable types with no UI or I/O.
- Diagnostics use the shared `Finding` model: evidence with its source,
  severity, confidence, steps, safe actions and follow-up checks.
- Nothing destructive happens without a review step and an explicit
  confirmation; privileged work goes through an administrator prompt or the
  helper, which only accepts sanitised settings.

## Files Apex writes

| Path | Contents |
|---|---|
| `~/Library/Application Support/Apex Activity Manager/` | `history.json` (app usage), `events.json`, `charge.json`, `drives.json` |
| `/Library/PrivilegedHelperTools/com.apex.fanhelper` + LaunchDaemon | The helper, when enabled |
| `/Library/Application Support/Apex/fans.json`, `status.json` | Helper settings and status |

# Changelog

## 1.3.0 (2026-10-26)

- **Servers and containers:** add Linux servers (SSH, or the new
  [Apex Server Edition](https://github.com/sudo-user101/Apex-Activity-Manager-Server-Edition))
  and see Docker containers in the This Mac menu. Pick one and the whole app
  shows it: Processes, Performance, Users, Services, and a **Report** tab
  (last 1, 6 or 24 hours, what happened and what was busiest, save as PDF),
  plus a report for all servers or all containers at once.
- **Apex Server Edition pairing:** enter the server's address and the
  one-time pairing code; Apex remembers the server's certificate and refuses
  any other. End processes and start, stop or restart services and
  containers, without sudo or SSH.
- **Census** (Processes › More, ⇧⌘K): the top apps for CPU, memory, energy,
  disk, network and GPU in one view.
- **Energy:** select what's using power and End Task or Force End it.
- **Memory page:** calmer colours, a clearer graph, and a breakdown in three
  columns (overview, composition, memory pressure). Pressure is shown as
  macOS's own score, coloured by its state. Swap has a round, easy-to-hit
  button.
- **Assistant:** ask about your Mac with a local model, or any AI provider
  with your own key (named, grouped keys, checked when saved, nothing
  spent); Apex Agent can quit apps and stop processes when you ask and
  confirm.
- **Settings:** a native window with General, Alerts, History, Shelf and
  Permissions tabs.
- **Shelf:**
  - Opens as a stack.
  - Drag single files out of the list.
  - Every kind of drop lands, and a failed one says why.
  - Dropping files back on their own shelf no longer duplicates them.
  - Kept shelves in the menu bar show a pile, a count and an icon.
  - Pin up to 5, pinned first.
  - After you drop its files into an app or a folder, the floating shelf
    flies into the menu bar and waits in the menu bar's Shelf tab.
- **Safer Quit and Force Quit:** Apex now remembers exactly which process
  you chose (not just its number), and macOS itself refuses the action if
  that process has quit and its number was reused. Quit from an alert asks
  first. Ending another user's process as administrator re-checks each one.
- **Network › Shell:** ready-made commands in categories with live output.
- **Cloud Disks:** says when a service's app is signed out or not open.
- **Remove app** also finds system files, installer records and sign-ins.
- **Disk › Clean:** plain words, safety labels, and a Free Up button.

- **Signed and notarized releases:** `build.sh --notarize` signs the app and
  its helper with a Developer ID (hardened runtime, secure timestamp),
  notarizes and staples the app and the .dmg; credentials come only from
  environment variables. A release workflow does it all when a version tag
  is pushed and publishes the .dmg with its SHA-256
  ([Releasing](docs/RELEASING.md)).
- New README, a website (`site/`, published with GitHub Pages), a security
  policy explaining the helper and every password prompt, contribution
  guidelines, and bug report and feature request forms.

## 1.2.0 (2026-10-25)

- **Cloud Disks** (Performance): iCloud Drive, OneDrive, Google Drive,
  Dropbox, Nextcloud and other synced folders, plus your own folders and
  WebDAV servers. See what's on this Mac and what's online only, make files
  online-only (or offload everything), and check uploads: speed, time left,
  whether the server can be reached and why not, a ring per file (uploading,
  paused, can't upload), pause and resume. Online storage from WebDAV, the
  provider's own page, or typed in.
- **Display** page: brightness for built-in and external monitors,
  resolutions, arrangement and AirPlay devices.
- **Network:** one page per connection (Wi-Fi, Ethernet, VPN), public IP
  (hide it with the eye), internet speed test, **Network Doctor**, a clear
  Pause for the traffic list, and double-click an app for its last
  10 minutes and every server it talked to.
- **Menu bar:** Monitor, Energy, Shelf, Clipboard and Sessions tabs; click
  three times to open Apex.
- **Shelf:** a floating shelf appears when you drag a file (wiggle it for a
  new one). Files sit as a stack (drag them all out at once) or a list;
  minimize to the side, the menu bar or a category. Compress photos, videos,
  PDFs and anything else (ZIP), compare with the original side by side,
  remove photo and video details without losing quality.
- **Record:** save everything Apex measures to a file you can hand to an AI
  to find out what was going on; or record just one resource from its page.
- **Energy:** power mode, Stay Awake (for a while, on chosen days, or with
  the lid closed for chosen apps), power in detail, accessories with power
  estimates; the graphs come first.
- **Memory:** optimized apps are remembered, and Restore All is always there.
- **Assistant** (Local AI): ask a model on your Mac about your Mac, with
  Apex's live readings.
- **Remove apps** with or without everything they left behind.
- **First launch:** a welcome tour and every permission in one place.
- Bootable Media Creator: drivers folder, computer name, time zone, and no
  automatic device encryption.
- Fixes: a memory leak in Clean, charge schedules stopping when Apex quit,
  smoother animations, and nothing heavy on the main thread.

## 1.1.0 (2026-10-24)

- Faster storage scans: Clean, Analyze and drive Storage measure folders in
  parallel across all CPU cores (about 2× faster on caches in testing).

- Accessories: stop a USB drive and resume it without unplugging it, and
  disconnect / reconnect Bluetooth accessories; Reconnect brings back a drive
  that was ejected but is still plugged in.
- Startup lists everything macOS starts automatically: apps that open at
  login and background items apps registered, next to launch agents and daemons.

## 1.0.0 (2026-10-24): first public release

- Processes, Performance (CPU, Memory, Disk, Network, GPU, Energy, Sensors),
  Local AI, History, Startup, Users and Services, plus a menu bar monitor.
- Drives: a page per plugged-in drive, Drive Doctor, Storage (Optimize,
  Analyze, Clean; drive Trash and helper files for external drives),
  live transfers with Cancel / Move / Trash, Format, and the Bootable Media
  Creator with Windows setup options.
- Memory: Optimize and Restore, Quit and Reopen with windows, clear cache.
- Network: local IP per interface, router and host names, per-app traffic.
- GPU: rendering / geometry load, memory, temperature, top processes, local AI share.
- Energy: per-app power, battery health, accessories with hubs.
- Battery: charge limit, Charge to 100% Now, schedules, night charging.
- Alerts and history for sustained CPU, memory, swap, heat and disk problems.

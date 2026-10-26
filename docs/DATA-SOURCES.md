# Data sources

Where every number in Apex comes from, and how it's calculated. No value is
estimated or simulated unless the row says so. Code paths are under
`Sources/TaskManager/`.

## Memory (Performance › Memory)

All system memory values come from one call per sample:
`host_statistics64(HOST_VM_INFO64)` in `Sampling/SystemSampler.swift`
(`memory()`), multiplied by `vm_kernel_page_size` (16 KB on Apple Silicon).
This is how macOS itself counts memory.

| Shown as | Formula / source | Meaning in plain words |
|---|---|---|
| Physical memory (8 GB) | `hw.memsize` | Installed RAM |
| **Memory used** | Apps + Operating System Memory + Compressed | RAM that is busy now |
| **Apps** | (`internal_page_count` − `purgeable_count`) × page | Memory apps asked for and are using |
| **Operating System Memory** | `wire_count` × page ("wired") | Memory macOS itself needs and can't move or compress (kernel, drivers, GPU buffers). Renamed from "System Memory" |
| **Compressed** | `compressor_page_count` × page | RAM holding squeezed-up app memory that wasn't used recently |
| Stored in compressor | `total_uncompressed_pages_in_compressor` × page | How big that compressed memory would be if expanded (shown in the swap details) |
| **Cache** | (`external_page_count` + `purgeable_count`) × page | Copies of files and data that can be thrown away instantly when apps need room |
| **Free** | (`free_count` + `speculative_count`) × page | RAM holding nothing |
| **Available** | Physical memory − Memory used | What apps could get without macOS having to swap (free plus cache) |
| **Swap used** | `sysctlbyname("vm.swapusage")` → `xsu_used` / `xsu_total` | Memory moved to the disk because RAM ran out. macOS adds swap files as needed, so the total grows |
| Swap in / out speed | Change in `swapins` / `swapouts` (pages) × page ÷ seconds | How fast memory is moving between RAM and disk right now |
| **Memory pressure** (state) | `kern.memorystatus_vm_pressure_level`: 1 Normal, 2 Elevated, 4 Critical | macOS's own state, the one it acts on; the headline on the Memory page |
| **Pressure score %** | 100 − `kern.memorystatus_level` | The kernel's memory level, shown as "Score … from the kernel"; not RAM used |
| Pressure colour / level | `kern.memorystatus_vm_pressure_level`: 1 Normal (green), 2 Elevated (yellow), 4 Critical (red) | The kernel's own verdict; Apex never calls yellow "high" |
| RAM type / speed / maker | `system_profiler SPMemoryDataType -json`; on Apple Silicon the speed isn't reported, so the chip's **spec-sheet** value is shown and labelled as such | |
| Memory graph series | Each panel row's value as % of physical memory, one point per sample, 10 minutes kept | |

### Per-app memory

| Shown as | Source |
|---|---|
| Memory column (Processes, top processes, Local AI) | `proc_pid_rusage(RUSAGE_INFO_V6).ri_phys_footprint`, the same "Memory" macOS shows. Fallback for restricted processes: `pti_resident_size` from `proc_pidinfo(PROC_PIDTASKALLINFO)`, or `ps` |
| App totals | Sum over the app's processes (helpers grouped under their app by bundle path) |
| Per-app swap (swap details popover) | `/usr/bin/footprint --swapped -f bytes <pid>` for your own processes, on demand only. macOS can't separate "compressed" from "swapped" per app, so the column is "compressed or swapped". To avoid counting shared memory twice, each process's swapped **share** is applied to its own footprint (`System/SwapScan.swift`) |
| Apex's own memory | `ri_phys_footprint` of itself (`App/MemoryGuard.swift`); caches are purged when hidden or under pressure (target < 80 MB) |

### Memory actions

| Action | What it does |
|---|---|
| Free Up Memory › Optimize | `taskpolicy -b -p <pid>`: Darwin background priority (lower CPU/IO priority, more willing to be compressed). Reversible with `-B` |
| Free Up Memory › Quit apps | Normal quit (`NSRunningApplication.terminate`); End in Processes can force quit |
| Free Up Memory › Clear Cache | `/usr/sbin/purge` with an administrator prompt: drops file cache |
| Pause | `SIGSTOP` / `SIGCONT` |

## CPU

| Value | Source |
|---|---|
| Total, user, system, per core | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick deltas (user, system, idle, nice) |
| P / E cores | `hw.perflevel0.physicalcpu` / `hw.perflevel1.physicalcpu` |
| Load average, uptime | `getloadavg`, `kern.boottime` |
| Per-process CPU | Change in `pti_total_user` + `pti_total_system` (`proc_pidinfo`, Mach time → ns) ÷ wall time. 100% = one core (macOS convitor convention; Settings can switch to share of all cores) |
| Thermal state | `ProcessInfo.thermalState` |

## Disk

| Value | Source |
|---|---|
| Read / write speed, reads/writes per second | The **startup drive's** `IOBlockStorageDriver` › `Statistics` counter deltas (the driver under `/`). Other drives have their own pages; disk images are excluded |
| Read / written since startup | The same counters as totals: bytes plus number of operations |
| Read / written in its lifetime | NVMe health log `Data Units Read/Written` × 512 000 bytes (internal SSD only) |
| Capacity / available | `URLResourceValues` `volumeTotalCapacity` / `volumeAvailableCapacityForImportantUsage` (matches Finder) |
| Per-process disk | `ri_diskio_bytesread` / `ri_diskio_byteswritten` deltas |

## Plugged-in drives and network adapters

| Value | Source |
|---|---|
| Which drives exist | Every `IOBlockStorageDriver`, its whole-disk `IOMedia` child (BSD name), and DiskArbitration's description: `DeviceProtocol` (USB, Thunderbolt, Secure Digital…), `DeviceInternal`, `DeviceVendor`/`DeviceModel`, `MediaSize`, `MediaEjectable`/`MediaRemovable` |
| Left out | The startup drive (that's the Disk page) and disk images (`Virtual Interface` / `Disk Image`) |
| Volumes on a drive | `FileManager.mountedVolumeURLs` (hidden volumes skipped) → `DADiskCreateFromVolumePath` → BSD name → walk IOKit parents to the drive's `IOBlockStorageDriver` (works through APFS containers). Size and free space from `URLResourceValues` |
| Drive read/write, operations | That driver's `Statistics` counters (reset when the drive is plugged in, hence "since plugged in") |
| Which network connections get a tab | The Wi-Fi card; built-in Ethernet ports (`IONetworkInterface` with `IOBuiltin` = Yes, SC type Ethernet, not a "Thunderbolt N" bridge port); and plugged-in adapters (IOKit ancestors include an `IOUSBHostDevice` (USB) or an `IOPCITunnelled` PCI device (Thunderbolt)). Virtual interfaces (`anpi`, the always-present "Ethernet Adapter" en3/en4, which have `IOBuiltin` = No) are left out. Wired ports are named Ethernet, Ethernet 2… (built-in first) |
| VPN tabs | `utun*` / `ipsec*` / `ppp*` interfaces that are up and have an IPv4 address in `SCDynamicStore` (macOS's idle system tunnels only have IPv6 link-local addresses). Name from the matching `State:/Network/Service/<id>/IPv4` → `Setup:/Network/Service/<id>` `UserDefinedName`, cached per tunnel; VPN apps that manage their own tunnel may not report one |
| Adapter name, type, MAC | `SCNetworkInterfaceCopyAll` (localized display name, interface type, hardware address) |
| Adapter traffic, link speed, up/down | The same `NET_RT_IFLIST2` sysctl as the whole-Mac numbers, per interface: `ifi_ibytes`/`ifi_obytes`, `ifi_baudrate`, `IFF_UP`+`IFF_RUNNING` |
| Adapter IP | `SCDynamicStore` `State:/Network/Interface/<bsd>/IPv4` |
| Hotplug | `IOServiceAddMatchingNotification` (first match / terminated) for `IOBlockStorageDriver`, `IOMedia`, `IONetworkInterface`; `NSWorkspace` did mount / unmount / rename |
| Eject | `NSWorkspace.unmountAndEjectDevice(at:)` |

## USB standard

`IOUSBHostDevice` above the drive or adapter: `Device Speed` (0 low 1.5 Mb/s,
1 full 12 Mb/s, 2 high 480 Mb/s = USB 2.0, 3 SuperSpeed 5 Gb/s = USB 3.2 Gen 1,
4 SuperSpeed+ 10 Gb/s = Gen 2, 5 = Gen 2×2 20 Gb/s) for how it's connected, and
`bcdUSB` (BCD, 0x0320 = USB 3.2) for what it supports. Serial number:
`kUSBSerialNumberString`.

## Drive health

| Value | Source |
|---|---|
| Internal SSD health | NVMe SMART log page 2 via `IOCreatePlugInInterfaceForService` on the service with `NVMe SMART Capable` = Yes, user client `AA0FA6F9-…` / interface `CCD1DB19-…`, `SMARTReadData`. Bytes: 0 critical warning, 1–2 temperature (K), 3 spare %, 4 spare threshold %, 5 % lifespan used, 32 data read, 48 data written (units of 512 000 bytes), 112 power cycles, 128 power-on hours, 144 unsafe shutdowns, 160 media errors |
| Response time | Δ(`Total Time (Read)` + `Total Time (Write)`) ÷ Δoperations from `IOBlockStorageDriver` `Statistics`; only when ≥20 ops/s and the time counter grows no faster than 32× real time (USB bridges fail this and are ignored) |
| Errors | Δ`Errors (Read/Write)`, Δ`Retries (Read/Write)` where reported |
| Transfers | Drive read + write ≥ 10 MB/s for ≥ 10 s; average speed of the episode |
| Apps run from a drive | Running processes whose executable path is on one of the drive's volumes |
| Time Machine | `Backups.backupdb` on a volume |
| Stored | `~/Library/Application Support/Apex Activity Manager/drives.json` (saved every 5 min and on quit) |
| File transfers | `Progress.addSubscriber(forFileURL:)` per mounted volume + home folder: `fileURL` (destination), `fileOperationKind`, `fractionCompleted`, `isCancellable` / `isPausable`; cancel via `Progress.cancel()` |
| Check for errors | `diskutil verifyVolume <volume>` (read-only First Aid); OK when exit 0 and "appears to be OK" |
| Drive Doctor | Pure rules over the record above (`DriveDoctor.diagnose`): SMART critical warning / spare < threshold → critical; % used ≥ 70 notice, ≥ 90 warning; media errors > 0, I/O errors → warning; retries > 10, response time > 3× usual (after 10 min active), last 3 transfers < ½ best, USB 3 device at USB 2 speed, < 10 % free (< 3 % warning) → notice; failed First Aid → warning |
| Remaining life | Only with an SSD health log: (100 − used%) ÷ wear rate, rate = (used% now − first reading) ÷ days since first seen; needs ≥ 30 days and ≥ 1 point; range from ±1 point (no upper bound at 1 point). Never for USB drives (no wear data) |

## Bootable Media Creator

| Value | Source |
|---|---|
| Windows version / editions / arch | `sources/install.wim` or `.esd` header: XML resource at 0x48 (7-byte size, 8-byte offset at 0x50), UTF-16LE; `<DISPLAYNAME>`, `<BUILD>`, `<ARCH>` (0 x86, 9 x64, 12 Arm64), `<LANGUAGE>`. Windows 11 = build ≥ 22000 |
| Linux ISO name | Mounted volume name (`hdiutil attach -readonly`) |
| Answer file | `autounattend.xml` in the drive root: windowsPE `reg add HKLM\SYSTEM\Setup\LabConfig` Bypass{TPM,SecureBoot,RAM}Check; specialize `…\OOBE BypassNRO`; oobeSystem International-Core locales, Shell-Setup `ProtectYourPC 3`, LocalAccounts, FirstLogonCommands (`net user /logonpasswordchg:yes`, winget installs) |
| Verification | Every copied file exists with the image's size; optional 4 MB-chunk byte comparison |
| Same drive check | IOKit registry ID at the Drive step must match at Review |

## Router and host names

| Value | Source |
|---|---|
| Router name | Reverse DNS of the gateway (`getnameinfo`, 2 s limit); else UPnP: SSDP M-SEARCH for `InternetGatewayDevice:1`, reply accepted only from the gateway IP with a description URL on the gateway, `friendlyName` |
| Router model | UPnP `manufacturer` + `modelName` |
| This Mac's host name | `SCDynamicStoreCopyLocalHostName` + `.local` |
| This Mac on the network | Reverse DNS of this Mac's IPv4 |
| Caching | Per router IP, 10 minutes; only while the Network page is open |

## Network

| Value | Source |
|---|---|
| Whole-Mac speed | `sysctl NET_RT_IFLIST2` 64-bit interface counters (getifaddrs wraps at 4 GB) |
| Per-app traffic | `nettop -P -x -L 1 -J bytes_in,bytes_out` snapshot per tick, diffed (a streaming nettop used 100% CPU, so it was replaced) |
| Interfaces, IPs, router, DNS | `getifaddrs`, `SCDynamicStore` |
| Local IP (stats) | `getifaddrs` IPv4 on interfaces that are up and running (no loopback), primary from `State:/Network/Global/IPv4` › `PrimaryInterface`, names from `SCNetworkInterfaceGetLocalizedDisplayName`; `utun/ipsec/ppp/tun/tap` = VPN. Scope: 10/8, 172.16/12, 192.168/16 private; 169.254/16 link-local; 100.64/10 shared (CGNAT); else public. Every 5 s while visible. No outside lookups |

## GPU

| Value | Source |
|---|---|
| Utilization, Rendering, Geometry | `IOAccelerator` › `PerformanceStatistics`: `Device`, `Renderer`, `Tiler Utilization %` |
| Memory in use / reserved | `In use system memory` / `Alloc system memory` (shared system memory) |
| GPU restarts | `recoveryCount` |
| Temperature | Average of the HID sensors named GPU (Sensors) |
| Per-app GPU % | Δ`accumulatedGPUTime` of each accelerator user client (`IOUserClientCreator` "pid N, name") ÷ wall time; sampled on Processes, Performance and Local AI |
| Local AI line | Sum of per-app GPU % of processes matching the Local AI signatures (names / bundles only) |
| GPU power | Not shown: only `powermetrics` (root) / IOReport reports it |

## Energy and battery

| Value | Source |
|---|---|
| Whole-Mac power (W) | `AppleSmartBattery` › `PowerTelemetryData.SystemLoad` (mW) |
| Per-app power | Change in `ri_energy_nj` ÷ time |
| Charge %, cycles, health, temperature, current | `AppleSmartBattery`: `AppleRawCurrentCapacity`, `AppleRawMaxCapacity`, `DesignCapacity`, `CycleCount`, `Temperature`, `InstantAmperage`; `IOPSCopyPowerSourcesInfo` for state |
| Night charging | `FanControl.nightPlan`: hold at `holdAt` from `start`; top-up from `fullBy − ((100 − holdAt) × 2 + 15) min`; keep full until `openedAt` (screen wake, set by Apex) ≥ `fullBy` or 12:00. Helper keeps CHIE hold through sleep while holding and wakes the Mac via `IOPMSchedulePowerEvent(kIOPMAutoWake)` every 30 min / at top-up |
| Charge schedules | Helper evaluates `FanControl.effectiveLimit` every 10 s from `fans.json` › `chargeSchedules` (weekday of the window's start, minutes after local midnight) |
| Accessories (USB) | `system_profiler SPUSBDataType -json` (nested `_items` = devices behind a hub; `serial_num` matches drives for Eject): `bus_power_used` + `extra_current_used` (mA allocated) × 5 V = "up to" W; `bus_power` = port offers; `device_speed`, `vendor_id` name. Every 60 s on Energy, on popover open, on drive hotplug |
| Accessory stop / resume | Drives: `diskutil unmountDisk` / `mountDisk` (stays attached); ejected drives: `IOUSBHostDevice(__ioService:).reset()` re-enumerates the device (mass storage = an interface with `bInterfaceClass` 8). Bluetooth: `IOBluetoothDevice.pairedDevices()`, `isConnected()`, `closeConnection()` / `openConnection()` |
| Accessories (Bluetooth) | `BatteryPercent` + `Product` on `IOHIDDevice` / `AppleDeviceManagementHIDEventService` |
| Charge history | One point a minute, 12 hours, saved in `charge.json` |
| Charge limit | Helper writes SMC `CHIE` (0x08 hold / 0x00 allow) on this Mac; `CH0B`+`CH0C` or `CHTE` on firmware that has them. Status read back from `status.json` |

## Sensors

| Value | Source |
|---|---|
| Temperatures | `IOHIDEventSystemClient` with `PrimaryUsagePage 0xff00 / PrimaryUsage 5` (Apple Silicon HID sensors; no admin) |
| Fans | SMC `FNum`, `F<i>Ac`, `F<i>Mn`, `F<i>Mx`; control via the helper (`F<i>Md`, `F<i>Tg`, `Ftst`) |

## Processes, startup, users, services, Local AI

| Value | Source |
|---|---|
| Process list | `proc_listallpids` + `proc_pidinfo`; command line via `KERN_PROCARGS2`; start time via `sysctl KERN_PROC_PID` |
| Startup items | Property lists in `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`; "Add app to login" writes a LaunchAgent in `~/Library/LaunchAgents`; impact from usage history |
| Services | `launchctl` |
| Users | `utmpx` login sessions; names via `getpwuid` |
| Local AI | Known runtimes by process, plus their local APIs: Ollama `:11434`, LM Studio `:1234` |

## Startup

| Value | Source |
|---|---|
| Login agents / daemons | Plists in `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`; enabled state from launchd overrides |
| Opens at Login, Allowed in Background | `sfltool dumpbtm` (records for this user and UID 0): `Type` app + `[enabled` = opens at login; `login item` / `agent` / `daemon` = background items, named after their `Parent Identifier` app; `legacy` types skipped (already from plists) |
| Open at Login on/off | System Events `make` / `delete login item` (Automation permission) |

## Detection engine inputs

`Alerts.sample(_:)` turns each live snapshot into a `DetectionSample`: per-app
CPU, disk writes and memory (your own processes, grouped by app), pressure
level, memory %, swap used, physical memory, thermal state, disk free and
capacity, whole-disk write speed. See `docs/PROJECT.md` for the rules.

## Bluetooth accessories (Energy › Accessories)

| Value | Source |
|---|---|
| Which devices | `IOBluetoothDevice.pairedDevices()`: devices connected now, plus devices used regularly (connected on 3 different days in the last 14; `bluetoothSeenDays` in UserDefaults) unless removed (`bluetoothHidden`; a removed device returns after it disconnects and connects again) |
| Type | The user's choice (Settings › Bluetooth accessories, or the popover; `UserDefaults` `bluetoothTypes`, by address), else a guess from the class of device (major / minor) and the name (`BluetoothType.guess`) |
| Power | **Estimate, not measured** (macOS has no per-accessory power reading): a typical range for the type while in use. Earbuds 20–60 mW, headphones 50–300 mW, speaker 1–5 W, keyboard 10–50 mW, mouse / trackpad 10–30 mW, game controller 100–500 mW, watch 10–50 mW; phones and other devices: "varies" |

## Displays (Performance › Display)

| Value | Source |
|---|---|
| Displays | `CGGetActiveDisplayList`; name, HDR (`maximumPotentialExtendedDynamicRangeColorComponentValue` > 1) and color profile from the matching `NSScreen`; re-read on `didChangeScreenParametersNotification` |
| Looks like / pixels / refresh | `CGDisplayCopyDisplayMode`: `width`×`height` (points), `pixelWidth`×`pixelHeight`, `refreshRate` |
| Size | `CGDisplayScreenSize` (mm, reported by the display) → diagonal inches |
| Resolutions | `CGDisplayCopyAllDisplayModes` with duplicate low-resolution modes, usable for the desktop, de-duplicated; set with `CGConfigureDisplayWithDisplayMode` (`.permanently`) |
| Brightness: Apple displays | Private `DisplayServices` framework (`DisplayServicesCanChangeBrightness` / `Get` / `SetBrightness`), loaded at runtime |
| Brightness: other monitors | DDC/CI VCP code 0x10 over the display link (Apple silicon `IOAVService` read / write I2C, address 0x37, sub-address 0x51, 40 ms before reading a reply). The display's `DCPAVServiceProxy` (Location External) is matched to the screen by vendor / product from `DisplayAttributes`; with one external display, that one. Not tested yet (no external monitor) |
| Brightness: fallback | Software dimming: `CGSetDisplayTransferByFormula` (15 % floor); macOS resets it when Apex quits |

## Public IP (Network page)

| Value | Source |
|---|---|
| Public IP | HTTPS GET `https://api.ipify.org` (plain text, nothing sent but the request), only while the Network page shows the connection in use; again when that connection changes, else every 10 minutes. Validated with `inet_pton`. Blurred by default; `blurPublicIP` in UserDefaults keeps the eye button's choice |
| Per-connection traffic | The Traffic list filtered to connections whose `nettop` interface is that tab's interface |

## Menu bar panel

| Value | Source |
|---|---|
| Graphs | The same 10-minute `History` as the Performance pages; memory is the pressure graph (green / yellow / red by level) |
| Temperatures | `HardwareStore` (HID sensors): CPU, GPU and Storage group averages; read every 5 s only while the panel is open |
| Power mode | `ProcessInfo.isLowPowerModeEnabled` (Low Power / Automatic) |
| Keep awake | `IOPMAssertionCreateWithName` `PreventUserIdleSystemSleep` (+ `PreventUserIdleDisplaySleep` with "Keep display on"); released when the time is up, switched off, or Apex quits |
| Latest screenshot | Newest of 40 recent files in the screenshot folder (`com.apple.screencapture` `location`, else Desktop) whose Spotlight `kMDItemIsScreenCapture` is true |
| Clipboard | `NSPasteboard.general.changeCount` every 0.5 s; skips items with `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType` (password managers, one-time codes); 50 items, images up to 8 MB, text up to 20 000 characters; in memory only |

## Energy page additions

| Value | Source |
|---|---|
| Power mode | `pmset -g`: `powermode` 0 / 1 / 2 (Automatic / Low Power / High Power) or `lowpowermode 1`; else `ProcessInfo.isLowPowerModeEnabled`. Read in the background at most every 10 s; pages show the last reading (never waits on `pmset`) |
| Accessories | Wired: USB devices that aren't hubs; Bluetooth: connected devices. Watts: USB allowances (current × 5 V) plus the upper end of each Bluetooth type's typical range: "up to", never a measurement |

## Floating shelf

| Value | Source |
|---|---|
| A file drag started | Global `NSEvent` monitors for left mouse down / dragged / up (mouse events need no permission); a drag counts when the system drag pasteboard (`NSPasteboard(name: .drag)`) changed since the mouse went down and holds a file URL or image |
| Wiggle (new shelf) | During a file drag, the pointer turning back 3 times (strokes of 24 pt or more, within 0.9 s) on either axis, from the mouse-dragged events (`ShakeDetector`); starts a new shelf, the old one moves to Recent shelves |
| Hide | 0.6 s after the drag ends, unless the shelf gained an item |
| Already showing | A plain drag leaves a shelf that is already up (or tucked at the edge) where it is |
| Motion | Appears by fading in while rising 12 pt (0.22 s); a wiggle while it's up glides it to the pointer (0.24 s); closes with a 0.16 s fade; tucking away 0.28 s. A fade-out or delayed hide that started earlier never hides a shelf shown again since (generation count). Items added / removed animate in and out |

## Internet connection speed

| Value | Source |
|---|---|
| Download / upload | `/usr/bin/networkQuality -c -I <interface> -M 25` (macOS's own test, Apple's servers), only when the user clicks Test: `dl_throughput` / `ul_throughput` in bits per second; `responsiveness` (round trips per minute under load) in the tooltip. The last result per interface is kept (`speedResults`). Moves real data (tens to hundreds of MB on fast links) |

## AirPlay displays

| Value | Source |
|---|---|
| Devices | Bonjour `_airplay._tcp` with `NWBrowser` while the AirPlay popover is open (Info.plist `NSBonjourServices`); this Mac's own receiver left out |
| Video or audio only | TXT `features` bits 0 (video) or 7 (screen mirroring); TXT `model` for the icon |
| Starting mirroring | Not possible for third-party apps (Apple's AirPlay sender needs Apple-only entitlements): Apex opens Displays settings, where macOS offers AirPlay |

## Removing an app (Disk › Analyze)

| Value | Source |
|---|---|
| App | `Bundle(path:)`: bundle identifier and name; Apple apps (`com.apple.*`, `/System`) are refused |
| What it left | `~/Library/` Application Support, Caches, Preferences (+ ByHost), Containers, Group Containers, Saved Application State, HTTPStorages, WebKit, Logs, LaunchAgents, Cookies, Application Scripts: items named the bundle id (or id + .plist / .savedState / .binarycookies), starting with the id + "." (extensions, helpers), or ending with "." + id (group containers); prefix rules only for ids with 3+ parts; folders named exactly like the app (3+ letters). Sizes with `FastSize` |
| Removing | `FileManager.trashItem` for the app and each ticked item: everything can be put back from the Trash |

## Stay Awake (Energy)

| Value | Source |
|---|---|
| Keep awake / chosen days | `KeepAwake` power assertions (lid open); days in `awakeDays` (weekday numbers), checked every 30 s |
| Lid-closed mode | Apex: on when enabled, a chosen app (bundle id) is running and the Mac is on power (`IOPSGetProvidingPowerSourceType`), or on battery if allowed and for at most `lidAwakeBatteryMinutes` (≤ 60) since unplugging. Apex writes `stayAwakeUntil` = now + 3 min to the helper's settings every 30 s. Helper (root): `pmset -a disablesleep 1` while `stayAwakeUntil` is in the future and at most 10 min ahead, else `0`; marker file `/Library/Application Support/Apex/sleep-disabled-by-apex` so a killed helper undoes it on start, and a pmset setting the user made is never touched |

## Removing an app: what belongs to it

| Value | Source |
|---|---|
| Data and settings | `~/Library` places (Application Support, Caches, Preferences, Containers, Group Containers, Saved Application State, HTTPStorages, WebKit, Logs, LaunchAgents, Cookies, Application Scripts, ByHost): names equal to the bundle ID or starting with it, group containers ending with it, the app's exact name or file name, and `<company>/<app>` folders (company = 2nd part of the bundle ID) |
| System files and helpers | `/Library/LaunchDaemons` and `/Library/LaunchAgents` plists named by the bundle ID or whose `Program` / `ProgramArguments[0]` is inside the app; `/Library/PrivilegedHelperTools` by bundle ID; `/Library` Application Support / Caches / Preferences / Logs by the same rules. Removed with one admin prompt: daemons `launchctl bootout`, files `mv` to your Trash with the time added |
| Installer records | `pkgutil --pkgs` ids matching the bundle ID; `pkgutil --forget` (admin) |
| Saved sign-ins | Login keychain generic and internet passwords (`SecItemCopyMatching`, attributes only, never passwords): service, server or label equal to / starting with the bundle ID, or starting with the app's name as whole words ("Chrome Safe Storage"); removed with `SecItemDelete` |
| Files made with it | Content types the app owns (`CFBundleDocumentTypes` with `LSHandlerRank` Owner) or declares (`UTExportedTypeDeclarations`), not public.* / com.apple.*; `mdfind -onlyin ~` outside ~/Library, up to 300. Needs Full Disk Access to see Documents and Desktop |
| Running | Every process whose path is inside the app bundle (helpers too); Quit It terminates the app, then SIGTERM to helpers left |
| Who made it | Code signature team ID (`SecCodeCopySigningInformation`) |

## Shelf: details and compare

| Value | Source |
|---|---|
| Photo details | ImageIO properties: pixel size, megapixels, colour model / depth, profile, dpi, alpha (Transparency), orientation; TIFF make / model / software; Exif lens, f-number, exposure, ISO, focal length, flash, white balance, date taken, comment; GPS latitude / longitude; HDR = an HDR gain map (`CGImageSourceCopyAuxiliaryDataInfoAtIndex`, `kCGImageAuxiliaryDataTypeHDRGainMap`); Frames = `CGImageSourceGetCount` > 1. Data per pixel = file size × 8 ÷ (width × height) |
| File details | Format (`UTType` description), created / modified (`URLResourceValues`) |
| Picture quality | Both pictures as ImageIO thumbnails (768 px, orientation applied), drawn at the same size into sRGB RGBA; PSNR over R, G, B (`MediaInfo.psnr`): ≥ 40 dB "Looks the same", 35–40 "Hard to tell apart", 30–35 "Slight change", below "Noticeable change" |
| Video details | AVFoundation: duration, first video track's natural size, frame rate, estimated data rate, codec (format description); common metadata make / model / creation date / location / software |
| PDF details | PDFKit page count, author, creator |
| Remove Details | Photos: `CGImageDestinationCopyImageSource` with an empty metadata set (orientation kept), XMP and GPS excluded: the image data is copied, not re-encoded. Videos: `AVAssetExportPresetPassthrough`, `metadata = []`, `.forSharing()` filter |
| Removed | Personal-detail fields (camera, lens, settings, taken, location, software, comment) in the original and not in the copy |

## Shelf: side and categories

| Value | Source |
|---|---|
| Names | `ShelfSet.displayName`: the name given (categories; side and menu bar shelves can be named), else the first file's name without extension, "+ N more" |
| Category look | `icon` (SF Symbol from `ShelfLook.symbols`) and `color` (`ShelfLook.colors`), saved in categories.json |
| In the menu bar | `pinned` categories each get an `NSStatusItem` (`PinnedShelves`): the symbol in its colour (template image without a colour); click shows the category in a popover; files dropped on the icon are taken by the status item's window (`registerForDraggedTypes([.fileURL])`, window delegate as the dragging destination) and added to the category |
| Limits | None in the code: every recent shelf and shelf to the side is kept |
| Side shelves | `ShelfStore.side` (newest first, up to 10), saved in `Shelf/side.json` |
| Categories | `ShelfStore.categories` (named), saved in `Shelf/categories.json`; adding merges by file path (no file twice); a new category with an existing name (any case) adds to that one |
| What's open | `ShelfStore.open`: the current shelf, a side shelf or a category; the floating shelf and the menu bar Shelf tab show it |
| Edge handle | A 22 × 96 pt panel at the right edge of the main screen, shown while anything is to the side or a category has items |
| Previews | `QLThumbnailGenerator` thumbnails of the first four items |

## Shelf: compress and convert

| Value | Source |
|---|---|
| Images | ImageIO re-encode. JPEG stays JPEG, everything else becomes HEIC (keeps transparency). Quality 0.8 → 0.7 → 0.6 until at least 50 % smaller; last resort 85 % of the resolution, never for files under 512 KB. Never kept if not smaller. Details (EXIF, GPS…) copied with `CGImageDestinationAddImageFromSource`, or dropped (orientation only) |
| Videos | `AVAssetExportSession` HEVC Highest Quality; if not 50 % smaller and wider than 1920 px, HEVC 1920×1080. Details kept (`metadata`) or dropped (`metadata = []`, `metadataItemFilter = .forSharing()`) |
| PDFs | PDFKit `write(to:withOptions:)` with `saveImagesAsJPEGOption` + `optimizeImagesForScreenOption`: pictures re-saved as JPEG at screen resolution, text and drawings untouched. Kept only if smaller; otherwise the original stays and the note says it's text or already compressed |
| Anything else | `ditto -c -k --sequesterRsrc --keepParent` (the same ZIP as Finder's Compress), files, folders and apps |
| Finder aliases | Followed to the original (`URL(resolvingAliasFileAt:)`) when added and when old shelves load, so the shelf shows and compresses the real file |
| Output | "Name (compressed).heic" / "(converted)" next to the original (or in Downloads if that folder can't be written), never overwriting; the original is never changed |
| Thumbnails | `QLThumbnailGenerator` (the file's Quick Look preview) |

## Cloud Disks: the service's app

| Value | Source |
|---|---|
| Signed out | A waiting file's `ubiquitousItemUploadingError` is `NSFileProviderErrorDomain` -1000 (not authenticated) → the whole service |
| Not open | Services synced by their own app (detected in ~/Library/CloudStorage, not iCloud): no running process inside `<Name>.app` (`CloudUpload.processes`) while files wait |
| Open button | `/Applications/<Name>.app` or `~/Applications/<Name>.app` |

## Census

| Value | Source |
|---|---|
| Right Now | The live process sample (`AppModel.snapshot.processes`), summed per app (`appKey`: outer .app bundle, else name): CPU %, memory (resident), disk read + write rate, network rate, GPU %, power (W). Network and GPU per process are sampled while Census is open. Top 6 per resource above a floor (0.5 % CPU / GPU, 1 KB/s, 0.05 W) |
| Today | App History's totals for today (`HistoryStore.totals(days: 1)`): CPU time, peak memory, disk and network bytes, energy (J → Wh). No GPU |
| Marked | In the top 3 of two or more resources (`Census.heavy`) |

## Servers and containers

**Apex Server Edition** (on the server, as root, every 2 s while someone is
looking, every 15 s otherwise): `/proc/stat`, `/proc/meminfo`, `/proc/loadavg`,
`/proc/net/dev`, `/proc/net/tcp{,6}` (established), `/proc/diskstats` +
`/proc/self/mountinfo` + statfs (real file systems, one per device),
`/proc/<pid>/{stat,status,cmdline,io}` for every process, `/etc/passwd`,
`/sys/class/hwmon` (temperatures), `nvidia-smi` / `/sys/class/drm` (GPUs),
`systemctl list-units` / `rc-status` / `service --status-all` (services, every
5 s), the Docker or Podman socket (`/containers/json`, `/stats`), `/run/utmp`
or `loginctl` (signed in). Served as the same JSON the SSH script prints, over
HTTPS on port 7443. Actions: `kill`, `systemctl` / `rc-service` / `service`,
Docker's `/containers/<id>/<verb>`.

Chosen in Performance › **This Mac** menu (All Servers, This Mac, Docker
Containers, each server and running container, Add Server…). Processes,
Performance, Services and Users then show that server or container; Assistant,
History and Startup stay this Mac's. Apex always opens on this Mac.

| Value | Source |
|---|---|
| Connection | `/usr/bin/ssh` with `BatchMode=yes` (keys only, never a password), `ConnectTimeout=8`, `StrictHostKeyChecking=accept-new`; your `~/.ssh/config` applies. One shared connection (socket in `~/Library/Caches/Apex/ssh`, kept 60 s after last use) started on its own with `-f -N` and no pipes (`ServerClient.openShared`); each reading uses it with `ControlMaster=no`. (Started by a reading with `ControlMaster=auto`, the background connection held the reading's output open and each reading waited ~60 s) |
| Readings | `Resources/apex-agent.py` (Python 3.6 or later; leaves out itself and its own `ps`; disks: real devices + a container's overlay root, not mounted files), sent on stdin to `python3 -` (or `docker exec -i <container> python3 -`) each refresh, every 3 s while the page shows: `/proc/stat` (CPU, two readings 1 s apart), `/proc/meminfo`, `/proc/loadavg`, `/proc/net/dev`, `/proc/diskstats` + `df`, `ps` (up to 500, busiest first), `nvidia-smi`, `docker ps -a` + `docker stats`, `systemctl list-units --type=service --all` (every service: state, description) and `--state=failed`, `who` (signed-in users), `ss` (established connections), web servers by process name. Refreshed every 3 s while a server is shown (whichever page), every 5 s for All Servers |
| Containers on this Mac | The `docker` command line tool (Homebrew, Docker Desktop, OrbStack paths; its current context, e.g. Colima): `docker ps -a` + `docker stats --no-stream` (list, every 5 s on Docker Containers); for one container every 3 s: `docker stats` (CPU as a share of Docker's CPUs from `docker info` NCPU, memory used / limit, network and block I/O → rates from the previous reading), `docker inspect` (image, started), the container's own `ps` via `docker exec` (its own process ids, so End works; Apex's `ps` left out) or `docker top` when it has none (shown, not ended), `docker exec … df -kP /` (size; "not available" without df) |
| Users (server) | Processes grouped by user (count, CPU, memory) + `who` sessions (terminal, from where); signed-in users first |
| Actions | Confirmed first. Over the same SSH: `docker start / stop / restart`, `kill` / `kill -9` (inside the container with `docker exec` when watching one), `sudo -n systemctl start / stop / restart` (only where sudo needs no password). For a container on this Mac only `docker …` commands run (`LocalDocker.action` refuses anything else) |
| Report | `ServerReports`: every saved server and running container read once a minute while Apex is open (`ServerStore.startReports`; ones read in the last 50 s are skipped), plus every reading while one is on screen. Each minute: average and peak CPU and memory, fullest disk (% used, mount), average network in / out, up-time, failed services, 5 busiest processes by CPU; a minute with no answer is marked down. 24 hours in `~/Library/Application Support/Apex Activity Manager/server-reports.json` (every 5 min and on quit). `ReportSummary`: averages and peaks over the range; events: CPU or memory ≥ 90 % for 5+ minutes in a row (a gap over 2 minutes ends a stretch), minutes unreachable, restarted (up-time over 2 minutes behind where it should be), fullest disk ≥ 90 %, failed services; received / sent = average rate × 60 per minute; busiest = time among the top 3 × average CPU |
| Insights | `ServerInsights`: load > 1.5 × cores, available memory < 15 % / 5 %, swap > 50 %, disks ≥ 85 % / 95 %, days until full from growth (one point a minute, needs ≥ 10 min), failed services, containers exited with an error |

## Shell

| Value | Source |
|---|---|
| Commands | `ShellCatalog` (built in); blanks filled with `Shell.quote` (single-quoted, so typed text is only ever a value) |
| Running | `/bin/zsh -lc` (your PATH, like Terminal), output streamed from a pipe; admin commands and `sudo …` lines via `osascript … with administrator privileges`; output kept to the last ~200 KB |
| History | The command line's last 100 commands, in Apex's settings (`shellHistory`) |
| Network services | `networksetup -listallnetworkservices` |
| Interactive programs | top, ssh, editors, pagers, bare `sudo`, REPLs → Terminal via AppleScript `do script` |

## Record

| Value | Source |
|---|---|
| Everything | The same `Snapshot` every page uses, written as it arrives (`Recorder.record`, called from `AppModel.apply`). While recording, sampling covers every process with network and GPU, window open or closed, every 2 s (or the chosen slower rate) |
| Processes per line | Those doing something (CPU ≥ 0.5 %, disk, network or GPU) + the 15 largest by memory; every 60 s all processes |
| Events | Apex alerts (`EventLog`) as they happen |
| Summary | Average / peak CPU (and when), peak memory and swap, worst pressure and heat, top 10 by average CPU and by peak memory |
| File | `~/Documents/Apex Recordings/<Everything | CPU | Memory | Disk | Network | GPU | Energy>/…jsonl`, one file per recording (several can run at once), written on a background queue; closed (with the summary) on Stop or when Apex quits |
| Scoped (page) recordings | Only the resource's part of `system` and, per process, its figures: CPU (cpu, threads; processes ≥ 0.5 %), Memory (memory; 30 biggest), Disk (read / write; processes using the disk), Network (net; processes using it), GPU (gpu), Energy (power, battery, thermal; top 30 by power). All processes once a minute |

## Network: an app's last 10 minutes

| Value | Source |
|---|---|
| Speed graph | The traffic list's `nettop` snapshot every 5 s, summed per app (connections' rates), `TrafficHistory.points` |
| Servers | Every non-local connection seen, by its key: bytes received / sent since Apex first saw it (deltas), first / last seen, still open or closed; grouped per server (protocol, address, port) |
| When | Only while an Apex window is on screen (`AppModel.isWindowVisible`); older than 10 minutes dropped on every snapshot; memory only |

## Cloud Disks: file rings and syncing

| Value | Source |
|---|---|
| Ring per file | Every 5 s while the list shows: `CloudUpload.states` of the listed files (uploaded / sending / queued / error) and `CloudUpload.dot`: sending = green (even if Apex's server check failed), queued = green, or yellow when paused or the server didn't answer (checked every 30 s, or from a running check); errors: File Provider -1004 / -2005 = connection (yellow while the server is down, else red), -1003 full, -1000 signed out, -1001 name clash, -2010 excluded = red |
| Progress | Estimate: the service's app's bytes sent (one `nettop` of its processes per refresh) shared between the files it's sending, ÷ file size, capped at 97 % until the file's own "uploaded" flag; kept while paused. macOS doesn't give other apps per-file upload progress for File Provider services |
| "Syncing" | A listed file is being sent, or the app sent > 10 KB since the last refresh |

## Cloud Disks: online storage by hand

| Value | Source |
|---|---|
| Check on Website | The catalogue's storage page, or for Nextcloud `<server>/index.php/settings/user`, ownCloud `<server>/index.php/settings/personal` (server from `CloudUpload.knownServer`; http for private IPv4, else https), opened in `WebStorageSheet`; `CloudCatalog.parseUsage` reads "X of Y used" |
| Enter Storage | Typed used + plan size (MB / GB / TB, decimal comma or point), saved with the web-read figures in `cloudWebQuota` with `manual = 1`; loaded on every refresh |

## Cloud Disks: upload monitor

| Value | Source |
|---|---|
| Files left / sending now | Every 3 s, fresh `resourceValues` of each waiting file: `ubiquitousItemIsUploaded`, `ubiquitousItemIsUploading`, `ubiquitousItemUploadingError`. Uploaded files are offloaded straight away (Offload) or counted (Check Uploads) |
| Speed, server | The service's app: processes whose program is inside "<Name>.app" (app + File Provider extension; iCloud: iCloudDriveCore / CloudKit / the iCloud Drive extension), found with `proc_listallpids` + `proc_pidpath` every 30 s. One `nettop -L 1 -x -n -p <pids>` (~10 ms) every 3 s: bytes sent since the last reading = speed; the remote address sent the most = the server |
| Server when nothing's open | WebDAV address; well-known API host for iCloud / OneDrive / Google Drive / Dropbox / Box; the host in a "Nextcloud-host-user" folder name |
| Reachable | TCP connect (`NWConnection`, 3 s limit) every 10 s; ms to connect |
| Why not | Private IPv4 server (10/8, 172.16/12, 192.168/16) not on any of this Mac's networks (`getifaddrs` address + netmask): "on a different network; connect to it or its VPN" |
| Time left | Size left ÷ current speed (only when ≥ 1 KB/s) |
| Gives up | 15 minutes without a file finishing or the app sending (≥ 2 KB/s) while the server answers; while it can't be reached it waits however long it takes |
| Pause | Pause stops offloading and reading traffic; every 3 s the waiting files are checked and every 10 s the server: it carries on by itself when files upload again (the service's app syncing) or the server answers after being unreachable. Resume / Stop by hand |
| Notifications | Lost connection after 60 s (once), connection back, and the result with the total time |

## Network Doctor

| Check | Source |
|---|---|
| Wi-Fi signal, noise, link speed, band | CoreWLAN `CWInterface` `rssiValue`, `noiseMeasurement`, `transmitRate`, `wlanChannel.channelBand` (no location permission needed) |
| Address | the connection's IPv4 (`SCDynamicStore`); 169.254.x.x = made up by the Mac (no DHCP answer) |
| Router | `State:/Network/Global/IPv4` `Router` (connection in use only); `/sbin/ping -q -c 8 -i 0.25 -t 5 -b <interface>` |
| Internet | ping 1.1.1.1 through the connection, and HTTPS GET `https://www.apple.com/library/test/success.html` (some networks block ping) |
| Website names | `getaddrinfo("www.apple.com")`, timed, 4 s limit |
| Sign-in page | `http://captive.apple.com/hotspot-detect.html` must contain "Success" (Apple's own captive-portal test) |
| Rules | `NetworkDoctor.diagnose` (pure, tested): first failing step is blamed; router loss ≥ 20 % warning, Wi-Fi router reply > 30 ms congested; internet reply > 150 ms slow; DNS > 300 ms slow; signal < −75 dBm weak, < −67 fair; signal − noise < 20 dB interference; last speed test < 5 Mb/s slow |

## Power in detail (Energy, Advanced graph)

| Value | Source |
|---|---|
| Mac uses | `PowerTelemetryData.SystemLoad` (mW) |
| From charger | `PowerTelemetryData.SystemPowerIn` (mW) |
| Battery charging / draining | `PowerTelemetryData.BatteryPower` (mW, signed, stored as unsigned 64-bit): + charging, − draining, drawn as two lines |
| Apps vs the rest | Sum of the Energy table's per-app power (CPU work) against Mac uses; the rest is display, chip, memory, Wi-Fi and other parts |
| Update rate | The battery controller refreshes these every few seconds, so lines move in steps |

## Cloud (Performance › Cloud)

| Value | Source |
|---|---|
| Services | iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs`); each folder in `~/Library/CloudStorage` (macOS File Provider: OneDrive, Google Drive, Dropbox, Box, Nextcloud…; name from the folder prefix); added folders and WebDAV servers (`cloudServices` in UserDefaults, passwords in the login keychain) |
| On this Mac / online only | Walk of the folder with `fileSize` (logical) and `totalFileAllocatedSize` (stored here) per file; a file with size > 0 and nothing stored is online-only. Reading metadata never downloads. Rescanned when the page opens if older than 10 min, or with ↻ |
| Online storage | WebDAV `PROPFIND` Depth 0 for `quota-used-bytes` / `quota-available-bytes` (RFC 4331). macOS doesn't give apps the quota of File Provider services (their folder reports the Mac's disk), so for those the page says so |
| Make Online-Only | `FileManager.evictUbiquitousItem` on the chosen files (the largest stored here, over 1 MB) |
| Offload All | Every file with storage on this Mac (`storedFiles`), `evictUbiquitousItem` in chunks of 50; on failure `ubiquitousItemIsUploaded` = false → retried every 60 s (10 rounds), `ubiquitousItemUploadingError` → reported; a notification (`Alerts.notify`) at the end |

## Assistant: Local AI

| Value | Source |
|---|---|
| Server | First of LM Studio (`http://127.0.0.1:1234/v1`) and Ollama (`http://127.0.0.1:11434/v1`) whose `/models` answers within 1.5 s, looked for when the Local AI mode opens |
| Models | `/v1/models` ids, embedding models left out; the choice is kept (`assistantModel`) |
| Answers | `/v1/chat/completions`, `stream: true`, temperature 0.3, last 12 messages, the same instructions as Claude with the readings (if on) in the system message. Nothing leaves the Mac |
| Models on this Mac | The former Local AI page (runtimes by process, their local APIs, installed models on disk), now a sheet from the Models button |
| Start LM Studio's Server | `~/.lmstudio/bin/lms server start`, only when the user presses the button |

## Assistant: Apex Agent

| Value | Source |
|---|---|
| Questions | `ApexAgent.topics`: 22 topics (slow, storage, battery drain and health, heat, Wi-Fi, frozen apps, kernel_task, WindowServer, memory, login items, sleep, eject, Bluetooth, malware, background jobs, backup, updates, restart, disk health, what's using it, Apex itself). The question is lower-cased, punctuation removed, everyday words evened out ("laggy" → slow, "ram" → memory); each topic's words and phrases add up; 2 or more wins, otherwise "Please try Lumen AI" |
| Readings | `ApexAgent.Readings.current()`: Apex's latest sample (busiest and largest apps without Apex itself, memory pressure, swap, startup disk, battery, CPU temperature, network, kernel_task and WindowServer CPU). Nothing leaves the Mac |
| Buttons | Free Up Memory, Disk › Clean, a Performance page (`perfItem`), or a section |
| Commands | `ApexAgent.command`: a quit word (quit, close, exit, kill, end, stop, terminate, shut, force) not at the start of a question; "all / everything / apps…" = every open app (`NSWorkspace.runningApplications`, regular, not Finder or Apex) minus any named after "except / but / besides…"; otherwise apps named by their full name or any distinctive word. "process(es)": your own non-app processes (same user, not in /System or /usr/libexec, not Dock, WindowServer…). Nothing happens until the button: `terminate()` (apps ask to save) or `forceTerminate()` when "force" was said; processes `SIGTERM`, only if still yours |

## Assistant (Claude)

| Value | Source |
|---|---|
| Service | Anthropic Messages API, `POST https://api.anthropic.com/v1/messages`, `anthropic-version: 2026-10-21`, the user's API key (`x-api-key`) from the login Keychain (service "Apex Activity Manager", account `anthropic-api-key`) |
| Key check | `GET /v1/models?limit=1` when the key is entered (costs nothing); 401 → "didn't accept this API key" |
| Models | Claude Opus 5.5 (default), Sonnet 5.5, Haiku 5.5; the choice is kept (`assistantCloudModel`) |
| Answers | `stream: true` (server-sent events), `max_tokens` 16000, adaptive thinking with summarized display (the "Thinking" line), effort medium, prompt caching on, no sampling settings (removed in 2026-10-21). Opus/Sonnet: `fallbacks: "default"` with beta `server-side-fallback-2026-07-01`, so a declined question is retried on Anthropic's recommended model |
| History | Every turn is sent back unchanged (thinking blocks and signatures included, citations stripped from text); a turn that fails or is stopped is removed with its question, which goes back into the box. New Chat clears it |
| Context | With readings on (the gauge button, `assistantReadings`), each question carries Apex's live readings as plain text before it (`AssistantContext.build`): Mac, CPU, memory and pressure, swap, startup disk, network, GPU, battery, five busiest and largest apps (names), five latest alerts. No files or passwords. This leaves the Mac, and the UI says so |
| Errors | Error types → plain words (key, billing, rate limit, overloaded, too long); `stop_reason` refusal / max_tokens → a short note |
| Scope | System instructions: this Mac; plain words; short; steps in order; Apex pages to use; no risky commands without warning |

## Cloud services (catalogue and totals)

| Value | Source |
|---|---|
| Catalogue | `CloudCatalog.providers`: Google (Drive, Gmail, Photos), OneDrive, iCloud, Dropbox, Box, MEGA, pCloud, Proton Drive, Sync.com, Tresorit, IDrive, Icedrive, Koofr, Yandex Disk, Jottacloud, Filen, TeraBox, Nextcloud, ownCloud, Seafile, Synology; each with its storage page, WebDAV address and Mac app folder where they exist; "Other provider" by address |
| Total storage (web sign-in) | The provider's storage page in a WKWebView with its own persistent `WKWebsiteDataStore(forIdentifier:)` per service; page text (`document.body.innerText`) every 2 s, `CloudCatalog.parseUsage` finds "X unit (used) of Y unit" (of, /, out of, von, de…; decimal commas; largest total wins). Saved with the time (`cloudWebQuota`), re-read in a hidden web view every 6 h or on ↻. If the provider redesigns its page, the line may not be found: Apex says to sign in again |
| Added folders | Total and free space of the disk they're on (`volumeTotalCapacity`, `volumeAvailableCapacityForImportantUsage`) |


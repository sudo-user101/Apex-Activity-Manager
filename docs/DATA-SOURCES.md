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
| **Memory pressure %** | 100 − `kern.memorystatus_level` | macOS's own pressure signal |
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
| Which network adapters count | `IONetworkInterface` whose IOKit ancestors include an `IOUSBHostDevice` (USB) or an `IOPCITunnelled` PCI device (Thunderbolt). Built-in Wi-Fi, Thunderbolt Bridge ports and virtual interfaces (`anpi`, the always-present "Ethernet Adapter" en3/en4) are left out |
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

## Detection engine inputs

`Alerts.sample(_:)` turns each live snapshot into a `DetectionSample`: per-app
CPU, disk writes and memory (your own processes, grouped by app), pressure
level, memory %, swap used, physical memory, thermal state, disk free and
capacity, whole-disk write speed. See `docs/PROJECT.md` for the rules.

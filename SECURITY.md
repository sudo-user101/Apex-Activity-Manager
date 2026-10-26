# Security

Apex sees a lot of your Mac, so it should be clear exactly what it can do.
This page explains what runs with administrator rights, when Apex asks for
your password, and how to report a security problem.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Report it
privately on GitHub: open the repository's **Security** tab and click
**Report a vulnerability** ([direct link](https://github.com/sudo-user101/Apex-Activity-Manager-MacOSX/security/advisories/new)).

Include the Apex version, your macOS version and Mac model, what an attacker
could do, and the steps to reproduce it. You'll get a reply in the same
report, and you'll be credited in the release notes when it's fixed (unless
you'd rather not be).

Fixes go into the latest release. Please update to it before reporting.

## What runs with administrator rights

Apex itself runs as you, with no special privileges. The only part that runs
as root is the **battery and fan helper**, and only if you install it.

### The battery and fan helper

**When it's installed:** only when you turn on something that needs it: a
charge limit, charge schedules, night charging, fan control on Macs with fans,
or keeping the Mac awake with the lid closed. Apex asks for your password once
to install it, with a message that says what it's for.

**Where it lives:**

| File | What it is |
|---|---|
| `/Library/PrivilegedHelperTools/com.apex.fanhelper` | The helper program (a copy of `Contents/MacOS/apex-fanhelper` from the app) |
| `/Library/LaunchDaemons/com.apex.fanhelper.plist` | Tells macOS to run it in the background |
| `/Library/Application Support/Apex/fans.json` | Its settings, written by Apex (owned by your user account) |
| `/Library/Application Support/Apex/status.json` | What it reports back to Apex |

**What it does, and nothing else:**

- Reads its one settings file. It takes no other input: no network, no
  commands, no messages from other programs.
- Writes the Mac's SMC keys for **fan speed** (always kept within each fan's
  own minimum and maximum) and for **charging** (charge limit, schedules,
  night charging).
- Runs `/usr/bin/pmset disablesleep` to keep the Mac awake with the lid
  closed, only while Apex keeps asking for it, and turns it off again
  afterwards (also after a crash, the next time it starts).
- Reads temperatures, to follow a fan curve.

**Safety:** fans return to automatic when Apex quits or stops updating the
settings, and when the settings are missing, invalid or all set to
automatic. Charging goes back to normal before the Mac sleeps (except during
night charging, when the Mac is woken briefly to re-check), and everything
goes back to normal when the helper is stopped or removed.

**Good to know:** the settings file is writable by your user account, so that
Apex (running as you) can change it. That means any program running as you
could also change fan speeds, the charge limit or lid-closed wake, within the
same limits. It can't make the helper run commands, read files or reach the
network.

**Removing it:** click **Remove Helper…** in the Charge limit or Fan control
panel (it asks for your password). Or by hand in Terminal:

```bash
sudo launchctl bootout system/com.apex.fanhelper
sudo rm -f /Library/LaunchDaemons/com.apex.fanhelper.plist /Library/PrivilegedHelperTools/com.apex.fanhelper
sudo rm -rf "/Library/Application Support/Apex"
```

The helper's source is in [`Sources/ApexFanHelper`](Sources/ApexFanHelper), and
its rules (clamping, timeouts, schedules) in [`Sources/FanControlCore`](Sources/FanControlCore).

## When Apex asks for your password

Every password prompt is the standard macOS administrator dialog. Apex never
sees, stores or sends your password. You're asked only when you choose one
of these:

- **Installing or removing the battery and fan helper** (above).
- **Ending, force quitting, pausing, resuming, optimizing or changing the
  priority of a process that belongs to another user or to macOS.**
  Your own apps never need it.
- **Run New Task** with *Run with administrator privileges* ticked.
- **Turning a system-wide startup item or service on or off** (launch
  daemons, and agents for all users).
- **Storage › Optimize** tasks marked as needing it: resetting the DNS cache
  and clearing the file cache (also in Free Up Memory).
- **Drive tools that write to a whole drive:** erasing a drive, and writing an
  installer or disk image to a USB drive in the Bootable Media Creator.
  Apex shows what will be erased and asks you to confirm first.

Nothing else needs your password. Monitoring, alerts, history, storage
analysis and clean-up of your own files all run as you.

## Network and privacy

Apex has no account, no analytics and no telemetry, and doesn't upload
anything about your Mac. Its network use is only for what you see on screen:

- your router's name and model (asked on your own network) and the host
  names of connections (normal DNS lookups);
- your public IP address, from `api.ipify.org`, while a Network page is
  open (every 10 minutes);
- the internet speed test, with macOS's own `networkQuality`, when you run it;
- local AI runtimes on your own Mac.

"Check on VirusTotal" opens your browser with a file's fingerprint, only when
you click it.

## Verifying a download

Releases built by the [release workflow](.github/workflows/release.yml) are
signed with Developer ID and notarized by Apple, and each comes with a
SHA-256 checksum. To check one:

```bash
shasum -a 256 "Apex Activity Manager 1.3.0.dmg"   # compare with the .sha256 file on the release
spctl --assess --type execute --verbose=2 "/Applications/Apex Activity Manager.app"
```

Version 1.2.0 and earlier aren't notarized.

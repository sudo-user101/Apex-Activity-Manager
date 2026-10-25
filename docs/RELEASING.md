# Releasing Apex

Releases are signed with a **Developer ID Application** certificate,
notarized by Apple and stapled, so the app opens on any Mac without
the "can't be checked" warning. The [Release workflow](../.github/workflows/release.yml)
does all of it when you push a version tag; `build.sh` does the same on
your own Mac.

Nothing secret is stored in this repository. Everything comes from
environment variables (locally) or repository secrets (on GitHub).

## What you need once

1. **An Apple Developer Program membership** (paid, for the Developer ID
   certificate and notarization).
2. **A Developer ID Application certificate.** In Xcode: *Settings ›
   Accounts › your team › Manage Certificates… › + › Developer ID
   Application*. Or at
   [developer.apple.com › Certificates](https://developer.apple.com/account/resources/certificates/list)
   with a certificate signing request from Keychain Access. It lands in your
   login keychain as "Developer ID Application: *Your Name* (*TEAMID*)".
3. **Your Team ID**: 10 characters, shown at
   [developer.apple.com › Membership details](https://developer.apple.com/account#MembershipDetailsCard)
   and in the certificate's name.
4. **An app-specific password** for notarization: [account.apple.com](https://account.apple.com)
   › *Sign-In and Security › App-Specific Passwords* › +. Name it
   "Apex notarization". This isn't your Apple Account password.

## GitHub repository secrets

*Repository › Settings › Secrets and variables › Actions › New repository secret*:

| Secret | What to put in it |
|---|---|
| `DEVELOPER_ID_CERT_P12` | The certificate **and its private key**, exported as .p12 and base64-encoded (below) |
| `DEVELOPER_ID_CERT_PASSWORD` | The password you chose when exporting the .p12 |
| `APPLE_ID` | The Apple Account email of your developer membership |
| `APPLE_TEAM_ID` | Your 10-character Team ID |
| `APPLE_APP_PASSWORD` | The app-specific password from step 4 |

**Exporting the certificate:** open Keychain Access › *login* › *My
Certificates*, find "Developer ID Application: …", make sure it has a
private key under it (the disclosure triangle), right-click › *Export…* ›
format *Personal Information Exchange (.p12)*, choose a strong password.
Then copy it as one base64 line:

```bash
base64 -i DeveloperID.p12 | pbcopy   # paste into DEVELOPER_ID_CERT_P12
rm DeveloperID.p12                     # don't leave it lying around
```

The workflow imports it into a temporary keychain that's deleted when the
job ends, finds the "Developer ID Application" identity in it, and never
prints any secret.

## Making a release

1. Set the version in `Resources/Info.plist`: `CFBundleShortVersionString`
   (e.g. `1.3.0`) and bump `CFBundleVersion` (the build number).
2. Add a section to `CHANGELOG.md` headed `## 1.3.0 (YYYY-MM-DD)`. It
   becomes the release notes.
3. Commit, then tag and push:

   ```bash
   git tag v1.3.0
   git push origin main v1.3.0
   ```

The workflow checks the tag matches the version, builds a universal
(Apple silicon + Intel) app, signs the app and its helper with the hardened
runtime, notarizes and staples the app, builds the .dmg, signs, notarizes
and staples that too, and publishes a GitHub release with the .dmg and its
SHA-256. It takes about 10–20 minutes, mostly waiting for Apple.

If notarization is rejected, the job stops and prints Apple's log, which
names the file and the problem.

## Signing on your own Mac

```bash
# Once: store the notarization credentials in your keychain (asks for the app-specific password).
xcrun notarytool store-credentials apex-notary --apple-id you@example.com --team-id TEAMID

export APEX_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APEX_NOTARY_PROFILE=apex-notary
./build.sh --universal --dmg --notarize
```

Instead of a keychain profile you can set `APEX_APPLE_ID`, `APEX_TEAM_ID`
and `APEX_APP_PASSWORD` (that's what the workflow does). The profile is
better on a shared Mac, because the password isn't on the command line.

| Variable | Used for |
|---|---|
| `APEX_SIGN_IDENTITY` | The signing identity's name or SHA-1 (`security find-identity -v -p codesigning`). Without it, `build.sh` signs ad hoc for local use, as before |
| `APEX_KEYCHAIN` | Optional: the keychain that holds the identity |
| `APEX_NOTARY_PROFILE` | A `notarytool store-credentials` profile |
| `APEX_APPLE_ID`, `APEX_TEAM_ID`, `APEX_APP_PASSWORD` | Or these three instead of the profile |

Check a finished build:

```bash
codesign --verify --strict --deep --verbose=2 "dist/Apex Activity Manager.app"
spctl --assess --type execute --verbose=2 "dist/Apex Activity Manager.app"   # "source=Notarized Developer ID"
xcrun stapler validate "dist/Apex Activity Manager 1.3.0.dmg"
```

## What gets signed, and how

| Item | Identifier | Entitlements |
|---|---|---|
| `Contents/MacOS/apex-fanhelper` (the privileged helper) | `com.apex.fanhelper` | [`Resources/ApexFanHelper.entitlements`](../Resources/ApexFanHelper.entitlements): none needed |
| The app | `com.taskmanager.mac.native` | [`Resources/Apex.entitlements`](../Resources/Apex.entitlements): Apple Events, for adding and removing login items through System Events |
| The .dmg | | Signed (no entitlements), notarized and stapled |

Both executables use the hardened runtime and a secure timestamp. The app
isn't sandboxed: it reads system-wide process, disk and hardware
information that the sandbox doesn't allow.

**After the first signed release**, people who installed the helper from an
unsigned version will find it marked as not up to date (Apex compares it
byte for byte with the copy inside the app): the Charge limit panel shows
**Update Helper…**, which reinstalls it once with their password.

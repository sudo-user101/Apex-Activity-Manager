import Foundation

/// Windows Setup options Apex can put on the installer, as an
/// `autounattend.xml` answer file in the root of the USB drive (Windows Setup
/// reads it automatically). Nothing on the installation image is modified.
struct WindowsSetupOptions: Equatable, Sendable {
    /// Windows 11 only: skip the TPM 2.0, Secure Boot and 4 GB RAM checks.
    var skipTPM = false
    var skipSecureBoot = false
    var skipRAM = false
    /// Allow finishing setup offline with a local account (no Microsoft account).
    var allowOfflineAccount = false
    /// Create this local administrator (empty = ask during setup as usual).
    /// It starts with no password and Windows asks for one at first sign-in.
    var localAccount = ""
    /// Region and keyboard (e.g. "en-ZA"); empty = ask during setup.
    var locale = ""
    /// Answer the privacy questions with the most private choices.
    var minimalPrivacy = false
    /// winget package IDs installed at first sign-in (needs internet then).
    var apps: [String] = []
    /// The PC's name (empty = Windows picks one). Up to 15 letters, digits and hyphens.
    var computerName = ""
    /// Windows time zone ID, e.g. "South Africa Standard Time" (empty = ask).
    var timeZone = ""
    /// Stop Windows from turning on device encryption (BitLocker) by itself.
    var noAutoEncryption = false

    var isEmpty: Bool { self == WindowsSetupOptions() }
    var bypassesChecks: Bool { skipTPM || skipSecureBoot || skipRAM }
}

/// Apps offered for installing at first sign-in, by their ID in the official
/// winget catalogue (Microsoft's community repository; downloads come from
/// each publisher). Nothing is bundled or downloaded by Apex itself.
struct WindowsApp: Hashable, Sendable, Identifiable {
    var id: String          // winget ID
    var name: String
    var category: String

    static let catalogue: [WindowsApp] = [
        .init(id: "Google.Chrome", name: "Google Chrome", category: "Browsers"),
        .init(id: "Mozilla.Firefox", name: "Firefox", category: "Browsers"),
        .init(id: "Brave.Brave", name: "Brave", category: "Browsers"),
        .init(id: "7zip.7zip", name: "7-Zip", category: "Utilities"),
        .init(id: "VideoLAN.VLC", name: "VLC media player", category: "Media"),
        .init(id: "Spotify.Spotify", name: "Spotify", category: "Media"),
        .init(id: "Microsoft.VisualStudioCode", name: "Visual Studio Code", category: "Developer"),
        .init(id: "Git.Git", name: "Git", category: "Developer"),
        .init(id: "Python.Python.3.12", name: "Python 3.12", category: "Developer"),
        .init(id: "Notepad++.Notepad++", name: "Notepad++", category: "Utilities"),
        .init(id: "Discord.Discord", name: "Discord", category: "Communication"),
        .init(id: "Zoom.Zoom", name: "Zoom", category: "Communication"),
        .init(id: "Valve.Steam", name: "Steam", category: "Games"),
    ]
}

enum Autounattend {
    static let fileName = "autounattend.xml"

    /// The answer file, or nil when no option is set (then nothing is written).
    static func xml(_ o: WindowsSetupOptions, arch: WindowsArch, imageLanguage: String = "en-US") -> String? {
        guard !o.isEmpty else { return nil }
        let archs: [String] = {
            switch arch {
            case .amd64: return ["amd64"]
            case .arm64: return ["arm64"]
            case .x86: return ["x86"]
            case .unknown: return ["amd64", "arm64"]
            }
        }()
        var passes: [String] = []

        // windowsPE: registry keys Windows 11 Setup checks before its hardware test.
        var lab: [String] = []
        if o.skipTPM { lab.append("BypassTPMCheck") }
        if o.skipSecureBoot { lab.append("BypassSecureBootCheck") }
        if o.skipRAM { lab.append("BypassRAMCheck") }
        if !lab.isEmpty {
            let cmds = lab.map { "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \($0) /t REG_DWORD /d 1 /f" }
            passes.append(pass("windowsPE", archs.map { component("Microsoft-Windows-Setup", $0, runSync(cmds, tag: "RunSynchronous", item: "RunSynchronousCommand", field: "Path")) }))
        }

        // specialize: offline setup, automatic encryption, PC name and time zone.
        var special: [String] = []
        var specialCmds: [String] = []
        if o.allowOfflineAccount {
            // Lets the out-of-box setup offer "I don't have internet".
            specialCmds.append("reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f")
        }
        if o.noAutoEncryption {
            specialCmds.append("reg add HKLM\\SYSTEM\\CurrentControlSet\\Control\\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f")
        }
        if !specialCmds.isEmpty {
            special += archs.map { component("Microsoft-Windows-Deployment", $0, runSync(specialCmds, tag: "RunSynchronous", item: "RunSynchronousCommand", field: "Path")) }
        }
        let pc = cleanComputerName(o.computerName)
        var shellSpecial: [String] = []
        if !pc.isEmpty { shellSpecial.append("<ComputerName>\(escape(pc))</ComputerName>") }
        if !o.timeZone.isEmpty { shellSpecial.append("<TimeZone>\(escape(o.timeZone))</TimeZone>") }
        if !shellSpecial.isEmpty {
            special += archs.map { component("Microsoft-Windows-Shell-Setup", $0, shellSpecial.joined(separator: "\n")) }
        }
        if !special.isEmpty { passes.append(pass("specialize", special)) }

        // oobeSystem: region, privacy, account, first sign-in tasks.
        var oobe: [String] = []
        if !o.locale.isEmpty {
            let l = escape(o.locale)
            oobe += archs.map { component("Microsoft-Windows-International-Core", $0, """
                <InputLocale>\(l)</InputLocale>
                <SystemLocale>\(l)</SystemLocale>
                <UILanguage>\(escape(imageLanguage))</UILanguage>
                <UserLocale>\(l)</UserLocale>
                """) }
        }
        let name = cleanAccountName(o.localAccount)
        var shell: [String] = []
        var oobeFlags: [String] = []
        if o.minimalPrivacy { oobeFlags.append("<ProtectYourPC>3</ProtectYourPC>") }
        if !name.isEmpty { oobeFlags.append("<HideOnlineAccountScreens>true</HideOnlineAccountScreens>") }
        if !oobeFlags.isEmpty { shell.append("<OOBE>\n" + oobeFlags.joined(separator: "\n") + "\n</OOBE>") }
        var firstLogon: [String] = []
        if !name.isEmpty {
            shell.append("""
                <UserAccounts>
                <LocalAccounts>
                <LocalAccount wcm:action="add">
                <Name>\(escape(name))</Name>
                <Group>Administrators</Group>
                <Password><Value></Value><PlainText>true</PlainText></Password>
                </LocalAccount>
                </LocalAccounts>
                </UserAccounts>
                """)
            // No password yet: Windows makes the user choose one at first sign-in.
            firstLogon.append("net user \"\(name)\" /logonpasswordchg:yes")
        }
        if !o.apps.isEmpty { firstLogon.append(wingetCommand(o.apps)) }
        if !firstLogon.isEmpty {
            shell.append(runSync(firstLogon, tag: "FirstLogonCommands", item: "SynchronousCommand", field: "CommandLine"))
        }
        if !shell.isEmpty { oobe += archs.map { component("Microsoft-Windows-Shell-Setup", $0, shell.joined(separator: "\n")) } }
        if !oobe.isEmpty { passes.append(pass("oobeSystem", oobe)) }

        return """
            <?xml version="1.0" encoding="utf-8"?>
            <!-- Made by Apex Activity Manager (CyberNet Labs). Windows Setup reads this file from the USB drive. -->
            <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            \(passes.joined(separator: "\n"))
            </unattend>

            """
    }

    /// Waits for winget (it arrives a little after first sign-in), then installs each app.
    static func wingetCommand(_ ids: [String]) -> String {
        let safe = ids.filter { $0.allSatisfy { $0.isLetter || $0.isNumber || ".-+_".contains($0) } }
        let list = safe.map { "'\($0)'" }.joined(separator: ",")
        let script = "for($i=0;$i -lt 60 -and -not (Get-Command winget -ErrorAction SilentlyContinue);$i++){Start-Sleep 10};"
            + "foreach($id in @(\(list))){winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements}"
        return "powershell -NoProfile -ExecutionPolicy Bypass -Command \"\(script)\""
    }

    /// Computer names: up to 15 letters, digits and hyphens, not all digits.
    static func cleanComputerName(_ s: String) -> String {
        let n = String(s.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(15))
        return n.allSatisfy(\.isNumber) ? "" : n
    }

    /// The Windows time zone for this Mac's, for the most common zones (else empty: Windows asks).
    static func windowsTimeZone(_ tz: TimeZone = .current) -> String {
        let map = ["Africa/Johannesburg": "South Africa Standard Time", "Europe/London": "GMT Standard Time",
                   "Europe/Berlin": "W. Europe Standard Time", "Europe/Paris": "Romance Standard Time",
                   "Europe/Amsterdam": "W. Europe Standard Time", "Africa/Lagos": "W. Central Africa Standard Time",
                   "Africa/Nairobi": "E. Africa Standard Time", "Africa/Cairo": "Egypt Standard Time",
                   "America/New_York": "Eastern Standard Time", "America/Chicago": "Central Standard Time",
                   "America/Denver": "Mountain Standard Time", "America/Los_Angeles": "Pacific Standard Time",
                   "America/Toronto": "Eastern Standard Time", "America/Sao_Paulo": "E. South America Standard Time",
                   "Asia/Dubai": "Arabian Standard Time", "Asia/Kolkata": "India Standard Time",
                   "Asia/Shanghai": "China Standard Time", "Asia/Tokyo": "Tokyo Standard Time",
                   "Asia/Singapore": "Singapore Standard Time", "Australia/Sydney": "AUS Eastern Standard Time",
                   "UTC": "UTC", "GMT": "UTC"]
        return map[tz.identifier] ?? ""
    }

    /// Windows user names: up to 20 characters, none of " / \ [ ] : ; | = , + * ? < > @.
    static func cleanAccountName(_ s: String) -> String {
        let bad = Set("\"/\\[]:;|=,+*?<>@")
        return String(s.filter { !bad.contains($0) && !$0.isNewline }.trimmingCharacters(in: .whitespaces).prefix(20))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func pass(_ name: String, _ components: [String]) -> String {
        "<settings pass=\"\(name)\">\n" + components.joined(separator: "\n") + "\n</settings>"
    }

    private static func component(_ name: String, _ arch: String, _ body: String) -> String {
        """
        <component name="\(name)" processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
        \(body)
        </component>
        """
    }

    private static func runSync(_ commands: [String], tag: String, item: String, field: String) -> String {
        let items = commands.enumerated().map { i, c in
            "<\(item) wcm:action=\"add\">\n<Order>\(i + 1)</Order>\n<\(field)>\(escape(c))</\(field)>\n</\(item)>"
        }
        return "<\(tag)>\n" + items.joined(separator: "\n") + "\n</\(tag)>"
    }
}

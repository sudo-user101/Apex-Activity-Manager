import SwiftUI

/// First launch: welcome, a short tour, every permission in one place, done.
/// Also opened from Help › Welcome to Apex and Settings › Permissions.
struct OnboardingView: View {
    /// Raised when the welcome changes enough to show it again after an update.
    static let version = 2
    static let versionKey = "welcomeVersion"
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarded") private var onboarded = false
    @State var step: Int = 0
    private let perms = PermissionCenter.shared

    private let tour: [(String, String, String)] = [
        ("list.bullet.rectangle", "Processes", "Every app and what it uses. Quit, pause, or Optimize an app so it uses less without closing it."),
        ("gauge.with.dots.needle.33percent", "Performance", "CPU, memory, disk, cloud, network, GPU, display and energy, each with a doctor that explains problems in plain words and fixes them."),
        ("stethoscope", "Doctors", "Drive Doctor and Network Doctor check step by step and tell you what's wrong and what to do, safely."),
        ("menubar.rectangle", "Menu bar", "Live graphs, Stay Awake, a shelf for files, clipboard history and sessions. Click the icon three times to open Apex."),
        ("sparkles", "Assistant", "Ask about your Mac, with Apex's live readings: Apex Agent on this Mac, a local model, or any AI service with your own key."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: tourPage
                case 2: permissionsPage
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<4) { i in
                        Capsule().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == step ? 18 : 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 && step < 3 { Button("Back") { go(step - 1) } }
                Button(step == 3 ? "Start Using Apex" : (step == 2 ? "Continue" : "Next")) {
                    if step == 3 { onboarded = true; UserDefaults.standard.set(Self.version, forKey: Self.versionKey); dismiss() } else { go(step + 1) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
        .onAppear { perms.refresh() }
    }

    private func go(_ n: Int) { withAnimation(.easeInOut(duration: 0.28)) { step = n } }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 104, height: 104)
            VStack(spacing: 4) {
                Text("Welcome to Apex Activity Manager").font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                Text("by CyberNet Labs").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }
            Text("See what your Mac is doing, find out why it’s slow, full or offline, and fix it, in plain words.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Label("Apex reads your Mac on your Mac. Nothing about it is sent anywhere unless you use an online feature yourself (speed test, an AI service with your key, a server you add).",
                  systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .padding(30)
    }

    private var tourPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What’s inside").font(.title.weight(.bold))
            ForEach(tour, id: \.1) { t in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: t.0).font(.title2).foregroundStyle(.tint).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.1).font(.headline)
                        Text(t.2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(30)
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions").font(.title.weight(.bold))
            HStack(alignment: .top) {
                Text("Everything Apex can use, in one place. Allow what you want now; you can change any of it later in Settings › Permissions. Apex only uses each one for what it says.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Allow All") { perms.allowAll() }
                    .help("Asks for each one macOS lets an app ask for, then opens the Full Disk Access switch. The fan and battery helper is left for you to install, as it needs your password.")
            }
            ScrollView { PermissionsList() }
        }
        .padding(30)
    }

    private var done: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("You’re all set").font(.largeTitle.weight(.bold))
            Text("Apex is in your menu bar too. Click it once for the panel, three times to come back here.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
        }
        .padding(30)
    }
}

/// The permission rows, shared by the welcome flow and Settings.
struct PermissionsList: View {
    private let perms = PermissionCenter.shared
    @State private var askedInSettings: Set<Permission> = []

    var body: some View {
        VStack(spacing: 8) {
            if let p = perms.allowing {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow All: \(p.title)").font(.headline)
                        Text(perms.allowingNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Skip") { perms.skip() }
                    Button("Stop") { perms.stopAllowAll() }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(Permission.allCases) { p in
                let ok = perms.granted[p] ?? false
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: p.symbol).font(.title3).foregroundStyle(ok ? Color.green : Color.accentColor).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(p.title).font(.headline)
                            if p.optional { Text("Optional").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(p.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 10)
                    if ok {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
                    } else {
                        VStack(alignment: .trailing, spacing: 4) {
                            Button(p == .helper ? "Install…" : (p == .fullDisk ? "Open Settings" : "Allow")) {
                                askedInSettings.insert(p); perms.grant(p)
                            }
                            .controlSize(.small)
                            if PermissionCenter.tccService(p) != nil, askedInSettings.contains(p) || perms.allowing == p {
                                Button("Already on? Fix") { perms.resetAndAsk(p) }
                                    .buttonStyle(.link).font(.caption)
                                    .help("System Settings shows it on, but it’s for an earlier copy of Apex. This clears that entry and asks again; switch it on once more.")
                            }
                        }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            perms.refresh()      // back from System Settings
        }
        // Switches flipped in System Settings show here within a second, even while Apex isn't in front.
        .task {
            while !Task.isCancelled {
                perms.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

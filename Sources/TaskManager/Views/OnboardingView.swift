import SwiftUI

/// First launch: welcome, a short tour, every permission in one place, done.
/// Also opened from Help › Welcome to Apex and Settings › Permissions.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarded") private var onboarded = false
    @State var step: Int = 0
    private let perms = PermissionCenter.shared

    private let tour: [(String, String, String)] = [
        ("list.bullet.rectangle", "Processes", "Every app and what it uses. Quit, pause, or Optimize an app so it uses less without closing it."),
        ("gauge.with.dots.needle.33percent", "Performance", "CPU, memory, disk, cloud, network, GPU, display and energy, each with a doctor that explains problems in plain words and fixes them."),
        ("stethoscope", "Doctors", "Drive Doctor and Network Doctor check step by step and tell you what's wrong and what to do, safely."),
        ("menubar.rectangle", "Menu bar", "Live graphs, Stay Awake, a shelf for files, clipboard history and sessions. Click the icon three times to open Apex."),
        ("sparkles", "Assistant", "Ask a model on your Mac about your Mac, with Apex's live readings. Nothing leaves the Mac."),
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
                    if step == 3 { onboarded = true; dismiss() } else { go(step + 1) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 520)
        .onAppear { perms.refresh() }
    }

    private func go(_ n: Int) { withAnimation(.easeInOut(duration: 0.28)) { step = n } }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Welcome to Apex").font(.largeTitle.weight(.bold))
            Text("See what your Mac is doing, find out why it’s slow, full or offline, and fix it, in plain words.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            Text("By CyberNet Labs").font(.caption).foregroundStyle(.tertiary)
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
            Text("Everything Apex can use, in one place. Grant what you want now; you can change any of it later in Settings.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PermissionsList()
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

    var body: some View {
        VStack(spacing: 8) {
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
                        Button(p == .helper ? "Install…" : (p == .fullDisk ? "Open Settings" : "Allow")) { perms.grant(p) }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            perms.refresh()      // back from System Settings
        }
    }
}

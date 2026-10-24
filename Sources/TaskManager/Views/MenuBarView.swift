import SwiftUI

/// Text shown in the menu bar.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let m = model.menuStats
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            switch model.menuBarStyle {
            case "cpu": Text("\(m.cpu)%")
            case "memory": Text("\(m.memory)%")
            case "both": Text("\(m.cpu)% · \(m.memory)%")
            default: EmptyView()
            }
        }
        .monospacedDigit()
    }
}

/// Click-through panel from the menu bar.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = model.snapshot.system, h = model.history
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apex Activity Manager").font(.headline)
                Spacer()
                Text(s.memory.pressureLevel.title).font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(s.memory.pressureLevel.color.opacity(0.2), in: Capsule())
            }
            row("CPU", "\(Int(s.cpu.total.rounded()))%", LineGraph(series: [.init(values: h.cpu, color: .blue)], gridLines: false, cornerRadius: 4))
            row("Memory", "\(Fmt.bytes(s.memory.used)) · \(Int(s.memory.percent.rounded()))%",
                LineGraph(series: [.init(values: h.memory, color: .windowsBlue)], gridLines: false, cornerRadius: 4))
            row("Network", "↓ \(Fmt.rate(s.network.inPerSec))  ↑ \(Fmt.rate(s.network.outPerSec))",
                LineGraph(series: [.init(values: h.netIn, color: .orange), .init(values: h.netOut, color: .blue, fill: false)], maxValue: nil, gridLines: false, cornerRadius: 4))
            Divider()
            Text("Top apps").font(.caption).foregroundStyle(.secondary)
            ForEach(topApps(), id: \.pid) { p in
                HStack(spacing: 8) {
                    Image(nsImage: IconCache.shared.icon(forBundle: p.bundlePath)).resizable().frame(width: 16, height: 16)
                    Text(p.name).lineLimit(1)
                    if p.background { Image(systemName: "leaf.fill").font(.caption2).foregroundStyle(.green) }
                    Spacer()
                    Text(Fmt.percent(p.cpu * model.cpuScale) + "%").monospacedDigit().foregroundStyle(.secondary)
                    Text(Fmt.bytes(p.memory)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                }
                .font(.callout)
            }
            Divider()
            HStack {
                Button("Open Apex") { open() }.keyboardShortcut(.defaultAction)
                Button("Free Up Memory…") { open(); model.section = .performance; model.showFreeMemory = true }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.menuPanelOpen = true }
        .onDisappear { model.menuPanelOpen = false }
    }

    private func topApps() -> [ProcessInfoSample] {
        Array(model.snapshot.processes.filter(\.isRegularApp).sorted { $0.cpu + Double($0.memory) / 1e10 > $1.cpu + Double($1.memory) / 1e10 }.prefix(5))
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func row<G: View>(_ label: String, _ value: String, _ graph: G) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.medium)).monospacedDigit()
            }
            Spacer()
            graph.frame(width: 120, height: 30)
        }
    }
}

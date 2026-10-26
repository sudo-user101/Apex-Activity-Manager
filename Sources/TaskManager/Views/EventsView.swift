import SwiftUI
import DetectionCore

/// History › Events: every alert and recorded spike, newest first, with the
/// rule and numbers behind it ("why this fired").
struct EventsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = "all"
    @State private var search = ""
    @State private var confirmClear = false
    private var log: EventLog { EventLog.shared }

    private var rows: [DetectionEvent] {
        log.events.filter { e in
            switch filter {
            case "alerts": return e.kind != .spike
            case "spikes": return e.kind == .spike
            default: return true
            }
        }
        .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.subject ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        @Bindable var model = model
        let rows = rows
        VStack(spacing: 0) {
            HSplitView {
                List(selection: $model.selectedEvent) {
                    ForEach(rows) { e in EventRow(event: e).tag(e.id) }
                }
                .listStyle(.inset)
                .frame(minWidth: 300, idealWidth: 380)
                .overlay {
                    if rows.isEmpty {
                        if !search.isEmpty { ContentUnavailableView.search(text: search) }
                        else {
                            ContentUnavailableView("No Events", systemImage: "checkmark.seal",
                                description: Text(filter == "spikes" ? "No short spikes recorded."
                                    : "Nothing needed your attention. Alerts and short spikes will be listed here."))
                        }
                    }
                }
                Group {
                    if let id = model.selectedEvent, let e = log.events.first(where: { $0.id == id }) {
                        EventDetail(event: e)
                    } else {
                        ContentUnavailableView("Select an Event", systemImage: "list.bullet.rectangle",
                                               description: Text("See what happened, why it fired and what you can do."))
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Picker("Filter", selection: $filter) {
                    Text("All").tag("all"); Text("Alerts").tag("alerts"); Text("Spikes").tag("spikes")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                Text("\(log.events.count) \(log.events.count == 1 ? "event" : "events") · last \(Int(EventLog.keepDays)) days")
                    .font(.caption).foregroundStyle(.secondary)
                if !Alerts.shared.enabled {
                    Text("· alerts are off in Settings").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Clear Events…") { confirmClear = true }.controlSize(.small).disabled(log.events.isEmpty)
            }
            .padding(.horizontal, 14).frame(height: 30).background(.bar)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search events")
        .confirmationDialog("Clear all events?", isPresented: $confirmClear) {
            Button("Clear Events", role: .destructive) { log.clear(); model.selectedEvent = nil }
        }
    }
}

extension DetectionEvent {
    var icon: (String, Color) {
        if kind == .spike { return ("waveform.path.ecg", .secondary) }
        switch severity {
        case .critical: return ("exclamationmark.octagon.fill", .red)
        case .warning: return ("exclamationmark.triangle.fill", .orange)
        case .info: return ("info.circle.fill", .blue)
        }
    }
}

private struct EventRow: View {
    let event: DetectionEvent
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.icon.0).foregroundStyle(event.icon.1).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).lineLimit(1)
                Text(event.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if event.kind == .spike {
                    Text("Spike").font(.caption2).foregroundStyle(.secondary)
                } else if event.notify {
                    Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.secondary).help("Notification sent")
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct EventDetail: View {
    @Environment(AppModel.self) private var model
    let event: DetectionEvent

    var body: some View {
        let running = event.pids.filter { pid in model.snapshot.processes.contains { $0.pid == pid } }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: event.icon.0).foregroundStyle(event.icon.1).font(.largeTitle)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(event.date.formatted(date: .abbreviated, time: .standard) + " · " + event.rule.title)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(event.summary).fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Why this fired").font(.headline)
                    Text(event.reason).fixedSize(horizontal: false, vertical: true)
                    Label(kindText, systemImage: event.kind == .spike ? "waveform.path.ecg" : event.notify ? "bell" : "tray")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                if let series = event.series, series.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.rule == .memoryGrowth ? "Memory over time" : "Over time").font(.headline)
                        let span = event.date.timeIntervalSince(event.started)
                        let times = series.indices.map { event.started.addingTimeInterval(span * Double($0) / Double(series.count - 1)) }
                        LineGraph(series: [.init(values: series, color: MemoryColor.used, name: "Memory")], maxValue: (series.max() ?? 1) * 1.15)
                            .environment(\.graphTimeline, GraphTimeline(times: times, window: max(span, 1), end: event.date))
                            .environment(\.graphUnit, .bytes)
                            .environment(\.advancedGraph, true)
                            .frame(height: 140)
                    }
                }

                if !event.evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Evidence").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            ForEach(Array(event.evidence.enumerated()), id: \.offset) { _, e in
                                GridRow {
                                    Text(e.label).foregroundStyle(.secondary)
                                    Text(e.value).monospacedDigit().textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    if let pid = running.first {
                        Button("Show in Processes") { model.reveal(pid: pid) }
                    }
                    if event.rule == .memoryGrowth, !running.isEmpty {
                        Button("Quit \(event.subject ?? "App")") { model.end(pids: running, force: false) }
                            .help("Quitting and reopening it gives the memory back")
                    }
                    if event.rule == .appCPU, !running.isEmpty {
                        Button("Optimize") { model.setOptimized(pids: running, true) }
                            .help("Lower its priority so it runs lighter")
                    }
                    if event.rule == .memoryPressure || event.rule == .swapGrowth {
                        Button("Free Up Memory…") { model.section = .performance; model.showFreeMemory = true }
                    }
                    if event.rule == .diskSpace || event.rule == .diskFilling {
                        Button("Clean Up Disk…") { model.showCleanup = true }
                    }
                    Spacer()
                    Button("Delete") { EventLog.shared.remove(event.id); model.selectedEvent = nil }
                }
                if !event.pids.isEmpty && running.isEmpty {
                    Text("The processes involved are no longer running.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var kindText: String {
        switch event.kind {
        case .spike: return "Short spike: recorded only, no notification"
        case .instant: return event.notify ? "Notification sent" : "Recorded"
        case .sustained: return event.notify ? "Lasted long enough to alert; notification sent" : "Sustained; recorded in History"
        }
    }
}

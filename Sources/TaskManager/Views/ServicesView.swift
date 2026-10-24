import SwiftUI

@MainActor enum ServicesCache { static var items: [ServiceItem]? }

struct ServicesView: View {
    @State private var services: [ServiceItem] = ServicesCache.items ?? []
    @State private var loading = ServicesCache.items == nil
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\ServiceItem.label)]
    @State private var search = ""
    @State private var error: String?

    var body: some View {
        let shown = services.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
        Table(shown, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Label", value: \.label) { s in Text(s.label).lineLimit(1).truncationMode(.middle) }
                .width(min: 220, ideal: 420)
            TableColumn("PID", value: \.pidSort) { s in NumberCell(s.pid.map { String($0) } ?? "—", bold: false) }
                .width(min: 50, ideal: 64)
            TableColumn("Status", value: \.statusText) { s in
                HStack(spacing: 5) {
                    Circle().fill(s.isRunning ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(s.statusText)
                }
            }
            .width(min: 70, ideal: 90)
            TableColumn("Last Exit") { s in
                NumberCell(s.lastExit.map { String($0) } ?? "—", bold: false)
            }
            .width(min: 50, ideal: 64)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let s = services.first(where: { ids.contains($0.id) }) {
                if s.isRunning {
                    Button("Stop") { perform(.stop, s) }
                    Button("Restart") { perform(.restart, s) }
                } else {
                    Button("Start") { perform(.start, s) }
                }
                Divider()
                Button("Copy Label") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.label, forType: .string)
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .navigationSubtitle("\(services.filter(\.isRunning).count) running · \(services.count) total")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                let s = services.first { selection.contains($0.id) }
                Button { if let s { perform(.start, s) } } label: { Label("Start", systemImage: "play.fill") }
                    .disabled(s == nil || s?.isRunning == true)
                Button { if let s { perform(.stop, s) } } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(s?.isRunning != true)
                Button { if let s { perform(.restart, s) } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    .disabled(s?.isRunning != true)
            }
        }
        .alert("Couldn’t change service", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task {
            // Refresh slowly and only while this view is on screen.
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func reload() async {
        services = await Task.detached(priority: .utility) { Launchd.services() }.value
        ServicesCache.items = services
        loading = false
    }

    private func perform(_ action: Launchd.Action, _ s: ServiceItem) {
        Task {
            let err = await Task.detached { Launchd.perform(action, label: s.label) }.value
            if let err { error = err }
            try? await Task.sleep(for: .milliseconds(400))
            await reload()
        }
    }
}

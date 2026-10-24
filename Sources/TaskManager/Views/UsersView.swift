import SwiftUI

struct UsersView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [String: Int] = [:]
    @State private var sortOrder = [KeyPathComparator(\UserSummary.processes, order: .reverse)]

    var body: some View {
        let users = Users.summarize(model.snapshot.processes, sessions: sessions)
        let rows = sortOrder.first?.keyPath == \UserSummary.processes && sortOrder.first?.order == .reverse
            ? users : users.sorted(using: sortOrder)
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("User", value: \.name) { u in
                HStack(spacing: 8) {
                    Image(systemName: u.uid == 0 || u.name.hasPrefix("_") ? "gearshape.circle.fill" : "person.crop.circle.fill")
                        .font(.title3).foregroundStyle(u.isCurrent ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(u.name + (u.isCurrent ? " (you)" : ""))
                        if !u.fullName.isEmpty && u.fullName != u.name {
                            Text(u.fullName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Status", value: \.status) { u in Text(u.status).foregroundStyle(u.status.hasPrefix("Logged") ? .primary : .secondary) }
                .width(min: 100, ideal: 140)
            TableColumn("% CPU", value: \.cpu) { u in NumberCell(Fmt.percent(u.cpu * model.cpuScale), bold: false) }
                .width(min: 56, ideal: 70)
            TableColumn("Memory", value: \.memory) { u in NumberCell(Fmt.bytes(u.memory), bold: false) }
                .width(min: 70, ideal: 90)
            TableColumn("Processes", value: \.processes) { u in NumberCell("\(u.processes)", bold: false) }
                .width(min: 60, ideal: 80)
        }
        .navigationSubtitle("\(sessions.count) logged in")
        .task { sessions = Users.loggedIn() }
    }
}

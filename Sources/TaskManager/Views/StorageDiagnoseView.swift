import SwiftUI

/// Storage › Diagnose: Drive Doctor (Automatic / Manual) for any drive,
/// picked at the top.
struct StorageDiagnoseView: View {
    @Environment(AppModel.self) private var model
    /// A plugged-in drive's volume to start on; nil = the startup drive.
    var startAt: String?
    var onBack: () -> Void
    var onDone: () -> Void
    @State private var selected: String?

    private static let startupID = "startup"

    var body: some View {
        let s = model.snapshot.system
        let devices = s.storageDevices
        let id = selected ?? startAt.flatMap { p in devices.first { $0.volumes.contains { $0.path == p } }?.id } ?? Self.startupID
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button { onBack() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).help("Back")
                Image(systemName: "stethoscope").font(.title2).foregroundStyle(.tint)
                Text("Diagnose").font(.title2).bold()
                Spacer()
                Picker("Drive", selection: Binding(get: { id }, set: { selected = $0 })) {
                    Label(s.disk.volumeName, systemImage: "internaldrive").tag(Self.startupID)
                    ForEach(devices) { d in Label(d.name, systemImage: d.symbol).tag(d.id) }
                }
                .fixedSize()
            }
            Group {
                if let d = devices.first(where: { $0.id == id }) {
                    DriveDoctorView(title: d.name, record: DriveHealthStore.shared.record(for: d), usb: d.usb,
                                    capacity: d.capacity, available: d.available,
                                    volumes: d.volumes.map { ($0.name, $0.path) }, embedded: true)
                } else {
                    DriveDoctorView(title: s.disk.volumeName, record: DriveHealthStore.shared.startup, usb: nil,
                                    capacity: s.disk.capacity, available: s.disk.available,
                                    volumes: [(s.disk.volumeName, "/"), ("\(s.disk.volumeName) – Data", "/System/Volumes/Data")],
                                    embedded: true)
                }
            }
            .id(id)   // a different drive starts with fresh results
            HStack { Spacer(); Button("Done") { onDone() }.keyboardShortcut(.cancelAction) }
        }
    }
}

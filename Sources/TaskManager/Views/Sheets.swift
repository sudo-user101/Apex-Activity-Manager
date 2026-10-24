import SwiftUI

struct RunTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var asAdmin = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run New Task").font(.headline)
            Text("Type an app name (for example “Safari”) or a shell command.")
                .foregroundStyle(.secondary)
            TextField("Open:", text: $command)
                .textFieldStyle(.roundedBorder)
                .onSubmit(run)
            Toggle("Run with administrator privileges", isOn: $asAdmin)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run", action: run).keyboardShortcut(.defaultAction).disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func run() {
        let cmd = command, admin = asAdmin
        Task {
            let outcome = await Task.detached { ProcessActions.run(cmd, asAdmin: admin) }.value
            if case .failed(let msg) = outcome { error = msg } else { dismiss(); model.refreshNow() }
        }
    }
}

import SwiftUI

/// Settings › Shelf: the floating shelf, and what brings it up.
struct ShelfSettingsTab: View {
    @State private var on = FloatingShelf.shared.enabled
    @AppStorage("shelfOnAnyDrag") private var onAnyDrag = false

    var body: some View {
        Form {
            Section {
                Toggle("Floating shelf", isOn: $on.animation(.easeInOut(duration: 0.2)))
                    .onChange(of: on) { FloatingShelf.shared.enabled = on }
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show it", selection: $onAnyDrag) {
                        Text("When you shake a file you’re dragging").tag(false)
                        Text("As soon as you start dragging a file").tag(true)
                    }
                    Text("Each shake starts a new shelf.").settingsCaption()
                }
                .help("A shake is a quick left-right (or up-down) wiggle while holding the file. Each shake starts a new shelf.")
                .disabled(!on)
            }
        }
        .settingsForm()
    }
}

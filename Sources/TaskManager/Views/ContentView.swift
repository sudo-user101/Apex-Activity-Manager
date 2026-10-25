import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        // One click between views via a segmented
        // control centred in the toolbar (⌘1…⌘6 also work).
        NavigationStack {
            Group {
                switch model.section {
                case .processes: ProcessesView()
                case .performance: PerformanceView()
                case .ai: LocalAIView()
                case .history: HistoryView()
                case .startup: StartupView()
                case .users: UsersView()
                case .services: ServicesView()
                }
            }
            .id(model.section)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.14), value: model.section)
            .navigationTitle("Apex")
            .modifier(HideToolbarTitle())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $model.section) {
                        ForEach(AppSection.allCases) { s in
                            Text(s.shortTitle).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Switch view (⌘1–⌘6)")
                }
                ToolbarItem(placement: .primaryAction) { RecordButton() }
            }
        }
        .onAppear {
            let open = openWindow
            model.openMainWindow = { open(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        }
        .sheet(isPresented: $model.showWelcome) { OnboardingView() }
        .task {
            // First launch (or APEX_OPEN=welcome): the welcome flow.
            if !UserDefaults.standard.bool(forKey: "onboarded") || ProcessInfo.processInfo.environment["APEX_OPEN"] == "welcome" {
                try? await Task.sleep(for: .milliseconds(600))
                model.showWelcome = true
            }
        }
        .sheet(isPresented: $model.showRunTask) {
            RunTaskSheet()
        }
        .sheet(isPresented: $model.showFreeMemory) {
            FreeMemorySheet()
        }
        .sheet(isPresented: $model.showWhoIsUsing) {
            WhoIsUsingSheet()
        }
        .sheet(isPresented: $model.showCleanup) {
            CleanupSheet()
        }
        .alert(model.adminPrompt?.title ?? "", isPresented: Binding(
            get: { model.adminPrompt != nil }, set: { if !$0 { model.adminPrompt = nil } }),
               presenting: model.adminPrompt) { prompt in
            Button("Continue…") { model.runAdmin(prompt) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
        .alert("Couldn’t complete the action", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The tabs and actions need the whole toolbar; the app name is still in the
/// Dock, menu bar and Window menu. (macOS 15+; older systems keep the title.)
struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

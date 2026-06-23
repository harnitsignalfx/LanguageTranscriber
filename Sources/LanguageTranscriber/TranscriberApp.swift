import SwiftUI

@main
struct TranscriberApp: App {
    @StateObject private var viewModel = TranscriberViewModel()

    var body: some Scene {
        WindowGroup("Language Transcriber") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Standard macOS Settings scene — opens with Cmd+, from the menu bar.
        Settings {
            SettingsView()
                .environmentObject(viewModel)
        }
    }
}

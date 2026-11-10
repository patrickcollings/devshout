import DevshoutCore
import DevshoutMac
import SwiftUI

/// Placeholder app shell. The real menu bar, onboarding, settings and pipeline wiring land in App/Devshout/.
@main
struct DevshoutApp: App {
    var body: some Scene {
        MenuBarExtra("devshout", systemImage: "waveform") {
            Text("devshout \(DevshoutMac.version)")
            Divider()
            Button("Quit devshout") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

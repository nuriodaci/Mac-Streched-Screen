import AppKit
import AppUI
import SwiftUI
import StretchCore

struct MacStrechedScreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Stretch Screen", id: "main") {
            ContentView(model: delegate.model)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 480, height: 480)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Refresh Displays") {
                    delegate.model.refreshDisplays()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(delegate.model.isBusy || delegate.model.pendingChange != nil)
            }
            CommandGroup(replacing: .help) {
                Button("Mac-Streched-Screen Help") {
                    if let help = Bundle.main.url(forResource: "README", withExtension: "md") {
                        NSWorkspace.shared.open(help)
                    }
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Diagnostic hook used by the layout tests to inspect the expanded window without
        // synthesizing clicks. It only changes local view state.
        if ProcessInfo.processInfo.environment["MSS_UI_EXPAND"] == "1" {
            model.showsAdvanced = true
        }
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    // Rolling back before exit keeps a live override from outliving the window.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.handleTermination()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.handleTermination()
    }
}

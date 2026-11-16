import Foundation
import StretchCore

/// Routed before SwiftUI/AppKit initialization. No command can apply an unconfirmed mode.
enum CommandRouting {
    static func runIfNeeded() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { return }
        // LaunchServices can supply its legacy process-serial argument.
        if command.hasPrefix("-psn_") { return }
        do {
            guard args.count == 1 else { throw StretchError.invalidInput("Unexpected arguments. Use --help.") }
            switch command {
            case "--version": print("Mac-Streched-Screen 0.1.0-preview")
            case "help", "--help", "-h":
                print("""
                Mac-Streched-Screen — experimental physical 4:3 display utility
                Usage:
                  Mac-Streched-Screen           Open the app
                  Mac-Streched-Screen list      Read external display information (no mode change)
                  Mac-Streched-Screen restore   Remove this app's temporary EDID overrides
                  Mac-Streched-Screen --version

                Apple Silicon only. Private API, not guaranteed across OS/hardware versions.
                The monitor must support Full/Wide/Stretch scaling. Save your work before testing.
                A watchdog cannot recover a hung kernel/display driver. Reconnect or reboot if needed.
                """)
            case "list":
                for display in try MacDisplayPlatform().displays() {
                    print("[\(display.id)] \(display.info.name) · \(display.info.identity.vendor) · \(display.info.blocks) EDID block(s)\(Edid.isOverride(display.edid) ? " · override active" : "")")
                }
            case "restore":
                let store = try BackupStore.applicationDefault()
                try manualRestore(store: store)
            default: throw StretchError.invalidInput("Unknown command: \(command). Use --help.")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Mac-Streched-Screen: \(error.displayMessage)\n".utf8))
            exit(1)
        }
    }

    private static func manualRestore(store: BackupStore) throws {
        // The session and terminal command share an operation lock, never the GUI lifetime lock.
        // Do not cancel a helper until the reset actually succeeds.
        let platform = try MacDisplayPlatform()
        let count = try Watchdog.restoreAll(store: store, platform: platform)
        print("Restore requested for \(count) remaining override(s). A reset does not guarantee the previous refresh rate or window arrangement.")
    }
}

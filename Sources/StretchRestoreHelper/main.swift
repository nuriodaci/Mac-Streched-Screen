import Foundation
import StretchCore

// Deliberately separate from the application and test binaries. This executable cannot apply a
// mode or spawn another process. Only a private state file in our Application Support is accepted.
do {
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--state" else {
        throw StretchError.invalidInput("Usage: StretchRestoreHelper --state <record>")
    }
    let store = try BackupStore.applicationDefault()
    let state = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    guard state.deletingLastPathComponent() == store.pendingDirectory.standardizedFileURL,
          state.pathExtension == "json", UUID(uuidString: state.deletingPathExtension().lastPathComponent) != nil else {
        throw StretchError.invalidInput("Invalid restore-record location.")
    }
    try Watchdog.run(stateURL: state, platform: MacDisplayPlatform())
} catch {
    FileHandle.standardError.write(Data("Restore failed: \(error.displayMessage)\n".utf8))
    exit(1)
}

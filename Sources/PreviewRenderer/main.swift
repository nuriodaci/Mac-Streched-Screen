import AppKit
import AppUI
import StretchCore

// Synthetic offscreen views only. Never accesses a live display.
MainActor.assumeIsolated {
    do { try PreviewRenderer.run() }
    catch {
        FileHandle.standardError.write(Data("Preview rendering failed: \(error)\n".utf8))
        exit(1)
    }
}

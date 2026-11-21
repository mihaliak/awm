import AppKit

@MainActor
struct WindowControlHandoff {
    var openSettings: () -> Void
    var revealApplication: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    func open() {
        openSettings()
        revealApplication(Bundle.main.bundleURL)
    }
}

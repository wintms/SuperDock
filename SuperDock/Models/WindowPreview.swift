import AppKit
import ApplicationServices

struct DockTarget: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    /// Accessibility/Quartz coordinates (origin at the primary display's top-left).
    let dockItemFrame: CGRect
}

@MainActor
final class WindowPreview: ObservableObject, Identifiable {
    let id: CGWindowID
    let captureWindowID: CGWindowID?
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let accessibilityElement: AXUIElement
    let closeButton: AXUIElement?
    @Published var image: NSImage?

    init(
        id: CGWindowID,
        captureWindowID: CGWindowID?,
        title: String,
        frame: CGRect,
        isMinimized: Bool,
        accessibilityElement: AXUIElement,
        closeButton: AXUIElement?,
        image: NSImage? = nil
    ) {
        self.id = id
        self.captureWindowID = captureWindowID
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.accessibilityElement = accessibilityElement
        self.closeButton = closeButton
        self.image = image
    }
}

import AppKit
import ScreenCaptureKit
import CoreGraphics

enum ScreenshotService {
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func capture(windowID: CGWindowID, sourceSize: CGSize) async -> NSImage? {
        guard windowID != 0 else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = min(1, 520 / max(sourceSize.width, 1))
            configuration.width = max(1, Int(sourceSize.width * scale))
            configuration.height = max(1, Int(sourceSize.height * scale))
            configuration.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }
}

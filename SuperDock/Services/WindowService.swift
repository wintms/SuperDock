import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class WindowService {
    func windows(for processIdentifier: pid_t) -> [WindowPreview] {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        guard let elements: [AXUIElement] = axAttribute(appElement, kAXWindowsAttribute as CFString) else {
            return []
        }

        let cgWindows = cgWindowDescriptions(for: processIdentifier)

        return elements.compactMap { element in
            let role: String? = axAttribute(element, kAXRoleAttribute as CFString)
            guard role == (kAXWindowRole as String),
                  let frame = axFrame(element),
                  frame.width >= 80, frame.height >= 60 else { return nil }

            let title: String = axAttribute(element, kAXTitleAttribute as CFString) ?? "Untitled Window"
            let minimized: Bool = axAttribute(element, kAXMinimizedAttribute as CFString) ?? false
            let closeButton: AXUIElement? = axAttribute(element, kAXCloseButtonAttribute as CFString)
            let match = bestCGWindowMatch(title: title, frame: frame, candidates: cgWindows)

            // A stable synthetic ID keeps minimized/unexposed windows in the list.
            let fallback = CGWindowID(abs(title.hashValue ^ Int(frame.minX) ^ Int(frame.minY)) & 0x7fff_ffff)
            return WindowPreview(
                id: match?.id ?? fallback,
                captureWindowID: match?.id,
                title: title.isEmpty ? "Untitled Window" : title,
                frame: frame,
                isMinimized: minimized,
                accessibilityElement: element,
                closeButton: closeButton
            )
        }
    }

    @discardableResult
    func close(_ preview: WindowPreview) -> Bool {
        guard let closeButton = preview.closeButton else { return false }
        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    }

    func activate(_ preview: WindowPreview, processIdentifier: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else { return }

        if preview.isMinimized {
            AXUIElementSetAttributeValue(
                preview.accessibilityElement,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }

        application.activate()
        AXUIElementPerformAction(preview.accessibilityElement, kAXRaiseAction as CFString)

        let appElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            preview.accessibilityElement
        )
    }

    private struct CGWindowDescription {
        let id: CGWindowID
        let title: String
        let frame: CGRect
    }

    private func cgWindowDescriptions(for processIdentifier: pid_t) -> [CGWindowDescription] {
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return rawList.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let boundsValue = info[kCGWindowBounds as String] else { return nil }

            let bounds = boundsValue as! CFDictionary
            guard let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }

            return CGWindowDescription(
                id: CGWindowID(number.uint32Value),
                title: info[kCGWindowName as String] as? String ?? "",
                frame: frame
            )
        }
    }

    private func bestCGWindowMatch(
        title: String,
        frame: CGRect,
        candidates: [CGWindowDescription]
    ) -> CGWindowDescription? {
        candidates.min { lhs, rhs in
            matchScore(title: title, frame: frame, candidate: lhs)
                < matchScore(title: title, frame: frame, candidate: rhs)
        }.flatMap { candidate in
            matchScore(title: title, frame: frame, candidate: candidate) < 200 ? candidate : nil
        }
    }

    private func matchScore(title: String, frame: CGRect, candidate: CGWindowDescription) -> CGFloat {
        let titlePenalty: CGFloat = title == candidate.title ? 0 : 100
        return titlePenalty
            + abs(frame.minX - candidate.frame.minX)
            + abs(frame.minY - candidate.frame.minY)
            + abs(frame.width - candidate.frame.width)
            + abs(frame.height - candidate.frame.height)
    }
}

import AppKit
import ApplicationServices

@MainActor
final class DockHoverMonitor {
    var onTargetChanged: ((DockTarget?) -> Void)?
    var onDockContextMenuRequested: (() -> Void)?

    private let systemWideElement = AXUIElementCreateSystemWide()
    private var timer: Timer?
    private var rightMouseMonitor: Any?
    private var lastTarget: DockTarget?
    private var contextMenuTarget: DockTarget?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        rightMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
            Task { @MainActor in
                self?.handleRightMouseDown()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let rightMouseMonitor {
            NSEvent.removeMonitor(rightMouseMonitor)
            self.rightMouseMonitor = nil
        }
        contextMenuTarget = nil
        publish(nil)
    }

    private func poll() {
        guard AccessibilitySupport.isTrusted,
              let location = CGEvent(source: nil)?.location else {
            publish(nil)
            return
        }

        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(location.x),
            Float(location.y),
            &hitElement
        )
        guard result == .success, let hitElement else {
            publish(nil)
            return
        }

        let target = resolveDockTarget(startingAt: hitElement)

        // Keep the preview suppressed while the pointer is still on the Dock
        // item whose native context menu was opened. Leaving the item clears
        // suppression and restores normal hover behavior.
        if let contextMenuTarget {
            guard target != contextMenuTarget else { return }
            self.contextMenuTarget = nil
        }

        publish(target)
    }

    private func resolveDockTarget(startingAt element: AXUIElement) -> DockTarget? {
        var current: AXUIElement? = element

        for _ in 0..<8 {
            guard let candidate = current else { break }
            let role: String? = axAttribute(candidate, kAXRoleAttribute as CFString)
            let subrole: String? = axAttribute(candidate, kAXSubroleAttribute as CFString)

            if role == "AXDockItem", subrole == "AXApplicationDockItem" || role == "AXDockItem" {
                if let target = makeTarget(from: candidate) {
                    return target
                }
            }

            current = axAttribute(candidate, kAXParentAttribute as CFString)
        }
        return nil
    }

    private func makeTarget(from dockItem: AXUIElement) -> DockTarget? {
        guard let frame = axFrame(dockItem) else { return nil }

        let title: String = axAttribute(dockItem, kAXTitleAttribute as CFString) ?? "Application"
        let appURL: URL? = axAttribute(dockItem, kAXURLAttribute as CFString)
        let standardizedPath = appURL?.standardizedFileURL.path

        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        let runningApp = candidates.first { app in
            if let standardizedPath, app.bundleURL?.standardizedFileURL.path == standardizedPath {
                return true
            }
            return app.localizedName == title
        }

        guard let runningApp else { return nil }
        return DockTarget(
            processIdentifier: runningApp.processIdentifier,
            bundleIdentifier: runningApp.bundleIdentifier,
            applicationName: runningApp.localizedName ?? title,
            dockItemFrame: frame
        )
    }

    private func publish(_ target: DockTarget?) {
        guard target != lastTarget else { return }
        lastTarget = target
        onTargetChanged?(target)
    }

    private func handleRightMouseDown() {
        guard let lastTarget else { return }
        contextMenuTarget = lastTarget
        publish(nil)
        onDockContextMenuRequested?()
    }
}

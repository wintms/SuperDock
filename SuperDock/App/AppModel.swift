import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var isEnabled = true {
        didSet { updateMonitorState() }
    }
    @Published private(set) var hasAccessibilityPermission = AccessibilitySupport.isTrusted
    @Published private(set) var hasScreenRecordingPermission = ScreenshotService.hasPermission
    @Published private(set) var statusText = "正在等待权限"

    private let monitor = DockHoverMonitor()
    private let windowService = WindowService()
    private let panelController = PreviewPanelController()
    private var didStart = false
    private var currentTarget: DockTarget?
    private var hoverTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var isPointerInsidePanel = false
    private var thumbnailCache: [CachedWindowThumbnail] = []

    init() {
        monitor.onTargetChanged = { [weak self] target in
            self?.dockTargetChanged(target)
        }
        monitor.onDockContextMenuRequested = { [weak self] in
            self?.dockContextMenuRequested()
        }
        panelController.onPointerPresenceChanged = { [weak self] inside in
            self?.panelPointerPresenceChanged(inside)
        }
        Task { @MainActor [weak self] in
            self?.startIfNeeded()
        }
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        refreshPermissions()
        updateMonitorState()
    }

    func refreshPermissions() {
        hasAccessibilityPermission = AccessibilitySupport.isTrusted
        hasScreenRecordingPermission = ScreenshotService.hasPermission
        statusText = hasAccessibilityPermission
            ? (isEnabled ? "已启用，移动鼠标到 Dock 应用图标" : "已暂停")
            : "需要辅助功能权限"
        updateMonitorState()
    }

    func requestAccessibilityPermission() {
        AccessibilitySupport.requestTrustPrompt()
        AccessibilitySupport.openAccessibilitySettings()
        refreshPermissions()
    }

    func openScreenRecordingSettings() {
        ScreenshotService.requestPermission()
        AccessibilitySupport.openScreenRecordingSettings()
        refreshPermissions()
    }

    private func updateMonitorState() {
        guard didStart else { return }
        if isEnabled, hasAccessibilityPermission {
            monitor.start()
            statusText = "已启用，移动鼠标到 Dock 应用图标"
        } else {
            monitor.stop()
            panelController.hide()
            statusText = hasAccessibilityPermission ? "已暂停" : "需要辅助功能权限"
        }
    }

    private func dockTargetChanged(_ target: DockTarget?) {
        hoverTask?.cancel()

        if let target {
            currentTarget = target
            hideTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(240))
                guard !Task.isCancelled, self?.currentTarget == target else { return }
                await self?.showPreview(for: target)
            }
        } else {
            currentTarget = nil
            scheduleHide()
        }
    }

    private func showPreview(for target: DockTarget) async {
        let windows = windowService.windows(for: target.processIdentifier)
        guard !windows.isEmpty else {
            panelController.hide()
            return
        }

        // Reuse the most recent successful capture immediately. This is what
        // lets minimized windows keep a useful preview even though WindowServer
        // may no longer expose their live pixels to ScreenCaptureKit.
        for preview in windows {
            preview.image = cachedThumbnail(
                for: preview,
                processIdentifier: target.processIdentifier
            )
        }

        panelController.show(
            target: target,
            windows: windows,
            onSelect: { [weak self] preview in
                guard let self else { return }
                self.windowService.activate(preview, processIdentifier: target.processIdentifier)
                self.panelController.hide()
            },
            onClose: { [weak self] preview in
                guard let self, self.windowService.close(preview) else { return }
                self.panelController.removeWindow(id: preview.id)

                // Some apps close asynchronously (or present a save dialog).
                // Re-read Accessibility state so the preview stays accurate.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(220))
                    guard let self, self.panelController.isVisible else { return }
                    await self.showPreview(for: target)
                }
            }
        )

        guard ScreenshotService.hasPermission else {
            hasScreenRecordingPermission = false
            ScreenshotService.requestPermission()
            return
        }

        hasScreenRecordingPermission = true
        for preview in windows where !preview.isMinimized {
            guard let captureWindowID = preview.captureWindowID else { continue }
            Task { @MainActor [weak self] in
                guard let image = await ScreenshotService.capture(
                    windowID: captureWindowID,
                    sourceSize: preview.frame.size
                ) else { return }

                preview.image = image
                self?.storeThumbnail(
                    image,
                    for: preview,
                    processIdentifier: target.processIdentifier
                )
            }
        }
    }

    private func cachedThumbnail(
        for preview: WindowPreview,
        processIdentifier: pid_t
    ) -> NSImage? {
        pruneThumbnailCache()

        let candidates = thumbnailCache.filter { $0.processIdentifier == processIdentifier }
        if let windowID = preview.captureWindowID,
           let exact = candidates.first(where: { $0.windowID == windowID }) {
            return exact.image
        }

        guard let closest = candidates.min(by: {
            thumbnailMatchScore($0, preview: preview) < thumbnailMatchScore($1, preview: preview)
        }) else { return nil }

        let frameDistance = thumbnailFrameDistance(closest.frame, preview.frame)
        // Titles generally remain stable while a window is minimized. If an
        // app changes the title, only accept an almost identical saved frame
        // to avoid borrowing a sibling window's thumbnail.
        if closest.title == preview.title {
            return frameDistance <= 240 ? closest.image : nil
        }
        return frameDistance <= 12 ? closest.image : nil
    }

    private func storeThumbnail(
        _ image: NSImage,
        for preview: WindowPreview,
        processIdentifier: pid_t
    ) {
        let entry = CachedWindowThumbnail(
            processIdentifier: processIdentifier,
            windowID: preview.captureWindowID,
            title: preview.title,
            frame: preview.frame,
            image: image,
            updatedAt: Date()
        )

        if let index = thumbnailCache.firstIndex(where: { cached in
            guard cached.processIdentifier == processIdentifier else { return false }
            if let windowID = preview.captureWindowID, cached.windowID == windowID {
                return true
            }
            return cached.title == preview.title
                && thumbnailFrameDistance(cached.frame, preview.frame) <= 12
        }) {
            thumbnailCache[index] = entry
        } else {
            thumbnailCache.append(entry)
        }

        pruneThumbnailCache()
        if thumbnailCache.count > 80 {
            thumbnailCache.sort { $0.updatedAt > $1.updatedAt }
            thumbnailCache.removeLast(thumbnailCache.count - 80)
        }
    }

    private func pruneThumbnailCache() {
        let expiration = Date().addingTimeInterval(-30 * 60)
        thumbnailCache.removeAll { $0.updatedAt < expiration }
    }

    private func thumbnailMatchScore(
        _ cached: CachedWindowThumbnail,
        preview: WindowPreview
    ) -> CGFloat {
        (cached.title == preview.title ? 0 : 400)
            + thumbnailFrameDistance(cached.frame, preview.frame)
    }

    private func thumbnailFrameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    private func panelPointerPresenceChanged(_ inside: Bool) {
        isPointerInsidePanel = inside
        if inside {
            hideTask?.cancel()
        } else if currentTarget == nil {
            scheduleHide()
        }
    }

    private func dockContextMenuRequested() {
        hoverTask?.cancel()
        hideTask?.cancel()
        currentTarget = nil
        isPointerInsidePanel = false
        panelController.hide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, self?.currentTarget == nil, self?.isPointerInsidePanel == false else { return }
            self?.panelController.hide()
        }
    }
}

private struct CachedWindowThumbnail {
    let processIdentifier: pid_t
    let windowID: CGWindowID?
    let title: String
    let frame: CGRect
    let image: NSImage
    let updatedAt: Date
}

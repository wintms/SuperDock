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

        panelController.show(target: target, windows: windows) { [weak self] preview in
            guard let self else { return }
            self.windowService.activate(preview, processIdentifier: target.processIdentifier)
            self.panelController.hide()
        }

        guard ScreenshotService.hasPermission else {
            hasScreenRecordingPermission = false
            ScreenshotService.requestPermission()
            return
        }

        hasScreenRecordingPermission = true
        for preview in windows where !preview.isMinimized {
            guard let captureWindowID = preview.captureWindowID else { continue }
            Task { @MainActor in
                preview.image = await ScreenshotService.capture(
                    windowID: captureWindowID,
                    sourceSize: preview.frame.size
                )
            }
        }
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

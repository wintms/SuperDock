import SwiftUI
import AppKit

@main
struct SuperDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("SuperDock", image: "MenuBarIcon") {
            MenuContentView(model: model)
                .frame(width: 300)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct MenuContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SuperDock")
                        .font(.headline)
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enable", isOn: $model.isEnabled)
                    .labelsHidden()
            }

            if !model.hasAccessibilityPermission {
                Label("需要“辅助功能”权限来识别 Dock 和激活窗口。", systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("授予辅助功能权限") {
                    model.requestAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)
            }

            if !model.hasScreenRecordingPermission {
                Label("需要“屏幕录制”权限来生成窗口缩略图。", systemImage: "rectangle.dashed.badge.record")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("打开屏幕录制设置") {
                    model.openScreenRecordingSettings()
                }
            }

            Divider()

            HStack {
                Button("重新检查权限") {
                    model.refreshPermissions()
                }
                Spacer()
                Button("退出") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(16)
        .task {
            model.startIfNeeded()
        }
    }
}

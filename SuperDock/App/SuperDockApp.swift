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
                Toggle("menu.enable", isOn: $model.isEnabled)
                    .labelsHidden()
            }

            if !model.hasAccessibilityPermission {
                Label("permission.accessibility.description", systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("permission.accessibility.action") {
                    model.requestAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)
            }

            if !model.hasScreenRecordingPermission {
                Label("permission.screenRecording.description", systemImage: "rectangle.dashed.badge.record")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("permission.screenRecording.action") {
                    model.openScreenRecordingSettings()
                }
            }

            Divider()

            HStack {
                Button("permission.recheck") {
                    model.refreshPermissions()
                }
                Spacer()
                Button("common.quit") {
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

import SwiftUI
import AppKit
import CoreGraphics

@MainActor
final class PreviewPanelController: NSObject, NSWindowDelegate {
    var onPointerPresenceChanged: ((Bool) -> Void)?

    private let panel: HoverPanel
    private let model = PreviewPanelModel()

    override init() {
        panel = HoverPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Native Dock/context menus use a higher window level and must always
        // appear unobstructed above the preview panel.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self

        let root = WindowPreviewPanelView(
            model: model,
            onPointerPresenceChanged: { [weak self] inside in
                self?.onPointerPresenceChanged?(inside)
            }
        )
        panel.contentView = NSHostingView(rootView: root)
    }

    func show(
        target: DockTarget,
        windows: [WindowPreview],
        onSelect: @escaping (WindowPreview) -> Void,
        onClose: @escaping (WindowPreview) -> Void
    ) {
        model.applicationName = target.applicationName
        model.windows = windows
        model.onSelect = onSelect
        model.onClose = onClose

        let itemFrame = cocoaFrame(fromAccessibilityFrame: target.dockItemFrame)
        // Include breathing room for the card's hover scale and shadow so the
        // first/last card is not clipped by the horizontal ScrollView.
        let width = min(820, max(280, CGFloat(windows.count) * 236 + 40))
        let height: CGFloat = 226
        let origin = panelOrigin(size: CGSize(width: width, height: height), dockItemFrame: itemFrame)
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
    }

    var isVisible: Bool { panel.isVisible }

    func removeWindow(id: CGWindowID) {
        model.windows.removeAll { $0.id == id }
        if model.windows.isEmpty {
            hide()
        }
    }

    func hide() {
        panel.orderOut(nil)
        model.windows = []
    }

    private func cocoaFrame(fromAccessibilityFrame frame: CGRect) -> CGRect {
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            let displayBounds = CGDisplayBounds(displayID)
            if displayBounds.intersects(frame) || displayBounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                return CGRect(
                    x: screen.frame.minX + frame.minX - displayBounds.minX,
                    y: screen.frame.maxY - (frame.maxY - displayBounds.minY),
                    width: frame.width,
                    height: frame.height
                )
            }
        }

        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    private func panelOrigin(size: CGSize, dockItemFrame: CGRect) -> CGPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(dockItemFrame) }) ?? NSScreen.main
        guard let screen else { return .zero }
        let visible = screen.visibleFrame
        let gap: CGFloat = 10

        let bottomDistance = abs(dockItemFrame.minY - screen.frame.minY)
        let leftDistance = abs(dockItemFrame.minX - screen.frame.minX)
        let rightDistance = abs(screen.frame.maxX - dockItemFrame.maxX)

        var origin: CGPoint
        if leftDistance < bottomDistance, leftDistance <= rightDistance {
            origin = CGPoint(x: dockItemFrame.maxX + gap, y: dockItemFrame.midY - size.height / 2)
        } else if rightDistance < bottomDistance {
            origin = CGPoint(x: dockItemFrame.minX - size.width - gap, y: dockItemFrame.midY - size.height / 2)
        } else {
            origin = CGPoint(x: dockItemFrame.midX - size.width / 2, y: dockItemFrame.maxY + gap)
        }

        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        origin.y = min(max(origin.y, visible.minY + 6), visible.maxY - size.height - 6)
        return origin
    }
}

private final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PreviewPanelModel: ObservableObject {
    @Published var applicationName = ""
    @Published var windows: [WindowPreview] = []
    var onSelect: ((WindowPreview) -> Void)?
    var onClose: ((WindowPreview) -> Void)?
}

private struct WindowPreviewPanelView: View {
    @ObservedObject var model: PreviewPanelModel
    let onPointerPresenceChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.applicationName)
                    .font(.headline)
                Spacer()
                Text(windowCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if model.windows.isEmpty {
                ContentUnavailableView("preview.empty", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(model.windows) { preview in
                            WindowCard(
                                preview: preview,
                                onSelect: { model.onSelect?(preview) },
                                onClose: { model.onClose?(preview) }
                            )
                        }
                    }
                    // Hovered cards move up, scale, and cast a shadow. Keep all
                    // of that inside the ScrollView's clipping boundary.
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .contentMargins(0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(PreviewPanelSurface())
        .onHover(perform: onPointerPresenceChanged)
    }

    private var windowCountText: String {
        let count = model.windows.count
        let format = count == 1
            ? String(localized: "preview.windowCount.one")
            : String(localized: "preview.windowCount.other")
        return String.localizedStringWithFormat(format, Int64(count))
    }
}

/// Uses the system Liquid Glass renderer on macOS 26 and newer while keeping
/// the existing material appearance for users on macOS 14 and 15.
private struct PreviewPanelSurface: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular
                        .tint(.white.opacity(0.06)),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
                }
        } else {
            content
                .background(.ultraThickMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
                }
        }
    }
}

private struct WindowCard: View {
    @ObservedObject var preview: WindowPreview
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onSelect) {
                cardContent
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isHovering, preview.closeButton != nil {
                Button(action: onClose) {
                    ZStack {
                        Circle()
                            .fill(.red.opacity(0.86))
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .offset(x: 12, y: 12)
                .transition(.scale(scale: 0.82).combined(with: .opacity))
                .help(String(localized: "window.close"))
                .accessibilityLabel(
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "accessibility.closeWindow"),
                            preview.title
                        )
                    )
                )
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.24))

                if let image = preview.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: preview.isMinimized ? "macwindow.badge.minus" : "macwindow")
                            .font(.system(size: 30))
                        if preview.isMinimized {
                            Text("preview.minimized")
                                .font(.caption2)
                        } else {
                            Text("preview.unavailable")
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 212, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack(spacing: 5) {
                if preview.isMinimized {
                    Image(systemName: "minus.square")
                }
                Text(preview.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.primary)
            .frame(width: 212, alignment: .leading)
        }
        .frame(width: 212, alignment: .leading)
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.white.opacity(isHovering ? 0.16 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(isHovering ? 0.28 : 0), lineWidth: 0.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(
            color: .black.opacity(isHovering ? 0.16 : 0),
            radius: isHovering ? 8 : 0,
            y: isHovering ? 4 : 0
        )
        .scaleEffect(isHovering ? 1.015 : 1)
        .offset(y: isHovering ? -2 : 0)
    }
}

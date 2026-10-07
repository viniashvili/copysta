import AppKit
import SwiftUI

// Shared state between PopupPanel (key events) and HistoryView (rendering).
final class PopupKeyState: ObservableObject {
    @Published var selectedIndex: Int = 0
}

final class PopupPanel: NSPanel {
    static let size = NSSize(width: 300, height: 380)
    /// Vertical gap between the caret's bottom edge and the popup's top edge.
    static let gap: CGFloat = 6
    /// Distance from the popup's left edge to row text (list padding + row padding),
    /// so the text lines up under the caret.
    static let textInset: CGFloat = 16

    private let service: HistoryService
    private let watcher: ClipboardWatcher
    private let keyState = PopupKeyState()

    init(service: HistoryService, watcher: ClipboardWatcher) {
        self.service = service
        self.watcher = watcher
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildContentView()
        setupDismiss()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Keyboard navigation

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // ↓
            let max = service.entries.count - 1
            if keyState.selectedIndex < max { keyState.selectedIndex += 1 }
        case 126: // ↑
            if keyState.selectedIndex > 0 { keyState.selectedIndex -= 1 }
        case 36, 76: // Return / numpad Enter
            let entries = service.entries
            guard !entries.isEmpty else { return }
            let idx = min(keyState.selectedIndex, entries.count - 1)
            copyAndPaste(entries[idx])
        case 53: // Escape
            orderOut(nil)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Show / position

    func showNear(_ point: NSPoint) {
        keyState.selectedIndex = 0

        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
                     ?? NSScreen.main!
        let visible = screen.visibleFrame
        let sz = frame.size

        // point.y is the caret BOTTOM edge (AppKit, Y up).
        // Preferred: popup directly below the caret, row text aligned with the caret x.
        var origin = NSPoint(x: point.x - Self.textInset, y: point.y - sz.height - Self.gap)

        // If popup goes off the bottom of the screen, show it above instead.
        // Estimate caret height as 20 px to find its top edge.
        if origin.y < visible.minY {
            origin.y = point.y + 20 + Self.gap
        }
        // Clamp: don't go above top of screen.
        if origin.y + sz.height > visible.maxY {
            origin.y = visible.maxY - sz.height
        }
        // Clamp horizontally.
        if origin.x + sz.width > visible.maxX { origin.x = visible.maxX - sz.width }
        if origin.x < visible.minX { origin.x = visible.minX }

        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
    }

    // MARK: - Private


    private func buildContentView() {
        let bounds = NSRect(origin: .zero, size: Self.size)

        // Rounded, clipped container holding the blur layer and the SwiftUI content as siblings.
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor

        let fx = ClearBlurView(frame: bounds)
        fx.material = .fullScreenUI
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.autoresizingMask = [.width, .height]
        container.addSubview(fx)

        let panel = self
        let rootView = HistoryView(service: service, keyState: keyState) { entry in
            panel.copyAndPaste(entry)
        }
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        contentView = container
    }

    private func setupDismiss() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in self?.orderOut(nil) }
    }

    private func copyAndPaste(_ entry: Entry) {
        // Write to clipboard.
        watcher.suppressNext()
        let pb = NSPasteboard.general
        pb.clearContents()
        switch entry.kind {
        case .text:
            if let t = entry.text { pb.setString(t, forType: .string) }
        case .image:
            if let path = entry.imagePath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                pb.setData(data, forType: .png)
            }
        }

        // Hide the panel so the previously focused window regains key status.
        orderOut(nil)

        // Simulate ⌘V into the frontmost app after a brief yield.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let src = CGEventSource(stateID: .hidSystemState) else { return }
            let kd = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
            let ku = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            kd?.flags = .maskCommand
            ku?.flags = .maskCommand
            kd?.post(tap: .cgSessionEventTap)
            ku?.post(tap: .cgSessionEventTap)
        }
    }
}

/// Frosted glass with a lighter blur and a thinner milky tint, so text behind stays faintly visible.
/// NSVisualEffectView stacks a `backdrop` layer (the blur) under a `fill` layer (~48 % white);
/// fading only `fill` makes the panel more see-through without letting the unblurred
/// background bleed in. If AppKit ever renames these layers, this silently does nothing.
final class ClearBlurView: NSVisualEffectView {
    /// Opacity of the white tint over the blur: 1 = stock look, 0 = pure blur.
    var tintOpacity: Float = 0.35
    /// Gaussian blur radius of what's behind (stock is 30, which smears small text away).
    var blurRadius: CGFloat = 12

    // AppKit (re)builds the material sublayers when it updates the view's layer,
    // so re-apply after every update rather than only on layout.
    override func updateLayer() {
        super.updateLayer()
        thinTint()
    }

    override func layout() {
        super.layout()
        thinTint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        thinTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        thinTint()
    }

    private func thinTint() {
        for material in layer?.sublayers ?? [] {
            for sub in material.sublayers ?? [] {
                switch sub.name {
                case "fill":
                    sub.opacity = tintOpacity
                case "backdrop":
                    sub.setValue(blurRadius, forKeyPath: "filters.gaussianBlur.inputRadius")
                default:
                    break
                }
            }
        }
    }
}

import AppKit
import SwiftUI

// Shared state between PopupPanel (key events) and HistoryView (rendering).
final class PopupKeyState: ObservableObject {
    @Published var selectedIndex: Int = 0
    /// True for a split second while the chosen row blinks before pasting.
    @Published var isFlashing = false
}

final class PopupPanel: NSPanel {
    static let size = NSSize(width: 300, height: 380)
    /// Vertical gap between the caret's bottom edge and the popup's top edge.
    static let gap: CGFloat = 6
    /// Distance from the popup's left edge to row text (list padding + row padding),
    /// so the text lines up under the caret.
    static let textInset: CGFloat = 16
    /// Transparent margin around the card where its drop shadow is drawn. The shadow lives
    /// on the card's layer (not the window) so it scales with the open/close animation.
    static let shadowMargin: CGFloat = 32

    private let service: HistoryService
    private let watcher: ClipboardWatcher
    private let keyState = PopupKeyState()
    /// The visible popup (rounded, blurred, with shadow) inside the slightly larger window.
    private let card = NSView(frame: NSRect(origin: NSPoint(x: shadowMargin, y: shadowMargin), size: size))
    /// Bumped on every show, so a fade-out that finishes after a re-show doesn't hide the panel.
    private var showGeneration = 0
    private(set) var isClosing = false

    private static let openDuration: CFTimeInterval = 0.24
    private static let closeDuration: CFTimeInterval = 0.16
    /// Scale the popup grows from / shrinks to — effectively a dot at the caret.
    private static let collapsedScale: CGFloat = 0.04
    /// Where the caret sits in the card's own coordinates; the grow/shrink anchor.
    private var caretAnchor = CGPoint.zero

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(service: HistoryService, watcher: ClipboardWatcher) {
        self.service = service
        self.watcher = watcher
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.size.width + 2 * Self.shadowMargin,
                                                            height: Self.size.height + 2 * Self.shadowMargin)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
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
            dismiss()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Show / position

    func showNear(_ point: NSPoint) {
        keyState.selectedIndex = 0
        keyState.isFlashing = false

        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
                     ?? NSScreen.main!
        let visible = screen.visibleFrame
        let sz = Self.size

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

        // The caret relative to the popup — the point it grows out of.
        caretAnchor = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        animateIn(to: origin)
    }

    // MARK: - Animations

    /// Grow out of the caret: the content starts as a dot at `caretAnchor` and scales up.
    private func animateIn(to origin: NSPoint) {
        showGeneration += 1
        isClosing = false

        setFrameOrigin(NSPoint(x: origin.x - Self.shadowMargin, y: origin.y - Self.shadowMargin))
        alphaValue = 1
        guard let layer = card.layer, !reduceMotion else {
            fadeWindow(from: 0, to: 1, duration: Self.openDuration)
            makeKeyAndOrderFront(nil)
            return
        }

        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        makeKeyAndOrderFront(nil)

        CATransaction.begin()
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = collapsedTransform()
        grow.toValue = CATransform3DIdentity
        grow.duration = Self.openDuration
        // Fast start, soft landing with a hint of overshoot.
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.04)
        layer.add(grow, forKey: "grow")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.openDuration * 0.5
        layer.add(fade, forKey: "fadeIn")
        CATransaction.commit()
    }

    /// Shrink back into the caret (the reverse of opening), then remove the panel.
    func dismiss(completion: (() -> Void)? = nil) {
        guard isVisible, !isClosing else {
            completion?()
            return
        }
        isClosing = true
        let generation = showGeneration
        let finish = { [weak self] in
            guard let self, generation == self.showGeneration else { return }
            self.orderOut(nil)
            self.card.layer?.removeAllAnimations()
            self.card.layer?.transform = CATransform3DIdentity
            self.card.layer?.opacity = 1
            self.alphaValue = 1
            self.isClosing = false
            completion?()
        }

        guard let layer = card.layer, !reduceMotion else {
            fadeWindow(from: 1, to: 0, duration: Self.closeDuration, completion: finish)
            return
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock(finish)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = CATransform3DIdentity
        shrink.toValue = collapsedTransform()
        shrink.duration = Self.closeDuration
        shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.6)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: "shrink")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + Self.closeDuration * 0.4
        fade.duration = Self.closeDuration * 0.6
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "fadeOut")
        CATransaction.commit()
    }

    /// Scale about the caret anchor: translate the anchor to the origin, scale, move back.
    /// (A view's backing layer has its anchorPoint at the bottom-left, so we can't just
    /// change anchorPoint — AppKit owns that.)
    private func collapsedTransform() -> CATransform3D {
        let a = caretAnchor
        var t = CATransform3DMakeTranslation(a.x, a.y, 0)
        t = CATransform3DScale(t, Self.collapsedScale, Self.collapsedScale, 1)
        return CATransform3DTranslate(t, -a.x, -a.y, 0)
    }

    private func fadeWindow(from: CGFloat, to: CGFloat, duration: CFTimeInterval,
                            completion: (() -> Void)? = nil) {
        alphaValue = from
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            animator().alphaValue = to
        }, completionHandler: completion)
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
        // Card = shadow + clipped container. The shadow can't sit on `container` itself
        // because masksToBounds would clip it away.
        card.wantsLayer = true
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.22
        card.layer?.shadowRadius = 16
        card.layer?.shadowOffset = CGSize(width: 0, height: -6)
        card.layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
        card.addSubview(container)

        let root = ShadowMarginView(frame: NSRect(origin: .zero, size: frame.size))
        root.onClickOutsideCard = { [weak self] in self?.dismiss() }
        root.addSubview(card)
        contentView = root
    }

    private func setupDismiss() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in self?.dismiss() }
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

        // Blink the chosen row like a macOS menu item, fade the panel out, then paste
        // into the previously focused app (which regains key status once we're gone).
        keyState.isFlashing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            self?.keyState.isFlashing = false
            self?.dismiss {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { Self.postPaste() }
            }
        }
    }

    private static func postPaste() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let kd = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let ku = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        kd?.flags = .maskCommand
        ku?.flags = .maskCommand
        kd?.post(tap: .cgSessionEventTap)
        ku?.post(tap: .cgSessionEventTap)
    }
}

/// The window's root view. Its margin only holds the card's shadow, so a click there
/// counts as a click outside the popup.
private final class ShadowMarginView: NSView {
    var onClickOutsideCard: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClickOutsideCard?()
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

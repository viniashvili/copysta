import AppKit

final class ClipboardWatcher {
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var ignoreCount = 0
    private let onItem: (ClipItem) -> Void

    // Types that indicate a password-manager or transient entry — skip these.
    private static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "de.petermaurer.TransientPasteboardType",
        "com.agilebits.onepassword-pasteboard-data",
        "com.lastpass.LastPassSecretPasteboardType",
    ]

    init(onItem: @escaping (ClipItem) -> Void) {
        self.onItem = onItem
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Call before writing to the clipboard so the watcher skips that change.
    func suppressNext() {
        ignoreCount += 1
    }

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if ignoreCount > 0 {
            ignoreCount -= 1
            return
        }

        // Skip concealed / transient items.
        let types = (pb.types ?? []).map { $0.rawValue }
        for t in types where Self.concealedTypes.contains(t) { return }

        if let text = pb.string(forType: .string), !text.isEmpty {
            onItem(ClipItem(kind: .text, text: text, imageData: nil))
        } else if let data = pb.data(forType: .png) {
            onItem(ClipItem(kind: .image, text: nil, imageData: data))
        } else if let data = pb.data(forType: .tiff) {
            // Convert TIFF to PNG for uniform storage.
            if let image = NSImage(data: data),
               let tiffRep = image.representations.first as? NSBitmapImageRep,
               let png = tiffRep.representation(using: .png, properties: [:]) {
                onItem(ClipItem(kind: .image, text: nil, imageData: png))
            }
        }
    }
}

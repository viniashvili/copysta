import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var historyService: HistoryService!
    private var clipboardWatcher: ClipboardWatcher!
    private var panel: PopupPanel!
    private var hotkey: HotkeyManager!
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let dataDir = makeDataDir()
        let dbPath  = (dataDir as NSString).appendingPathComponent("history.db")

        do {
            store = try Store(dbPath: dbPath, dataDir: dataDir)
        } catch {
            fatalError("Cannot open database: \(error)")
        }

        historyService   = HistoryService(store: store)
        clipboardWatcher = ClipboardWatcher { [weak self] item in
            self?.historyService.add(item)
        }
        panel = PopupPanel(service: historyService, watcher: clipboardWatcher)

        clipboardWatcher.start()
        setupStatusItem()
        setupHotkey()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Template image so macOS tints it for light/dark menu bars. Falls back to an SF Symbol
        // under `swift run`, where there's no app bundle to load resources from.
        let icon = Bundle.main.image(forResource: "MenuBarIcon")
                   ?? NSImage(systemSymbolName: "clipboard", accessibilityDescription: "copysta")
        icon?.isTemplate = true
        statusItem?.button?.image = icon

        let menu = NSMenu()
        let show = NSMenuItem(title: "Show History", action: #selector(showPanel), keyEquivalent: "v")
        show.keyEquivalentModifierMask = [.command, .shift]
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear History…", action: #selector(confirmClear), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit copysta",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func showPanel() {
        showPanelNearCaret()
    }

    @objc private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "All copied text and images will be deleted. This can’t be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            historyService.clear()
        }
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkey = HotkeyManager()
        hotkey.register { [weak self] in
            guard let self else { return }
            if self.panel.isVisible && !self.panel.isClosing {
                self.panel.dismiss()
            } else {
                self.showPanelNearCaret()
            }
        }

        // Chromium/Electron apps build their AX tree lazily; switch it on as soon as
        // an app becomes frontmost so the caret is available by the time ⌘⇧V is pressed.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                enableAccessibilityTree(for: app)
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            enableAccessibilityTree(for: app)
        }
    }

    private func showPanelNearCaret() {
        // Read the caret BEFORE the panel takes key status.
        let loc = locateCaret()
        if loc.isPrecise {
            panel.showNear(loc.point)
            return
        }
        // The AX tree may have only just been enabled; give it a moment and retry once.
        if let app = NSWorkspace.shared.frontmostApplication {
            enableAccessibilityTree(for: app)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.panel.showNear(locateCaret().point)
        }
    }

    // MARK: - Helpers

    private func makeDataDir() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                       .first?.path ?? NSHomeDirectory()
        let dir  = (base as NSString).appendingPathComponent("copysta")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}

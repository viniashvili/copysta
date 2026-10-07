import AppKit
import ApplicationServices

/// Where to anchor the popup. `point` is in AppKit coords (Y up) and means
/// "the popup's top-left corner goes just below this point".
struct CaretLocation {
    let point: NSPoint
    let source: String   // "caret", "char", "field", "window", "screen" — for diagnostics
    var isPrecise: Bool { source != "window" && source != "screen" }
}

// Chromium browsers only build their AX tree when AXEnhancedUserInterface is set.
private let chromiumBundleIDs: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
    "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
]

/// Asks Electron (AXManualAccessibility) and Chromium (AXEnhancedUserInterface) apps
/// to expose their accessibility tree, without which caret bounds are unavailable.
func enableAccessibilityTree(for app: NSRunningApplication) {
    guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    // Electron apps (VS Code, Slack…) need this too — AXManualAccessibility alone isn't enough.
    if isChromiumBased(app) {
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
}

private func isChromiumBased(_ app: NSRunningApplication) -> Bool {
    if let bid = app.bundleIdentifier, chromiumBundleIDs.contains(bid) { return true }
    guard let url = app.bundleURL else { return false }
    let electron = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
    return FileManager.default.fileExists(atPath: electron.path)
}

func locateCaret() -> CaretLocation {
    let app = NSWorkspace.shared.frontmostApplication
    let bid = app?.bundleIdentifier ?? "?"

    if !AXIsProcessTrusted() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        let loc = screenFallback()
        caretLog("\(bid) untrusted -> \(loc.source)")
        return loc
    }

    guard let focused = focusedElement(app: app) else {
        let loc = windowFallback(app: app) ?? screenFallback()
        caretLog("\(bid) no focused element -> \(loc.source) \(loc.point)")
        return loc
    }

    // 1. Exact caret rect for the current selection.
    var rangeRef: CFTypeRef?
    var range = CFRange()
    if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
       let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID(),
       AXValueGetValue(unsafeBitCast(rangeRef, to: AXValue.self), .cfRange, &range) {

        if let r = bounds(of: focused, range: range) {
            return logged(bid, CaretLocation(point: NSPoint(x: r.minX, y: r.minY), source: "caret"))
        }
        // 2. Empty selections often report no bounds; measure the adjacent character instead.
        if range.length == 0 {
            if range.location > 0,
               let r = bounds(of: focused, range: CFRange(location: range.location - 1, length: 1)) {
                return logged(bid, CaretLocation(point: NSPoint(x: r.maxX, y: r.minY), source: "char"))
            }
            if let r = bounds(of: focused, range: CFRange(location: range.location, length: 1)) {
                return logged(bid, CaretLocation(point: NSPoint(x: r.minX, y: r.minY), source: "char"))
            }
        }
    }

    // 3. Chromium/WebKit text-marker API — how Chrome exposes the caret in web content.
    if let r = textMarkerCaret(of: focused) {
        return logged(bid, CaretLocation(point: NSPoint(x: r.minX, y: r.minY), source: "marker"))
    }

    // 4. Small focused element (single-line field, or VS Code's hidden textarea that
    //    tracks the cursor): anchor below it.
    if let f = frame(of: focused), f.height < 120, f.width > 0 {
        // Chrome's address bar reports text + font but no caret rect: measure the text
        // before the caret to find its x position.
        if let w = textWidthBeforeCaret(in: focused, caretIndex: range.location) {
            let x = min(f.minX + w, f.maxX)
            return logged(bid, CaretLocation(point: NSPoint(x: x, y: f.minY), source: "measured"),
                          role: role(of: focused))
        }
        return logged(bid, CaretLocation(point: NSPoint(x: f.minX, y: f.minY), source: "field"),
                      role: role(of: focused))
    }

    let loc = windowFallback(app: app) ?? screenFallback()
    return logged(bid, loc, role: role(of: focused))
}

// MARK: - AX helpers

private func focusedElement(app: NSRunningApplication?) -> AXUIElement? {
    var ref: CFTypeRef?
    if let app {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
           let ref { return unsafeBitCast(ref, to: AXUIElement.self) }
    }
    if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                     kAXFocusedUIElementAttribute as CFString, &ref) == .success,
       let ref { return unsafeBitCast(ref, to: AXUIElement.self) }
    // Electron apps (VS Code) expose a focused text area deep in the tree but never report it
    // via AXFocusedUIElement, so search the focused window for it.
    guard let app else { return nil }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref) == .success,
          let ref else { return nil }
    return findFocusedTextElement(in: unsafeBitCast(ref, to: AXUIElement.self), depth: 0)
}

private func findFocusedTextElement(in el: AXUIElement, depth: Int) -> AXUIElement? {
    guard depth < 45 else { return nil }
    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXFocusedAttribute as CFString, &ref) == .success,
       (ref as? Bool) == true, ["AXTextArea", "AXTextField"].contains(role(of: el)) {
        return el
    }
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
          let kids = ref as? [AXUIElement] else { return nil }
    for kid in kids {
        if let found = findFocusedTextElement(in: kid, depth: depth + 1) { return found }
    }
    return nil
}

/// Bounds of a text range, converted to AppKit coords. Rejects the empty/garbage rects
/// some apps (Chrome) return alongside a "success" status.
private func bounds(of el: AXUIElement, range: CFRange) -> NSRect? {
    var r = range
    guard let rangeValue = AXValueCreate(.cfRange, &r) else { return nil }
    var ref: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
        el, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &ref
    ) == .success, let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(unsafeBitCast(ref, to: AXValue.self), .cgRect, &rect),
          rect.height > 0, rect.height < 200 else { return nil }
    let appKit = toAppKit(rect)
    guard onSomeScreen(appKit) else { return nil }
    return appKit
}

private func textMarkerCaret(of el: AXUIElement) -> NSRect? {
    var markerRange: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
          let markerRange else { return nil }
    var ref: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
        el, "AXBoundsForTextMarkerRange" as CFString, markerRange, &ref
    ) == .success, let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(unsafeBitCast(ref, to: AXValue.self), .cgRect, &rect),
          rect.height > 0, rect.height < 200 else { return nil }
    let appKit = toAppKit(rect)
    return onSomeScreen(appKit) ? appKit : nil
}

/// Width of the field's text up to `caretIndex`, using the font the app reports via AX.
private func textWidthBeforeCaret(in el: AXUIElement, caretIndex: Int) -> CGFloat? {
    var ref: CFTypeRef?
    guard caretIndex > 0, role(of: el) == "AXTextField",
          AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref) == .success,
          let text = ref as? String else { return nil }
    let utf16 = Array(text.utf16)
    guard caretIndex <= utf16.count,
          let prefix = String(utf16CodeUnits: utf16, count: caretIndex) as String? else { return nil }

    // Ask for the font of the first character; fall back to the system font at 14 pt.
    var size: CGFloat = 14
    var fontName: String?
    var r = CFRange(location: 0, length: 1)
    if let rv = AXValueCreate(.cfRange, &r),
       AXUIElementCopyParameterizedAttributeValue(
           el, kAXAttributedStringForRangeParameterizedAttribute as CFString, rv, &ref) == .success,
       let attr = ref as? NSAttributedString, attr.length > 0,
       let info = attr.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any] {
        if let s = info["AXFontSize"] as? CGFloat { size = s }
        fontName = info["AXFontName"] as? String
    }
    let font = fontName.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
    return (prefix as NSString).size(withAttributes: [.font: font]).width
}

private func role(of el: AXUIElement) -> String {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref)
    return (ref as? String) ?? "?"
}

private func frame(of el: AXUIElement) -> NSRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posRef, let sizeRef else { return nil }
    var pos = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &pos),
          AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size),
          size.height > 0 else { return nil }
    let appKit = toAppKit(CGRect(origin: pos, size: size))
    return onSomeScreen(appKit) ? appKit : nil
}

// MARK: - Fallbacks

/// Popup centered inside the frontmost app's focused window.
private func windowFallback(app: NSRunningApplication?) -> CaretLocation? {
    guard let app else { return nil }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref) == .success,
          let ref, let f = frame(of: unsafeBitCast(ref, to: AXUIElement.self)) else { return nil }
    return CaretLocation(point: centeredAnchor(in: f), source: "window")
}

/// Popup centered on the screen under the mouse.
private func screenFallback() -> CaretLocation {
    let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                 ?? NSScreen.main ?? NSScreen.screens[0]
    return CaretLocation(point: centeredAnchor(in: screen.visibleFrame), source: "screen")
}

/// Anchor such that PopupPanel.showNear() (which hangs the popup below the point)
/// ends up centered in `rect`.
private func centeredAnchor(in rect: NSRect) -> NSPoint {
    let size = PopupPanel.size
    return NSPoint(x: rect.midX - size.width / 2 + PopupPanel.textInset,
                   y: rect.midY + size.height / 2 + PopupPanel.gap)
}

// MARK: - Coordinates

/// Quartz (origin top-left of primary screen, Y down) → AppKit (origin bottom-left, Y up).
private func toAppKit(_ r: CGRect) -> NSRect {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
}

private func onSomeScreen(_ r: NSRect) -> Bool {
    NSScreen.screens.contains { $0.frame.insetBy(dx: -2, dy: -2).intersects(r) }
}

// MARK: - Diagnostics (no clipboard content is ever logged)

private func logged(_ bid: String, _ loc: CaretLocation, role: String = "") -> CaretLocation {
    caretLog("\(bid) \(role) -> \(loc.source) \(loc.point)")
    return loc
}

private func caretLog(_ msg: String) {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return }
    let url = base.appendingPathComponent("copysta/caret.log")
    let line = Data("\(Date()) \(msg)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line)
        try? h.close()
    } else {
        try? line.write(to: url)
    }
}

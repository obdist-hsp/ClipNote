import AppKit
import ScreenCaptureKit

/// 範囲キャプチャ → 全ディスプレイに透明オーバーレイ → ドラッグで矩形選択 → ScreenCaptureKit で切り抜き
@MainActor
final class ScreenCapturer {
    private var overlays: [SelectionOverlayWindow] = []
    private var completion: ((NSImage?) -> Void)?

    var isSelecting: Bool { !overlays.isEmpty }

    func beginSelection(completion: @escaping (NSImage?) -> Void) {
        guard !isSelecting else { return }
        guard ensurePermission() else { completion(nil); return }
        self.completion = completion
        for screen in NSScreen.screens {
            let w = SelectionOverlayWindow(screen: screen)
            w.onFinish = { [weak self] rect in self?.finish(rectInScreenCoords: rect) }
            w.onCancel = { [weak self] in self?.cancel() }
            overlays.append(w)
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "画面収録の許可が必要です"
        alert.informativeText = "システム設定 › プライバシーとセキュリティ › 画面収録 で ClipNote を許可してから、もう一度キャプチャしてください。"
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "閉じる")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func teardown() {
        NSCursor.pop()
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }

    private func cancel() {
        teardown()
        completion?(nil); completion = nil
    }

    private func finish(rectInScreenCoords rect: NSRect) {
        teardown()
        let done = completion; completion = nil
        guard rect.width >= 2, rect.height >= 2 else { done?(nil); return }
        Task { @MainActor in
            // オーバーレイが消えるのを待つ
            try? await Task.sleep(nanoseconds: 80_000_000)
            let img = await Self.capture(rect: rect)
            done?(img)
        }
    }

    /// rect: NSScreen 座標系（左下原点、グローバル）
    private static func capture(rect: NSRect) async -> NSImage? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(num.uint32Value)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            // NSScreen(左下原点) → ディスプレイ内ローカル(左上原点, pt)
            let clipped = rect.intersection(screen.frame)
            let localX = clipped.minX - screen.frame.minX
            let localY = screen.frame.maxY - clipped.maxY
            let source = CGRect(x: localX, y: localY, width: clipped.width, height: clipped.height)
            let scale = screen.backingScaleFactor

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = source
            cfg.width = Int(source.width * scale)
            cfg.height = Int(source.height * scale)
            cfg.captureResolution = .best
            cfg.showsCursor = false
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let img = NSImage(cgImage: cg, size: NSSize(width: source.width, height: source.height))
            return img
        } catch {
            NSLog("capture failed: \(error)")
            return nil
        }
    }
}

// MARK: - Overlay

final class SelectionOverlayWindow: NSWindow {
    var onFinish: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let v = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.onFinish = { [weak self] local in
            guard let self else { return }
            let global = NSRect(x: local.minX + self.frame.minX, y: local.minY + self.frame.minY,
                                width: local.width, height: local.height)
            self.onFinish?(global)
        }
        v.onCancel = { [weak self] in self?.onCancel?() }
        contentView = v
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

final class SelectionView: NSView {
    var onFinish: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    private var selection: NSRect? {
        guard let s = start, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil); current = start; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        let r = selection ?? .zero
        start = nil; current = nil
        onFinish?(r)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        guard let sel = selection else {
            drawHint()
            return
        }
        // 選択部分を透明に
        NSColor.clear.setFill()
        sel.fill(using: .copy)
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
        // サイズ表示
        let label = "\(Int(sel.width)) × \(Int(sel.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        var p = NSPoint(x: sel.maxX - size.width - 4, y: sel.minY - size.height - 4)
        if p.y < 0 { p.y = sel.minY + 4 }
        (label as NSString).draw(at: p, withAttributes: attrs)
    }

    private func drawHint() {
        let hint = "ドラッグで範囲を選択　Esc でキャンセル"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let size = (hint as NSString).size(withAttributes: attrs)
        (hint as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 80), withAttributes: attrs)
    }
}

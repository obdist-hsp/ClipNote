import AppKit
import SwiftUI

/// 常時表示の浮動パネル。非アクティブ化しないので他アプリの作業を邪魔しない
final class StickyPanel: NSPanel {
    private static let frameKey = "StickyPanel.frame"

    init<Content: View>(content: Content) {
        let defaultFrame = NSRect(x: 0, y: 0, width: 300, height: 520)
        super.init(contentRect: defaultFrame,
                   styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "ClipNote"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 220, height: 200)
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: content)

        if let saved = UserDefaults.standard.string(forKey: Self.frameKey), !saved.isEmpty {
            setFrame(NSRectFromString(saved), display: false)
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            setFrame(NSRect(x: vf.maxX - defaultFrame.width - 16, y: vf.maxY - defaultFrame.height - 16,
                            width: defaultFrame.width, height: defaultFrame.height), display: false)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(persistFrame), name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(persistFrame), name: NSWindow.didEndLiveResizeNotification, object: self)
    }

    /// 保存位置が現在のどの画面にも十分に載っていなければ、メイン画面の右上へ移す
    func ensureOnScreen() {
        let onSomeScreen = NSScreen.screens.contains { screen in
            let inter = screen.visibleFrame.intersection(frame)
            return !inter.isNull && inter.width >= 120 && inter.height >= 80
        }
        guard !onSomeScreen, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let w = min(frame.width, vf.width - 32), h = min(frame.height, vf.height - 32)
        setFrame(NSRect(x: vf.maxX - w - 16, y: vf.maxY - h - 16, width: w, height: h), display: true)
        persistFrame()
    }

    @objc private func persistFrame() {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
    }
}

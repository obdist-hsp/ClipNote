import AppKit
import SwiftUI
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: HistoryStore!
    private var watcher: PasteboardWatcher!
    private var ocr: OCRQueue!
    private var capturer = ScreenCapturer()
    private var hotKey: HotKey?
    private var panel: StickyPanel!
    private var preview: PreviewController!
    private var statusItem: NSStatusItem!

    private var pauseMenuItem: NSMenuItem!
    private var panelMenuItem: NSMenuItem!
    private var loginMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
        store = HistoryStore()
        watcher = PasteboardWatcher(store: store)
        ocr = OCRQueue(store: store)

        let actions = ClipActions(
            copy: { [weak self] in self?.copyToPasteboard($0) },
            toggleBookmark: { [weak self] in self?.store.toggleBookmark($0) },
            delete: { [weak self] in self?.store.delete($0) },
            revealInFinder: { [weak self] item in
                guard let url = self?.store.imageURL(for: item) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            copyOCR: { [weak self] item in
                guard let self, let t = item.ocrText, !t.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
                self.watcher.ignoreCurrentChange()
            },
            capture: { [weak self] in self?.startCapture() },
            preview: { [weak self] in self?.preview.show($0) }
        )
        preview = PreviewController(store: store, actions: actions)
        panel = StickyPanel(content: HistoryListView(store: store, actions: actions))
        panel.ensureOnScreen()
        panel.orderFrontRegardless()
        // ディスプレイ構成が変わったら画面内に戻す
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panel.ensureOnScreen() }
        }

        setupStatusItem()
        watcher.start()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            Task { @MainActor in self?.startCapture() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panelMenuItem.title = "パネルを表示" }
        }
        // install.sh から `--enable-login-item` 付きで起動されたらログイン項目に登録する
        if CommandLine.arguments.contains("--enable-login-item") {
            do {
                try SMAppService.mainApp.register()
                NSLog("ClipNote login item registered: status=\(SMAppService.mainApp.status.rawValue)")
            } catch {
                NSLog("ClipNote login item registration failed: \(error)")
            }
            loginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }


    /// Finder / Launchpad でアプリを再度開いたとき（既に起動中）: パネルを見える位置に出す
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    private func showPanel() {
        panel.ensureOnScreen()
        panel.orderFrontRegardless()
        panelMenuItem.title = "パネルを隠す"
    }

    private static func menuBarImage(paused: Bool) -> NSImage? {
        if let named = NSImage(named: "MenuBarIcon") {
            named.isTemplate = true
            named.size = NSSize(width: 18, height: 18)
            named.accessibilityDescription = "ClipNote"
            return named
        }
        let symbol = paused ? "note.text.badge.plus" : "note.text"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: "ClipNote")
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarImage(paused: false)

        let menu = NSMenu()
        panelMenuItem = NSMenuItem(title: "パネルを隠す", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(panelMenuItem)
        let cap = NSMenuItem(title: "範囲キャプチャ", action: #selector(captureAction), keyEquivalent: "2")
        cap.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(cap)
        pauseMenuItem = NSMenuItem(title: "クリップボード監視を一時停止", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(pauseMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "保存フォルダを Finder で開く", action: #selector(openDataFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "ブックマーク以外を全消去…", action: #selector(clearAll), keyEquivalent: ""))
        menu.addItem(.separator())
        loginMenuItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLogin), keyEquivalent: "")
        loginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginMenuItem)
        menu.addItem(NSMenuItem(title: "ClipNote について", action: #selector(about), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? nil : self }
        statusItem.menu = menu
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
            panelMenuItem.title = "パネルを表示"
        } else {
            showPanel()
        }
    }

    @objc private func captureAction() { startCapture() }

    @objc private func togglePause() {
        watcher.setPaused(!watcher.paused)
        pauseMenuItem.title = watcher.paused ? "クリップボード監視を再開" : "クリップボード監視を一時停止"
        statusItem.button?.image = Self.menuBarImage(paused: watcher.paused)
        statusItem.button?.appearsDisabled = watcher.paused
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.baseDir])
    }

    @objc private func clearAll() {
        let a = NSAlert()
        a.messageText = "ブックマーク以外の履歴をすべて削除しますか？"
        a.informativeText = "画像ファイルも削除されます。この操作は取り消せません。"
        a.alertStyle = .warning
        a.addButton(withTitle: "削除")
        a.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            store.clearAllNonBookmarked()
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify("ログイン項目の変更に失敗", "\(error.localizedDescription)\n(.app を /Applications に置くと安定します)")
        }
        loginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func about() {
        let a = NSAlert()
        a.messageText = "ClipNote"
        a.informativeText = """
        クリップボード履歴 + 範囲キャプチャ付箋。
        App Sandbox 有効・ネットワーク権限なしで動作し、データは端末内にのみ保存されます。

        保存先: \(store.baseDir.path)
        レコード数: \(store.totalCount)
        画像合計: \(HistoryListView.bytes(store.totalImageBytes)) / 上限 \(HistoryListView.bytes(HistoryStore.imageCapacityBytes))
        """
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: - Actions

    private func startCapture() {
        capturer.beginSelection { [weak self] image in
            guard let self, let image else { return }
            self.store.addImage(image)
            // クリップボードにも入れる（自分の変更は無視）
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            self.watcher.ignoreCurrentChange()
        }
    }

    private func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .file:
            let urls = (item.text ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            pb.writeObjects(urls)
        case .image:
            if let img = store.loadImage(for: item) { pb.writeObjects([img]) }
        }
        watcher.ignoreCurrentChange()
    }

    private func notify(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

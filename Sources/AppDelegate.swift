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
    private var menuBar: MenuBarBridge!

    private static let captureHotKeyKey = "captureHotKeyEnabled"
    private var captureHotKeyEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.captureHotKeyKey)
    }

    private static let keepOnTopKey = "panelKeepOnTop"
    /// 未設定なら ON（画面先頭に固定）
    private var keepOnTopEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.keepOnTopKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: Self.keepOnTopKey)
    }

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
            revealInFinder: { [weak self] row in
                guard let url = self?.store.imageURL(for: row) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            copyOCR: { [weak self] row in
                guard let self, let t = self.store.item(id: row.id)?.ocrText, !t.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
                self.watcher.ignoreCurrentChange()
            },
            capture: { [weak self] in self?.startCapture() },
            preview: { [weak self] in self?.preview.show($0) }
        )
        preview = PreviewController(store: store, actions: actions)
        panel = StickyPanel(content: HistoryListView(store: store, actions: actions))
        panel.setKeepOnTop(keepOnTopEnabled)
        panel.ensureOnScreen()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panel.ensureOnScreen() }
        }

        watcher.start()
        applyCaptureHotKey()

        if CommandLine.arguments.contains("--enable-login-item") {
            do {
                try SMAppService.mainApp.register()
                NSLog("ClipNote login item registered: status=\(SMAppService.mainApp.status.rawValue)")
            } catch {
                NSLog("ClipNote login item registration failed: \(error)")
            }
        }

        menuBar = MenuBarBridge(baseDir: store.baseDir, snapshot: { [weak self] in
            guard let self else {
                return .init(panelVisible: false, keepOnTop: true, captureHotKey: false, paused: false, loginEnabled: false)
            }
            return .init(
                panelVisible: self.panel.isVisible,
                keepOnTop: self.keepOnTopEnabled,
                captureHotKey: self.captureHotKeyEnabled,
                paused: self.watcher.paused,
                loginEnabled: SMAppService.mainApp.status == .enabled
            )
        }, handler: { [weak self] command in
            self?.handleMenuCommand(command)
        })
        menuBar.start()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.menuBar.publish() }
        }
    }

    /// Finder / Launchpad でアプリを再度開いたとき（既に起動中）: パネルを見える位置に出す
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    private func handleMenuCommand(_ command: MenuCommand) {
        switch command {
        case .togglePanel:
            if panel.isVisible { hidePanel() } else { showPanel() }
        case .toggleKeepOnTop:
            toggleKeepOnTop()
        case .capture:
            startCapture()
        case .toggleCaptureHotKey:
            toggleCaptureHotKey()
        case .togglePause:
            togglePause()
        case .openDataFolder:
            NSWorkspace.shared.activateFileViewerSelecting([store.baseDir])
        case .clearAll:
            clearAll()
        case .toggleLogin:
            toggleLogin()
        case .about:
            about()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func showPanel() {
        panel.ensureOnScreen()
        panel.orderFrontRegardless()
        menuBar.publish()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        menuBar.publish()
    }

    private func toggleKeepOnTop() {
        let next = !keepOnTopEnabled
        UserDefaults.standard.set(next, forKey: Self.keepOnTopKey)
        panel.setKeepOnTop(next)
        if next, panel.isVisible { panel.orderFrontRegardless() }
        menuBar.publish()
    }

    private func toggleCaptureHotKey() {
        UserDefaults.standard.set(!captureHotKeyEnabled, forKey: Self.captureHotKeyKey)
        applyCaptureHotKey()
        menuBar.publish()
    }

    private func applyCaptureHotKey() {
        hotKey = nil
        guard captureHotKeyEnabled else { return }
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            Task { @MainActor in self?.startCapture() }
        }
    }

    private func togglePause() {
        watcher.setPaused(!watcher.paused)
        menuBar.publish()
    }

    private func clearAll() {
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

    private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify("ログイン項目の変更に失敗", "\(error.localizedDescription)\n(.app を /Applications に置くと安定します)")
        }
        menuBar.publish()
    }

    private func about() {
        let a = NSAlert()
        a.messageText = "ClipNote"
        a.informativeText = """
        ベータ版  v0.2.0
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

    private func startCapture() {
        capturer.beginSelection { [weak self] image in
            guard let self, let image else { return }
            self.store.addImage(image)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            self.watcher.ignoreCurrentChange()
        }
    }

    /// 一覧行は本文の切り出ししか持たないので、ここで全文を取ってから書き込む
    private func copyToPasteboard(_ row: ClipRow) {
        guard let item = store.item(id: row.id) else { return }
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

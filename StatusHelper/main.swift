import AppKit
import Darwin

/// メニューバー専用。本体のメインスレッドが止まってもここから強制再起動できる。
@main
enum StatusHelperMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = StatusHelperDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class StatusHelperDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var lock: ExclusiveLock?
    private var statusURL: URL!
    private var appBundleURL: URL!
    private var lastStatus: MenuStatus?
    private var hung = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        appBundleURL = Self.resolveAppBundle()
        guard let url = Self.parseStatusURL() else {
            NSLog("ClipNoteStatus: --status-file required")
            NSApp.terminate(nil)
            return
        }
        statusURL = url

        let lockURL = URL(fileURLWithPath: statusURL.path + ".lock")
        guard let lock = ExclusiveLock(path: lockURL.path) else {
            NSApp.terminate(nil)
            return
        }
        self.lock = lock

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        reloadStatus()

        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.reloadStatus()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        reloadStatus()
        rebuild(menu)
    }

    private func reloadStatus() {
        lastStatus = Self.readStatus(at: statusURL)
        hung = lastStatus?.isHung == true
        statusItem.button?.appearsDisabled = hung || lastStatus?.paused == true
        applyIcon()
    }

    private func applyIcon() {
        if hung, let warn = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "ClipNote 応答なし") {
            warn.isTemplate = true
            statusItem.button?.image = warn
            return
        }
        let png = appBundleURL.appendingPathComponent("Contents/Resources/MenuBarIcon.png")
        if let img = NSImage(contentsOf: png) {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            img.accessibilityDescription = "ClipNote"
            statusItem.button?.image = img
            return
        }
        let symbol = (lastStatus?.paused == true) ? "note.text.badge.plus" : "note.text"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClipNote")
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = lastStatus

        if hung {
            let item = NSMenuItem(title: "応答なし — 強制再起動", action: #selector(forceRestart), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let panelTitle = (s?.panelVisible == true) ? "パネルを隠す" : "パネルを表示"
        add(menu, panelTitle, #selector(togglePanel))
        addCheck(menu, "画面先頭に固定", #selector(toggleKeepOnTop), on: s?.keepOnTop == true)
        add(menu, "範囲キャプチャ", #selector(capture))
        addCheck(menu, "⌘⇧2 ショートカット", #selector(toggleCaptureHotKey), on: s?.captureHotKey == true)
        let pauseTitle = (s?.paused == true) ? "クリップボード監視を再開" : "クリップボード監視を一時停止"
        add(menu, pauseTitle, #selector(togglePause))
        menu.addItem(.separator())
        add(menu, "保存フォルダを Finder で開く", #selector(openDataFolder))
        add(menu, "ブックマーク以外を全消去…", #selector(clearAll))
        menu.addItem(.separator())
        addCheck(menu, "ログイン時に起動", #selector(toggleLogin), on: s?.loginEnabled == true)
        add(menu, "ClipNote について", #selector(about))
        menu.addItem(.separator())
        if !hung {
            add(menu, "強制再起動", #selector(forceRestart))
        }
        add(menu, "終了", #selector(quitAll), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func addCheck(_ menu: NSMenu, _ title: String, _ sel: Selector, on: Bool) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    @objc private func togglePanel() { post(.togglePanel) }
    @objc private func toggleKeepOnTop() { post(.toggleKeepOnTop) }
    @objc private func capture() { post(.capture) }
    @objc private func toggleCaptureHotKey() { post(.toggleCaptureHotKey) }
    @objc private func togglePause() { post(.togglePause) }
    @objc private func openDataFolder() { post(.openDataFolder) }
    @objc private func clearAll() { post(.clearAll) }
    @objc private func toggleLogin() { post(.toggleLogin) }
    @objc private func about() { post(.about) }

    private func post(_ command: MenuCommand) {
        guard let s = lastStatus ?? Self.readStatus(at: statusURL) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            StatusBridge.commandNotification,
            object: s.commandObject(command),
            userInfo: nil,
            deliverImmediately: true
        )
    }

    @objc private func forceRestart() {
        killMain()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.appBundleURL)
        }
    }

    @objc private func quitAll() {
        post(.quit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.killMain()
            NSApp.terminate(nil)
        }
    }

    private func killMain() {
        reloadStatus()
        let pid = lastStatus?.pid
        let mains = NSWorkspace.shared.runningApplications.filter {
            $0.executableURL?.lastPathComponent == "ClipNote"
        }
        if let pid, let match = mains.first(where: { $0.processIdentifier == pid }) {
            match.forceTerminate()
        } else {
            mains.forEach { $0.forceTerminate() }
        }
        if let pid, pid > 1 {
            kill(pid, SIGKILL)
        }
    }

    private static func parseStatusURL() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--status-file"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    private static func resolveAppBundle() -> URL {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func readStatus(at url: URL) -> MenuStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MenuStatus.self, from: data)
    }
}

/// 二重起動でメニューアイコンが二つ出ないようにする
final class ExclusiveLock {
    private let fd: Int32
    init?(path: String) {
        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
    }
    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

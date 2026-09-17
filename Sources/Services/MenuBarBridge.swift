import AppKit
import Foundation

/// 本体側: 状態をファイルに書き、メニュー操作の通知を受ける。メニューバー自体は持たない。
@MainActor
final class MenuBarBridge {
    private let statusURL: URL
    private let token = UUID().uuidString
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private let snapshot: () -> MenuStatusParts
    private let handler: (MenuCommand) -> Void

    struct MenuStatusParts {
        var panelVisible: Bool
        var keepOnTop: Bool
        var captureHotKey: Bool
        var paused: Bool
        var loginEnabled: Bool
    }

    init(baseDir: URL, snapshot: @escaping () -> MenuStatusParts, handler: @escaping (MenuCommand) -> Void) {
        self.statusURL = baseDir.appendingPathComponent(StatusBridge.statusFileName)
        self.snapshot = snapshot
        self.handler = handler
    }

    func start() {
        publish()
        launchHelper()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: StatusBridge.commandNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handle(note) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        timer?.tolerance = 0.15
    }

    func publish() {
        let p = snapshot()
        let status = MenuStatus(
            pid: ProcessInfo.processInfo.processIdentifier,
            token: token,
            heartbeatAt: Date().timeIntervalSince1970,
            panelVisible: p.panelVisible,
            keepOnTop: p.keepOnTop,
            captureHotKey: p.captureHotKey,
            paused: p.paused,
            loginEnabled: p.loginEnabled
        )
        do {
            let data = try JSONEncoder().encode(status)
            try data.write(to: statusURL, options: .atomic)
        } catch {
            NSLog("menu status write failed: \(error)")
        }
    }

    private func handle(_ note: Notification) {
        guard let object = note.object as? String,
              let command = MenuStatus.parseCommand(object, token: token) else { return }
        handler(command)
        publish()
    }

    private func launchHelper() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ClipNoteStatus")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            NSLog("ClipNoteStatus missing at \(url.path)")
            return
        }
        let p = Process()
        p.executableURL = url
        p.arguments = ["--status-file", statusURL.path]
        do {
            try p.run()
        } catch {
            NSLog("failed to launch ClipNoteStatus: \(error)")
        }
    }
}

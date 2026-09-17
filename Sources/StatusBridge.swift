import Foundation

/// メニューバー専用プロセスと本体の橋。本体メインスレッドが止まってもメニューは動かす。
enum StatusBridge {
    static let commandNotification = Notification.Name("obdist.hsp.clipnote.menuCommand")
    /// この秒数ハートビートが途切れたら本体を応答なしとみなす
    static let hungAfter: TimeInterval = 2.5
    static let statusFileName = "menu-status.json"
}

enum MenuCommand: String, CaseIterable {
    case togglePanel
    case toggleKeepOnTop
    case capture
    case toggleCaptureHotKey
    case togglePause
    case openDataFolder
    case clearAll
    case toggleLogin
    case about
    case quit
}

struct MenuStatus: Codable, Equatable {
    var pid: Int32
    var token: String
    var heartbeatAt: TimeInterval
    var panelVisible: Bool
    var keepOnTop: Bool
    var captureHotKey: Bool
    var paused: Bool
    var loginEnabled: Bool

    var isHung: Bool {
        Date().timeIntervalSince1970 - heartbeatAt > StatusBridge.hungAfter
    }

    func commandObject(_ command: MenuCommand) -> String {
        "\(token) \(command.rawValue)"
    }

    static func parseCommand(_ object: String, token: String) -> MenuCommand? {
        let prefix = token + " "
        guard object.hasPrefix(prefix) else { return nil }
        return MenuCommand(rawValue: String(object.dropFirst(prefix.count)))
    }
}

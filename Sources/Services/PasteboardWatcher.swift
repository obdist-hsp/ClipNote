import AppKit

/// NSPasteboard.general の changeCount をポーリングして履歴に取り込む
@MainActor
final class PasteboardWatcher {
    private let store: HistoryStore
    private var timer: Timer?
    private var lastChangeCount: Int
    private(set) var paused = false

    init(store: HistoryStore) {
        self.store = store
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.1
    }

    func setPaused(_ p: Bool) {
        paused = p
        // 再開時に一時停止中の内容を拾わない
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// 自アプリが書き込んだ変更を無視するために呼ぶ
    func ignoreCurrentChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard !paused else { return }
        capture(from: pb)
    }

    private func capture(from pb: NSPasteboard) {
        // 1. ファイル
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            // 画像ファイル単体は画像として扱う
            if urls.count == 1, let img = NSImage(contentsOf: urls[0]), img.isValid {
                store.addImage(img)
            } else {
                store.addFiles(urls)
            }
            return
        }
        // 2. 画像
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        if pb.availableType(from: imageTypes) != nil,
           let img = NSImage(pasteboard: pb), img.isValid {
            store.addImage(img)
            return
        }
        // 3. テキスト
        if let s = pb.string(forType: .string), !s.isEmpty {
            store.addText(s)
        }
    }
}

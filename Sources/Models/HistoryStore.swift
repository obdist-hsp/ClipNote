import AppKit
import CryptoKit
import Combine

/// 履歴の保持・永続化（SQLite）。表示中のページだけをメモリに持つ。
@MainActor
final class HistoryStore: ObservableObject {
    static let pageSize = 100
    static let minQueryLength = 3
    /// 画像ファイル合計の上限（既定 100 GB、UserDefaults "imageCapacityBytes" で上書き可）
    static var imageCapacityBytes: Int {
        let v = UserDefaults.standard.integer(forKey: "imageCapacityBytes")
        return v > 0 ? v : 100 * 1024 * 1024 * 1024
    }

    // 表示状態
    @Published private(set) var bookmarks: [ClipItem] = []
    @Published private(set) var page: [ClipItem] = []       // 通常一覧 or 検索結果（100件ずつ増える）
    @Published private(set) var hasMore = false
    @Published private(set) var totalCount = 0
    @Published private(set) var matchCount: Int? = nil     // 検索中のヒット数
    @Published private(set) var totalImageBytes = 0
    @Published private(set) var query = ""
    var isSearching: Bool { query.count >= Self.minQueryLength }

    let baseDir: URL
    let imagesDir: URL
    private let db: Database

    /// 画像 item が追加されたときの通知（OCRQueue が購読）
    let imageAdded = PassthroughSubject<ClipItem, Never>()
    /// レコードが更新されたとき（プレビュー等が追従）
    let itemChanged = PassthroughSubject<ClipItem, Never>()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = support.appendingPathComponent("ClipNote", isDirectory: true)
        imagesDir = baseDir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        do {
            db = try Database(path: baseDir.appendingPathComponent("clipnote.sqlite").path)
        } catch {
            fatalError("DB open failed: \(error)")
        }
        migrateLegacyJSONIfNeeded()
        reload()
    }

    // MARK: - Loading

    func reload() {
        bookmarks = (try? db.bookmarks()) ?? []
        totalCount = (try? db.totalCount()) ?? 0
        totalImageBytes = (try? db.totalImageBytes()) ?? 0
        page = []
        hasMore = true
        matchCount = isSearching ? ((try? db.searchCount(query)) ?? 0) : nil
        loadMore()
    }

    func loadMore() {
        guard hasMore else { return }
        let last = page.last.map { ($0.createdAt, $0.rowid) }
        let next: [ClipItem]
        if isSearching {
            next = (try? db.search(query, before: last, limit: Self.pageSize)) ?? []
        } else {
            next = (try? db.page(before: last, limit: Self.pageSize)) ?? []
        }
        page.append(contentsOf: next)
        hasMore = next.count == Self.pageSize
    }

    /// 末尾に近づいたら呼ぶ
    func loadMoreIfNeeded(current item: ClipItem) {
        guard hasMore, let idx = page.firstIndex(where: { $0.id == item.id }) else { return }
        if idx >= page.count - 20 { loadMore() }
    }

    func setQuery(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed != query else { return }
        let wasSearching = isSearching
        query = trimmed
        if isSearching || wasSearching { reload() }
    }

    // MARK: - Add

    @discardableResult
    func addText(_ text: String, date: Date = Date()) -> ClipItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let hash = Self.sha256(Data(text.utf8))
        let item = ClipItem(rowid: 0, id: UUID(), kind: .text, text: text, imageFile: nil,
                            imageWidth: nil, imageHeight: nil, imageBytes: 0, imageDeleted: false,
                            ocrText: nil, contentHash: hash, createdAt: date, bookmarkOrder: nil)
        return insertOrTouch(item)
    }

    @discardableResult
    func addFiles(_ urls: [URL]) -> ClipItem? {
        guard !urls.isEmpty else { return nil }
        let text = urls.map { $0.path }.joined(separator: "\n")
        let hash = Self.sha256(Data(("files:" + text).utf8))
        let item = ClipItem(rowid: 0, id: UUID(), kind: .file, text: text, imageFile: nil,
                            imageWidth: nil, imageHeight: nil, imageBytes: 0, imageDeleted: false,
                            ocrText: nil, contentHash: hash, createdAt: Date(), bookmarkOrder: nil)
        return insertOrTouch(item)
    }

    @discardableResult
    func addImage(_ image: NSImage) -> ClipItem? {
        guard let png = image.pngData() else { return nil }
        let hash = Self.sha256(png)
        let now = Date()
        if let existing = try? db.item(hash: hash) {
            var updated = existing
            if existing.imageFile == nil {
                // 容量上限で消えていた画像を復元
                let fileName = "\(existing.id.uuidString).png"
                guard (try? png.write(to: imagesDir.appendingPathComponent(fileName), options: .atomic)) != nil else { return nil }
                try? db.restoreImage(rowid: existing.rowid, file: fileName, bytes: png.count, date: now)
                updated.imageFile = fileName; updated.imageBytes = png.count; updated.imageDeleted = false
                ThumbnailCache.shared.remove(existing.id)
            } else {
                try? db.touch(rowid: existing.rowid, date: now)
            }
            updated.createdAt = now
            moveToTop(updated)
            if updated.ocrText == nil { imageAdded.send(updated) }
            enforceCapacity()
            return updated
        }
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        do { try png.write(to: imagesDir.appendingPathComponent(fileName), options: .atomic) } catch { return nil }
        let px = image.pixelSize
        var item = ClipItem(rowid: 0, id: id, kind: .image, text: nil, imageFile: fileName,
                            imageWidth: Int(px.width), imageHeight: Int(px.height), imageBytes: png.count,
                            imageDeleted: false, ocrText: nil, contentHash: hash, createdAt: now, bookmarkOrder: nil)
        guard let rowid = try? db.insert(item) else { return nil }
        item = withRowid(item, rowid)
        totalCount += 1
        prependToPage(item)
        imageAdded.send(item)
        enforceCapacity()
        return item
    }

    private func insertOrTouch(_ item: ClipItem) -> ClipItem? {
        if let existing = try? db.item(hash: item.contentHash) {
            try? db.touch(rowid: existing.rowid, date: item.createdAt)
            var u = existing; u.createdAt = item.createdAt
            moveToTop(u)
            return u
        }
        guard let rowid = try? db.insert(item) else { return nil }
        let saved = withRowid(item, rowid)
        totalCount += 1
        prependToPage(saved)
        return saved
    }

    private func withRowid(_ item: ClipItem, _ rowid: Int64) -> ClipItem {
        ClipItem(rowid: rowid, id: item.id, kind: item.kind, text: item.text, imageFile: item.imageFile,
                 imageWidth: item.imageWidth, imageHeight: item.imageHeight, imageBytes: item.imageBytes,
                 imageDeleted: item.imageDeleted, ocrText: item.ocrText, contentHash: item.contentHash,
                 createdAt: item.createdAt, bookmarkOrder: item.bookmarkOrder)
    }

    private func prependToPage(_ item: ClipItem) {
        guard !isSearching else { return }   // 検索中は次回 reload で反映
        page.insert(item, at: 0)
    }

    private func moveToTop(_ item: ClipItem) {
        if item.isBookmarked {
            if let i = bookmarks.firstIndex(where: { $0.id == item.id }) { bookmarks[i] = item }
            itemChanged.send(item)
            return
        }
        page.removeAll { $0.id == item.id }
        prependToPage(item)
        itemChanged.send(item)
    }

    // MARK: - Mutations

    func updateOCR(id: UUID, text: String) {
        try? db.updateOCR(id: id, text: text)
        replaceInMemory(id: id) { $0.ocrText = text }
    }

    func toggleBookmark(_ item: ClipItem) {
        if item.isBookmarked {
            try? db.setBookmark(id: item.id, order: nil)
            bookmarks.removeAll { $0.id == item.id }
            var u = item; u.bookmarkOrder = nil
            // 通常一覧の適切な位置へ戻す（表示中の範囲にあれば挿入）
            if !isSearching {
                if let idx = page.firstIndex(where: { $0.createdAt < u.createdAt }) { page.insert(u, at: idx) }
                else if !hasMore { page.append(u) }
            } else {
                replaceInMemory(id: item.id) { $0.bookmarkOrder = nil }
            }
            itemChanged.send(u)
        } else {
            let order = ((try? db.maxBookmarkOrder()) ?? 0) + 1
            try? db.setBookmark(id: item.id, order: order)
            var u = item; u.bookmarkOrder = order
            page.removeAll { $0.id == item.id && !isSearching }
            if isSearching { replaceInMemory(id: item.id) { $0.bookmarkOrder = order } }
            bookmarks.append(u)
            itemChanged.send(u)
        }
    }

    /// ブックマーク内の並び替え（ドラッグ中に呼ばれる。DB 反映は commitBookmarkOrder）
    func moveBookmark(fromOffsets: IndexSet, toOffset: Int) {
        bookmarks.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func moveBookmark(id: UUID, to index: Int) {
        guard let from = bookmarks.firstIndex(where: { $0.id == id }), from != index,
              index >= 0, index < bookmarks.count else { return }
        let it = bookmarks.remove(at: from)
        bookmarks.insert(it, at: index)
    }

    func commitBookmarkOrder() {
        var pairs: [(UUID, Double)] = []
        for (i, b) in bookmarks.enumerated() {
            let o = Double(i + 1)
            pairs.append((b.id, o))
            bookmarks[i].bookmarkOrder = o
        }
        try? db.setBookmarkOrders(pairs)
    }

    func delete(_ item: ClipItem) {
        try? db.delete(id: item.id)
        deleteImageFile(item.imageFile)
        ThumbnailCache.shared.remove(item.id)
        bookmarks.removeAll { $0.id == item.id }
        page.removeAll { $0.id == item.id }
        totalCount = max(0, totalCount - 1)
        if matchCount != nil { matchCount = max(0, (matchCount ?? 1) - 1) }
        totalImageBytes = max(0, totalImageBytes - item.imageBytes)
    }

    func clearAllNonBookmarked() {
        let files = (try? db.deleteAllNonBookmarked()) ?? []
        files.forEach { deleteImageFile($0) }
        reload()
    }

    private func replaceInMemory(id: UUID, _ f: (inout ClipItem) -> Void) {
        if let i = page.firstIndex(where: { $0.id == id }) { f(&page[i]); itemChanged.send(page[i]) }
        if let i = bookmarks.firstIndex(where: { $0.id == id }) { f(&bookmarks[i]); itemChanged.send(bookmarks[i]) }
    }

    private func deleteImageFile(_ name: String?) {
        guard let f = name else { return }
        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(f))
    }

    // MARK: - Capacity (画像合計が上限を超えたら古い順に画像だけ削除)

    func enforceCapacity() {
        totalImageBytes = (try? db.totalImageBytes()) ?? 0
        let cap = Self.imageCapacityBytes
        guard totalImageBytes > cap else { return }
        var freed = 0
        var removedIDs: [UUID] = []
        while totalImageBytes - freed > cap {
            guard let victims = try? db.oldestImages(limit: 50), !victims.isEmpty else { break }
            for v in victims {
                deleteImageFile(v.imageFile)
                try? db.markImageDeleted(rowid: v.rowid)
                ThumbnailCache.shared.remove(v.id)
                freed += v.imageBytes
                removedIDs.append(v.id)
                if totalImageBytes - freed <= cap { break }
            }
        }
        totalImageBytes -= freed
        for id in removedIDs {
            replaceInMemory(id: id) { $0.imageFile = nil; $0.imageBytes = 0; $0.imageDeleted = true }
        }
    }

    // MARK: - Query helpers

    func imageURL(for item: ClipItem) -> URL? {
        item.imageFile.map { imagesDir.appendingPathComponent($0) }
    }

    func loadImage(for item: ClipItem) -> NSImage? {
        imageURL(for: item).flatMap { NSImage(contentsOf: $0) }
    }

    var pendingOCR: [ClipItem] { (try? db.pendingOCR()) ?? [] }

    /// 現在表示中の全カード（ブックマーク → 一覧）。プレビューの前後移動に使う
    var visibleItems: [ClipItem] { isSearching ? page : bookmarks + page }

    // MARK: - Legacy import

    /// 旧 JSON (ClipItem 配列) → SQLite。成功したらファイルをリネーム退避
    private func migrateLegacyJSONIfNeeded() {
        let json = baseDir.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: json) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let legacy = try? dec.decode([LegacyClipItem].self, from: data) else { return }
        var order = (try? db.maxBookmarkOrder()) ?? 0
        try? db.db.transaction {
            for l in legacy.reversed() {   // 旧配列は新しいものが先頭
                if (try? db.item(hash: l.contentHash)) != nil { continue }
                var bytes = 0
                if let f = l.imageFile,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: imagesDir.appendingPathComponent(f).path) {
                    bytes = (attrs[.size] as? Int) ?? 0
                }
                var bo: Double? = nil
                if l.pinned { order += 1; bo = order }
                let it = ClipItem(rowid: 0, id: l.id, kind: l.kind, text: l.text, imageFile: l.imageFile,
                                  imageWidth: l.imageWidth, imageHeight: l.imageHeight, imageBytes: bytes,
                                  imageDeleted: false, ocrText: l.ocrText, contentHash: l.contentHash,
                                  createdAt: l.createdAt, bookmarkOrder: bo)
                _ = try? db.insert(it)
            }
        }
        try? FileManager.default.moveItem(at: json, to: baseDir.appendingPathComponent("history.json.migrated"))
    }

    // MARK: - Util

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension NSImage {
    var pixelSize: NSSize {
        if let rep = representations.max(by: { $0.pixelsWide < $1.pixelsWide }) {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }

    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

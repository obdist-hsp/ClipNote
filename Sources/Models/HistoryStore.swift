import AppKit
import CryptoKit
import Combine

/// 履歴の保持・永続化（SQLite）。一覧には軽量な `ClipRow` だけを持ち、全文は必要なときに `item(id:)` で取る。
@MainActor
final class HistoryStore: ObservableObject {
    static let pageSize = 100
    static let minQueryLength = 3
    /// 画像ファイル合計の上限（既定 100 GB、UserDefaults "imageCapacityBytes" で上書き可）
    static var imageCapacityBytes: Int {
        let v = UserDefaults.standard.integer(forKey: "imageCapacityBytes")
        return v > 0 ? v : 100 * 1024 * 1024 * 1024
    }

    // 表示状態（一覧用の軽量行。本文・OCR は先頭だけ）
    @Published private(set) var bookmarks: [ClipRow] = []
    @Published private(set) var page: [ClipRow] = []       // 通常一覧 or 検索結果（100件ずつ増える）
    @Published private(set) var hasMore = false
    @Published private(set) var totalCount = 0
    @Published private(set) var matchCount: Int? = nil     // 検索中のヒット数
    @Published private(set) var totalImageBytes = 0
    @Published private(set) var query = ""
    var isSearching: Bool { query.count >= Self.minQueryLength }
    var isEmpty: Bool { bookmarks.isEmpty && page.isEmpty }
    /// 同一ターンで再入して全件を一気に読むのを防ぐ
    private var loadingMore = false

    let baseDir: URL
    let imagesDir: URL
    private let db: Database

    /// 画像 item が追加されたときの通知（OCRQueue が購読）
    let imageAdded = PassthroughSubject<ClipRow, Never>()
    /// レコードが更新されたとき（プレビュー等が必要なら取り直す）
    let itemChanged = PassthroughSubject<UUID, Never>()

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
        loadingMore = false
        bookmarks = (try? db.bookmarks()) ?? []
        totalCount = (try? db.totalCount()) ?? 0
        totalImageBytes = (try? db.totalImageBytes()) ?? 0
        page = []
        hasMore = true
        matchCount = isSearching ? ((try? db.searchCount(query)) ?? 0) : nil
        loadMore()
    }

    func loadMore() {
        guard hasMore, !loadingMore else { return }
        loadingMore = true
        fetchNextPage()
        // テーブルのセル生成から同期で呼ばれても、次の表示更新まで再入しない
        Task { @MainActor in
            self.loadingMore = false
        }
    }

    private func fetchNextPage() {
        let last = page.last.map { ($0.createdAt, $0.rowid) }
        let next: [ClipRow]
        if isSearching {
            next = (try? db.search(query, before: last, limit: Self.pageSize)) ?? []
        } else {
            next = (try? db.page(before: last, limit: Self.pageSize)) ?? []
        }
        page.append(contentsOf: next)
        hasMore = next.count == Self.pageSize
    }

    func setQuery(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed != query else { return }
        let wasSearching = isSearching
        query = trimmed
        if isSearching || wasSearching { reload() }
    }

    // MARK: - Full record access

    /// 全文レコード。コピー・ドラッグ・プレビューなど、本文や OCR 全文が要るときだけ呼ぶ
    func item(id: UUID) -> ClipItem? {
        try? db.item(id: id)
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
            let row = ClipRow(updated)
            moveToTop(row)
            if updated.ocrText == nil { imageAdded.send(row) }
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
        let row = ClipRow(item)
        prependToPage(row)
        imageAdded.send(row)
        enforceCapacity()
        return item
    }

    private func insertOrTouch(_ item: ClipItem) -> ClipItem? {
        if let existing = try? db.item(hash: item.contentHash) {
            try? db.touch(rowid: existing.rowid, date: item.createdAt)
            var u = existing; u.createdAt = item.createdAt
            moveToTop(ClipRow(u))
            return u
        }
        guard let rowid = try? db.insert(item) else { return nil }
        let saved = withRowid(item, rowid)
        totalCount += 1
        prependToPage(ClipRow(saved))
        return saved
    }

    private func withRowid(_ item: ClipItem, _ rowid: Int64) -> ClipItem {
        ClipItem(rowid: rowid, id: item.id, kind: item.kind, text: item.text, imageFile: item.imageFile,
                 imageWidth: item.imageWidth, imageHeight: item.imageHeight, imageBytes: item.imageBytes,
                 imageDeleted: item.imageDeleted, ocrText: item.ocrText, contentHash: item.contentHash,
                 createdAt: item.createdAt, bookmarkOrder: item.bookmarkOrder)
    }

    private func prependToPage(_ row: ClipRow) {
        guard !isSearching else { return }   // 検索中は次回 reload で反映
        page.insert(row, at: 0)
    }

    private func moveToTop(_ row: ClipRow) {
        if row.isBookmarked {
            if let i = bookmarks.firstIndex(where: { $0.id == row.id }) { bookmarks[i] = row }
            itemChanged.send(row.id)
            return
        }
        if isSearching {
            // 検索結果の並びは変えず、内容だけ追従
            if let i = page.firstIndex(where: { $0.id == row.id }) { page[i] = row }
        } else {
            page.removeAll { $0.id == row.id }
            prependToPage(row)
        }
        itemChanged.send(row.id)
    }

    // MARK: - Mutations

    func updateOCR(id: UUID, text: String) {
        try? db.updateOCR(id: id, text: text)
        replaceInMemory(id: id) {
            $0.hasOCR = true
            $0.ocrPreview = text.scalarPrefix(ClipRow.ocrPreviewLimit)
            $0.ocrLength = text.scalarCount
        }
    }

    func toggleBookmark(_ row: ClipRow) {
        if row.isBookmarked {
            try? db.setBookmark(id: row.id, order: nil)
            bookmarks.removeAll { $0.id == row.id }
            var u = row; u.bookmarkOrder = nil
            // 通常一覧の適切な位置へ戻す（表示中の範囲にあれば挿入）
            if !isSearching {
                if let idx = page.firstIndex(where: { $0.createdAt < u.createdAt }) { page.insert(u, at: idx) }
                else if !hasMore { page.append(u) }
            } else {
                replaceInMemory(id: row.id) { $0.bookmarkOrder = nil }
            }
            itemChanged.send(u.id)
        } else {
            let order = ((try? db.maxBookmarkOrder()) ?? 0) + 1
            try? db.setBookmark(id: row.id, order: order)
            var u = row; u.bookmarkOrder = order
            page.removeAll { $0.id == row.id && !isSearching }
            if isSearching { replaceInMemory(id: row.id) { $0.bookmarkOrder = order } }
            bookmarks.append(u)
            itemChanged.send(u.id)
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

    /// 既存 order の最長増加部分列は据え置き、それ以外の行だけ隣同士の中間値を割り当てて保存する
    /// （1 回のドラッグ → 通常 1 行 UPDATE）。中間値を取り続けて間隔が詰まったら 1..n で振り直す
    func commitBookmarkOrder() {
        let keep = Self.longestIncreasingSubsequence(bookmarks.map(\.bookmarkOrder))
        var pairs: [(UUID, Double)] = []
        var prev = 0.0
        for i in bookmarks.indices {
            if keep.contains(i), let o = bookmarks[i].bookmarkOrder { prev = o; continue }
            var next = prev + 2
            for j in (i + 1)..<bookmarks.count where keep.contains(j) {
                if let o = bookmarks[j].bookmarkOrder { next = o; break }
            }
            guard next - prev >= 1e-6 else { renumberBookmarks(); return }
            let o = (prev + next) / 2
            bookmarks[i].bookmarkOrder = o
            pairs.append((bookmarks[i].id, o))
            prev = o
        }
        if !pairs.isEmpty { try? db.setBookmarkOrders(pairs) }
    }

    /// nil を除き厳密に増加する最長部分列のインデックス（patience sorting, O(n log n)）
    private static func longestIncreasingSubsequence(_ values: [Double?]) -> Set<Int> {
        var tails: [Int] = []                                    // tails[k] = 長さ k+1 の増加列の末尾インデックス
        var prevIndex = [Int](repeating: -1, count: values.count)
        for (i, value) in values.enumerated() {
            guard let v = value else { continue }
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if let t = values[tails[mid]], t < v { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prevIndex[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var out = Set<Int>()
        var cur = tails.last ?? -1
        while cur >= 0 { out.insert(cur); cur = prevIndex[cur] }
        return out
    }

    private func renumberBookmarks() {
        var pairs: [(UUID, Double)] = []
        for (i, b) in bookmarks.enumerated() {
            let o = Double(i + 1)
            pairs.append((b.id, o))
            bookmarks[i].bookmarkOrder = o
        }
        try? db.setBookmarkOrders(pairs)
    }

    func delete(_ row: ClipRow) {
        try? db.delete(id: row.id)
        deleteImageFile(row.imageFile)
        ThumbnailCache.shared.remove(row.id)
        bookmarks.removeAll { $0.id == row.id }
        page.removeAll { $0.id == row.id }
        totalCount = max(0, totalCount - 1)
        if matchCount != nil { matchCount = max(0, (matchCount ?? 1) - 1) }
        totalImageBytes = max(0, totalImageBytes - row.imageBytes)
    }

    func clearAllNonBookmarked() {
        let files = (try? db.deleteAllNonBookmarked()) ?? []
        files.forEach { deleteImageFile($0) }
        reload()
    }

    private func replaceInMemory(id: UUID, _ f: (inout ClipRow) -> Void) {
        var changed = false
        if let i = page.firstIndex(where: { $0.id == id }) { f(&page[i]); changed = true }
        if let i = bookmarks.firstIndex(where: { $0.id == id }) { f(&bookmarks[i]); changed = true }
        if changed { itemChanged.send(id) }
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

    func imageURL(file: String?) -> URL? {
        file.map { imagesDir.appendingPathComponent($0) }
    }

    func imageURL(for row: ClipRow) -> URL? { imageURL(file: row.imageFile) }
    func imageURL(for item: ClipItem) -> URL? { imageURL(file: item.imageFile) }

    func loadImage(for item: ClipItem) -> NSImage? {
        imageURL(for: item).flatMap { NSImage(contentsOf: $0) }
    }

    var pendingOCR: [ClipRow] { (try? db.pendingOCR()) ?? [] }

    /// 現在表示中の全カード（ブックマーク → 一覧）。プレビューの前後移動に使う
    var visibleRows: [ClipRow] { isSearching ? page : bookmarks + page }

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

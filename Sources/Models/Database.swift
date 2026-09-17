import Foundation

/// スキーマとクエリ。HistoryStore からのみ使う
final class Database {
    let db: SQLite

    init(path: String) throws {
        db = try SQLite(path: path)
        try migrate()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS items (
            rowid          INTEGER PRIMARY KEY,
            id             TEXT NOT NULL UNIQUE,
            kind           TEXT NOT NULL,
            text           TEXT,
            image_file     TEXT,
            image_w        INTEGER,
            image_h        INTEGER,
            image_bytes    INTEGER NOT NULL DEFAULT 0,
            image_deleted  INTEGER NOT NULL DEFAULT 0,
            ocr_text       TEXT,
            content_hash   TEXT NOT NULL UNIQUE,
            created_at     REAL NOT NULL,
            bookmark_order REAL
        );
        CREATE INDEX IF NOT EXISTS idx_items_created ON items(created_at DESC, rowid DESC);
        CREATE INDEX IF NOT EXISTS idx_items_bookmark ON items(bookmark_order) WHERE bookmark_order IS NOT NULL;
        CREATE INDEX IF NOT EXISTS idx_items_image ON items(created_at) WHERE image_file IS NOT NULL;

        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
            text, ocr_text, content='items', content_rowid='rowid', tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
            INSERT INTO items_fts(rowid, text, ocr_text) VALUES (new.rowid, new.text, new.ocr_text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, text, ocr_text) VALUES ('delete', old.rowid, old.text, old.ocr_text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE OF text, ocr_text ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, text, ocr_text) VALUES ('delete', old.rowid, old.text, old.ocr_text);
            INSERT INTO items_fts(rowid, text, ocr_text) VALUES (new.rowid, new.text, new.ocr_text);
        END;
        """)
    }

    // MARK: - Row mapping

    static let columns = "rowid, id, kind, text, image_file, image_w, image_h, image_bytes, image_deleted, ocr_text, content_hash, created_at, bookmark_order"

    static func item(from r: SQLite.Row) -> ClipItem {
        ClipItem(rowid: r.int64(0),
                 id: UUID(uuidString: r.string(1) ?? "") ?? UUID(),
                 kind: ClipKind(rawValue: r.string(2) ?? "text") ?? .text,
                 text: r.string(3),
                 imageFile: r.string(4),
                 imageWidth: r.isNull(5) ? nil : r.int(5),
                 imageHeight: r.isNull(6) ? nil : r.int(6),
                 imageBytes: r.int(7),
                 imageDeleted: r.bool(8),
                 ocrText: r.string(9),
                 contentHash: r.string(10) ?? "",
                 createdAt: r.date(11),
                 bookmarkOrder: r.isNull(12) ? nil : r.double(12))
    }

    // MARK: - Insert / fetch

    func insert(_ it: ClipItem) throws -> Int64 {
        try db.run("""
        INSERT INTO items (id, kind, text, image_file, image_w, image_h, image_bytes, image_deleted, ocr_text, content_hash, created_at, bookmark_order)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """, [it.id.uuidString, it.kind.rawValue, it.text, it.imageFile, it.imageWidth, it.imageHeight,
              it.imageBytes, it.imageDeleted, it.ocrText, it.contentHash, it.createdAt, it.bookmarkOrder])
        return db.lastInsertRowID
    }

    func item(hash: String) throws -> ClipItem? {
        try db.scalar("SELECT \(Self.columns) FROM items WHERE content_hash = ?", [hash], Self.item)
    }

    func item(id: UUID) throws -> ClipItem? {
        try db.scalar("SELECT \(Self.columns) FROM items WHERE id = ?", [id.uuidString], Self.item)
    }

    /// 通常一覧（ブックマーク除外）: created_at のキーセットページング
    func page(before: (Date, Int64)?, limit: Int) throws -> [ClipItem] {
        var out: [ClipItem] = []
        if let (d, r) = before {
            try db.query("""
            SELECT \(Self.columns) FROM items
            WHERE bookmark_order IS NULL AND (created_at < ? OR (created_at = ? AND rowid < ?))
            ORDER BY created_at DESC, rowid DESC LIMIT ?
            """, [d, d, r, limit]) { out.append(Self.item(from: $0)) }
        } else {
            try db.query("""
            SELECT \(Self.columns) FROM items WHERE bookmark_order IS NULL
            ORDER BY created_at DESC, rowid DESC LIMIT ?
            """, [limit]) { out.append(Self.item(from: $0)) }
        }
        return out
    }

    /// 検索（全件対象、ブックマーク含む）
    func search(_ query: String, before: (Date, Int64)?, limit: Int) throws -> [ClipItem] {
        var out: [ClipItem] = []
        let match = Self.ftsQuery(query)
        if let (d, r) = before {
            try db.query("""
            SELECT \(Self.columns.split(separator: ",").map { "i." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
            FROM items_fts f JOIN items i ON i.rowid = f.rowid
            WHERE items_fts MATCH ? AND (i.created_at < ? OR (i.created_at = ? AND i.rowid < ?))
            ORDER BY i.created_at DESC, i.rowid DESC LIMIT ?
            """, [match, d, d, r, limit]) { out.append(Self.item(from: $0)) }
        } else {
            try db.query("""
            SELECT \(Self.columns.split(separator: ",").map { "i." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
            FROM items_fts f JOIN items i ON i.rowid = f.rowid
            WHERE items_fts MATCH ?
            ORDER BY i.created_at DESC, i.rowid DESC LIMIT ?
            """, [match, limit]) { out.append(Self.item(from: $0)) }
        }
        return out
    }

    func searchCount(_ query: String) throws -> Int {
        try db.scalar("SELECT count(*) FROM items_fts WHERE items_fts MATCH ?", [Self.ftsQuery(query)]) { $0.int(0) } ?? 0
    }

    /// trigram 用: 語をダブルクォートで囲みフレーズ検索にする
    static func ftsQuery(_ q: String) -> String {
        "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func totalCount() throws -> Int {
        try db.scalar("SELECT count(*) FROM items") { $0.int(0) } ?? 0
    }

    func bookmarks() throws -> [ClipItem] {
        var out: [ClipItem] = []
        try db.query("SELECT \(Self.columns) FROM items WHERE bookmark_order IS NOT NULL ORDER BY bookmark_order, rowid") {
            out.append(Self.item(from: $0))
        }
        return out
    }

    func pendingOCR() throws -> [ClipItem] {
        var out: [ClipItem] = []
        try db.query("SELECT \(Self.columns) FROM items WHERE kind='image' AND ocr_text IS NULL AND image_file IS NOT NULL ORDER BY created_at DESC") {
            out.append(Self.item(from: $0))
        }
        return out
    }

    // MARK: - Updates

    func touch(rowid: Int64, date: Date) throws {
        try db.run("UPDATE items SET created_at = ? WHERE rowid = ?", [date, rowid])
    }

    func updateOCR(id: UUID, text: String) throws {
        try db.run("UPDATE items SET ocr_text = ? WHERE id = ?", [text, id.uuidString])
    }

    func restoreImage(rowid: Int64, file: String, bytes: Int, date: Date) throws {
        try db.run("UPDATE items SET image_file = ?, image_bytes = ?, image_deleted = 0, created_at = ? WHERE rowid = ?",
                   [file, bytes, date, rowid])
    }

    func setBookmark(id: UUID, order: Double?) throws {
        try db.run("UPDATE items SET bookmark_order = ? WHERE id = ?", [order, id.uuidString])
    }

    func setBookmarkOrders(_ pairs: [(UUID, Double)]) throws {
        try db.transaction {
            for (id, o) in pairs { try db.run("UPDATE items SET bookmark_order = ? WHERE id = ?", [o, id.uuidString]) }
        }
    }

    func maxBookmarkOrder() throws -> Double {
        try db.scalar("SELECT COALESCE(MAX(bookmark_order), 0) FROM items") { $0.double(0) } ?? 0
    }

    func delete(id: UUID) throws {
        try db.run("DELETE FROM items WHERE id = ?", [id.uuidString])
    }

    /// ブックマーク以外を全削除。戻り値 = 削除対象の画像ファイル名
    func deleteAllNonBookmarked() throws -> [String] {
        var files: [String] = []
        try db.query("SELECT image_file FROM items WHERE bookmark_order IS NULL AND image_file IS NOT NULL") {
            if let f = $0.string(0) { files.append(f) }
        }
        try db.run("DELETE FROM items WHERE bookmark_order IS NULL")
        return files
    }

    // MARK: - Capacity

    func totalImageBytes() throws -> Int {
        try db.scalar("SELECT COALESCE(SUM(image_bytes), 0) FROM items WHERE image_file IS NOT NULL") { $0.int(0) } ?? 0
    }

    /// 容量超過分を古い順に「画像だけ」削除する候補
    func oldestImages(limit: Int) throws -> [ClipItem] {
        var out: [ClipItem] = []
        try db.query("""
        SELECT \(Self.columns) FROM items
        WHERE image_file IS NOT NULL AND bookmark_order IS NULL
        ORDER BY created_at ASC, rowid ASC LIMIT ?
        """, [limit]) { out.append(Self.item(from: $0)) }
        return out
    }

    func markImageDeleted(rowid: Int64) throws {
        try db.run("UPDATE items SET image_file = NULL, image_bytes = 0, image_deleted = 1 WHERE rowid = ?", [rowid])
    }
}

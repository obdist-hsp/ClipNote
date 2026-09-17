import Foundation
import SQLite3

let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite(\(code)): \(message)" }
}

/// macOS 標準 libsqlite3 の最小ラッパー（外部依存なし）
final class SQLite {
    private var db: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw SQLiteError(code: -1, message: msg)
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(db) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }
    var changes: Int { Int(sqlite3_changes(db)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(code: -1, message: msg)
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let r = try body(); try exec("COMMIT"); return r }
        catch { try? exec("ROLLBACK"); throw error }
    }

    /// 実行のみ
    func run(_ sql: String, _ args: [Any?] = []) throws {
        let st = try Statement(db: db!, sql: sql)
        try st.bind(args)
        try st.step()
    }

    /// 行ごとにクロージャ
    func query(_ sql: String, _ args: [Any?] = [], _ row: (Row) throws -> Void) throws {
        let st = try Statement(db: db!, sql: sql)
        try st.bind(args)
        while try st.step() { try row(Row(st.stmt)) }
    }

    func scalar<T>(_ sql: String, _ args: [Any?] = [], _ f: (Row) -> T) throws -> T? {
        var result: T?
        try query(sql, args) { r in if result == nil { result = f(r) } }
        return result
    }

    final class Statement {
        let stmt: OpaquePointer
        private let db: OpaquePointer
        init(db: OpaquePointer, sql: String) throws {
            var p: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &p, nil) == SQLITE_OK, let p else {
                throw SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)) + " in: " + sql)
            }
            self.stmt = p; self.db = db
        }
        deinit { sqlite3_finalize(stmt) }

        func bind(_ args: [Any?]) throws {
            for (i, a) in args.enumerated() {
                let idx = Int32(i + 1)
                switch a {
                case nil: sqlite3_bind_null(stmt, idx)
                case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
                case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
                case let v as Int32: sqlite3_bind_int(stmt, idx, v)
                case let v as Bool: sqlite3_bind_int(stmt, idx, v ? 1 : 0)
                case let v as Double: sqlite3_bind_double(stmt, idx, v)
                case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_PTR)
                case let v as Data:
                    v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT_PTR) }
                case let v as Date: sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
                default: throw SQLiteError(code: -1, message: "unsupported bind type \(type(of: a))")
                }
            }
        }

        /// true = 行あり
        @discardableResult
        func step() throws -> Bool {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    struct Row {
        let stmt: OpaquePointer
        init(_ s: OpaquePointer) { stmt = s }
        func isNull(_ i: Int) -> Bool { sqlite3_column_type(stmt, Int32(i)) == SQLITE_NULL }
        func int(_ i: Int) -> Int { Int(sqlite3_column_int64(stmt, Int32(i))) }
        func int64(_ i: Int) -> Int64 { sqlite3_column_int64(stmt, Int32(i)) }
        func double(_ i: Int) -> Double { sqlite3_column_double(stmt, Int32(i)) }
        func bool(_ i: Int) -> Bool { sqlite3_column_int(stmt, Int32(i)) != 0 }
        func string(_ i: Int) -> String? {
            guard let c = sqlite3_column_text(stmt, Int32(i)) else { return nil }
            return String(cString: c)
        }
        func date(_ i: Int) -> Date { Date(timeIntervalSince1970: double(i)) }
    }
}

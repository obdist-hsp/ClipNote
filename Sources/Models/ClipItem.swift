import Foundation

enum ClipKind: String, Codable {
    case text, image, file
}

struct ClipItem: Identifiable, Equatable, Hashable {
    let rowid: Int64
    let id: UUID
    let kind: ClipKind
    var text: String?          // text: 本文 / file: パス一覧(改行区切り)
    var imageFile: String?     // image: images/ 配下のファイル名（容量上限で削除されると nil）
    var imageWidth: Int?
    var imageHeight: Int?
    var imageBytes: Int        // 画像ファイルのバイト数（削除後は 0）
    var imageDeleted: Bool     // 容量上限で画像だけ削除された
    var ocrText: String?       // image: 後追い OCR 結果（nil = 未処理, "" = 文字なし）
    let contentHash: String
    var createdAt: Date
    var bookmarkOrder: Double? // non-nil = ブックマーク済み。小さいほど上

    var isBookmarked: Bool { bookmarkOrder != nil }

    /// カード表示用の一行
    var preview: String {
        switch kind {
        case .text, .file: return text ?? ""
        case .image:
            if let w = imageWidth, let h = imageHeight { return "画像 \(w)×\(h)" }
            return "画像"
        }
    }

    /// grapheme の `count` は巨大文字列でメインスレッドを止める。表示用は UTF-16 長。
    var utf16Count: Int { text?.utf16.count ?? 0 }

    func truncatedText(_ limit: Int = 400) -> String {
        guard let t = text else { return "" }
        if t.utf16.count <= limit { return t }
        return String(t.prefix(limit)) + "…"
    }

    func truncatedOCR(_ limit: Int = 200) -> String {
        guard let t = ocrText, !t.isEmpty else { return "" }
        if t.utf16.count <= limit { return t }
        return String(t.prefix(limit)) + "…"
    }
}

/// 旧 JSON (history.json) の 1 レコード。SQLite 移行時にのみ使用
struct LegacyClipItem: Codable {
    let id: UUID
    let kind: ClipKind
    var text: String?
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var ocrText: String?
    var contentHash: String
    let createdAt: Date
    var pinned: Bool = false
}

/// 一覧用の軽量な行。本文と OCR は先頭だけ切り出して持ち、全文は `HistoryStore.item(id:)` で取り直す。
/// 10000 件読み込んでも数 MB に収まるよう、巨大テキストをメモリに載せない。
struct ClipRow: Identifiable, Equatable, Hashable {
    /// SQLite の substr() と同じコードポイント単位
    static let textPreviewLimit = 400
    static let ocrPreviewLimit = 200

    let rowid: Int64
    let id: UUID
    let kind: ClipKind
    var textPreview: String        // text: 本文の先頭 / file: パス一覧の先頭
    var textLength: Int            // 全文のコードポイント数（SQLite length() と同じ単位）
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var imageBytes: Int
    var imageDeleted: Bool
    var hasOCR: Bool               // ocr_text IS NOT NULL（"" = 文字なし も true。false = 未処理）
    var ocrPreview: String
    var ocrLength: Int
    var createdAt: Date
    var bookmarkOrder: Double?

    var isBookmarked: Bool { bookmarkOrder != nil }
    var hasNonEmptyOCR: Bool { hasOCR && ocrLength > 0 }

    /// カード表示用の一行
    var preview: String {
        switch kind {
        case .text, .file: return textPreview
        case .image:
            if let w = imageWidth, let h = imageHeight { return "画像 \(w)×\(h)" }
            return "画像"
        }
    }

    /// 一覧に出す本文（切り出し済み。全文より短ければ "…" を付ける）
    var displayText: String {
        textLength > Self.textPreviewLimit ? textPreview + "…" : textPreview
    }

    func displayOCR(_ limit: Int = ClipRow.ocrPreviewLimit) -> String {
        guard hasNonEmptyOCR else { return "" }
        if ocrLength <= limit { return ocrPreview }
        return ocrPreview.scalarPrefix(limit) + "…"
    }
}

extension ClipRow {
    /// 全文レコードから一覧行を作る（新規追加直後など、DB を読み直さずに反映するとき）
    init(_ item: ClipItem) {
        self.init(rowid: item.rowid, id: item.id, kind: item.kind,
                  textPreview: item.text?.scalarPrefix(Self.textPreviewLimit) ?? "",
                  textLength: item.text?.scalarCount ?? 0,
                  imageFile: item.imageFile, imageWidth: item.imageWidth, imageHeight: item.imageHeight,
                  imageBytes: item.imageBytes, imageDeleted: item.imageDeleted,
                  hasOCR: item.ocrText != nil,
                  ocrPreview: item.ocrText?.scalarPrefix(Self.ocrPreviewLimit) ?? "",
                  ocrLength: item.ocrText?.scalarCount ?? 0,
                  createdAt: item.createdAt, bookmarkOrder: item.bookmarkOrder)
    }
}

extension String {
    /// SQLite substr() と同じコードポイント単位で先頭 n 文字
    func scalarPrefix(_ n: Int) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: unicodeScalars.prefix(n))
        return String(v)
    }
    /// SQLite length() と同じコードポイント数
    var scalarCount: Int { unicodeScalars.count }
}

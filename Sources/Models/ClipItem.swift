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

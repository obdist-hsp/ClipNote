import SwiftUI
import UniformTypeIdentifiers
import ImageIO

/// 画像サムネイルのキャッシュ（縮小済み）。デコードはメインスレッドに載せない。
/// 上限は件数ではなくバイト数で持ち、画面外に流れたセルのデコードは始める前に打ち切る
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private static let decodeQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "obdist.hsp.clipnote.thumb"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()
    init() {
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func thumbnail(for item: ClipRow, store: HistoryStore, maxWidth: CGFloat = 360) async -> NSImage? {
        let key = item.id.uuidString as NSString
        if let c = cache.object(forKey: key) { return c }
        guard let url = store.imageURL(for: item), !Task.isCancelled else { return nil }
        let maxPixel = Int(maxWidth)
        // SwiftUI の .task(id:) がキャンセルされたら（セルが別の行に使い回された）、
        // まだ始まっていないデコードは飛ばす。Operation.cancel() だと continuation が resume されずに漏れるので、
        // フラグを見てブロック側で必ず 1 回 resume する
        let cancel = CancelFlag()
        let result: (image: NSImage, cost: Int)? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(image: NSImage, cost: Int)?, Never>) in
                Self.decodeQueue.addOperation {
                    guard !cancel.isCancelled else { continuation.resume(returning: nil); return }
                    continuation.resume(returning: Self.makeThumbnail(url: url, maxPixel: maxPixel))
                }
            }
        } onCancel: {
            cancel.cancel()
        }
        guard let result else { return nil }
        cache.setObject(result.image, forKey: key, cost: result.cost)
        return result.image
    }

    nonisolated private static func makeThumbnail(url: URL, maxPixel: Int) -> (image: NSImage, cost: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return (image, cg.bytesPerRow * cg.height)
    }

    func remove(_ id: UUID) { cache.removeObject(forKey: id.uuidString as NSString) }
}

/// デコードキューとキャンセルハンドラの両方から触るフラグ
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flagged }
    func cancel() { lock.lock(); flagged = true; lock.unlock() }
}

/// 一覧カード用。本体 PNG を View.body で読まない。高さ予約で LazyVStack が全部測らないようにする
private struct CardThumbnail: View {
    let item: ClipRow
    let store: HistoryStore
    @State private var image: NSImage?

    private var reservedHeight: CGFloat {
        let maxH: CGFloat = 180
        guard let w = item.imageWidth, let h = item.imageHeight, w > 0 else { return 80 }
        return min(maxH, max(48, 240 * CGFloat(h) / CGFloat(w)))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: reservedHeight)
            }
        }
        .task(id: item.id) {
            image = await ThumbnailCache.shared.thumbnail(for: item, store: store)
        }
    }
}

struct ClipCardView: View {
    let item: ClipRow
    let store: HistoryStore
    let actions: ClipActions
    let flashing: Bool
    let onCopied: () -> Void
    /// ブックマークカードのみ: グリップからのドラッグ開始
    let onGripDrag: (() -> NSItemProvider)?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let onGripDrag {
                grip.onDrag(onGripDrag)
            }
            VStack(alignment: .leading, spacing: 6) {
                content
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(flashing ? Color.accentColor.opacity(0.35)
                      : hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(item.isBookmarked ? Color.orange.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovering { copyButton.padding(6) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { actions.preview(item) }
        .onDrag { dragProvider() }
        .contextMenu { menu }
        .help("ダブルクリックで拡大 / ドラッグで他アプリへ貼り付け")
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 22)
            .contentShape(Rectangle())
            .help("ドラッグで並び替え")
    }

    private var copyButton: some View {
        Button {
            actions.copy(item)
            onCopied()
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .padding(5)
                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help("クリップボードにコピー")
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            Text(item.displayText)
                .font(.system(size: 12))
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .file:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                Text(item.textPreview.split(separator: "\n").prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
                    .font(.system(size: 12)).lineLimit(3)
            }
        case .image:
            if item.imageDeleted || item.imageFile == nil {
                // 画像本体は容量上限で削除済み。OCR テキストだけを控えめに表示
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                    Text(item.hasNonEmptyOCR ? item.displayOCR() : "（文字なし）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                CardThumbnail(item: item, store: store)
                if item.hasNonEmptyOCR {
                    Text(item.displayOCR(120))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if item.isBookmarked { Image(systemName: "bookmark.fill").foregroundStyle(.orange) }
            Text(Self.relative(item.createdAt))
            if item.kind == .image {
                if item.imageDeleted || item.imageFile == nil {
                    Label("画像は容量上限で削除・OCR テキストのみ", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.orange.opacity(0.8))
                } else {
                    Text(item.preview)
                }
                if !item.hasOCR && !item.imageDeleted {
                    Label("OCR中", systemImage: "hourglass")
                } else if item.hasNonEmptyOCR {
                    Label("OCR済", systemImage: "text.viewfinder")
                }
            } else if item.kind == .text {
                Text("\(item.textLength)字")
            }
            Spacer()
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder private var menu: some View {
        Button("コピー") { actions.copy(item); onCopied() }
        Button("拡大表示") { actions.preview(item) }
        Button(item.isBookmarked ? "ブックマークを解除" : "ブックマークに追加") { actions.toggleBookmark(item) }
        if item.kind == .image {
            Divider()
            Button("OCR テキストをコピー") { actions.copyOCR(item) }
                .disabled(!item.hasNonEmptyOCR)
            Button("Finder で表示") { actions.revealInFinder(item) }
                .disabled(item.imageFile == nil)
        }
        Divider()
        Button("削除", role: .destructive) { actions.delete(item) }
    }

    /// ドラッグ開始時に 1 回だけ呼ばれる。一覧行は切り出しなので、本文は DB から全文を取る
    private func dragProvider() -> NSItemProvider {
        switch item.kind {
        case .text:
            let full = store.item(id: item.id)?.text ?? item.textPreview
            return NSItemProvider(object: full as NSString)
        case .file:
            let full = store.item(id: item.id)?.text ?? item.textPreview
            let urls = full.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            if let first = urls.first { return NSItemProvider(contentsOf: first) ?? NSItemProvider() }
            return NSItemProvider()
        case .image:
            let provider = NSItemProvider()
            if let url = store.imageURL(for: item) {
                provider.suggestedName = url.lastPathComponent
                provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier,
                                                    fileOptions: [], visibility: .all) { completion in
                    completion(url, false, nil)
                    return nil
                }
            }
            if provider.registeredTypeIdentifiers.isEmpty {
                if item.hasNonEmptyOCR, let t = store.item(id: item.id)?.ocrText, !t.isEmpty {
                    return NSItemProvider(object: t as NSString)
                }
                return NSItemProvider()
            }
            return provider
        }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .short
        return f
    }()
    private static func relative(_ d: Date) -> String {
        if Date().timeIntervalSince(d) < 60 { return "今" }
        return formatter.localizedString(for: d, relativeTo: Date())
    }
}

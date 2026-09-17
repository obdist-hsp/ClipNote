import AppKit
import SwiftUI
import Combine

/// ダブルクリックで開く拡大プレビュー。← → で前後、Esc で閉じる。
/// 前後移動は一覧の軽量行で行い、表示中の 1 件だけ全文を DB から取る（全件をコピーして抱えない）
@MainActor
final class PreviewController: ObservableObject {
    @Published private(set) var rows: [ClipRow] = []
    @Published private(set) var index = 0
    @Published private(set) var current: ClipItem?

    private var window: PreviewWindow?
    private let store: HistoryStore
    private let actions: ClipActions
    private var cancellable: AnyCancellable?

    init(store: HistoryStore, actions: ClipActions) {
        self.store = store
        self.actions = actions
        cancellable = store.itemChanged.sink { [weak self] id in
            guard let self, id == self.current?.id else { return }
            self.loadCurrent()
        }
    }

    func show(_ row: ClipRow) {
        rows = store.visibleRows
        index = rows.firstIndex(where: { $0.id == row.id }) ?? 0
        if rows.isEmpty { rows = [row]; index = 0 }
        loadCurrent()
        if window == nil {
            let w = PreviewWindow(controller: self)
            w.contentView = NSHostingView(rootView: PreviewView(controller: self, store: store, actions: actions))
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.orderOut(nil) }
    func next() { if index + 1 < rows.count { index += 1; loadCurrent() } }
    func prev() { if index > 0 { index -= 1; loadCurrent() } }

    private func loadCurrent() {
        guard rows.indices.contains(index) else { current = nil; return }
        current = store.item(id: rows[index].id)
    }
}

final class PreviewWindow: NSWindow {
    private static let frameKey = "PreviewWindow.frame"
    private weak var controller: PreviewController?

    init(controller: PreviewController) {
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "プレビュー"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 320, height: 240)
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey), !saved.isEmpty {
            setFrame(NSRectFromString(saved), display: false)
        } else {
            center()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(persistFrame), name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(persistFrame), name: NSWindow.didEndLiveResizeNotification, object: self)
    }

    @objc private func persistFrame() { UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey) }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: orderOut(nil)                          // Esc
        case 123, 126: controller?.prev()               // ← ↑
        case 124, 125: controller?.next()               // → ↓
        default: super.keyDown(with: event)
        }
    }
}

struct PreviewView: View {
    @ObservedObject var controller: PreviewController
    let store: HistoryStore
    let actions: ClipActions
    @State private var image: NSImage?
    @State private var loadedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                if let item = controller.current { content(item) } else { Text("項目がありません").foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: controller.current?.id) { _, _ in loadImage() }
        .onChange(of: controller.current?.imageFile) { _, _ in loadImage() }
        .onAppear { loadImage() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { controller.prev() } label: { Image(systemName: "chevron.left") }
                .disabled(controller.index == 0)
            Text("\(controller.index + 1) / \(controller.rows.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { controller.next() } label: { Image(systemName: "chevron.right") }
                .disabled(controller.index + 1 >= controller.rows.count)
            Spacer()
            if let item = controller.current {
                Text(item.preview.isEmpty ? "" : item.kind == .image ? item.preview : "\(item.utf16Count) 字")
                    .font(.caption).foregroundStyle(.secondary)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Button { actions.toggleBookmark(ClipRow(item)) } label: {
                    Image(systemName: item.isBookmarked ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(item.isBookmarked ? .orange : .primary)
                }
                .help(item.isBookmarked ? "ブックマークを解除" : "ブックマークに追加")
                Button { actions.copy(ClipRow(item)) } label: { Label("コピー", systemImage: "doc.on.doc") }
                    .keyboardShortcut("c", modifiers: .command)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .text, .file:
            ScrollView {
                Text(item.text ?? "")
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .image:
            VSplitOrStack(item: item, image: image, store: store)
        }
    }

    private func loadImage() {
        guard let item = controller.current, item.kind == .image else { image = nil; loadedID = nil; return }
        if loadedID == item.id && image != nil && item.imageFile != nil { return }
        image = store.loadImage(for: item)
        loadedID = item.id
    }
}

/// 画像 + OCR テキスト（あれば下に折りたたみ表示）
private struct VSplitOrStack: View {
    let item: ClipItem
    let image: NSImage?
    let store: HistoryStore
    @State private var showOCR = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark").font(.system(size: 32)).foregroundStyle(.secondary)
                        Text(item.imageDeleted ? "画像は容量上限で削除済み" : "画像を読み込めません").foregroundStyle(.secondary)
                    }
                }
            }
            if let ocr = item.ocrText, !ocr.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $showOCR) {
                    ScrollView {
                        Text(ocr)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 180)
                } label: {
                    Label("OCR テキスト", systemImage: "text.viewfinder").font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .onAppear { showOCR = image == nil }   // 画像が無いときは OCR を開いておく
    }
}

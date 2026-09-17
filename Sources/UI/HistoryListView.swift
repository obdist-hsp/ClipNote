import SwiftUI
import UniformTypeIdentifiers

/// パネルから呼ぶ操作
struct ClipActions {
    var copy: (ClipItem) -> Void
    var toggleBookmark: (ClipItem) -> Void
    var delete: (ClipItem) -> Void
    var revealInFinder: (ClipItem) -> Void
    var copyOCR: (ClipItem) -> Void
    var capture: () -> Void
    var hidePanel: () -> Void
    var preview: (ClipItem) -> Void
}

struct HistoryListView: View {
    @ObservedObject var store: HistoryStore
    let actions: ClipActions
    @State private var queryText = ""
    @State private var flashID: UUID?
    @State private var draggingBookmarkID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.visibleItems.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 220, minHeight: 200)
        .background(VisualEffectBackground())
        .onChange(of: queryText) { _, v in store.setQuery(v) }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 72) // 信号ボタンと重ならないように空ける
                WindowDragRegion()
                    .frame(maxWidth: .infinity)
                    .help("ドラッグでパネルを移動")
                Button(action: actions.hidePanel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("パネルを非表示")
                .padding(.trailing, 8)
            }
            .frame(height: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("検索（本文と OCR 結果、3 文字以上）", text: $queryText)
                        .textFieldStyle(.plain)
                    if !queryText.isEmpty {
                        Button { queryText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    Button(action: actions.capture) { Image(systemName: "scissors") }
                        .buttonStyle(.plain)
                        .help("範囲キャプチャ")
                }
                if !queryText.isEmpty && queryText.trimmingCharacters(in: .whitespaces).count < HistoryStore.minQueryLength {
                    Text("3 文字以上で検索します")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(.leading, 20)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 8)
        }
    }

    // MARK: list

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8, pinnedViews: []) {
                if !store.isSearching && !store.bookmarks.isEmpty {
                    sectionLabel("ブックマーク", systemImage: "bookmark.fill")
                    ForEach(store.bookmarks) { item in
                        card(item)
                            .onDrop(of: [UTType.plainText], delegate: BookmarkDropDelegate(
                                target: item, store: store, dragging: $draggingBookmarkID))
                    }
                    if !store.page.isEmpty {
                        sectionLabel("履歴", systemImage: "clock").padding(.top, 6)
                    }
                }
                ForEach(store.page) { item in
                    card(item)
                        .onAppear { store.loadMoreIfNeeded(current: item) }
                }
                if store.hasMore {
                    ProgressView().controlSize(.small).padding(8)
                        .onAppear { store.loadMore() }
                }
            }
            .padding(10)
        }
    }

    private func card(_ item: ClipItem) -> some View {
        ClipCardView(item: item, store: store, actions: actions,
                     flashing: flashID == item.id,
                     onCopied: { flash(item) },
                     onGripDrag: item.isBookmarked ? {
                        draggingBookmarkID = item.id
                        return NSItemProvider(object: item.id.uuidString as NSString)
                     } : nil)
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    // MARK: footer / empty

    private var footer: some View {
        WindowDragRegion()
            .frame(height: 22)
            .overlay {
                HStack(spacing: 8) {
                    if store.isSearching {
                        Text("\(store.matchCount ?? 0) 件ヒット")
                        if store.hasMore { Text("・\(store.page.count) 件表示中") }
                    } else {
                        Text("全 \(store.totalCount) 件")
                        if !store.bookmarks.isEmpty { Text("・ブックマーク \(store.bookmarks.count)") }
                    }
                    Spacer()
                    Text("画像 \(Self.bytes(store.totalImageBytes))")
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .allowsHitTesting(false)
            }
            .help("ドラッグでパネルを移動。画像は上限 \(Self.bytes(HistoryStore.imageCapacityBytes)) を超えると古いものから削除（テキストは残る）")
    }

    private var emptyState: some View {
        WindowDragRegion()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: store.isSearching ? "magnifyingglass" : "note.text")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(store.isSearching ? "一致する項目がありません" : "コピーした内容がここに並びます")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding()
                .allowsHitTesting(false)
            }
            .help("ドラッグでパネルを移動")
    }

    private func flash(_ item: ClipItem) {
        flashID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if flashID == item.id { flashID = nil }
        }
    }

    static func bytes(_ n: Int) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(n))
    }
}

/// ブックマーク並び替え: グリップからのドラッグが他のブックマークカードに入った時点で入れ替える
struct BookmarkDropDelegate: DropDelegate {
    let target: ClipItem
    let store: HistoryStore
    @Binding var dragging: UUID?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target.id,
              let to = store.bookmarks.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { store.moveBookmark(id: d, to: to) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard dragging != nil else { return false }
        store.commitBookmarkOrder()
        dragging = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

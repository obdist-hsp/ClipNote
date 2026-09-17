import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI の ScrollView/LazyVStack は NSPanel の HostingView 内で全行を測って固まる。
/// 見える行だけ実体化する NSTableView に載せる。
/// データ変更は Store の配列と手元の行列を ID で突き合わせ、変わった行だけ差し替える（全件 reloadData しない）。
struct HistoryTableView: NSViewRepresentable {
    @ObservedObject var store: HistoryStore
    let actions: ClipActions
    var flashID: UUID?
    @Binding var draggingBookmarkID: UUID?
    let onCopied: (ClipRow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = PassthroughTable()
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.addTableColumn(NSTableColumn(identifier: .init("card")))

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.contentInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        scroll.scrollerStyle = .overlay
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        context.coordinator.observeFrameChanges()
        let coordinator = context.coordinator
        table.onEndLiveResize = { coordinator.liveResizeDidEnd() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.store = store
        context.coordinator.actions = actions
        context.coordinator.flashID = flashID
        context.coordinator.dragging = $draggingBookmarkID
        context.coordinator.onCopied = onCopied
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var store: HistoryStore!
        var actions: ClipActions!
        var flashID: UUID?
        var dragging: Binding<UUID?> = .constant(nil)
        var onCopied: ((ClipRow) -> Void) = { _ in }
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        private var rows: [HistoryRow] = []
        private var keys: [RowKey] = []
        private var lastFlashID: UUID?
        /// ライブリサイズ中は見える行しか高さを通知しないので、終了時に画像行をまとめて通知する
        private var needsFullHeightPass = false
        /// これより大きい構造変更は差分適用せず reloadData に落とす
        private static let maxBatchChange = 200

        // MARK: sync（SwiftUI の更新ごとに呼ばれる。変わっていなければ何もしない）

        func sync() {
            guard store != nil, let table else { return }
            fitColumn(table)
            let newRows = HistoryRow.build(store: store)
            let newKeys = newRows.map(\.key)
            let oldRows = rows
            let oldKeys = keys
            let oldFlash = lastFlashID
            let flashChanged = flashID != lastFlashID
            lastFlashID = flashID

            if newKeys == oldKeys {
                // 同じ行構成: 内容が変わった行と、高さが変わった行だけ
                rows = newRows
                guard !newRows.isEmpty else { return }
                withoutAnimation {
                    applyContentChanges(oldRows: oldRows, newRows: newRows, lcp: newRows.count, lcs: 0, table: table)
                    if flashChanged { refreshFlashRows(oldFlash: oldFlash) }
                }
                return
            }
            let partial = applyStructuralChange(oldRows: oldRows, oldKeys: oldKeys, newRows: newRows, newKeys: newKeys, table: table)
            if partial, flashChanged {
                withoutAnimation { refreshFlashRows(oldFlash: oldFlash) }
            }
        }

        /// 位置が対応する行（共通の接頭辞 lcp 行・接尾辞 lcs 行・任意の 1 組）を比べ、
        /// 内容が変わった行は画面上のセルを差し替え、高さが変わった行は高さを再通知する
        private func applyContentChanges(oldRows: [HistoryRow], newRows: [HistoryRow], lcp: Int, lcs: Int,
                                         extra: (old: Int, new: Int)? = nil, table: NSTableView) {
            let width = rowWidth
            var content = IndexSet()
            var height = IndexSet()
            func compare(_ o: Int, _ n: Int) {
                guard newRows[n] != oldRows[o] else { return }
                content.insert(n)
                if newRows[n].height(width: width) != oldRows[o].height(width: width) { height.insert(n) }
            }
            for i in 0..<lcp { compare(i, i) }
            for k in 0..<lcs { compare(oldRows.count - 1 - k, newRows.count - 1 - k) }
            if let extra { compare(extra.old, extra.new) }
            if !height.isEmpty { table.noteHeightOfRows(withIndexesChanged: height) }
            if !content.isEmpty { refreshLiveCells { i, _ in content.contains(i) } }
        }

        /// コピー時の flash（ON/OFF）は該当カードだけ差し替える。押したカードは見えているので在席セルで足りる
        private func refreshFlashRows(oldFlash: UUID?) {
            refreshLiveCells { _, row in
                guard case .item(let r) = row else { return false }
                return r.id == self.flashID || r.id == oldFlash
            }
        }

        /// 行の増減・移動。共通の接頭辞と接尾辞を除いた差分が「純挿入」「純削除」「1 要素の移動」なら部分更新、
        /// それ以外（セクション行の出現、検索語変更、空からの初回投入など）は reloadData。戻り値 = 部分更新で済んだか
        @discardableResult
        private func applyStructuralChange(oldRows: [HistoryRow], oldKeys: [RowKey], newRows: [HistoryRow], newKeys: [RowKey], table: NSTableView) -> Bool {
            let oldCount = oldKeys.count, newCount = newKeys.count
            var lcp = 0
            while lcp < oldCount && lcp < newCount && oldKeys[lcp] == newKeys[lcp] { lcp += 1 }
            var lcs = 0
            while lcs < oldCount - lcp && lcs < newCount - lcp
                    && oldKeys[oldCount - 1 - lcs] == newKeys[newCount - 1 - lcs] { lcs += 1 }
            let removed = oldCount - lcp - lcs
            let inserted = newCount - lcp - lcs

            func fullReload() {
                rows = newRows; keys = newKeys
                table.reloadData()
            }
            guard oldCount > 0, newCount > 0, max(removed, inserted) <= Self.maxBatchChange else { fullReload(); return false }

            if removed == 0, inserted > 0 {
                // 純挿入: 新規コピーの先頭追加、追加読み込みの末尾追加
                let keep = scrollAnchorIfNeeded(insertingAt: lcp, table: table)
                rows = newRows; keys = newKeys
                withoutAnimation {
                    table.beginUpdates()
                    table.insertRows(at: IndexSet(integersIn: lcp..<(lcp + inserted)), withAnimation: [])
                    table.endUpdates()
                    keep?(lcp, inserted)
                    // 同じ更新内で内容だけ変わった行（容量超過で画像が消えた等）も反映する
                    applyContentChanges(oldRows: oldRows, newRows: newRows, lcp: lcp, lcs: lcs, table: table)
                }
                return true
            }
            if inserted == 0, removed > 0 {
                // 純削除: 削除、ブックマーク解除でセクションが残る場合
                rows = newRows; keys = newKeys
                withoutAnimation {
                    table.beginUpdates()
                    table.removeRows(at: IndexSet(integersIn: lcp..<(lcp + removed)), withAnimation: [])
                    table.endUpdates()
                    applyContentChanges(oldRows: oldRows, newRows: newRows, lcp: lcp, lcs: lcs, table: table)
                }
                return true
            }
            if oldCount == newCount, removed == inserted, removed >= 2 {
                // 1 要素の移動（既存テキストの再コピーで先頭へ移る、など）
                let oldEnd = oldCount - lcs, newEnd = newCount - lcs
                var move: (from: Int, to: Int)? = nil
                if newKeys[lcp] == oldKeys[oldEnd - 1], oldKeys[lcp..<(oldEnd - 1)] == newKeys[(lcp + 1)..<newEnd] {
                    move = (oldEnd - 1, lcp)                       // 後ろの要素が前へ
                } else if oldKeys[lcp] == newKeys[newEnd - 1], oldKeys[(lcp + 1)..<oldEnd] == newKeys[lcp..<(newEnd - 1)] {
                    move = (lcp, newEnd - 1)                       // 前の要素が後ろへ
                }
                if let move {
                    rows = newRows; keys = newKeys
                    withoutAnimation {
                        table.beginUpdates()
                        table.moveRow(at: move.from, to: move.to)
                        table.endUpdates()
                        // 移動した行は createdAt やブックマーク有無（画像の幅→高さ）も変わっている
                        applyContentChanges(oldRows: oldRows, newRows: newRows, lcp: lcp, lcs: lcs,
                                            extra: (old: move.from, new: move.to), table: table)
                    }
                    return true
                }
            }
            fullReload()
            return false
        }

        /// 可視範囲より上に行が挿入されるとき、ユーザーが先頭にいなければ表示位置を保つための補正を返す
        private func scrollAnchorIfNeeded(insertingAt index: Int, table: NSTableView) -> ((Int, Int) -> Void)? {
            guard let scroll else { return nil }
            let clip = scroll.contentView
            let origin = clip.bounds.origin
            let atTop = origin.y <= -scroll.contentInsets.top + 1
            let firstVisible = table.rows(in: table.visibleRect).location
            guard !atTop, index <= firstVisible else { return nil }
            return { [weak table, weak scroll] start, count in
                guard let table, let scroll else { return }
                let first = table.rect(ofRow: start)
                let end = start + count
                let insertedHeight = end < table.numberOfRows
                    ? table.rect(ofRow: end).minY - first.minY
                    : table.rect(ofRow: end - 1).maxY - first.minY
                scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + insertedHeight))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        /// 画面に出ているセルのうち条件に合うものだけ、中身を差し替える（セルを作り直さないのでホバー状態が残る）
        private func refreshLiveCells(_ shouldRefresh: (Int, HistoryRow) -> Bool) {
            guard let table else { return }
            table.enumerateAvailableRowViews { rowView, i in
                guard self.rows.indices.contains(i), shouldRefresh(i, self.rows[i]) else { return }
                switch self.rows[i] {
                case .section(let title, let symbol):
                    (rowView.view(atColumn: 0) as? SectionCell)?.set(title: title, symbol: symbol)
                case .item(let row):
                    (rowView.view(atColumn: 0) as? CardCell)?.configure(self.makeCard(row))
                }
            }
        }

        private func withoutAnimation(_ body: () -> Void) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            body()
            NSAnimationContext.endGrouping()
        }

        // MARK: 幅・高さ

        private var rowWidth: CGFloat {
            let w = (scroll?.documentVisibleRect.width ?? table?.bounds.width ?? 280) - 4
            return max(160, w)
        }

        private func fitColumn(_ table: NSTableView) {
            guard let col = table.tableColumns.first else { return }
            let w = max(160, table.enclosingScrollView?.contentSize.width ?? table.bounds.width)
            if abs(col.width - w) > 1 { col.width = w }
        }

        /// 列幅の追従を SwiftUI の updateNSView に頼らず、スクロール領域のサイズ変化で直接行う。
        /// selector 方式のオブザーバは解放時に自動で外れる
        func observeFrameChanges() {
            guard let scroll else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(clipFrameDidChange(_:)),
                                                   name: NSView.frameDidChangeNotification, object: scroll.contentView)
        }

        @objc private func clipFrameDidChange(_ note: Notification) {
            if let table { fitColumn(table) }
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table else { return }
            withoutAnimation {
                if table.inLiveResize {
                    // ドラッグ中は見える行（前後 10 行を含む）だけ。全行に比例する通知はしない
                    let visible = table.rows(in: table.visibleRect)
                    let lo = max(0, visible.location - 10)
                    let hi = min(rows.count, visible.location + visible.length + 10)
                    if lo < hi { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: lo..<hi)) }
                    needsFullHeightPass = true
                } else {
                    noteImageRowHeights(table)
                }
            }
        }

        func liveResizeDidEnd() {
            guard needsFullHeightPass, let table else { return }
            withoutAnimation { noteImageRowHeights(table) }
        }

        /// 幅で高さが変わる行（画像の縦横比、折り返すテキスト／ファイル／OCR）
        private func noteImageRowHeights(_ table: NSTableView) {
            var idx = IndexSet()
            for (i, r) in rows.enumerated() {
                if case .item(let item) = r, HistoryRow.heightDependsOnWidth(item) { idx.insert(i) }
            }
            if !idx.isEmpty { table.noteHeightOfRows(withIndexesChanged: idx) }
            needsFullHeightPass = false
        }

        // MARK: NSTableViewDataSource / Delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 80 }
            return rows[row].height(width: rowWidth)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            switch rows[row] {
            case .section(let title, let symbol):
                let id = NSUserInterfaceItemIdentifier("section")
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SectionCell ?? SectionCell()
                cell.identifier = id
                cell.set(title: title, symbol: symbol)
                return cell
            case .item(let item):
                let id = NSUserInterfaceItemIdentifier("card")
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CardCell ?? CardCell()
                cell.identifier = id
                cell.configure(makeCard(item))
                prefetchIfNeeded(row: row)
                return cell
            }
        }

        private func makeCard(_ item: ClipRow) -> AnyView {
            let dragging = self.dragging
            let onCopied = self.onCopied
            return AnyView(
                ClipCardView(
                    item: item,
                    store: store,
                    actions: actions,
                    flashing: flashID == item.id,
                    onCopied: { onCopied(item) },
                    onGripDrag: item.isBookmarked ? {
                        dragging.wrappedValue = item.id
                        return NSItemProvider(object: item.id.uuidString as NSString)
                    } : nil
                )
                .id(item.id)
                .onDrop(of: [UTType.plainText], delegate: BookmarkDropDelegate(
                    target: item, store: store, dragging: dragging))
            )
        }

        /// 末尾 15 行に入ったら次ページ。行番号で判定し、ID の線形走査はしない
        private func prefetchIfNeeded(row: Int) {
            guard store.hasMore, row >= rows.count - 15 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.store.loadMore()
            }
        }
    }
}

private enum RowKey: Hashable {
    case section(String)
    case item(UUID)
}

private enum HistoryRow: Equatable {
    case section(String, String)
    case item(ClipRow)

    var key: RowKey {
        switch self {
        case .section(let title, _): return .section(title)
        case .item(let row): return .item(row.id)
        }
    }

    @MainActor
    static func build(store: HistoryStore) -> [HistoryRow] {
        var out: [HistoryRow] = []
        out.reserveCapacity(store.bookmarks.count + store.page.count + 2)
        if !store.isSearching && !store.bookmarks.isEmpty {
            out.append(.section("ブックマーク", "bookmark.fill"))
            out.append(contentsOf: store.bookmarks.map { .item($0) })
            if !store.page.isEmpty {
                out.append(.section("履歴", "clock"))
            }
        }
        out.append(contentsOf: store.page.map { .item($0) })
        return out
    }

    func height(width: CGFloat) -> CGFloat {
        switch self {
        case .section: return 22
        case .item(let item): return Self.itemHeight(item, width: width)
        }
    }

    /// パネル幅で高さが変わりうるか。短文の 1 行カードは幅が変わっても定数のまま。
    static func heightDependsOnWidth(_ item: ClipRow) -> Bool {
        switch item.kind {
        case .image:
            return true
        case .text:
            return mightWrap(item.displayText, font: bodyFont)
        case .file:
            return mightWrap(filePreview(item), font: bodyFont)
        }
    }

    static func itemHeight(_ item: ClipRow, width: CGFloat) -> CGFloat {
        // ClipCardView: .padding(8) + VStack spacing 6 + 9pt フッター。
        // 本文は実線数だけ確保する。常に 4 行分だと 1 行カードの下に大きな空きが出る。
        let vPad: CGFloat = 16
        let footer: CGFloat = 16
        let gap: CGFloat = 6
        let fudge: CGFloat = 2
        let inner = max(80, width - 28 - (item.isBookmarked ? 20 : 0))
        let chrome = vPad + gap + footer + fudge
        switch item.kind {
        case .text:
            return chrome + wrappedHeight(item.displayText, width: inner, font: bodyFont, line: 16, maxLines: 4)
        case .file:
            return chrome + wrappedHeight(filePreview(item), width: inner, font: bodyFont, line: 16, maxLines: 3)
        case .image:
            if item.imageDeleted || item.imageFile == nil {
                let ocr = item.hasNonEmptyOCR ? item.displayOCR() : "（文字なし）"
                return chrome + wrappedHeight(ocr, width: inner, font: ocrFont, line: 14, maxLines: 4)
            }
            let maxH: CGFloat = 180
            var imgH: CGFloat = 80
            if let w = item.imageWidth, let h = item.imageHeight, w > 0 {
                imgH = min(maxH, max(48, inner * CGFloat(h) / CGFloat(w)))
            }
            guard item.hasNonEmptyOCR else { return chrome + imgH }
            let ocrH = wrappedHeight(item.displayOCR(120), width: inner, font: ocrThumbFont, line: 13, maxLines: 2)
            return chrome + imgH + gap + ocrH
        }
    }

    private static let bodyFont = NSFont.systemFont(ofSize: 12)
    private static let ocrFont = NSFont.systemFont(ofSize: 11)
    private static let ocrThumbFont = NSFont.systemFont(ofSize: 10)
    /// これより細い列では折り返しうる、という下限（rowWidth の下限 160 − 余白）
    private static let minInner: CGFloat = 80

    private static func filePreview(_ item: ClipRow) -> String {
        item.textPreview.split(separator: "\n").prefix(3)
            .map { ($0 as NSString).lastPathComponent }
            .joined(separator: "\n")
    }

    private static func mightWrap(_ text: String, font: NSFont) -> Bool {
        if text.isEmpty { return false }
        let ns = text as NSString
        if ns.rangeOfCharacter(from: .newlines).location != NSNotFound { return true }
        let w = ns.size(withAttributes: [.font: font]).width
        return w > minInner
    }

    /// AppKit で折り返し線数を数え、SwiftUI Text の lineLimit に合わせた高さを返す。
    /// 短文は size(withAttributes:) だけで済ませ、10000 行でもメインスレッドを止めない。
    private static func wrappedHeight(_ text: String, width: CGFloat, font: NSFont, line: CGFloat, maxLines: Int) -> CGFloat {
        let maxH = line * CGFloat(maxLines)
        guard !text.isEmpty else { return line }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let ns = text as NSString
        let inner = max(1, width)
        if ns.rangeOfCharacter(from: .newlines).location == NSNotFound,
           ns.size(withAttributes: attrs).width <= inner {
            return line
        }
        let rect = ns.boundingRect(
            with: NSSize(width: inner, height: maxH),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        let lines = min(maxLines, max(1, Int(ceil(rect.height / max(1, line) - 0.05))))
        return CGFloat(lines) * line
    }
}

private final class PassthroughTable: NSTableView {
    /// ライブリサイズ終了時に Coordinator が画像行の高さをまとめて通知するためのフック
    var onEndLiveResize: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }
}

private final class SectionCell: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func set(title: String, symbol: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.stringValue = title
    }
}

private final class CardCell: NSView {
    private var hosting: NSHostingView<AnyView>?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(_ root: AnyView) {
        if let hosting {
            hosting.rootView = root
        } else {
            let h = NSHostingView(rootView: root)
            h.translatesAutoresizingMaskIntoConstraints = false
            addSubview(h)
            NSLayoutConstraint.activate([
                h.leadingAnchor.constraint(equalTo: leadingAnchor),
                h.trailingAnchor.constraint(equalTo: trailingAnchor),
                h.topAnchor.constraint(equalTo: topAnchor),
                h.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hosting = h
        }
    }
}

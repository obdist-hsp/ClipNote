import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI の ScrollView/LazyVStack は NSPanel の HostingView 内で全行を測って固まる。
/// 見える行だけ実体化する NSTableView に載せる。
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
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.store = store
        context.coordinator.actions = actions
        context.coordinator.flashID = flashID
        context.coordinator.dragging = $draggingBookmarkID
        context.coordinator.onCopied = onCopied
        context.coordinator.reload()
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
        private var lastKey = ""

        func reload() {
            guard store != nil else { return }
            let key = Self.snapshotKey(store: store, flashID: flashID)
            if let table { fitColumn(table) }
            guard key != lastKey else { return }
            lastKey = key
            rows = HistoryRow.build(store: store)
            table?.reloadData()
        }

        private static func snapshotKey(store: HistoryStore, flashID: UUID?) -> String {
            var s = flashID?.uuidString ?? "-"
            s += "|\(store.bookmarks.count)|\(store.page.count)|\(store.totalCount)|"
            for b in store.bookmarks { s += b.id.uuidString; s += b.hasOCR ? "1" : "0" }
            for p in store.page { s += p.id.uuidString; s += p.hasOCR ? "1" : "0" }
            return s
        }

        private var rowWidth: CGFloat {
            let w = (scroll?.documentVisibleRect.width ?? table?.bounds.width ?? 280) - 4
            return max(160, w)
        }

        private func fitColumn(_ table: NSTableView) {
            guard let col = table.tableColumns.first else { return }
            let w = max(160, table.enclosingScrollView?.contentSize.width ?? table.bounds.width)
            if abs(col.width - w) > 1 { col.width = w }
        }

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
                let dragging = self.dragging
                cell.configure(
                    ClipCardView(
                        item: item,
                        store: store,
                        actions: actions,
                        flashing: flashID == item.id,
                        onCopied: { [onCopied] in onCopied(item) },
                        onGripDrag: item.isBookmarked ? {
                            dragging.wrappedValue = item.id
                            return NSItemProvider(object: item.id.uuidString as NSString)
                        } : nil
                    )
                    .id(item.id)
                    .onDrop(of: [UTType.plainText], delegate: BookmarkDropDelegate(
                        target: item, store: store, dragging: dragging))
                )
                prefetchIfNeeded(row: row)
                return cell
            }
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table else { return }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
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

private enum HistoryRow: Equatable {
    case section(String, String)
    case item(ClipRow)

    @MainActor
    static func build(store: HistoryStore) -> [HistoryRow] {
        var out: [HistoryRow] = []
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

    static func itemHeight(_ item: ClipRow, width: CGFloat) -> CGFloat {
        let vPad: CGFloat = 20
        let footer: CGFloat = 16
        let gap: CGFloat = 6
        let inner = max(80, width - 28 - (item.isBookmarked ? 20 : 0))
        switch item.kind {
        case .text: return vPad + gap + footer + 64
        case .file: return vPad + gap + footer + 48
        case .image:
            if item.imageDeleted || item.imageFile == nil { return vPad + gap + footer + 56 }
            let maxH: CGFloat = 180
            var imgH: CGFloat = 80
            if let w = item.imageWidth, let h = item.imageHeight, w > 0 {
                imgH = min(maxH, max(48, inner * CGFloat(h) / CGFloat(w)))
            }
            let ocr: CGFloat = item.hasNonEmptyOCR ? 22 : 0
            return vPad + gap + footer + imgH + (ocr > 0 ? gap + ocr : 0)
        }
    }
}

private final class PassthroughTable: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
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

    func configure<V: View>(_ view: V) {
        let root = AnyView(view)
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

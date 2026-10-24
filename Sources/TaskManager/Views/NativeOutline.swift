import AppKit
import SwiftUI

/// Rows shown by `NativeOutline`.
protocol OutlineRow {
    var id: String { get }
    var children: [Self]? { get }
}

struct OutlineColumn<Row> {
    let id: String
    let title: String
    var width: CGFloat = 80
    var minWidth: CGFloat = 40
    var alignment: NSTextAlignment = .right
    var defaultAscending = false
    var canHide = true
    var text: (Row) -> String
    /// Name-style column: icon + text (+ optional trailing badge).
    var icon: ((Row) -> NSImage?)? = nil
    var badge: ((Row) -> NSImage?)? = nil
    var bold: ((Row) -> Bool)? = nil
    var secondary: Bool = false
    /// Optional 0…1 usage drawn as a thin bar behind the value.
    var bar: ((Row) -> Double)? = nil
    var barColor: NSColor = .controlAccentColor
    /// Header tooltip explaining what the number means.
    var help: String? = nil
}

/// NSOutlineView wrapped for SwiftUI.
///
/// Why not SwiftUI `Table`: with ~600 live rows it re-diffs the whole outline
/// on every tick (measured ~12 % of a core on its own). This keeps stable node
/// objects and, when the row order is unchanged, reloads only the rows that
/// are on screen — typically ~30 — so an update costs a couple of ms.
struct NativeOutline<Row: OutlineRow>: NSViewRepresentable {
    var rows: [Row]
    var columns: [OutlineColumn<Row>]
    var autosaveName: String
    var selection: Set<String>
    var sortKey: String
    var sortAscending: Bool
    var isExpanded: (String) -> Bool
    var onSelect: (Set<String>) -> Void
    var onSort: (String, Bool) -> Void
    var onExpand: (String, Bool) -> Void
    var onDoubleClick: (String) -> Void
    var menu: ([String]) -> NSMenu?
    /// When set, the row with this id is scrolled into view once.
    var scrollTo: String? = nil
    var onScrolled: () -> Void = {}
    /// When set, a single click shows this view in a popover next to the row.
    var popover: ((String) -> AnyView?)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .fullWidth
        outline.rowSizeStyle = .custom
        outline.rowHeight = 22
        outline.intercellSpacing = NSSize(width: 6, height: 0)
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.floatsGroupRows = false

        for (i, c) in columns.enumerated() {
            let col = NSTableColumn(identifier: .init(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.minWidth
            col.headerCell.alignment = c.alignment
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: c.defaultAscending)
            col.headerToolTip = c.help
            outline.addTableColumn(col)
            if i == 0 { outline.outlineTableColumn = col }
        }
        outline.autosaveName = autosaveName
        outline.autosaveTableColumns = true
        outline.autosaveExpandedItems = false

        let c = context.coordinator
        c.parent = self
        c.outline = outline
        outline.dataSource = c
        outline.delegate = c
        outline.target = c
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.action = #selector(Coordinator.clicked(_:))
        let m = NSMenu()
        m.delegate = c
        outline.menu = m
        outline.headerView?.menu = c.headerMenu()
        outline.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: sortAscending)]

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        c.apply(rows)
        // Saved column widths may come from a wider window: fit them to this one.
        DispatchQueue.main.async { outline.sizeToFit() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.apply(rows)
    }

    // MARK: -

    final class Node: NSObject {
        let id: String
        var row: Row
        var children: [Node] = []
        init(_ row: Row) { self.id = row.id; self.row = row }
        override var hash: Int { id.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Node)?.id == id }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: NativeOutline!
        weak var outline: NSOutlineView?
        private var roots: [Node] = []
        private var cache: [String: Node] = [:]
        private var shape: [String] = []        // ids of visible rows, in order
        private var applying = false
        private var iconObserver: NSObjectProtocol?

        override init() {
            super.init()
            iconObserver = NotificationCenter.default.addObserver(forName: IconCache.didUpdate, object: nil, queue: .main) { [weak self] _ in
                guard let o = self?.outline else { return }
                let visible = o.rows(in: o.visibleRect)
                guard visible.length > 0 else { return }
                o.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                             columnIndexes: IndexSet(integer: 0))
            }
        }

        deinit { if let iconObserver { NotificationCenter.default.removeObserver(iconObserver) } }

        func apply(_ rows: [Row]) {
            guard let outline else { return }
            applying = true
            defer { applying = false }

            var nextCache: [String: Node] = [:]
            nextCache.reserveCapacity(cache.count)
            func node(_ r: Row) -> Node {
                let n = cache[r.id] ?? Node(r)
                n.row = r
                n.children = (r.children ?? []).map(node)
                nextCache[r.id] = n
                return n
            }
            roots = rows.map(node)
            cache = nextCache

            let newShape = visibleShape()
            if newShape == shape && outline.numberOfRows == newShape.count {
                // Same rows in the same order: refresh only what's on screen.
                let visible = outline.rows(in: outline.visibleRect)
                if visible.length > 0 {
                    outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                                       columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
                }
            } else {
                outline.reloadData()
                syncExpansion(roots)
                shape = visibleShape()
            }
            syncSelection()
            if let target = parent.scrollTo, let n = cache[target] {
                let r = outline.row(forItem: n)
                if r >= 0 {
                    outline.scrollRowToVisible(r)
                    outline.window?.makeFirstResponder(outline)
                }
                DispatchQueue.main.async { self.parent.onScrolled() }
            }
        }

        /// Ids in display order, honouring the expansion state we want.
        private func visibleShape() -> [String] {
            var out: [String] = []
            func walk(_ nodes: [Node]) {
                for n in nodes {
                    out.append(n.id)
                    if !n.children.isEmpty && parent.isExpanded(n.id) { walk(n.children) }
                }
            }
            walk(roots)
            return out
        }

        private func syncExpansion(_ nodes: [Node]) {
            guard let outline else { return }
            for n in nodes where !n.children.isEmpty {
                if parent.isExpanded(n.id) {
                    if !outline.isItemExpanded(n) { outline.expandItem(n) }
                    syncExpansion(n.children)
                } else if outline.isItemExpanded(n) {
                    outline.collapseItem(n)
                }
            }
        }

        private func syncSelection() {
            guard let outline else { return }
            var idx = IndexSet()
            for id in parent.selection {
                if let n = cache[id] {
                    let r = outline.row(forItem: n)
                    if r >= 0 { idx.insert(r) }
                }
            }
            if idx != outline.selectedRowIndexes { outline.selectRowIndexes(idx, byExtendingSelection: false) }
        }

        // MARK: Data source

        func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.children.count ?? roots.count
        }
        func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Node)?.children[index] ?? roots[index]
        }
        func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Node)?.children.isEmpty ?? true)
        }

        func outlineView(_ o: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let d = o.sortDescriptors.first, let key = d.key else { return }
            DispatchQueue.main.async { self.parent.onSort(key, d.ascending) }
        }

        // MARK: Delegate

        func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let tableColumn, let node = item as? Node,
                  let col = parent.columns.first(where: { $0.id == tableColumn.identifier.rawValue }) else { return nil }
            let row = node.row
            let cell = (o.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? Cell) ?? Cell(column: col, id: tableColumn.identifier)
            cell.configure(text: col.text(row), icon: col.icon?(row), badge: col.badge?(row), bold: col.bold?(row) ?? false,
                           bar: col.bar?(row))
            return cell
        }

        func outlineViewSelectionDidChange(_ n: Notification) {
            guard !applying, let o = outline else { return }
            let ids = Set(o.selectedRowIndexes.compactMap { (o.item(atRow: $0) as? Node)?.id })
            DispatchQueue.main.async { self.parent.onSelect(ids) }
        }

        func outlineViewItemDidExpand(_ n: Notification) {
            guard !applying, let node = n.userInfo?["NSObject"] as? Node else { return }
            shape = visibleShape(expanding: node.id, true)
            parent.onExpand(node.id, true)
        }

        func outlineViewItemDidCollapse(_ n: Notification) {
            guard !applying, let node = n.userInfo?["NSObject"] as? Node else { return }
            shape = visibleShape(expanding: node.id, false)
            parent.onExpand(node.id, false)
        }

        private func visibleShape(expanding id: String, _ open: Bool) -> [String] {
            var out: [String] = []
            func walk(_ nodes: [Node]) {
                for n in nodes {
                    out.append(n.id)
                    let expanded = n.id == id ? open : parent.isExpanded(n.id)
                    if !n.children.isEmpty && expanded { walk(n.children) }
                }
            }
            walk(roots)
            return out
        }

        private var shownPopover: NSPopover?
        private var shownFor: String?

        @objc func clicked(_ sender: NSOutlineView) {
            let r = sender.clickedRow
            guard r >= 0, let node = sender.item(atRow: r) as? Node, let make = parent.popover else { return }
            if shownPopover?.isShown == true {
                shownPopover?.performClose(nil)
                if shownFor == node.id { shownFor = nil; return }
            }
            guard let content = make(node.id) else { return }
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            let host = NSHostingController(rootView: content)
            host.sizingOptions = .preferredContentSize       // otherwise the popover opens at zero size
            p.contentViewController = host
            let rect = sender.rect(ofRow: r)
            let anchor = NSRect(x: min(rect.minX + 260, rect.maxX - 20), y: rect.minY, width: 20, height: rect.height)
            p.show(relativeTo: anchor, of: sender, preferredEdge: .maxX)
            shownPopover = p
            shownFor = node.id
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            shownPopover?.performClose(nil)
            let r = sender.clickedRow
            guard r >= 0, let node = sender.item(atRow: r) as? Node else { return }
            parent.onDoubleClick(node.id)
        }

        // MARK: Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let o = outline else { return }
            let clicked = o.clickedRow
            var ids: [String]
            if clicked >= 0, !o.selectedRowIndexes.contains(clicked) {
                // Right-click outside the selection acts on that row (Finder behaviour).
                o.selectRowIndexes([clicked], byExtendingSelection: false)
                ids = [(o.item(atRow: clicked) as? Node)?.id].compactMap { $0 }
            } else {
                ids = o.selectedRowIndexes.compactMap { (o.item(atRow: $0) as? Node)?.id }
            }
            guard !ids.isEmpty, let built = parent.menu(ids) else { return }
            for item in built.items { built.removeItem(item); menu.addItem(item) }
        }

        func headerMenu() -> NSMenu {
            let m = NSMenu()
            for c in parent.columns where c.canHide {
                let item = ClosureMenuItem(title: c.title) { [weak self] in
                    guard let col = self?.outline?.tableColumn(withIdentifier: .init(c.id)) else { return }
                    col.isHidden.toggle()
                }
                m.addItem(item)
            }
            m.delegate = HeaderMenuDelegate.shared
            HeaderMenuDelegate.shared.outline = outline
            return m
        }
    }

    final class Cell: NSTableCellView {
        private let label = NSTextField(labelWithString: "")
        private let iconView = NSImageView()
        private let badgeView = NSImageView()
        private let barLayer = CALayer()
        private var barFraction: Double = 0
        private let column: OutlineColumn<Row>

        init(column: OutlineColumn<Row>, id: NSUserInterfaceItemIdentifier) {
            self.column = column
            super.init(frame: .zero)
            identifier = id
            if column.bar != nil {
                wantsLayer = true
                barLayer.backgroundColor = column.barColor.withAlphaComponent(0.28).cgColor
                barLayer.cornerRadius = 2
                layer?.addSublayer(barLayer)
            }
            label.lineBreakMode = column.alignment == .left ? .byTruncatingMiddle : .byTruncatingTail
            label.alignment = column.alignment
            label.font = column.alignment == .right
                ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.systemFontSize)
            if column.secondary { label.textColor = .secondaryLabelColor }
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
            textField = label
            if column.icon != nil {
                iconView.translatesAutoresizingMaskIntoConstraints = false
                iconView.imageScaling = .scaleProportionallyUpOrDown
                badgeView.translatesAutoresizingMaskIntoConstraints = false
                addSubview(iconView)
                addSubview(badgeView)
                imageView = iconView
                NSLayoutConstraint.activate([
                    iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                    iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                    iconView.widthAnchor.constraint(equalToConstant: 16),
                    iconView.heightAnchor.constraint(equalToConstant: 16),
                    label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                    label.centerYAnchor.constraint(equalTo: centerYAnchor),
                    badgeView.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
                    badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
                    badgeView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
                ])
            } else {
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                    label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                    label.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            guard column.bar != nil else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let w = bounds.width * CGFloat(max(0, min(1, barFraction)))
            barLayer.frame = CGRect(x: bounds.width - w, y: bounds.midY - 8, width: w, height: 16)
            CATransaction.commit()
        }

        func configure(text: String, icon: NSImage?, badge: NSImage?, bold: Bool, bar: Double? = nil) {
            if let bar, abs(bar - barFraction) > 0.001 { barFraction = bar; needsLayout = true }
            if label.stringValue != text { label.stringValue = text }
            let wantBold = bold
            if (label.font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false) != wantBold {
                let size = NSFont.systemFontSize
                label.font = column.alignment == .right
                    ? .monospacedDigitSystemFont(ofSize: size, weight: wantBold ? .semibold : .regular)
                    : .systemFont(ofSize: size, weight: wantBold ? .semibold : .regular)
            }
            if column.icon != nil {
                if iconView.image !== icon { iconView.image = icon }
                iconView.isHidden = icon == nil
                if badgeView.image !== badge { badgeView.image = badge }
                badgeView.isHidden = badge == nil
            }
        }
    }
}

/// Keeps the column-visibility checkmarks in the header menu current.
final class HeaderMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = HeaderMenuDelegate()
    weak var outline: NSOutlineView?
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let o = menu.items.first.flatMap({ _ in outline }) else { return }
        for item in menu.items {
            if let col = o.tableColumns.first(where: { $0.title == item.title }) { item.state = col.isHidden ? .off : .on }
        }
    }
}

/// NSMenuItem that runs a closure (keeps menu construction declarative).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, enabled: Bool = true, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.target = self
        self.isEnabled = enabled
        self.state = state
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

extension NSMenu {
    static func build(_ items: [NSMenuItem]) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        items.forEach(m.addItem)
        return m
    }
}

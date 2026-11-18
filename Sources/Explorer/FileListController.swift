import AppKit
import ExplorerCore

@MainActor
protocol FileListDelegate: AnyObject {
    func fileListOpen(_ items: [FileItem], inNewTab: Bool)
    func fileListSelectionDidChange()
    func fileListMenu(for items: [FileItem]) -> NSMenu?
    func fileListRename(_ item: FileItem, to newName: String)
    func fileListHandleKey(_ event: NSEvent) -> Bool
    /// 빈 곳에 놓을 때의 대상 폴더. nil 이면 놓을 수 없다.
    func fileListDropDestination() -> URL?
    func fileListDrop(_ urls: [URL], onto folder: URL, operation: NSDragOperation) -> Bool
    func fileListSortDidChange(_ order: ExplorerCore.SortOrder)
}

/// 파일 목록. 자세히 보기는 NSTableView(V1), 나머지 보기는 NSCollectionView(V3).
@MainActor
final class FileListController: NSObject {
    weak var delegate: FileListDelegate?

    let containerView = NSView()
    let tableView = FileTableView()
    let collectionView = FileCollectionView()
    private let tableScroll = NSScrollView()
    private let collectionScroll = NSScrollView()
    private let messageLabel = UI.label("", color: .secondaryLabelColor)

    private(set) var items: [FileItem] = []
    var mode: ViewMode = .details { didSet { if oldValue != mode { applyMode(from: oldValue) } } }
    var showExtensions = true
    var showsFolderColumn = false {
        didSet { tableView.tableColumns.first { $0.identifier == Column.folder }?.isHidden = !showsFolderColumn }
    }

    private var activeRename: RenameEditor?
    var isRenaming: Bool { activeRename != nil }
    private var suppressSortCallback = false
    private var suppressSelectionCallback = false

    enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let date = NSUserInterfaceItemIdentifier("dateModified")
        static let type = NSUserInterfaceItemIdentifier("type")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let folder = NSUserInterfaceItemIdentifier("folder")
    }

    var activeView: NSView { mode == .details ? tableView : collectionView }

    override init() {
        super.init()
        setUpTable()
        setUpCollection()
        UI.pin(tableScroll, to: containerView)
        UI.pin(collectionScroll, to: containerView)
        containerView.addSubview(messageLabel)
        messageLabel.alignment = .center
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 60),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: containerView.widthAnchor, constant: -40),
        ])
        messageLabel.isHidden = true
        applyMode(from: mode)
    }

    // MARK: 설정

    private func setUpTable() {
        tableView.listController = self
        tableView.style = .fullWidth
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsTypeSelect = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.setAccessibilityLabel("파일 목록")

        addColumn(Column.name, "이름", width: 320, sortKey: .name)
        addColumn(Column.date, "수정한 날짜", width: 160, sortKey: .dateModified)
        addColumn(Column.type, "유형", width: 150, sortKey: .type)
        addColumn(Column.size, "크기", width: 100, sortKey: .size)
        addColumn(Column.folder, "폴더", width: 300, sortKey: nil)
        tableView.tableColumns.last?.isHidden = true
        tableView.autosaveName = "ExplorerDetailsColumns"
        tableView.autosaveTableColumns = true

        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.every, forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: false)

        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
    }

    private func addColumn(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, sortKey: SortKey?) {
        let column = NSTableColumn(identifier: id)
        column.title = title
        column.width = width
        column.minWidth = 50
        if let sortKey {
            column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey.rawValue, ascending: true)
        }
        if id == Column.size { column.headerCell.alignment = .right }
        tableView.addTableColumn(column)
    }

    private func setUpCollection() {
        collectionView.listController = self
        collectionView.collectionViewLayout = NSCollectionViewFlowLayout()
        collectionView.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.textBackgroundColor]
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask(.every, forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: false)
        collectionView.setAccessibilityLabel("파일 목록")

        collectionScroll.documentView = collectionView
        collectionScroll.hasVerticalScroller = true
        collectionScroll.autohidesScrollers = true
    }

    /// 보기를 바꾼다. 선택은 바꾸기 전 보기(previous)에서 읽어 새 보기로 옮긴다 (M4).
    private func applyMode(from previous: ViewMode) {
        let selection = selectedIndexes(in: previous).filter { $0 < items.count }.map { items[$0].url }
        let hadFocus = containerView.window.map { isFocused(in: $0) } ?? false
        cancelRename()
        tableScroll.isHidden = mode != .details
        collectionScroll.isHidden = mode == .details
        if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = FileIconItem.itemSize(for: mode)
            layout.minimumInteritemSpacing = mode == .list ? 0 : 6
            layout.minimumLineSpacing = mode == .list ? 0 : 6
            layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            layout.invalidateLayout()
        }
        // 숨은 보기는 setItems 에서 다시 그리지 않으므로 여기서 채운다. 이전 보기의 선택은 비운다.
        suppressSelectionCallback = true
        if mode == .details {
            tableView.reloadData()
            collectionView.selectionIndexPaths = []
        } else {
            collectionView.reloadData()
            tableView.deselectAll(nil)
        }
        suppressSelectionCallback = false
        select(selection, scroll: true, notify: false)
        if hadFocus { focus() }
    }

    private func isFocused(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === tableView || responder === collectionView
    }

    // MARK: 항목

    func setItems(_ newItems: [FileItem], selecting urls: [URL]) {
        if isRenaming { cancelRename() }
        items = newItems
        suppressSelectionCallback = true
        // 보이는 보기만 다시 그린다. 숨은 보기는 보기를 바꿀 때 채우고 선택도 그때 옮긴다 (M8).
        if mode == .details { tableView.reloadData() } else { collectionView.reloadData() }
        suppressSelectionCallback = false
        select(urls, scroll: false)
    }

    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil
    }

    func displayName(_ item: FileItem) -> String {
        Formats.displayName(item, showExtensions: showExtensions)
    }

    var selectedIndexes: IndexSet { selectedIndexes(in: mode) }

    private func selectedIndexes(in mode: ViewMode) -> IndexSet {
        if mode == .details { return tableView.selectedRowIndexes }
        return IndexSet(collectionView.selectionIndexPaths.map(\.item))
    }

    var selectedItems: [FileItem] {
        selectedIndexes.filter { $0 < items.count }.map { items[$0] }
    }

    var selectedURLs: [URL] { selectedItems.map(\.url) }

    func index(of url: URL) -> Int? {
        let key = Location.key(url)
        return items.firstIndex { Location.key($0.url) == key }
    }

    func select(_ urls: [URL], scroll: Bool = true, notify: Bool = true) {
        let keys = Set(urls.map(Location.key))
        let indexes = IndexSet(items.indices.filter { keys.contains(Location.key(items[$0].url)) })
        select(indexes: indexes, scroll: scroll, notify: notify)
    }

    func select(indexes: IndexSet, scroll: Bool = true, notify: Bool = true) {
        // 선택은 보이는 보기에만 둔다. 보기를 바꿀 때 applyMode 가 옮긴다.
        suppressSelectionCallback = true
        if mode == .details {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        } else {
            collectionView.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        }
        suppressSelectionCallback = false
        if scroll, let first = indexes.first {
            if mode == .details {
                tableView.scrollRowToVisible(first)
            } else {
                collectionView.scrollToItems(at: [IndexPath(item: first, section: 0)], scrollPosition: .nearestHorizontalEdge)
            }
        }
        if notify { delegate?.fileListSelectionDidChange() }
    }

    func invertSelection() {
        let current = selectedIndexes
        select(indexes: IndexSet(items.indices.filter { !current.contains($0) }), scroll: false)
    }

    func focus() {
        containerView.window?.makeFirstResponder(activeView)
    }

    func updateSortIndicator(_ order: ExplorerCore.SortOrder) {
        suppressSortCallback = true
        tableView.sortDescriptors = [NSSortDescriptor(key: order.key.rawValue, ascending: order.ascending)]
        suppressSortCallback = false
    }

    /// 잘라내기·숨김 상태에 따른 흐림(V8)만 다시 칠한다. 선택은 그대로 둔다.
    func refreshItemAppearance() {
        tableView.enumerateAvailableRowViews { rowView, row in
            guard row < self.items.count else { return }
            let alpha = itemAlpha(self.items[row])
            for column in 0..<rowView.numberOfColumns {
                (rowView.view(atColumn: column) as? NSView)?.alphaValue = alpha
            }
        }
        for indexPath in collectionView.indexPathsForVisibleItems() where indexPath.item < items.count {
            collectionView.item(at: indexPath)?.view.alphaValue = itemAlpha(items[indexPath.item])
        }
    }

    // MARK: 이름 바꾸기 (F3)

    func beginRename(_ url: URL) {
        guard let index = index(of: url) else { return }
        cancelRename()
        select(indexes: [index], scroll: true)
        let field: NSTextField?
        if mode == .details {
            let column = tableView.column(withIdentifier: Column.name)
            field = (tableView.view(atColumn: column, row: index, makeIfNecessary: true) as? NSTableCellView)?.textField
        } else {
            collectionView.layoutSubtreeIfNeeded()
            field = (collectionView.item(at: IndexPath(item: index, section: 0)) as? FileIconItem)?.textField
        }
        guard let field else { return }
        let item = items[index]
        let editor = RenameEditor(field: field, item: item, showExtensions: showExtensions)
        editor.onCommit = { [weak self] newName in self?.delegate?.fileListRename(item, to: newName) }
        editor.onEnd = { [weak self] in
            self?.activeRename = nil
            self?.focus()
        }
        activeRename = editor
        editor.begin()
    }

    func cancelRename() {
        activeRename?.cancel()
        activeRename = nil
    }

    // MARK: 입력 (FileTableView, FileCollectionView 에서 부른다)

    func handleKey(_ event: NSEvent) -> Bool {
        delegate?.fileListHandleKey(event) ?? false
    }

    func contextMenu(at index: Int?) -> NSMenu? {
        if let index, index < items.count {
            if !selectedIndexes.contains(index) { select(indexes: [index], scroll: false) }
            return delegate?.fileListMenu(for: selectedItems)
        }
        select(indexes: [], scroll: false)
        return delegate?.fileListMenu(for: [])
    }

    func open(index: Int, inNewTab: Bool) {
        guard index >= 0, index < items.count else { return }
        let item = items[index]
        if inNewTab {
            guard item.isNavigable else { return }
            delegate?.fileListOpen([item], inNewTab: true)
        } else {
            let selection = selectedIndexes.contains(index) ? selectedItems : [item]
            delegate?.fileListOpen(selection, inNewTab: false)
        }
    }

    /// V9 아이콘 보기의 타이핑 이동. 표시 이름이 입력으로 시작하는 첫 항목을 고른다.
    func typeSelect(_ prefix: String) -> Bool {
        guard let index = items.firstIndex(where: { displayName($0).lowercased().hasPrefix(prefix.lowercased()) })
        else { return false }
        select(indexes: [index], scroll: true)
        return true
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        if row >= 0 { open(index: row, inNewTab: false) }
    }

    fileprivate func selectionChangedByUser() {
        guard !suppressSelectionCallback else { return }
        delegate?.fileListSelectionDidChange()
    }
}

// MARK: - 자세히 보기

extension FileListController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < items.count else { return nil }
        let item = items[row]
        let id = column.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
        guard let text = cell.textField else { return cell }
        switch id {
        case Column.name:
            text.stringValue = displayName(item)
            cell.imageView?.image = IconCache.shared.icon(for: item.url)
        case Column.date:
            text.stringValue = Formats.dateString(item.dateModified)
        case Column.type:
            text.stringValue = item.typeDescription
        case Column.size:
            text.stringValue = item.isNavigable ? "" : item.size.map(SizeFormatter.explorerSize) ?? ""
        case Column.folder:
            text.stringValue = Formats.folderPath(item.url)
            text.toolTip = item.url.deletingLastPathComponent().path
        default:
            break
        }
        cell.alphaValue = itemAlpha(item)
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.cell?.truncatesLastVisibleLine = true
        cell.addSubview(text)
        cell.textField = text
        var leading = cell.leadingAnchor
        if id == Column.name {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = image.trailingAnchor
        } else {
            text.textColor = .secondaryLabelColor
        }
        if id == Column.size { text.alignment = .right }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionChangedByUser()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSortCallback, let descriptor = tableView.sortDescriptors.first,
              let key = SortKey(rawValue: descriptor.key ?? "") else { return }
        delegate?.fileListSortDidChange(ExplorerCore.SortOrder(key: key, ascending: descriptor.ascending))
    }

    /// V9 타이핑 이동은 NSTableView 기본 기능에 표시 이름을 넘긴다.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier == Column.name, row < items.count else { return nil }
        return displayName(items[row])
    }
}

// MARK: - 아이콘 보기

extension FileListController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let view = collectionView.makeItem(withIdentifier: FileIconItem.identifier, for: indexPath)
        if let cell = view as? FileIconItem, indexPath.item < items.count {
            let item = items[indexPath.item]
            cell.configure(name: displayName(item), icon: IconCache.shared.icon(for: item.url),
                           mode: mode, alpha: itemAlpha(item))
        }
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionChangedByUser()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionChangedByUser()
    }
}

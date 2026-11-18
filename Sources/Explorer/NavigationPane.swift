import AppKit
import ExplorerCore

/// 탐색 창 항목.
@MainActor
final class NavNode: NSObject {
    enum Kind { case home, header, folder, pinned, thisMac, volume, trash }
    let kind: Kind
    let title: String
    let url: URL?
    let volume: VolumeInfo?
    /// nil 이면 아직 하위 폴더를 읽지 않았다.
    var children: [NavNode]?
    /// 백그라운드에서 하위 폴더를 읽는 중.
    var isLoading = false

    init(_ kind: Kind, title: String, url: URL?, volume: VolumeInfo? = nil, children: [NavNode]? = nil) {
        self.kind = kind
        self.title = title
        self.url = url
        self.volume = volume
        self.children = children
    }

    var isExpandable: Bool { kind != .trash }

    /// 읽어 둔 하위 폴더. 아직 읽지 않았으면 빈 배열이다.
    var loadedChildren: [NavNode] { children ?? [] }

    /// 폴더 트리 펼치기. 느린 볼륨에서도 화면이 멈추지 않도록 백그라운드에서 읽고 끝나면 completion 을 부른다.
    /// 숨김 폴더는 트리에 넣지 않는다.
    func loadChildrenInBackground(_ completion: @escaping @MainActor (NavNode) -> Void) {
        guard children == nil, !isLoading, let url else { return }
        isLoading = true
        Task { [weak self] in
            let folders = await Task.detached(priority: .userInitiated) { () -> [FileItem] in
                let items = ((try? DirectoryLister.contents(of: url, showHidden: false)) ?? []).filter(\.isNavigable)
                return FileSorter.sorted(items, by: ExplorerCore.SortOrder())
            }.value
            guard let self else { return }
            self.isLoading = false
            self.children = folders.map { NavNode(.folder, title: $0.name, url: $0.url) }
            completion(self)
        }
    }
}

/// N6 탐색 창: 홈 / 빠른 액세스 / 내 Mac(볼륨, 용량 막대) / 휴지통.
@MainActor
final class NavigationPane: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onNavigate: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onDrop: (([URL], URL, NSDragOperation) -> Bool)?
    var onProperties: ((URL) -> Void)?
    var onTrash: (([URL]) -> Void)?

    private let outline = NavOutlineView()
    private let scroll = NSScrollView()
    private var roots: [NavNode] = []
    private var quickAccess = NavNode(.header, title: "빠른 액세스", url: nil, children: [])
    private var thisMac = NavNode(.thisMac, title: "내 Mac", url: Location.thisMac, children: [])
    private var suppressSelection = false
    /// 마지막으로 select(url:) 로 고른 위치. 트리를 다시 그린 뒤 선택을 되살릴 때 쓴다.
    private var selectedURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("nav"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = true
        outline.dataSource = self
        outline.delegate = self
        outline.pane = self
        outline.registerForDraggedTypes([.fileURL])
        outline.setAccessibilityLabel("탐색 창")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        UI.pin(scroll, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 데이터

    func reloadAll() {
        quickAccess.children = pinnedNodes()
        thisMac.children = volumeNodes()
        var nodes = [NavNode(.home, title: "홈", url: Location.home), quickAccess, thisMac]
        if let trash = Location.trash { nodes.append(NavNode(.trash, title: "휴지통", url: trash)) }
        roots = nodes
        outline.reloadData()
        outline.expandItem(quickAccess)
        outline.expandItem(thisMac)
    }

    func reloadPins() {
        quickAccess.children = pinnedNodes()
        outline.reloadItem(quickAccess, reloadChildren: true)
        outline.expandItem(quickAccess)
    }

    func reloadVolumes() {
        thisMac.children = volumeNodes()
        outline.reloadItem(thisMac, reloadChildren: true)
        outline.expandItem(thisMac)
    }

    private func pinnedNodes() -> [NavNode] {
        AppState.shared.pins.folders.map {
            NavNode(.pinned, title: FileManager.default.displayName(atPath: $0.path), url: $0)
        }
    }

    private func volumeNodes() -> [NavNode] {
        VolumeLister.volumes().map { NavNode(.volume, title: $0.name, url: $0.url, volume: $0) }
    }

    /// 현재 위치와 같은 항목을 고른다. 펼쳐진 항목만 찾는다.
    func select(url: URL) {
        selectedURL = url
        let key = Location.isThisMac(url) ? url.absoluteString : Location.key(url)
        var match = -1
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? NavNode, let nodeURL = node.url else { continue }
            let nodeKey = Location.isThisMac(nodeURL) ? nodeURL.absoluteString : Location.key(nodeURL)
            if nodeKey == key { match = row; break }
        }
        suppressSelection = true
        if match >= 0 {
            outline.selectRowIndexes([match], byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        suppressSelection = false
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? NavNode else { return roots.count }
        return node.loadedChildren.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? NavNode else { return roots[index] }
        return node.loadedChildren[index]
    }

    /// 펼칠 때 처음이면 하위 폴더를 백그라운드에서 읽고, 다 읽으면 그 항목만 다시 그린다.
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? NavNode, node.children == nil else { return }
        node.loadChildrenInBackground { [weak self] node in
            guard let self else { return }
            self.outline.reloadItem(node, reloadChildren: true)
            if node.loadedChildren.isEmpty {
                self.outline.collapseItem(node)
            } else {
                self.outline.expandItem(node)
            }
            self.select(url: self.selectedURL ?? node.url ?? Location.home)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? NavNode else { return false }
        if let children = node.children, node.kind == .folder { return !children.isEmpty }
        return node.isExpandable
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? NavNode else { return nil }
        if node.kind == .header {
            let cell = NSTableCellView()
            let text = UI.label(node.title, size: NSFont.smallSystemFontSize, bold: true, color: .secondaryLabelColor)
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        if let volume = node.volume { return VolumeCellView(volume: volume) }
        let cell = NSTableCellView()
        let image = NSImageView(image: icon(for: node))
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = UI.label(node.title)
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func icon(for node: NavNode) -> NSImage {
        switch node.kind {
        case .home: return UI.symbol("house", "홈")
        case .thisMac: return UI.symbol("desktopcomputer", "내 Mac")
        case .trash: return UI.symbol("trash", "휴지통")
        case .pinned: return node.url.map { IconCache.shared.icon(for: $0) } ?? UI.symbol("folder")
        default: return node.url.map { IconCache.shared.icon(for: $0) } ?? UI.symbol("folder")
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? NavNode)?.kind == .volume ? 42 : 24
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? NavNode)?.kind != .header
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let node = outline.item(atRow: outline.selectedRow) as? NavNode,
              let url = node.url else { return }
        onNavigate?(url)
    }

    // MARK: 놓기 (F10)

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? NavNode, index == NSOutlineViewDropOnItemIndex,
              let url = node.url, !Location.isThisMac(url) else { return [] }
        if node.kind == .trash { return .move }
        return DragPolicy.operation(for: info, urls: DragPolicy.fileURLs(from: info.draggingPasteboard), destination: url)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? NavNode, let url = node.url else { return false }
        let urls = DragPolicy.fileURLs(from: info.draggingPasteboard)
        if node.kind == .trash {
            guard !urls.isEmpty, let onTrash else { return false }
            onTrash(urls)
            return true
        }
        let operation = DragPolicy.operation(for: info, urls: urls, destination: url)
        guard !operation.isEmpty else { return false }
        return onDrop?(urls, url, operation) ?? false
    }

    // MARK: 우클릭, 가운데 클릭 (N7, N8)

    func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0, let node = outline.item(atRow: row) as? NavNode, let url = node.url,
              !Location.isThisMac(url) else { return nil }
        let menu = NSMenu()
        addItem(menu, "열기", #selector(openItem(_:)), url)
        addItem(menu, "새 탭에서 열기", #selector(openItemInNewTab(_:)), url)
        if node.kind != .trash {
            menu.addItem(.separator())
            let pinned = AppState.shared.pins.isPinned(url)
            addItem(menu, pinned ? "빠른 액세스에서 고정 해제" : "빠른 액세스에 고정", #selector(togglePin(_:)), url)
            menu.addItem(.separator())
            addItem(menu, "속성", #selector(showProperties(_:)), url)
        }
        return menu
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ url: URL) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = url
        menu.addItem(item)
    }

    func middleClick(row: Int) {
        guard row >= 0, let node = outline.item(atRow: row) as? NavNode, let url = node.url,
              !Location.isThisMac(url) else { return }
        onOpenInNewTab?(url)
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onNavigate?(url) }
    }

    @objc private func openItemInNewTab(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onOpenInNewTab?(url) }
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { AppState.shared.togglePin(url) }
    }

    @objc private func showProperties(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onProperties?(url) }
    }
}

@MainActor
final class NavOutlineView: NSOutlineView {
    weak var pane: NavigationPane?

    override func menu(for event: NSEvent) -> NSMenu? {
        pane?.menu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            pane?.middleClick(row: row(at: convert(event.locationInWindow, from: nil)))
            return
        }
        super.otherMouseDown(with: event)
    }
}

/// 볼륨 행: 아이콘, 이름, 용량 막대.
@MainActor
final class VolumeCellView: NSTableCellView {
    init(volume: VolumeInfo) {
        super.init(frame: .zero)
        let image = NSImageView(image: IconCache.shared.icon(for: volume.url))
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        let name = UI.label(volume.name)
        let bar = CapacityBar(volume: volume)
        for view in [image, name, bar] as [NSView] { addSubview(view) }
        imageView = image
        textField = name
        toolTip = CapacityBar.caption(for: volume)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 22),
            image.heightAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            bar.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 사용량 막대. 90% 이상이면 빨간색 (Windows 와 같다).
@MainActor
final class CapacityBar: NSLevelIndicator {
    init(volume: VolumeInfo) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        levelIndicatorStyle = .continuousCapacity
        minValue = 0
        maxValue = 1
        warningValue = 0.9
        criticalValue = 0.9
        let used = volume.totalBytes > 0
            ? Double(volume.totalBytes - volume.availableBytes) / Double(volume.totalBytes) : 0
        doubleValue = used
        setAccessibilityLabel(Self.caption(for: volume))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func caption(for volume: VolumeInfo) -> String {
        "\(SizeFormatter.humanSize(volume.totalBytes)) 중 \(SizeFormatter.humanSize(volume.availableBytes)) 사용 가능"
    }
}

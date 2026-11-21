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
    /// 읽는 중에 다시 읽기 요청이 왔다. 끝나면 한 번 더 읽는다.
    var needsReload = false

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
            let folders = await Task.detached(priority: .userInitiated) { Self.readFolders(url) }.value
            guard let self else { return }
            self.isLoading = false
            self.children = folders.map { NavNode(.folder, title: $0.name, url: $0.url) }
            completion(self)
        }
    }
}

extension NavNode {
    nonisolated static func readFolders(_ url: URL) -> [FileItem] {
        let items = ((try? DirectoryLister.contents(of: url, showHidden: false)) ?? []).filter(\.isNavigable)
        return FileSorter.sorted(items, by: ExplorerCore.SortOrder())
    }

    /// 빠른 액세스·내 Mac 처럼 섹션 머리글로 그리는 노드.
    var isSectionHeader: Bool { kind == .header || kind == .thisMac }

    /// 트리 노드 중 하위 폴더를 디스크에서 읽어 채우는 종류.
    var readsChildren: Bool { [.home, .folder, .pinned, .volume].contains(kind) }
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
    private let background = MicaView()
    private var roots: [NavNode] = []
    private var quickAccess = NavNode(.header, title: L("빠른 액세스"), url: nil, children: [])
    private var thisMac = NavNode(.thisMac, title: L("내 Mac"), url: Location.thisMac, children: [])
    private var suppressSelection = false
    /// 마지막으로 select(url:) 로 고른 위치. 트리를 다시 그린 뒤 선택을 되살릴 때 쓴다.
    private var selectedURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("nav"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.floatsGroupRows = false
        outline.indentationPerLevel = Theme.Metric.navIndent
        outline.autoresizesOutlineColumn = true
        outline.dataSource = self
        outline.delegate = self
        outline.pane = self
        outline.registerForDraggedTypes([.fileURL])
        outline.setAccessibilityLabel(L("탐색 창"))
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        // 탐색 창은 반투명 재질 (DESIGN 4장).
        UI.pin(background, to: self)
        UI.pin(scroll, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 데이터

    func reloadAll() {
        quickAccess.children = pinnedNodes()
        thisMac.children = volumeNodes()
        var nodes = [NavNode(.home, title: L("홈"), url: Location.home), quickAccess, thisMac]
        if let trash = Location.trash { nodes.append(NavNode(.trash, title: L("휴지통"), url: trash)) }
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

    /// 이미 읽어 둔 노드의 하위 폴더를 다시 읽는다. folders 가 nil 이면 읽어 둔 노드 전부다.
    /// 만들기·삭제·이름 바꾸기 뒤나 F5 에 부른다. 펼침 상태와 하위 노드는 경로가 같으면 그대로 둔다 (M7).
    func refreshTree(_ folders: [URL]?) {
        let keys = folders.map { Set($0.map(Location.key)) }
        var stack = roots
        while let node = stack.popLast() {
            stack += node.loadedChildren
            guard node.readsChildren, node.children != nil, let url = node.url else { continue }
            if let keys, !keys.contains(Location.key(url)) { continue }
            reloadChildren(of: node)
        }
    }

    private func reloadChildren(of node: NavNode) {
        guard let url = node.url else { return }
        if node.isLoading { node.needsReload = true; return }
        node.isLoading = true
        Task { [weak self, weak node] in
            let folders = await Task.detached(priority: .userInitiated) { NavNode.readFolders(url) }.value
            guard let self, let node else { return }
            node.isLoading = false
            let wasExpanded = self.outline.isItemExpanded(node)
            var previous: [String: NavNode] = [:]
            var expanded = Set<String>()
            for child in node.loadedChildren {
                guard let childURL = child.url else { continue }
                let key = Location.key(childURL)
                previous[key] = previous[key] ?? child
                if self.outline.isItemExpanded(child) { expanded.insert(key) }
            }
            node.children = folders.map { previous[Location.key($0.url)] ?? NavNode(.folder, title: $0.name, url: $0.url) }
            self.outline.reloadItem(node, reloadChildren: true)
            if wasExpanded, !node.loadedChildren.isEmpty {
                self.outline.expandItem(node)
                for child in node.loadedChildren where expanded.contains(Location.key(child.url!)) {
                    self.outline.expandItem(child)
                }
            }
            self.select(url: self.selectedURL ?? url)
            if node.needsReload {
                node.needsReload = false
                self.reloadChildren(of: node)
            }
        }
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
        if let volume = node.volume { return VolumeCellView(volume: volume) }
        if node.isSectionHeader { return sectionHeaderCell(node) }
        let cell = NSTableCellView()
        let image = NSImageView(image: icon(for: node))
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = UI.label(node.title, size: Theme.Font.body)
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        var trailing = cell.trailingAnchor
        if node.kind == .pinned {
            // 빠른 액세스 고정 표시. 흐리게, 마우스를 올린 행에서만 보인다 (DESIGN 4·6장).
            let pin = NSImageView(image: Theme.symbol("pin.fill", L("고정됨"), size: 10))
            pin.translatesAutoresizingMaskIntoConstraints = false
            pin.contentTintColor = Theme.secondaryText.withAlphaComponent(0.6)
            pin.identifier = Self.pinIdentifier
            pin.isHidden = true
            cell.addSubview(pin)
            NSLayoutConstraint.activate([
                pin.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                pin.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            trailing = pin.leadingAnchor
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static let pinIdentifier = NSUserInterfaceItemIdentifier("pin")

    /// 빠른 액세스·내 Mac 섹션 머리글: 11pt 회색 굵은 글자 (DESIGN 6장). 내 Mac 은 눌러서 이동할 수 있다.
    private func sectionHeaderCell(_ node: NavNode) -> NSTableCellView {
        let cell = NSTableCellView()
        let text = UI.label(node.title, size: Theme.Font.status, color: Theme.secondaryText)
        text.font = .systemFont(ofSize: Theme.Font.status, weight: .semibold)
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -Theme.Space.s),
        ])
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = ThemedRowView()
        row.showsAccentBar = true
        if (item as? NavNode)?.isSectionHeader == true { row.topInset = Theme.Space.m }
        return row
    }

    private func icon(for node: NavNode) -> NSImage {
        switch node.kind {
        // 폴더는 노랑, 그 밖의 기호는 accent 한 색으로 맞춘다 (DESIGN 6장).
        case .home: return tinted("house.fill", L("홈"), Theme.accent)
        case .header: return tinted("star.fill", L("빠른 액세스"), Theme.accent)
        case .thisMac: return ThisMacView.computerIcon
        case .trash: return tinted("trash.fill", L("휴지통"), Theme.accent)
        default: return node.url.map { IconCache.shared.icon(for: $0) } ?? FolderIcon.image()
        }
    }

    private func tinted(_ name: String, _ label: String, _ color: NSColor) -> NSImage {
        let image = Theme.symbol(name, label, size: 13)
        return image.withSymbolConfiguration(.init(paletteColors: [color])) ?? image
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? NavNode else { return Theme.Metric.rowHeight }
        if node.kind == .volume { return 38 }
        // 머리글 위에 간격 12 를 더 둔다.
        return node.isSectionHeader ? Theme.Metric.rowHeight + Theme.Space.m : Theme.Metric.rowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? NavNode)?.kind != .header
    }

    // MARK: 마우스를 올린 행

    fileprivate func setHoveredRow(_ row: Int) {
        outline.enumerateAvailableRowViews { view, index in
            let node = outline.item(atRow: index) as? NavNode
            (view as? ThemedRowView)?.isHovered = index == row && node?.kind != .header
            if node?.kind == .pinned, let cell = view.view(atColumn: 0) as? NSView {
                cell.subviews.first { $0.identifier == Self.pinIdentifier }?.isHidden = index != row
            }
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let node = outline.item(atRow: outline.selectedRow) as? NavNode,
              let url = node.url else { return }
        onNavigate?(url)
    }

    // MARK: 놓기 (F10)

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // 빠른 액세스 머리글이나 고정 항목 사이에 폴더를 놓으면 고정한다 (Windows 와 같음).
        if (item as? NavNode) === quickAccess {
            guard !Self.folders(in: info).isEmpty else { return [] }
            let position = index == NSOutlineViewDropOnItemIndex ? quickAccess.children?.count ?? 0 : index
            outlineView.setDropItem(quickAccess, dropChildIndex: position)
            return .link
        }
        guard let node = item as? NavNode, index == NSOutlineViewDropOnItemIndex,
              let url = node.url, !Location.isThisMac(url) else { return [] }
        if node.kind == .trash { return .move }
        return DragPolicy.operation(for: info, urls: DragPolicy.fileURLs(from: info.draggingPasteboard), destination: url)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        if (item as? NavNode) === quickAccess {
            let folders = Self.folders(in: info)
            guard !folders.isEmpty else { return false }
            AppState.shared.pin(folders, at: index)
            return true
        }
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

    /// 끌어 온 항목 중 열 수 있는 폴더. 패키지(.app)와 파일은 고정하지 않는다.
    private static func folders(in info: NSDraggingInfo) -> [URL] {
        DragPolicy.fileURLs(from: info.draggingPasteboard).filter { (try? FileItem.load($0))?.isNavigable == true }
    }

    // MARK: 우클릭, 가운데 클릭 (N7, N8)

    func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0, let node = outline.item(atRow: row) as? NavNode, let url = node.url,
              !Location.isThisMac(url) else { return nil }
        let menu = NSMenu()
        addItem(menu, L("열기"), #selector(openItem(_:)), url)
        addItem(menu, L("새 탭에서 열기"), #selector(openItemInNewTab(_:)), url)
        if node.kind != .trash {
            menu.addItem(.separator())
            let pinned = AppState.shared.pins.isPinned(url)
            addItem(menu, pinned ? L("빠른 액세스에서 고정 해제") : L("빠른 액세스에 고정"), #selector(togglePin(_:)), url)
            menu.addItem(.separator())
            addItem(menu, L("속성"), #selector(showProperties(_:)), url)
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["hover"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["hover": true]))
    }

    /// 선택 막대가 펼침 꺾쇠와 겹치지 않도록 내용을 오른쪽으로 민다.
    private static let leadingShift: CGFloat = 6

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        super.frameOfOutlineCell(atRow: row).offsetBy(dx: Self.leadingShift, dy: 0)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        frame.origin.x += Self.leadingShift
        frame.size.width -= Self.leadingShift
        return frame
    }

    /// 펼침 꺾쇠는 마우스가 탐색 창 위에 있을 때만 보인다. 펼친 상태는 그대로다 (DESIGN 6장).
    private var showsDisclosure = false {
        didSet {
            guard showsDisclosure != oldValue else { return }
            enumerateAvailableRowViews { rowView, _ in
                for view in rowView.subviews where view.identifier == NSOutlineView.disclosureButtonIdentifier {
                    view.animator().alphaValue = showsDisclosure ? 1 : 0
                }
            }
        }
    }

    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        if identifier == NSOutlineView.disclosureButtonIdentifier { view?.alphaValue = showsDisclosure ? 1 : 0 }
        return view
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        showsDisclosure = true
        pane?.setHoveredRow(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        showsDisclosure = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        showsDisclosure = false
        pane?.setHoveredRow(-1)
    }

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
        let symbol = Theme.symbol("internaldrive.fill", volume.name, size: 13)
        let image = NSImageView(image: symbol.withSymbolConfiguration(.init(paletteColors: [Theme.accent])) ?? symbol)
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        let name = UI.label(volume.name, size: Theme.Font.body)
        let bar = CapacityBar(volume: volume)
        for view in [image, name, bar] as [NSView] { addSubview(view) }
        imageView = image
        textField = name
        toolTip = CapacityBar.caption(for: volume)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            bar.heightAnchor.constraint(equalToConstant: 4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 드라이브 용량 막대. accent 로 칠하고 사용률 90% 이상이면 빨간색 (DESIGN 2장 driveBar).
@MainActor
final class CapacityBar: NSView {
    private let used: Double

    init(volume: VolumeInfo) {
        used = volume.totalBytes > 0
            ? Double(volume.totalBytes - volume.availableBytes) / Double(volume.totalBytes) : 0
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityValue(used)
        setAccessibilityLabel(Self.caption(for: volume))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Theme.divider.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let fill = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * min(max(used, 0), 1)), height: bounds.height)
        Theme.driveBar(usedFraction: used).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    static func caption(for volume: VolumeInfo) -> String {
        L("%1$@ 중 %2$@ 사용 가능", SizeFormatter.humanSize(volume.totalBytes), SizeFormatter.humanSize(volume.availableBytes))
    }
}

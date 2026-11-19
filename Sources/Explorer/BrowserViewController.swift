import AppKit
import ExplorerCore

/// V3 보기 방식. 값은 Cmd+1~4 와 같다.
enum ViewMode: Int, CaseIterable {
    case details = 1, list, mediumIcons, largeIcons

    var title: String {
        switch self {
        case .details: return "자세히"
        case .list: return "목록"
        case .mediumIcons: return "보통 아이콘"
        case .largeIcons: return "큰 아이콘"
        }
    }
}

/// 탭 하나의 화면. 주소 표시줄, 명령 모음, 탐색 창, 파일 목록, 미리 보기 창, 상태 표시줄.
@MainActor
final class BrowserViewController: NSViewController {
    let state = AppState.shared
    private(set) var history: NavigationHistory
    var currentURL: URL { history.current }
    var isThisMac: Bool { Location.isThisMac(currentURL) }
    var isSearching: Bool { searchQuery != nil }

    var sortOrder = ExplorerCore.SortOrder()
    private(set) var viewMode: ViewMode = .details
    private(set) var previewVisible = false
    private var rawItems: [FileItem] = []
    private var searchQuery: String?
    private var search: FileSearch?
    private var watcher: DirectoryWatcher?
    private var loadGeneration = 0
    /// 목록에 내용이 표시된 폴더(Location.key). 검색 결과나 다른 폴더를 보이는 중이면 현재 위치와 다르다.
    private var listedLocation: String?
    /// 화면에 아직 넣지 않은 검색 결과. 몇 묶음씩 모아서 백그라운드에서 정렬한다 (M8).
    private var pendingResults: [FileItem] = []
    /// 0.3초 묶음 타이머와 백그라운드 정렬이 걸린 검색 세대. 이전 세대의 것이 새 검색을 막지 않게 세대로 구분한다 (R2).
    private var searchFlushGeneration: Int?
    private var searchSortGeneration: Int?
    private var didLayoutSplit = false

    // 화면 요소
    private lazy var backButton = UI.circleButton("arrow.left", tip: "뒤로 (⌘[)", target: self, action: #selector(goBack(_:)))
    private lazy var forwardButton = UI.circleButton("arrow.right", tip: "앞으로 (⌘])", target: self, action: #selector(goForward(_:)))
    private lazy var upButton = UI.circleButton("arrow.up", tip: "상위 폴더 (⌥↑)", target: self, action: #selector(goUp(_:)))
    private lazy var refreshButton = UI.circleButton("arrow.clockwise", tip: "새로 고침 (F5)", target: self, action: #selector(refresh(_:)))
    let addressBar = AddressBar()
    let searchField = ThemedSearchField()
    private lazy var searchBox = SearchBox(field: searchField)
    private(set) lazy var commandBar = CommandBar(browser: self)
    let navPane = NavigationPane()
    let fileList = FileListController()
    let thisMacView = ThisMacView()
    let previewPane = PreviewPane()
    let statusBar = StatusBar()
    private let splitView = ThemedSplitView()
    private let centerContainer = FillView(Theme.contentBackground)

    /// 탭 이름·아이콘·창 제목이 바뀌었다. 탭 관리자가 탭 줄을 다시 그린다.
    var onChromeChange: ((BrowserViewController) -> Void)?
    /// 다른 탭으로 바꿀 때의 입력 포커스. 이 탭으로 돌아오면 되살린다.
    weak var savedFirstResponder: NSView?
    /// 다른 탭으로 바꿀 때 주소 표시줄에서 편집 중이던 입력. 돌아오면 이어서 편집한다 (RD-L1).
    private var savedAddressDraft: AddressBar.Draft?
    private(set) var tabTitle = ""
    private(set) var tabIcon = NSImage()
    private(set) var tabToolTip = ""
    private(set) var windowTitle = ""

    init(url: URL) {
        history = NavigationHistory(start: Location.isThisMac(url) ? url : url.standardizedFileURL)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 화면 구성

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 720))
        buildLayout()
    }

    private func buildLayout() {
        let navButtons = NSStackView(views: [backButton, forwardButton, upButton, refreshButton])
        navButtons.spacing = 2

        searchField.placeholderString = "검색"
        searchField.sendsSearchStringImmediately = false
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.setAccessibilityLabel("검색 상자")

        // 주소 줄: ← → ↑ ⟳ 원형 버튼, 둥근 주소 상자, 오른쪽 둥근 검색 상자 (DESIGN 1장).
        let top = FillView(Theme.toolbarBackground)
        let topStack = NSStackView(views: [navButtons, addressBar, searchBox])
        topStack.orientation = .horizontal
        topStack.spacing = 8
        topStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        UI.pin(topStack, to: top)
        addressBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let searchWidth = searchBox.widthAnchor.constraint(equalTo: top.widthAnchor, multiplier: 0.24)
        searchWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            searchWidth,
            searchBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            searchBox.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "ExplorerSplit"
        splitView.addArrangedSubview(navPane)
        splitView.addArrangedSubview(centerContainer)
        splitView.addArrangedSubview(previewPane)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 1)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(255), forSubviewAt: 2)
        navPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        centerContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        previewPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        previewPane.isHidden = true

        UI.pin(fileList.containerView, to: centerContainer)
        UI.pin(thisMacView, to: centerContainer)
        thisMacView.isHidden = true

        var previousBottom = view.topAnchor
        for subview in [top, commandBar, splitView, statusBar] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                subview.topAnchor.constraint(equalTo: previousBottom),
            ])
            previousBottom = subview.bottomAnchor
        }
        NSLayoutConstraint.activate([
            top.heightAnchor.constraint(equalToConstant: Theme.Metric.addressRowHeight),
            commandBar.heightAnchor.constraint(equalToConstant: Theme.Metric.commandBarHeight),
            statusBar.heightAnchor.constraint(equalToConstant: Theme.Metric.statusBarHeight),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        fileList.delegate = self
        fileList.showExtensions = state.showExtensions
        fileList.updateSortIndicator(sortOrder)

        addressBar.onNavigate = { [weak self] url in self?.navigate(to: url) }
        addressBar.onSubmit = { [weak self] text in self?.submitAddress(text) }
        addressBar.onEditingEnded = { [weak self] in self?.fileList.focus() }

        navPane.onNavigate = { [weak self] url in self?.navigate(to: url) }
        navPane.onOpenInNewTab = { [weak self] url in self?.openTab(at: url) }
        navPane.onDrop = { [weak self] urls, folder, operation in
            self?.transfer(urls, to: folder, move: operation == .move)
            return self != nil
        }
        navPane.onProperties = { url in PropertiesWindowController.show(for: [url]) }
        navPane.onTrash = { [weak self] urls in
            Task { await self?.runOperation { try FileOperations.trash(urls) } }
        }
        navPane.reloadAll()

        thisMacView.onOpen = { [weak self] url in self?.navigate(to: url) }
        statusBar.onModeChange = { [weak self] mode in self?.setViewMode(mode) }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(settingsDidChange(_:)), name: AppState.settingsChanged, object: nil)
        center.addObserver(self, selector: #selector(clipboardDidChange(_:)), name: AppState.clipboardChanged, object: nil)
        center.addObserver(self, selector: #selector(pinsDidChange(_:)), name: AppState.pinsChanged, object: nil)
        center.addObserver(self, selector: #selector(volumesDidChange(_:)), name: AppState.volumesChanged, object: nil)
        center.addObserver(self, selector: #selector(filesDidChange(_:)), name: AppState.filesChanged, object: nil)

        didChangeLocation(selecting: [])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !didLayoutSplit {
            didLayoutSplit = true
            if navPane.frame.width < 150 { splitView.setPosition(230, ofDividerAt: 0) }
            fileList.focus()
        }
        updateChrome()
    }

    /// 창이 닫혀 tearDown 을 마쳤다. 닫힌 창에 질문을 띄우지 않는 데 쓴다 (R3).
    private(set) var isClosed = false

    /// 창이 닫힐 때 백그라운드 작업과 감시를 멈춘다.
    func tearDown() {
        isClosed = true
        search?.cancel()
        search = nil
        watcher?.stop()
        watcher = nil
        loadGeneration += 1
        previewPane.show(nil)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: 탭 전환 포커스

    /// 다른 탭으로 바꾸기 전에 입력 포커스를 기억한다.
    func saveFocus() {
        savedFirstResponder = nil
        savedAddressDraft = addressBar.draft
        guard savedAddressDraft == nil, let window = view.window else { return }
        var responder: NSResponder? = window.firstResponder
        // 입력 칸을 편집하는 중이면 첫 응답자는 창이 함께 쓰는 field editor 다. 그 주인인 입력 칸을 기억한다.
        if let editor = responder as? NSTextView, editor.isFieldEditor { responder = editor.delegate as? NSResponder }
        if let saved = responder as? NSView, saved.isDescendant(of: view) { savedFirstResponder = saved }
    }

    /// 이 탭으로 돌아왔다. 기억한 포커스를 되살리고 없으면 파일 목록에 둔다.
    func restoreFocus() {
        defer { savedFirstResponder = nil; savedAddressDraft = nil }
        if let draft = savedAddressDraft {
            addressBar.resumeEditing(draft)
            return
        }
        if let saved = savedFirstResponder, let window = view.window, saved.window === window,
           window.makeFirstResponder(saved) {
            return
        }
        fileList.focus()
    }

    // MARK: 이동 (N1, N2, N5)

    func navigate(to url: URL) {
        let target = Location.isThisMac(url) ? url : url.standardizedFileURL
        let from = currentURL
        history.visit(target)
        didChangeLocation(selecting: [from])
    }

    private func didChangeLocation(selecting: [URL]) {
        cancelSearch(clearField: true)
        loadCurrent(selecting: selecting)
        updateChrome()
    }

    @objc func goBack(_ sender: Any?) {
        let from = currentURL
        guard history.goBack() != nil else { return }
        didChangeLocation(selecting: [from])
    }

    @objc func goForward(_ sender: Any?) {
        let from = currentURL
        guard history.goForward() != nil else { return }
        didChangeLocation(selecting: [from])
    }

    /// 검색 중이면 검색을 끝낸다. 루트("/")와 내 Mac 에서는 더 올라가지 않는다 (N2).
    var canGoUp: Bool {
        guard !isThisMac else { return false }
        return isSearching || AddressResolver.parent(of: currentURL) != nil
    }

    @objc func goUp(_ sender: Any?) {
        guard canGoUp else { return }
        if isSearching { endSearch(); return }
        guard let parent = AddressResolver.parent(of: currentURL) else { return }
        navigate(to: parent)
    }

    @objc func goToFolder(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        navigate(to: url)
    }

    func openTab(at url: URL) {
        guard let window = view.window else { return }
        AppDelegate.shared.openTab(in: window, at: url)
    }

    private func submitAddress(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { fileList.focus(); return }
        if ["내 Mac", "내 PC", "내 컴퓨터", "This PC", "this pc"].contains(input) {
            navigate(to: Location.thisMac)
            fileList.focus()
            return
        }
        let base = isThisMac ? Location.home : currentURL
        guard let url = AddressResolver.resolve(input, relativeTo: base) else {
            let alert = NSAlert()
            alert.messageText = "'\(input)'을(를) 찾을 수 없습니다."
            alert.informativeText = "철자를 확인하고 다시 시도하세요."
            alert.alertStyle = .warning
            if let window = view.window {
                alert.beginSheetModal(for: window) { [weak self] _ in
                    self?.addressBar.beginEditing(text: input)
                }
            }
            return
        }
        if (try? FileItem.load(url))?.isNavigable == true {
            navigate(to: url)
        } else {
            NSWorkspace.shared.open(url)
        }
        fileList.focus()
    }

    // MARK: 목록 불러오기 (N3)

    /// 현재 폴더를 다시 읽는다. 검색 중이면 검색을 다시 한다.
    func reload(selecting: [URL]? = nil, rename: URL? = nil) {
        // 닫은 탭에서 늦게 끝난 작업이 감시·검색을 다시 켜지 않게 한다 (RD-M1).
        guard !isClosed else { return }
        if let query = searchQuery {
            startSearch(query)
            return
        }
        loadCurrent(selecting: selecting ?? fileList.selectedURLs, rename: rename)
    }

    @objc func refresh(_ sender: Any?) {
        IconCache.shared.invalidate()
        if isThisMac { thisMacView.reload() }
        navPane.refreshTree(nil)
        reload()
    }

    private func loadCurrent(selecting: [URL], rename: URL? = nil) {
        guard !isClosed else { return }
        watcher?.stop()
        watcher = nil
        loadGeneration += 1
        if isThisMac {
            thisMacView.reload()
            thisMacView.isHidden = false
            fileList.containerView.isHidden = true
            rawItems = []
            listedLocation = nil
            fileList.setItems([], selecting: [])
            updateStatus()
            return
        }
        // 다른 위치로 왔으면 새 목록을 읽기 전에 이전 목록과 선택을 비운다.
        // 그래야 느린 폴더를 읽는 동안 삭제·잘라내기 같은 명령이 이전 폴더 항목에 가지 않는다 (H3).
        let key = Location.key(currentURL)
        if listedLocation != key {
            listedLocation = nil
            rawItems = []
            fileList.setItems([], selecting: [])
            fileList.showMessage(nil)
            statusBar.setActivity("불러오는 중…")
            updateStatus()
            updateCommandState()
        }
        thisMacView.isHidden = true
        fileList.containerView.isHidden = false

        let generation = loadGeneration
        let url = currentURL
        let showHidden = state.showHidden
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[FileItem], Error> in
                Result { try DirectoryLister.contents(of: url, showHidden: showHidden) }
            }.value
            guard let self, generation == self.loadGeneration else { return }
            self.listedLocation = key
            self.statusBar.setActivity(nil)
            switch result {
            case .success(let items):
                self.rawItems = items
                self.applyItems(selecting: selecting)
                self.fileList.showMessage(items.isEmpty ? "이 폴더는 비어 있습니다." : nil)
                if let rename { self.fileList.beginRename(rename) }
            case .failure(let error):
                self.rawItems = []
                self.applyItems(selecting: [])
                self.fileList.showMessage(error.localizedDescription)
            }
        }
        watcher = DirectoryWatcher(url: url) { [weak self] in
            MainActor.assumeIsolated { self?.directoryDidChange() }
        }
    }

    private func directoryDidChange() {
        guard !isSearching, !fileList.isRenaming else { return }
        IconCache.shared.invalidate()
        navPane.refreshTree([currentURL])
        reload()
    }

    /// 정렬해서 목록에 넣는다 (V2: 폴더 우선, 자연 정렬).
    private func applyItems(selecting: [URL]) {
        fileList.setItems(FileSorter.sorted(rawItems, by: sortOrder), selecting: selecting)
        updateStatus()
    }

    // MARK: 검색 (S1, S2)

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            if isSearching { endSearch() }
        } else {
            startSearch(query)
        }
    }

    private func startSearch(_ query: String) {
        guard !isThisMac, !isClosed else { return }
        search?.cancel()
        watcher?.stop()
        watcher = nil
        loadGeneration += 1
        let generation = loadGeneration
        searchQuery = query
        rawItems = []
        pendingResults = []
        listedLocation = nil
        fileList.showsFolderColumn = true
        applyItems(selecting: [])
        fileList.showMessage(nil)
        statusBar.setActivity("검색 중…")
        updateChrome()

        let finder = FileSearch(root: currentURL, query: query, showHidden: state.showHidden)
        search = finder
        // 창을 닫으면 tearDown 에서 검색을 취소하므로 강한 참조로 충분하다.
        let browser = self
        Task.detached(priority: .userInitiated) {
            finder.run { batch in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { browser.appendSearchResults(batch, generation: generation) }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { browser.searchDidFinish(generation: generation) }
            }
        }
    }

    /// 검색 결과 묶음은 바로 그리지 않고 모아 둔다. 0.3초마다 한 번, 정렬은 백그라운드에서 한다.
    private func appendSearchResults(_ batch: [FileItem], generation: Int) {
        guard generation == loadGeneration, isSearching else { return }
        pendingResults.append(contentsOf: batch)
        statusBar.setActivity("검색 중… \(rawItems.count + pendingResults.count)개 찾음")
        guard searchFlushGeneration != generation else { return }
        searchFlushGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.searchFlushGeneration == generation { self.searchFlushGeneration = nil }
                self.flushSearchResults(generation: generation, finished: false)
            }
        }
    }

    /// 모아 둔 결과를 합쳐 백그라운드에서 정렬하고 화면에 넣는다. 정렬 중에 온 결과는 끝난 뒤 다시 합친다.
    private func flushSearchResults(generation: Int, finished: Bool) {
        guard generation == loadGeneration, isSearching, searchSortGeneration != generation else { return }
        guard !pendingResults.isEmpty else {
            if finished { finishSearchDisplay() }
            return
        }
        let combined = rawItems + pendingResults
        pendingResults = []
        searchSortGeneration = generation
        let order = sortOrder
        Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) { FileSorter.sorted(combined, by: order) }.value
            guard let self else { return }
            if self.searchSortGeneration == generation { self.searchSortGeneration = nil }
            guard generation == self.loadGeneration, self.isSearching else {
                // 이전 세대 정렬이 끝났다. 그동안 쌓인 현재 검색 결과를 다시 내보낸다.
                if self.isSearching {
                    self.flushSearchResults(generation: self.loadGeneration, finished: self.search == nil)
                }
                return
            }
            self.rawItems = combined
            if order == self.sortOrder {
                self.fileList.setItems(sorted, selecting: self.fileList.selectedURLs)
                self.updateStatus()
            } else {
                self.applyItems(selecting: self.fileList.selectedURLs)
            }
            let done = self.search == nil
            if !self.pendingResults.isEmpty || done {
                self.flushSearchResults(generation: generation, finished: done)
            }
        }
    }

    private func searchDidFinish(generation: Int) {
        guard generation == loadGeneration, isSearching else { return }
        search = nil
        if pendingResults.isEmpty && searchSortGeneration != generation {
            finishSearchDisplay()
        } else {
            flushSearchResults(generation: generation, finished: true)
        }
    }

    private func finishSearchDisplay() {
        statusBar.setActivity(nil)
        fileList.showMessage(rawItems.isEmpty ? "검색 조건과 일치하는 항목이 없습니다." : nil)
    }

    /// 검색을 끝내고 폴더 목록으로 돌아간다.
    func endSearch() {
        cancelSearch(clearField: true)
        loadCurrent(selecting: [])
        updateChrome()
    }

    private func cancelSearch(clearField: Bool) {
        search?.cancel()
        search = nil
        pendingResults = []
        if searchQuery != nil { listedLocation = nil }
        searchQuery = nil
        fileList.showsFolderColumn = false
        statusBar.setActivity(nil)
        if clearField { searchField.stringValue = "" }
    }

    // MARK: 화면 갱신

    func updateChrome() {
        backButton.isEnabled = history.canGoBack
        forwardButton.isEnabled = history.canGoForward
        upButton.isEnabled = canGoUp
        searchField.isEnabled = !isThisMac

        let title: String
        if isThisMac {
            title = "내 Mac"
            tabIcon = ThisMacView.computerIcon
            tabToolTip = "내 Mac"
            addressBar.setLocation(crumbs: [Breadcrumb(title: "내 Mac", url: Location.thisMac)],
                                   path: "내 Mac", icon: tabIcon)
        } else {
            let crumbs = AddressResolver.breadcrumbs(for: currentURL)
            title = crumbs.last?.title ?? currentURL.lastPathComponent
            tabIcon = IconCache.shared.icon(for: currentURL)
            tabToolTip = AddressResolver.displayPath(for: currentURL)
            addressBar.setLocation(crumbs: crumbs, path: AddressResolver.displayPath(for: currentURL), icon: tabIcon)
        }
        searchField.placeholderString = isThisMac ? "검색" : "\(title) 검색"
        windowTitle = isSearching ? "검색 결과 - \(title)" : title
        tabTitle = windowTitle
        navPane.select(url: currentURL)
        updateCommandState()
        onChromeChange?(self)
    }

    func updateStatus() {
        let selected = fileList.selectedItems
        let bytes = selected.reduce(Int64(0)) { $0 + ($1.isNavigable ? 0 : ($1.size ?? 0)) }
        let count = isThisMac ? thisMacView.itemCount : fileList.items.count
        statusBar.update(count: count, selectedCount: selected.count,
                         selectedSize: bytes > 0 ? SizeFormatter.humanSize(bytes) : nil)
        statusBar.setMode(viewMode)
    }

    func updateCommandState() {
        let selected = fileList.selectedItems
        commandBar.update(hasSelection: !selected.isEmpty && !isThisMac,
                          singleSelection: selected.count == 1 && !isThisMac,
                          canPaste: ClipboardBridge.canPaste && !isThisMac,
                          canCreate: !isThisMac)
    }

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        fileList.mode = mode
        statusBar.setMode(mode)
    }

    func setSortOrder(_ order: ExplorerCore.SortOrder) {
        sortOrder = order
        fileList.updateSortIndicator(order)
        applyItems(selecting: fileList.selectedURLs)
    }

    func setPreviewVisible(_ visible: Bool) {
        previewVisible = visible
        previewPane.isHidden = !visible
        if visible {
            splitView.adjustSubviews()
            splitView.setPosition(max(splitView.bounds.width - 320, 400), ofDividerAt: 1)
            updatePreview()
        } else {
            previewPane.show(nil)
        }
    }

    private func updatePreview() {
        guard previewVisible else { return }
        let selected = fileList.selectedItems
        previewPane.show(selected.count == 1 ? selected[0] : nil)
    }

    // MARK: 알림

    @objc private func settingsDidChange(_ note: Notification) {
        fileList.showExtensions = state.showExtensions
        reload()
    }

    @objc private func clipboardDidChange(_ note: Notification) {
        fileList.refreshItemAppearance()
        updateCommandState()
    }

    /// 이 창이나 다른 창의 파일 작업이 끝났다. 탐색 창 트리의 해당 폴더를 다시 읽는다 (M7).
    @objc private func filesDidChange(_ note: Notification) {
        navPane.refreshTree(note.userInfo?["folders"] as? [URL])
    }

    @objc private func pinsDidChange(_ note: Notification) {
        navPane.reloadPins()
    }

    @objc private func volumesDidChange(_ note: Notification) {
        navPane.reloadVolumes()
        if isThisMac { thisMacView.reload() }
    }

    // MARK: 마우스 뒤로/앞으로 버튼, 스와이프 (N1)

    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3: goBack(nil)
        case 4: goForward(nil)
        default: super.otherMouseDown(with: event)
        }
    }

    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 { goBack(nil) } else if event.deltaX < 0 { goForward(nil) }
    }
}

// MARK: - 파일 목록 위임

extension BrowserViewController: FileListDelegate {
    func fileListOpen(_ items: [FileItem], inNewTab: Bool) {
        open(items, inNewTab: inNewTab)
    }

    func fileListSelectionDidChange() {
        ClipboardBridge.syncWithPasteboard()
        updateStatus()
        updateCommandState()
        updatePreview()
    }

    func fileListMenu(for items: [FileItem]) -> NSMenu? {
        items.isEmpty ? backgroundMenu() : itemMenu(for: items)
    }

    func fileListRename(_ item: FileItem, to newName: String) {
        commitRename(item, to: newName)
    }

    func fileListHandleKey(_ event: NSEvent) -> Bool {
        handleListKey(event)
    }

    func fileListDropDestination() -> URL? {
        isThisMac || isSearching ? nil : currentURL
    }

    func fileListDrop(_ urls: [URL], onto folder: URL, operation: NSDragOperation) -> Bool {
        transfer(urls, to: folder, move: operation == .move)
        return true
    }

    func fileListSortDidChange(_ order: ExplorerCore.SortOrder) {
        setSortOrder(order)
    }
}

import AppKit

/// 탐색기 창 하나. 탭(N8)은 macOS 창 탭이 아니라 자체 탭 줄(TabStripView)과 탭별 BrowserViewController 로 만든다.
/// 제목 표시줄은 투명하게 하고 그 자리에 탭 줄을 둔다. 신호등 버튼은 탭 줄 가운데 높이로 옮긴다.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let tabs: BrowserTabsController
    var onClose: (() -> Void)?

    convenience init(url: URL) {
        self.init(browsers: [BrowserViewController(url: url)])
    }

    /// 다른 창에서 떼어 온 탭으로 새 창을 만들 때도 쓴다.
    init(browsers: [BrowserViewController], frame: NSRect? = nil) {
        tabs = BrowserTabsController(browsers: browsers)
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.backgroundColor = Theme.windowBackground
        window.contentViewController = tabs
        window.setContentSize(NSSize(width: 1180, height: 720))
        window.contentMinSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("ExplorerBrowserWindow")
        if let frame {
            window.setFrame(frame, display: false)
        } else if !window.setFrameUsingName("ExplorerBrowserWindow") {
            window.center()
        }
        cascadeIfNeeded(window)
        tabs.onLayout = { [weak self] in self?.positionTrafficLights() }
        // AppKit 이 제목 표시줄을 다시 배치하면(창 표시, 외형 변경 등) 신호등이 제자리로 돌아간다. 그때마다 다시 옮긴다.
        if let container = window.standardWindowButton(.closeButton)?.superview?.superview {
            container.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(titlebarFrameChanged(_:)),
                                                   name: NSView.frameDidChangeNotification, object: container)
        }
    }

    @objc private func titlebarFrameChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.positionTrafficLights() }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        positionTrafficLights()
        DispatchQueue.main.async { [weak self] in self?.positionTrafficLights() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        tabs.tearDownAll()
        onClose?()
    }

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }

    func windowWillEnterFullScreen(_ notification: Notification) { tabs.setFullScreen(true) }
    func windowWillExitFullScreen(_ notification: Notification) { tabs.setFullScreen(false) }

    /// 신호등 버튼을 탭 줄 가운데 높이로 내린다. AppKit 이 제목 표시줄을 다시 배치하면 되돌아가므로
    /// 크기가 바뀔 때마다 다시 부른다.
    func positionTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        let stripHeight = Theme.Metric.tabStripHeight
        let centerFromTop = TabStripView.tabCenterFromTop
        var containerFrame = container.frame
        if containerFrame.height != stripHeight {
            containerFrame.size.height = stripHeight
            containerFrame.origin.y = window.frame.height - stripHeight
            container.frame = containerFrame
            titlebar.frame = container.bounds
        }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttons.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            var frame = button.frame
            let height = frame.height
            frame.origin.y = titlebar.isFlipped ? centerFromTop - height / 2
                : titlebar.bounds.height - centerFromTop - height / 2
            frame.origin.x = 14 + CGFloat(index) * 20
            if button.frame != frame { button.frame = frame }
        }
    }

    private func cascadeIfNeeded(_ window: NSWindow) {
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.browserTabs != nil }
        if let last = others.last, last.frame.origin == window.frame.origin {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
    }
}

/// 제목 표시줄 없이도 키 창이 될 수 있는 탐색기 창.
@MainActor
final class BrowserWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension NSWindow {
    /// 탐색기 창이면 탭 관리자.
    @MainActor var browserTabs: BrowserTabsController? { contentViewController as? BrowserTabsController }
    /// 탐색기 창의 활성 탭.
    @MainActor var activeBrowser: BrowserViewController? { browserTabs?.selectedBrowser }
}

/// 창 하나의 탭 묶음. 탭마다 BrowserViewController 하나를 두어 기록(N1)과 상태가 탭별로 따로다.
/// 활성 탭의 화면만 창에 붙이고 나머지는 떼어 둔다.
/// "탭 닫기"(Cmd+W)와 탭 전환 메뉴는 응답자 체인에서 창보다 먼저 이 컨트롤러가 받는다.
@MainActor
final class BrowserTabsController: NSViewController, NSMenuItemValidation {
    private(set) var browsers: [BrowserViewController] = []
    private(set) var selectedIndex = 0
    private let strip = TabStripView()
    private let stripBackground = MicaView(tintAlpha: 0.7)
    private let container = NSView()
    /// 창이 닫혀 모든 탭을 정리했다. 닫힌 창에 질문을 띄우지 않는 데 쓴다 (R3).
    private(set) var isClosed = false
    var onLayout: (() -> Void)?

    var selectedBrowser: BrowserViewController? {
        browsers.indices.contains(selectedIndex) ? browsers[selectedIndex] : nil
    }

    init(browsers: [BrowserViewController]) {
        super.init(nibName: nil, bundle: nil)
        for browser in browsers { attach(browser) }
        self.browsers = browsers
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = TabsRootView(frame: NSRect(x: 0, y: 0, width: 1180, height: 720))
        root.onLayout = { [weak self] in self?.onLayout?() }
        view = root
        for subview in [stripBackground, strip, container] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            stripBackground.topAnchor.constraint(equalTo: view.topAnchor),
            stripBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stripBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stripBackground.heightAnchor.constraint(equalToConstant: Theme.Metric.tabStripHeight),
            strip.topAnchor.constraint(equalTo: view.topAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: Theme.Metric.tabStripHeight),
            container.topAnchor.constraint(equalTo: strip.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        strip.onSelect = { [weak self] index in self?.select(index) }
        strip.onClose = { [weak self] index in self?.closeTab(at: index) }
        strip.onNew = { [weak self] in self?.newTab() }
        strip.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        showSelected(focus: false)
    }

    // MARK: 탭 추가·제거

    private func attach(_ browser: BrowserViewController) {
        addChild(browser)
        browser.onChromeChange = { [weak self] browser in self?.browserChromeChanged(browser) }
    }

    func addTab(_ browser: BrowserViewController, after index: Int? = nil) {
        attach(browser)
        let position = min((index ?? browsers.count - 1) + 1, browsers.count)
        browsers.insert(browser, at: position)
        select(position)
    }

    /// 탭을 정리하지 않고 떼어 낸다. 다른 창으로 옮길 때 쓴다.
    func detach(_ browser: BrowserViewController) {
        guard let index = browsers.firstIndex(where: { $0 === browser }) else { return }
        let wasSelected = index == selectedIndex
        browser.view.removeFromSuperview()
        browser.removeFromParent()
        browser.onChromeChange = nil
        browsers.remove(at: index)
        if index < selectedIndex || (wasSelected && selectedIndex >= browsers.count) {
            selectedIndex = max(0, selectedIndex - 1)
        }
        if browsers.isEmpty {
            reloadStrip()
        } else if wasSelected {
            showSelected(focus: true)
        } else {
            reloadStrip()
        }
    }

    /// 탭 하나를 닫는다. 그 탭의 감시·검색은 멈추고, 이미 시작한 파일 작업은 끝까지 한다 (R1).
    /// 마지막 탭이면 창을 닫는다.
    func closeTab(at index: Int) {
        guard browsers.indices.contains(index) else { return }
        guard browsers.count > 1 else {
            view.window?.performClose(nil)
            return
        }
        let browser = browsers[index]
        detach(browser)
        browser.tearDown()
    }

    func tearDownAll() {
        guard !isClosed else { return }
        isClosed = true
        for browser in browsers { browser.tearDown() }
    }

    private func newTab() {
        AppDelegate.shared.openTab(in: view.window, at: selectedBrowser?.currentURL ?? Location.home)
    }

    private func moveTab(from: Int, to: Int) {
        guard browsers.indices.contains(from), browsers.indices.contains(to), from != to else { return }
        let selected = selectedBrowser
        let browser = browsers.remove(at: from)
        browsers.insert(browser, at: to)
        if let selected, let index = browsers.firstIndex(where: { $0 === selected }) { selectedIndex = index }
        reloadStrip()
    }

    // MARK: 선택

    func select(_ index: Int) {
        guard browsers.indices.contains(index) else { return }
        if index == selectedIndex, selectedBrowser?.view.superview === container {
            reloadStrip()
            return
        }
        // 떠나는 탭의 입력 포커스를 기억해 두었다가 돌아오면 되살린다.
        if let current = selectedBrowser, let window = view.window,
           let responder = window.firstResponder as? NSView, responder.isDescendant(of: current.view) {
            current.savedFirstResponder = responder
        }
        selectedIndex = index
        showSelected(focus: true)
    }

    private func showSelected(focus: Bool) {
        guard isViewLoaded else { return }
        for subview in container.subviews { subview.removeFromSuperview() }
        reloadStrip()
        guard let browser = selectedBrowser else { return }
        UI.pin(browser.view, to: container)
        updateWindowTitle()
        guard focus, let window = view.window else { return }
        if let saved = browser.savedFirstResponder, saved.window === window, window.makeFirstResponder(saved) {
            browser.savedFirstResponder = nil
        } else {
            browser.fileList.focus()
        }
    }

    private func reloadStrip() {
        strip.tabs = browsers.map { TabStripView.Tab(title: $0.tabTitle, icon: $0.tabIcon, toolTip: $0.tabToolTip) }
        strip.selectedIndex = selectedIndex
    }

    private func browserChromeChanged(_ browser: BrowserViewController) {
        reloadStrip()
        if browser === selectedBrowser { updateWindowTitle() }
    }

    /// 창 제목은 보이지 않지만 윈도우 메뉴, Mission Control, 손쉬운 사용에 쓰인다.
    private func updateWindowTitle() {
        guard let browser = selectedBrowser, let window = view.window else { return }
        window.title = browser.windowTitle
        window.representedURL = browser.isThisMac ? nil : browser.currentURL
    }

    func setFullScreen(_ fullScreen: Bool) {
        strip.leadingInset = fullScreen ? 8 : TabStripView.trafficLightInset
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateWindowTitle()
        onLayout?()
    }

    // MARK: 메뉴 (응답자 체인)

    /// Cmd+W "탭 닫기". 제목 표시줄의 닫기 버튼은 창에 바로 보내므로 창 전체를 닫는다.
    @objc func performClose(_ sender: Any?) {
        closeTab(at: selectedIndex)
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard browsers.count > 1 else { return }
        select((selectedIndex + 1) % browsers.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard browsers.count > 1 else { return }
        select((selectedIndex + browsers.count - 1) % browsers.count)
    }

    @objc func moveTabToNewWindow(_ sender: Any?) {
        guard browsers.count > 1, let browser = selectedBrowser, let window = view.window else { return }
        detach(browser)
        let frame = window.frame.offsetBy(dx: 30, dy: -30)
        AppDelegate.shared.openWindow(with: [browser], frame: frame)
    }

    @objc func mergeAllWindows(_ sender: Any?) {
        guard let window = view.window else { return }
        let others = NSApp.orderedWindows.filter { $0 !== window && $0.browserTabs?.isClosed == false }
        for other in others {
            guard let tabs = other.browserTabs else { continue }
            for browser in tabs.browsers {
                tabs.detach(browser)
                attach(browser)
                browsers.append(browser)
            }
            other.close()
        }
        reloadStrip()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)), #selector(moveTabToNewWindow(_:)):
            return browsers.count > 1
        case #selector(mergeAllWindows(_:)):
            return NSApp.windows.contains { $0 !== view.window && $0.isVisible && $0.browserTabs?.isClosed == false }
        default:
            return true
        }
    }
}

/// 탭 컨트롤러의 바탕. 배치가 끝날 때마다 신호등 버튼 위치를 다시 맞춘다.
@MainActor
private final class TabsRootView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

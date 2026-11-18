import AppKit

/// 탐색기 창 하나. 탭(N8)은 macOS 기본 창 탭으로 묶는다.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let browser: BrowserViewController
    var onClose: (() -> Void)?

    init(url: URL) {
        browser = BrowserViewController(url: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1180, height: 720))
        window.contentMinSize = NSSize(width: 640, height: 400)
        window.tabbingIdentifier = "ExplorerBrowser"
        window.tabbingMode = .automatic
        window.setFrameAutosaveName("ExplorerBrowserWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("ExplorerBrowserWindow") { window.center() }
        cascadeIfNeeded(window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 탭 막대의 + 버튼, 그리고 Cmd+T.
    override func newWindowForTab(_ sender: Any?) {
        guard let window else { return }
        AppDelegate.shared.openTab(in: window, at: browser.currentURL)
    }

    /// 화면 구성(2장)처럼 탭이 하나여도 탭 막대를 보인다.
    func ensureTabBarVisible() {
        guard let window, let group = window.tabGroup, !group.isTabBarVisible else { return }
        window.toggleTabBar(nil)
    }

    func windowWillClose(_ notification: Notification) {
        browser.tearDown()
        onClose?()
    }

    private func cascadeIfNeeded(_ window: NSWindow) {
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.contentViewController is BrowserViewController }
        if let last = others.last, last.frame.origin == window.frame.origin {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
    }
}

import AppKit
import ExplorerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private var controllers: [BrowserWindowController] = []
    /// 마지막 창을 닫았지만 파일 작업이 남아 종료를 미뤘다. 작업이 끝나면 종료한다.
    private var terminateWhenIdle = false { didSet { updateProgressQuitNotice() } }
    /// Cmd+Q 에서 "끝난 뒤 종료"를 골랐다. 작업이 끝나면 창이 있어도 종료한다.
    private var quitWhenIdle = false { didSet { updateProgressQuitNotice() } }

    /// 작업이 끝나면 종료한다는 것을 진행률 창에도 보인다.
    private func updateProgressQuitNotice() {
        FileProgressCenter.shared.quitsWhenDone = quitWhenIdle || (terminateWhenIdle && controllers.isEmpty)
    }

    /// 현재 키 창의 탐색 화면.
    static var keyBrowser: BrowserViewController? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.activeBrowser
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 탭은 자체 탭 줄로 만든다. macOS 창 탭은 끈다.
        NSWindow.allowsAutomaticWindowTabbing = false
        AppState.shared.applyTheme()
        NSApp.mainMenu = MainMenu.build()
        GlobalKeyHandler.install()
        AppState.shared.operations.onIdle = { [weak self] in self?.operationsDidFinish() }
        if controllers.isEmpty { openWindow(at: Self.startFolder() ?? Location.home) }
        #if DEBUG
        // 확인용 실행은 사용자가 쓰는 앱에서 초점을 빼앗지 않는다.
        if DebugSnapshot.isRequested || DebugProgressHarness.isRequested {
            DebugSnapshot.runIfRequested()
            DebugProgressHarness.runIfRequested()
            return
        }
        #endif
        NSApp.activate()
    }

    /// `open Explorer.app --args <폴더>` 또는 실행 파일 인자로 받은 시작 폴더. 없거나 폴더가 아니면 nil.
    private static func startFolder() -> URL? {
        var arguments = Array(CommandLine.arguments.dropFirst())
        // NSUserDefaults 인자(-Key value)는 건너뛴다.
        var paths: [String] = []
        while let argument = arguments.first {
            arguments.removeFirst()
            if argument.hasPrefix("-") {
                if !arguments.isEmpty { arguments.removeFirst() }
                continue
            }
            paths.append(argument)
        }
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    // MARK: 종료 (R1)

    /// Windows 처럼 창을 닫아도 파일 작업은 끝까지 한다. 작업이 남아 있으면 끝난 뒤 종료한다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard AppState.shared.operations.isBusy else { return true }
        terminateWhenIdle = true
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppState.shared.operations.isBusy else { return .terminateNow }
        if quitWhenIdle { return .terminateCancel }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "파일 작업이 진행 중입니다."
        alert.informativeText = "지금 종료하면 작업이 중간에 끊깁니다. 작업이 끝난 뒤 종료할까요?"
        alert.addButton(withTitle: "끝난 뒤 종료")
        alert.addButton(withTitle: "취소")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        // 큐가 질문 사이에 비었으면 바로 종료한다.
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        guard AppState.shared.operations.isBusy else { return .terminateNow }
        // terminateLater 로 기다리면 AppKit 이 MainActor 작업을 돌리지 않아 큐가 끝나지 않는다.
        // 그래서 지금은 취소하고, 큐가 비면 다시 종료한다.
        quitWhenIdle = true
        // 무엇을 기다리는지 보이도록 진행률 창을 바로 띄운다.
        FileProgressCenter.shared.showNow()
        return .terminateCancel
    }

    private func operationsDidFinish() {
        let quit = quitWhenIdle || (terminateWhenIdle && controllers.isEmpty)
        quitWhenIdle = false
        terminateWhenIdle = false
        if quit { NSApp.terminate(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            terminateWhenIdle = false
            openWindow(at: Location.home)
        }
        return true
    }

    /// Dock 아이콘에 폴더를 끌어다 놓거나 `open -a` 로 연 경우.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let folder = (try? FileItem.load(url))?.isNavigable == true ? url : url.deletingLastPathComponent()
            if let window = NSApp.keyWindow, window.browserTabs != nil {
                openTab(in: window, at: folder)
            } else {
                openWindow(at: folder)
            }
        }
    }

    // MARK: 창과 탭 (N8, N9)

    @discardableResult
    func openWindow(at url: URL) -> BrowserWindowController {
        openWindow(with: [BrowserViewController(url: url)])
    }

    /// 다른 창에서 떼어 온 탭으로 새 창을 연다.
    @discardableResult
    func openWindow(with browsers: [BrowserViewController], frame: NSRect? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(browsers: browsers, frame: frame)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            self.controllers.removeAll { $0 === controller }
            // 진행률 창이 떠 있으면 마지막 탐색기 창을 닫아도 AppKit 은 마지막 창으로 보지 않는다.
            // 그래도 작업이 끝나면 종료하도록 직접 표시한다 (R1).
            if self.controllers.isEmpty, AppState.shared.operations.isBusy { self.terminateWhenIdle = true }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    /// 창의 현재 탭 바로 뒤에 새 탭을 열고 고른다. 탐색기 창이 아니면 새 창을 연다.
    func openTab(in window: NSWindow?, at url: URL) {
        guard let window, let tabs = window.browserTabs, !tabs.isClosed else {
            openWindow(at: url)
            return
        }
        tabs.addTab(BrowserViewController(url: url), after: tabs.selectedIndex)
        window.makeKeyAndOrderFront(nil)
    }

    private var currentFolder: URL {
        Self.keyBrowser?.currentURL ?? Location.home
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(at: currentFolder)
    }

    @objc func setTheme(_ sender: NSMenuItem) {
        if let theme = AppState.ThemeMode(rawValue: sender.tag) { AppState.shared.theme = theme }
    }

    /// 창 메뉴. 닫았던 진행률 창을 다시 띄운다.
    @objc func showFileProgress(_ sender: Any?) {
        FileProgressCenter.shared.showNow()
    }

    @objc func newTab(_ sender: Any?) {
        if let window = NSApp.keyWindow, window.browserTabs != nil {
            openTab(in: window, at: currentFolder)
        } else {
            openWindow(at: currentFolder)
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setTheme(_:)) {
            menuItem.state = menuItem.tag == AppState.shared.theme.rawValue ? .on : .off
        }
        if menuItem.action == #selector(showFileProgress(_:)) {
            return FileProgressCenter.shared.hasJobs
        }
        return true
    }
}

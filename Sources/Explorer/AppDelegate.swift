import AppKit
import ExplorerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private var controllers: [BrowserWindowController] = []
    /// 마지막 창을 닫았지만 파일 작업이 남아 종료를 미뤘다. 작업이 끝나면 종료한다.
    private var terminateWhenIdle = false
    /// Cmd+Q 에서 "끝난 뒤 종료"를 골랐다. 작업이 끝나면 창이 있어도 종료한다.
    private var quitWhenIdle = false

    /// 현재 키 창의 탐색 화면.
    static var keyBrowser: BrowserViewController? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.contentViewController as? BrowserViewController
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = MainMenu.build()
        GlobalKeyHandler.install()
        AppState.shared.operations.onIdle = { [weak self] in self?.operationsDidFinish() }
        if controllers.isEmpty { openWindow(at: Self.startFolder() ?? Location.home) }
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
            if let window = NSApp.keyWindow, window.contentViewController is BrowserViewController {
                openTab(in: window, at: folder)
            } else {
                openWindow(at: folder)
            }
        }
    }

    // MARK: 창과 탭 (N8, N9)

    @discardableResult
    func openWindow(at url: URL) -> BrowserWindowController {
        let controller = makeController(at: url)
        controller.showWindow(nil)
        controller.ensureTabBarVisible()
        return controller
    }

    func openTab(in window: NSWindow, at url: URL) {
        let controller = makeController(at: url)
        guard let newWindow = controller.window else { return }
        window.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }

    private func makeController(at url: URL) -> BrowserWindowController {
        let controller = BrowserWindowController(url: url)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        return controller
    }

    private var currentFolder: URL {
        Self.keyBrowser?.currentURL ?? Location.home
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(at: currentFolder)
    }

    @objc func newTab(_ sender: Any?) {
        if let window = NSApp.keyWindow, window.contentViewController is BrowserViewController {
            openTab(in: window, at: currentFolder)
        } else {
            openWindow(at: currentFolder)
        }
    }
}

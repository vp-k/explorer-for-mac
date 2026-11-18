import AppKit
import ExplorerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private var controllers: [BrowserWindowController] = []

    /// 현재 키 창의 탐색 화면.
    static var keyBrowser: BrowserViewController? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.contentViewController as? BrowserViewController
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = MainMenu.build()
        GlobalKeyHandler.install()
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(at: Location.home) }
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

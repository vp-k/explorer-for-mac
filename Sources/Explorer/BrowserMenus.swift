import AppKit
import ExplorerCore

/// 컨텍스트 메뉴(3.5장)와 명령 모음 드롭다운 메뉴.
extension BrowserViewController {
    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, symbol: String? = nil,
                     rep: Any? = nil, key: String = "", mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        item.target = action == nil ? nil : self
        item.representedObject = rep
        if let symbol { item.image = UI.symbol(symbol) }
        menu.addItem(item)
        return item
    }

    /// 항목 위에서 우클릭.
    func itemMenu(for items: [FileItem]) -> NSMenu {
        let menu = NSMenu()
        let single = items.count == 1 ? items[0] : nil
        let files = items.filter { !$0.isNavigable }

        add(menu, "열기", #selector(openSelection(_:)))
        if let file = files.first, files.count == items.count {
            add(menu, "연결 프로그램", nil).submenu = openWithMenu(for: file.url)
        }
        if items.contains(where: \.isNavigable) {
            add(menu, "새 탭에서 열기", #selector(openInNewTab(_:)), symbol: "plus.square.on.square")
        }
        menu.addItem(.separator())
        add(menu, "잘라내기", #selector(cut(_:)), symbol: "scissors", key: "x")
        add(menu, "복사", #selector(copy(_:)), symbol: "doc.on.doc", key: "c")
        if let single, single.isNavigable, ClipboardBridge.canPaste {
            add(menu, "붙여넣기", #selector(paste(_:)), symbol: "doc.on.clipboard", rep: "item")
        }
        add(menu, "경로로 복사", #selector(copyPath(_:)), symbol: "link", key: "c", mods: [.command, .shift])
        menu.addItem(.separator())
        if single != nil {
            add(menu, "이름 바꾸기", #selector(renameSelection(_:)), symbol: "pencil")
        }
        add(menu, "삭제", #selector(moveToTrash(_:)), symbol: "trash")
        menu.addItem(.separator())
        add(menu, "ZIP 파일로 압축", #selector(compressSelection(_:)), symbol: "doc.zipper")
        if let single, single.fileExtension == "zip" {
            add(menu, "압축 풀기", #selector(extractSelection(_:)), symbol: "arrow.up.bin")
        }
        if let single, single.isNavigable {
            let pinned = state.pins.isPinned(single.url)
            add(menu, pinned ? "빠른 액세스에서 고정 해제" : "빠른 액세스에 고정", #selector(togglePin(_:)),
                symbol: pinned ? "pin.slash" : "pin", rep: single.url)
        }
        menu.addItem(.separator())
        add(menu, "터미널에서 열기", #selector(openInTerminal(_:)), symbol: "terminal")
        add(menu, "Finder 에서 보기", #selector(revealInFinder(_:)), symbol: "folder")
        menu.addItem(.separator())
        add(menu, "속성", #selector(showProperties(_:)), symbol: "info.circle")
        return menu
    }

    /// 빈 곳에서 우클릭.
    func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, "보기", nil).submenu = viewMenu()
        add(menu, "정렬 기준", nil).submenu = sortMenu()
        add(menu, "새로 고침", #selector(refresh(_:)), symbol: "arrow.clockwise")
        menu.addItem(.separator())
        add(menu, "붙여넣기", #selector(paste(_:)), symbol: "doc.on.clipboard", rep: "background")
        add(menu, "실행 취소", #selector(undo(_:)), symbol: "arrow.uturn.backward")
        menu.addItem(.separator())
        add(menu, "새로 만들기", nil).submenu = newMenu()
        menu.addItem(.separator())
        add(menu, "터미널에서 열기", #selector(openInTerminal(_:)), symbol: "terminal", rep: "background")
        add(menu, "경로로 복사", #selector(copyPath(_:)), symbol: "link", rep: "background")
        add(menu, "속성", #selector(showProperties(_:)), symbol: "info.circle", rep: "background")
        return menu
    }

    func newMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, "폴더", #selector(newFolder(_:)), symbol: "folder.badge.plus", key: "n", mods: [.command, .shift])
        add(menu, "텍스트 문서", #selector(newTextFile(_:)), symbol: "doc.text")
        return menu
    }

    func sortMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, key) in SortKey.allCases.enumerated() {
            add(menu, key.title, #selector(setSortKeyFromMenu(_:))).tag = index
        }
        menu.addItem(.separator())
        add(menu, "오름차순", #selector(setSortDirectionFromMenu(_:))).tag = 1
        add(menu, "내림차순", #selector(setSortDirectionFromMenu(_:))).tag = 0
        return menu
    }

    func viewMenu() -> NSMenu {
        let menu = NSMenu()
        let symbols: [ViewMode: String] = [.details: "list.bullet", .list: "list.dash",
                                           .mediumIcons: "square.grid.3x2", .largeIcons: "square.grid.2x2"]
        for mode in ViewMode.allCases {
            add(menu, mode.title, #selector(setViewModeFromMenu(_:)), symbol: symbols[mode],
                key: "\(mode.rawValue)").tag = mode.rawValue
        }
        menu.addItem(.separator())
        add(menu, "숨긴 항목", #selector(toggleHiddenFiles(_:)), key: ".", mods: [.command, .shift])
        add(menu, "파일 확장명", #selector(toggleExtensions(_:)))
        add(menu, "미리 보기 창", #selector(togglePreviewPane(_:)), key: "p", mods: .option)
        return menu
    }

    /// 명령 모음의 ··· 메뉴.
    func moreMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, "모두 선택", #selector(NSResponder.selectAll(_:)), symbol: "checkmark.circle", key: "a")
            .target = nil
        add(menu, "선택 반전", #selector(invertSelection(_:)))
        menu.addItem(.separator())
        add(menu, "경로로 복사", #selector(copyPath(_:)), symbol: "link")
        add(menu, "ZIP 파일로 압축", #selector(compressSelection(_:)), symbol: "doc.zipper")
        add(menu, "압축 풀기", #selector(extractSelection(_:)), symbol: "arrow.up.bin")
        menu.addItem(.separator())
        add(menu, "빠른 액세스에 고정/해제", #selector(togglePin(_:)), symbol: "pin")
        add(menu, "터미널에서 열기", #selector(openInTerminal(_:)), symbol: "terminal")
        add(menu, "Finder 에서 보기", #selector(revealInFinder(_:)), symbol: "folder")
        menu.addItem(.separator())
        add(menu, "속성", #selector(showProperties(_:)), symbol: "info.circle")
        return menu
    }

    /// F16 연결 프로그램. 기본 앱을 맨 위에 둔다.
    func openWithMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: url)
        var apps = workspace.urlsForApplications(toOpen: url)
        if let defaultApp {
            apps.removeAll { $0 == defaultApp }
            apps.insert(defaultApp, at: 0)
        }
        for (index, app) in apps.prefix(30).enumerated() {
            var title = FileManager.default.displayName(atPath: app.path)
            if title.hasSuffix(".app") { title = String(title.dropLast(4)) }
            if index == 0, defaultApp != nil { title += " (기본값)" }
            let item = add(menu, title, #selector(openWithApplication(_:)), rep: app)
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            if index == 0, defaultApp != nil, apps.count > 1 { menu.addItem(.separator()) }
        }
        if !apps.isEmpty { menu.addItem(.separator()) }
        add(menu, "다른 앱 선택…", #selector(chooseApplication(_:)))
        return menu
    }
}

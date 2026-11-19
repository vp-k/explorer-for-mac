import AppKit
import ExplorerCore

/// 메인 메뉴. 대부분 target 을 비워 응답자 체인으로 키 창의 BrowserViewController 에 보낸다.
@MainActor
enum MainMenu {
    typealias B = BrowserViewController

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0, rep: Any? = nil,
                            target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        item.tag = tag
        item.representedObject = rep
        item.target = target
        menu.addItem(item)
        return item
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(functionKey)!))
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "탐색기")
        add(menu, "탐색기 정보", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        let services = NSMenu(title: "서비스")
        add(menu, "서비스", nil).submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        add(menu, "탐색기 가리기", #selector(NSApplication.hide(_:)), "h")
        add(menu, "기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(menu, "모두 보기", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "탐색기 종료", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "파일")
        add(menu, "새 창", #selector(AppDelegate.newWindow(_:)), "n")
        add(menu, "새 탭", #selector(AppDelegate.newTab(_:)), "t")
        add(menu, "새 폴더", #selector(B.newFolder(_:)), "n", [.command, .shift])
        add(menu, "새 텍스트 문서", #selector(B.newTextFile(_:)))
        add(menu, "복제", #selector(B.duplicateSelection(_:)), "d")
        menu.addItem(.separator())
        add(menu, "열기", #selector(B.openSelection(_:)), key(NSDownArrowFunctionKey))
        add(menu, "새 탭에서 열기", #selector(B.openInNewTab(_:)))
        menu.addItem(.separator())
        add(menu, "탭 닫기", #selector(NSWindow.performClose(_:)), "w")
        menu.addItem(.separator())
        add(menu, "이름 바꾸기", #selector(B.renameSelection(_:)), key(NSF2FunctionKey), [])
        add(menu, "휴지통으로 이동", #selector(B.moveToTrash(_:)), "\u{8}")
        add(menu, "영구적으로 삭제…", #selector(B.deletePermanently(_:)), "\u{8}", [.command, .option])
        menu.addItem(.separator())
        add(menu, "ZIP 파일로 압축", #selector(B.compressSelection(_:)))
        add(menu, "압축 풀기", #selector(B.extractSelection(_:)))
        menu.addItem(.separator())
        add(menu, "속성", #selector(B.showProperties(_:)), "i")
        add(menu, "터미널에서 열기", #selector(B.openInTerminal(_:)))
        add(menu, "Finder 에서 보기", #selector(B.revealInFinder(_:)))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "편집")
        add(menu, "실행 취소", #selector(B.undo(_:)), "z")
        add(menu, "다시 실행", #selector(B.redo(_:)), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "잘라내기", #selector(B.cut(_:)), "x")
        add(menu, "복사", #selector(B.copy(_:)), "c")
        add(menu, "붙여넣기", #selector(B.paste(_:)), "v")
        add(menu, "여기로 이동", #selector(B.pasteMove(_:)), "v", [.command, .option])
        add(menu, "경로로 복사", #selector(B.copyPath(_:)), "c", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "모두 선택", #selector(NSResponder.selectAll(_:)), "a")
        add(menu, "선택 반전", #selector(B.invertSelection(_:)))
        menu.addItem(.separator())
        add(menu, "검색", #selector(B.focusSearch(_:)), "f")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "보기")
        for mode in ViewMode.allCases {
            add(menu, mode.title, #selector(B.setViewModeFromMenu(_:)), "\(mode.rawValue)", tag: mode.rawValue)
        }
        menu.addItem(.separator())
        let sort = NSMenu(title: "정렬 기준")
        for (index, key) in SortKey.allCases.enumerated() {
            add(sort, key.title, #selector(B.setSortKeyFromMenu(_:)), tag: index)
        }
        sort.addItem(.separator())
        add(sort, "오름차순", #selector(B.setSortDirectionFromMenu(_:)), tag: 1)
        add(sort, "내림차순", #selector(B.setSortDirectionFromMenu(_:)), tag: 0)
        add(menu, "정렬 기준", nil).submenu = sort
        menu.addItem(.separator())
        add(menu, "숨긴 항목", #selector(B.toggleHiddenFiles(_:)), ".", [.command, .shift])
        add(menu, "파일 확장명", #selector(B.toggleExtensions(_:)))
        add(menu, "미리 보기 창", #selector(B.togglePreviewPane(_:)), "p", .option)
        menu.addItem(.separator())
        add(menu, "새로 고침", #selector(B.refresh(_:)), "r")
        add(menu, "주소 표시줄로 이동", #selector(B.focusAddressBar(_:)), "l")
        menu.addItem(.separator())
        add(menu, "전체 화면", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "이동")
        add(menu, "뒤로", #selector(B.goBack(_:)), "[")
        add(menu, "앞으로", #selector(B.goForward(_:)), "]")
        add(menu, "상위 폴더", #selector(B.goUp(_:)), key(NSUpArrowFunctionKey))
        menu.addItem(.separator())
        add(menu, "내 Mac", #selector(B.goToFolder(_:)), "c", [.command, .option], rep: Location.thisMac)
        add(menu, "홈", #selector(B.goToFolder(_:)), "h", [.command, .shift], rep: Location.home)
        let keys: [String: (String, NSEvent.ModifierFlags)] = [
            "바탕 화면": ("d", [.command, .shift]), "문서": ("o", [.command, .shift]),
            "다운로드": ("l", [.command, .option]),
        ]
        for folder in Location.standardFolders where folder.title != "홈" {
            let shortcut = keys[folder.title]
            add(menu, folder.title, #selector(B.goToFolder(_:)), shortcut?.0 ?? "", shortcut?.1 ?? [], rep: folder.url)
        }
        if let trash = Location.trash {
            add(menu, "휴지통", #selector(B.goToFolder(_:)), rep: trash)
        }
        menu.addItem(.separator())
        add(menu, "주소 입력…", #selector(B.focusAddressBar(_:)), "g", [.command, .shift])
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "윈도우")
        add(menu, "최소화", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "확대/축소", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "다음 탭 보기", #selector(NSWindow.selectNextTab(_:)), "\t", .control)
        add(menu, "이전 탭 보기", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift])
        add(menu, "탭을 새 창으로 이동", #selector(NSWindow.moveTabToNewWindow(_:)))
        add(menu, "모든 창 병합", #selector(NSWindow.mergeAllWindows(_:)))
        menu.addItem(.separator())
        add(menu, "모두 앞으로 가져오기", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }
}

extension SortKey {
    var title: String {
        switch self {
        case .name: return "이름"
        case .dateModified: return "수정한 날짜"
        case .type: return "유형"
        case .size: return "크기"
        case .dateCreated: return "만든 날짜"
        }
    }
}

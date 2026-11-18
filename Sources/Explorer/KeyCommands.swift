import AppKit

/// 앱 전체 키 입력 처리 (4장).
/// - Ctrl 조합을 Cmd 조합으로 바꿔 메뉴 단축키가 그대로 받게 한다.
/// - Ctrl+Tab 탭 전환, Ctrl+D·E·Y, F3·F4·F5, ⌥D 처럼 메뉴로 표현하기 어려운 키를 처리한다.
/// - 글자 입력 중(주소창, 이름 편집, 한글 조합 중)에는 파일 단축키를 가로채지 않는다.
@MainActor
enum GlobalKeyHandler {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
    }

    private enum Key {
        static let tab: UInt16 = 48, space: UInt16 = 49, returnKey: UInt16 = 36, escape: UInt16 = 53
        static let backspace: UInt16 = 51, forwardDelete: UInt16 = 117, enter: UInt16 = 76
        static let f2: UInt16 = 120, f3: UInt16 = 99, f4: UInt16 = 118, f5: UInt16 = 96
        static let d: UInt16 = 2, e: UInt16 = 14, y: UInt16 = 16
        static let home: UInt16 = 115, end: UInt16 = 119, pageUp: UInt16 = 116, pageDown: UInt16 = 121
        static let arrows: Set<UInt16> = [123, 124, 125, 126]
        /// 글자 입력 중에는 메뉴 단축키보다 입력 칸이 먼저 받아야 하는 키 (Cmd+↑, Cmd+⌫ 등).
        static let textEditing: Set<UInt16> = arrows.union([backspace, forwardDelete, home, end, pageUp, pageDown, f2])
    }

    /// 한글 입력 상태에서도 Ctrl+C 가 Cmd+C 가 되도록 키 코드로 ASCII 문자를 찾는다 (US 배열 기준).
    private static let asciiForKeyCode: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o",
        32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
    ]

    /// 글자 입력 중 Ctrl→Cmd 로 바꾸는 키. 나머지 Ctrl 키(Ctrl+A·E·K 등)는 macOS 편집 키로 남긴다.
    private static let textRemapKeys: Set<String> = ["c", "v", "x", "z", "y"]

    private static func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let window = event.window ?? NSApp.keyWindow

        // 한글 조합 중에는 어떤 키도 건드리지 않는다.
        if hasMarkedText(in: window) { return event }

        // Ctrl+Tab / Ctrl+Shift+Tab: 탭 전환
        if event.keyCode == Key.tab, flags.contains(.control), !flags.contains(.command) {
            if flags.contains(.shift) { window?.selectPreviousTab(nil) } else { window?.selectNextTab(nil) }
            return nil
        }

        let editing = isEditingText(in: window)
        let browser = window?.contentViewController as? BrowserViewController

        // 글자 입력 중의 커서·지우기 키는 메뉴 단축키(Cmd+↑ 상위, Cmd+⌫ 휴지통, F2 이름 바꾸기)로 새지 않게
        // 입력 칸으로 바로 보낸다.
        if editing, Key.textEditing.contains(event.keyCode), !flags.contains(.control),
           let responder = window?.firstResponder {
            responder.keyDown(with: event)
            return nil
        }

        // 기능 키는 수정 키 없이 눌렀을 때만.
        if flags.isEmpty, let browser {
            switch event.keyCode {
            case Key.f3: browser.focusSearch(nil); return nil
            case Key.f4: browser.focusAddressBar(nil); return nil
            case Key.f5: browser.refresh(nil); return nil
            default: break
            }
        }

        // ⌥D: 주소 표시줄. 글자 입력 중이면 그대로 둔다.
        if flags == .option, event.keyCode == Key.d, let browser, !editing {
            browser.focusAddressBar(nil)
            return nil
        }

        // Ctrl 전용 키: Ctrl+D 휴지통(Cmd+D 와 다름), Ctrl+E 검색, Ctrl+Y 다시 실행.
        if flags == .control, let browser, !editing {
            switch event.keyCode {
            case Key.d: browser.moveToTrash(nil); return nil
            case Key.e: browser.focusSearch(nil); return nil
            case Key.y: browser.redo(nil); return nil
            default: break
            }
        }

        // Ctrl → Cmd
        if flags.contains(.control), !flags.contains(.command),
           let remapped = remapControl(event, flags: flags, editing: editing) {
            return remapped
        }
        return event
    }

    private static func remapControl(_ event: NSEvent, flags: NSEvent.ModifierFlags, editing: Bool) -> NSEvent? {
        let excluded: Set<UInt16> = [Key.tab, Key.space, Key.returnKey, Key.escape, Key.backspace,
                                     Key.forwardDelete, Key.enter]
        if excluded.contains(event.keyCode) || Key.arrows.contains(event.keyCode) { return nil }
        guard let base = asciiForKeyCode[event.keyCode] else { return nil }
        if editing, !textRemapKeys.contains(base) { return nil }
        // Ctrl+Y 는 입력 칸에서 Cmd+Shift+Z(다시 실행)다.
        var newFlags = event.modifierFlags
        var key = base
        if base == "y" {
            key = "z"
            newFlags.insert(.shift)
        }
        newFlags.remove(.control)
        newFlags.insert(.command)
        var chars = event.charactersIgnoringModifiers ?? key
        if base == "y" || chars.isEmpty || !chars.allSatisfy(\.isASCII) {
            chars = newFlags.contains(.shift) ? key.uppercased() : key
        }
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: newFlags,
                                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                characters: chars.lowercased(), charactersIgnoringModifiers: chars,
                                isARepeat: event.isARepeat, keyCode: base == "y" ? 6 : event.keyCode)
    }

    /// 주소창·검색 상자·이름 편집처럼 글자를 입력하는 중인지.
    static func isEditingText(in window: NSWindow?) -> Bool {
        window?.firstResponder is NSText
    }

    private static func hasMarkedText(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }
}

extension BrowserViewController {
    /// 파일 목록에 포커스가 있을 때의 키 (F1, F3, F4, N1, N2, F13).
    func handleListKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 36, 76: // Return, Enter
            if flags.isEmpty { openSelection(nil); return true }
            if flags == .option { showProperties(nil); return true }
        case 125: // ↓
            if flags == .command { openSelection(nil); return true }
        case 126: // ↑
            if flags == .command || flags == .option { goUp(nil); return true }
        case 123: // ←
            if flags == .option { goBack(nil); return true }
        case 124: // →
            if flags == .option { goForward(nil); return true }
        case 51: // Backspace: Windows 처럼 뒤로
            if flags.isEmpty { goBack(nil); return true }
            if flags == .command { moveToTrash(nil); return true }
            if flags == [.command, .option] { deletePermanently(nil); return true }
        case 117: // Delete(⌦ = Fn+⌫)
            if flags.isEmpty { moveToTrash(nil); return true }
            if flags == .shift { deletePermanently(nil); return true }
        case 120: // F2
            if flags.isEmpty { renameSelection(nil); return true }
        default:
            break
        }
        return false
    }
}

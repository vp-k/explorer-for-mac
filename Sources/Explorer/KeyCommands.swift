import AppKit

/// 앱 전체 키 입력 처리 (4장).
/// - Ctrl 조합을 Cmd 조합으로 바꿔 메뉴 단축키가 그대로 받게 한다.
/// - Ctrl+Tab 탭 전환, F3·F4·F5, ⌥D 처럼 메뉴로 표현하기 어려운 키를 처리한다.
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
        static let f3: UInt16 = 99, f4: UInt16 = 118, f5: UInt16 = 96, d: UInt16 = 2
        static let arrows: Set<UInt16> = [123, 124, 125, 126]
    }

    /// 한글 입력 상태에서도 Ctrl+C 가 Cmd+C 가 되도록 키 코드로 ASCII 문자를 찾는다 (US 배열 기준).
    private static let asciiForKeyCode: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o",
        32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
    ]

    private static func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let window = event.window ?? NSApp.keyWindow

        // Ctrl+Tab / Ctrl+Shift+Tab: 탭 전환
        if event.keyCode == Key.tab, flags.contains(.control), !flags.contains(.command) {
            if flags.contains(.shift) { window?.selectPreviousTab(nil) } else { window?.selectNextTab(nil) }
            return nil
        }

        let browser = window?.contentViewController as? BrowserViewController

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
        if flags == .option, event.keyCode == Key.d, let browser, !isEditingText(in: window) {
            browser.focusAddressBar(nil)
            return nil
        }

        // Ctrl → Cmd
        if flags.contains(.control), !flags.contains(.command), let remapped = remapControl(event, flags: flags) {
            return remapped
        }
        return event
    }

    private static func remapControl(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> NSEvent? {
        let excluded: Set<UInt16> = [Key.tab, Key.space, Key.returnKey, Key.escape, Key.backspace,
                                     Key.forwardDelete, Key.enter]
        if excluded.contains(event.keyCode) || Key.arrows.contains(event.keyCode) { return nil }
        guard let base = asciiForKeyCode[event.keyCode] else { return nil }
        var chars = event.charactersIgnoringModifiers ?? base
        if chars.isEmpty || !chars.allSatisfy(\.isASCII) {
            chars = flags.contains(.shift) ? base.uppercased() : base
        }
        var newFlags = event.modifierFlags
        newFlags.remove(.control)
        newFlags.insert(.command)
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: newFlags,
                                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                characters: chars.lowercased(), charactersIgnoringModifiers: chars,
                                isARepeat: event.isARepeat, keyCode: event.keyCode)
    }

    static func isEditingText(in window: NSWindow?) -> Bool {
        window?.firstResponder is NSText
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
        case 51: // Backspace
            if flags.isEmpty { goUp(nil); return true }
            if flags == .command { moveToTrash(nil); return true }
            if flags == [.command, .option] || flags == .shift { deletePermanently(nil); return true }
        case 117: // Delete(⌦)
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

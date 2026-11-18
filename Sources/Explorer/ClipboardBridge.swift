import AppKit
import ExplorerCore

/// NSPasteboard 와 FileClipboard 를 잇는다 (F2, F12).
/// 복사·잘라내기 모두 파일 URL 을 대지에 써서 Finder 와 주고받을 수 있다.
/// 잘라내기 여부는 대지에 표시할 수 없으므로 changeCount 로 판단한다.
@MainActor
enum ClipboardBridge {
    private static var pasteboard: NSPasteboard { .general }
    private static let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    static func write(_ urls: [URL], mode: FileClipboard.Mode) {
        guard !urls.isEmpty else { return }
        let pb = pasteboard
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        let state = AppState.shared
        state.clipboard.set(urls, mode: mode)
        state.clipboardChangeCount = pb.changeCount
        state.post(AppState.clipboardChanged)
    }

    /// 붙여넣을 URL 과 동작. 다른 앱이 대지를 바꿨으면 잘라내기 상태를 버리고 복사로 본다.
    static func readForPaste() -> (urls: [URL], mode: FileClipboard.Mode)? {
        let pb = pasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL],
              !urls.isEmpty else { return nil }
        syncWithPasteboard()
        let state = AppState.shared
        if state.clipboard.mode == .cut, pb.changeCount == state.clipboardChangeCount {
            return (urls, .cut)
        }
        return (urls, .copy)
    }

    static var canPaste: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOptions)
    }

    /// 잘라내기 후 붙여넣기가 끝나면 Windows 처럼 대지를 비운다.
    static func finishCutPaste() {
        pasteboard.clearContents()
        clearCutState()
    }

    static func clearCutState() {
        let state = AppState.shared
        guard !state.clipboard.urls.isEmpty else { return }
        state.clipboard.clear()
        state.post(AppState.clipboardChanged)
    }

    /// 다른 앱이 대지를 덮어썼으면 흐리게 표시(V8)를 푼다.
    static func syncWithPasteboard() {
        let state = AppState.shared
        if state.clipboard.mode == .cut, pasteboard.changeCount != state.clipboardChangeCount {
            clearCutState()
        }
    }

    /// F12 경로로 복사. 여러 개면 줄마다 하나.
    static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = pasteboard
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        clearCutState()
    }
}

/// 잘라낸 항목처럼 대지 상태에 따라 흐리게 보일지 정한다.
@MainActor
func itemAlpha(_ item: FileItem) -> CGFloat {
    if AppState.shared.clipboard.isCut(item.url) { return 0.45 }
    return item.isHidden ? 0.6 : 1
}

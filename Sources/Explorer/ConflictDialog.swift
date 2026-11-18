import AppKit
import ExplorerCore

/// F8 같은 이름 충돌 대화상자. Core 정책이 작업 단위라 선택은 모든 충돌 항목에 적용된다.
@MainActor
enum ConflictDialog {
    /// 대상 폴더에 같은 이름이 이미 있는 원본. 같은 폴더 안 복사·이동(F9)은 충돌로 보지 않는다.
    static func conflicts(for sources: [URL], in destination: URL) -> [URL] {
        let destKey = Location.key(destination)
        return sources.filter { source in
            guard Location.key(source.deletingLastPathComponent()) != destKey else { return false }
            let target = destination.appendingPathComponent(source.lastPathComponent)
            return FileManager.default.fileExists(atPath: target.path)
        }
    }

    /// 사용자가 고른 정책. 취소하면 nil.
    static func ask(conflicts: [URL], total: Int, destination: URL, move: Bool,
                    window: NSWindow?) async -> ConflictPolicy? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let folder = destination.lastPathComponent
        if conflicts.count == 1 {
            alert.messageText = "대상 폴더에 '\(conflicts[0].lastPathComponent)' 파일이 이미 있습니다."
        } else {
            alert.messageText = "대상 폴더에 이름이 같은 항목이 \(conflicts.count)개 있습니다."
        }
        let verb = move ? "이동" : "복사"
        alert.informativeText = "\(total)개 항목을 '\(folder)'(으)로 \(verb)하는 중입니다. 어떻게 할까요?"
            + (conflicts.count > 1 ? "\n선택한 방법이 겹치는 모든 항목에 적용됩니다." : "")
        alert.addButton(withTitle: "파일 덮어쓰기")
        alert.addButton(withTitle: "이 파일 건너뛰기")
        alert.addButton(withTitle: "둘 다 유지")
        alert.addButton(withTitle: "취소")
        alert.buttons[3].keyEquivalent = "\u{1b}"

        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .skip
        case .alertThirdButtonReturn: return .keepBoth
        default: return nil
        }
    }
}

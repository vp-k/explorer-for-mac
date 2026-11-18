import AppKit
import ExplorerCore

/// F8 같은 이름 충돌 대화상자. 충돌 항목마다 묻고, "모든 항목에 적용"을 켜면 남은 항목에 같은 결정을 쓴다.
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

    /// 충돌 대상 경로(Location.key)마다 고른 정책. 취소하면 nil.
    static func decide(conflicts: [URL], total: Int, destination: URL, move: Bool,
                       window: NSWindow?) async -> [String: ConflictPolicy]? {
        var decisions: [String: ConflictPolicy] = [:]
        var applyToRest: ConflictPolicy?
        for (index, source) in conflicts.enumerated() {
            let target = Location.key(destination.appendingPathComponent(source.lastPathComponent))
            if let applyToRest {
                decisions[target] = applyToRest
                continue
            }
            guard let answer = await ask(source: source, remaining: conflicts.count - index, total: total,
                                         destination: destination, move: move, window: window) else { return nil }
            decisions[target] = answer.policy
            if answer.applyToAll { applyToRest = answer.policy }
        }
        return decisions
    }

    /// 항목 하나에 대한 질문. remaining 은 이 항목을 포함한 남은 충돌 수.
    private static func ask(source: URL, remaining: Int, total: Int, destination: URL, move: Bool,
                            window: NSWindow?) async -> (policy: ConflictPolicy, applyToAll: Bool)? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "대상 폴더에 '\(source.lastPathComponent)'이(가) 이미 있습니다."
        let verb = move ? "이동" : "복사"
        alert.informativeText = "\(total)개 항목을 '\(destination.lastPathComponent)'(으)로 \(verb)하는 중입니다. 어떻게 할까요?"
        alert.addButton(withTitle: "덮어쓰기")
        alert.addButton(withTitle: "건너뛰기")
        alert.addButton(withTitle: "둘 다 유지")
        alert.addButton(withTitle: "취소")
        alert.buttons[3].keyEquivalent = "\u{1b}"
        if remaining > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "남은 충돌 \(remaining)개 모두에 적용"
            alert.suppressionButton?.state = .off
        }

        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        let applyToAll = alert.suppressionButton?.state == .on && remaining > 1
        switch response {
        case .alertFirstButtonReturn: return (.replace, applyToAll)
        case .alertSecondButtonReturn: return (.skip, applyToAll)
        case .alertThirdButtonReturn: return (.keepBoth, applyToAll)
        default: return nil
        }
    }
}

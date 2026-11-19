import AppKit
import ExplorerCore

/// 충돌 질문 하나. source 는 원본 항목(폴더 병합이면 그 안의 하위 항목), target 은 이미 있는 대상이다.
struct ConflictQuestion: Sendable {
    let source: URL
    let target: URL
}

/// 붙여넣기·끌어 놓기 원본 하나를 Core 와 같은 규칙으로 미리 살펴본 결과.
struct ConflictCandidate: Sendable {
    enum Kind: Sendable {
        /// 같은 폴더 안 복사·이동(F9). 충돌로 보지 않는다.
        case sameFolder
        case noConflict
        /// 파일끼리 또는 파일·폴더가 부딪친다. 원본 단위로 묻는다.
        case item
        /// 폴더끼리는 Windows 처럼 병합한다. 안에서 부딪치는 항목마다 묻는다.
        case merge([ConflictQuestion])
    }
    let source: URL
    let target: URL
    let kind: Kind
}

/// Core 에 넘길 작업. 건너뛰기로 답한 최상위 원본은 sources 에서 뺀다.
struct ConflictPlan {
    let sources: [URL]
    let resolver: ConflictResolver
}

/// Core 의 충돌 콜백. 미리 받은 결정을 대상 경로로 찾아 돌려준다.
/// Core 는 같은 작업 안에서 한 대상 경로를 한 번만 묻는다. 같은 이름의 둘째 원본부터는 묻지 않고 둘 다 유지한다.
/// 미리 예상하지 못한 충돌(작업 중 생긴 파일 등)은 백그라운드 스레드를 세워 두고 대화상자로 묻는다.
final class ConflictResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var decisions: [String: ConflictPolicy] = [:]
    private var applyToRest: ConflictPolicy?
    private let destination: URL
    private let move: Bool
    private weak var window: NSWindow?
    /// 진행률 창의 작업. 취소하면 떠 있는 질문을 닫는다.
    private let job: ProgressJob?
    private let ticket: ProgressTicket?

    init(destination: URL, move: Bool, window: NSWindow?, job: ProgressJob?) {
        self.destination = destination
        self.move = move
        self.window = window
        self.job = job
        ticket = job?.ticket
    }

    func record(_ policy: ConflictPolicy, for target: URL) {
        lock.withLock { decisions[Location.key(target)] = policy }
    }

    func setApplyToRest(_ policy: ConflictPolicy) {
        lock.withLock { applyToRest = policy }
    }

    var restPolicy: ConflictPolicy? { lock.withLock { applyToRest } }

    /// Core 가 백그라운드에서 부른다.
    func policy(for target: URL) -> ConflictPolicy {
        let known: ConflictPolicy? = lock.withLock { decisions[Location.key(target)] ?? applyToRest }
        if let known { return known }
        guard !Thread.isMainThread else { return .keepBoth }
        // 이미 취소했으면 묻지 않는다. Core 가 곧 취소를 보고 되돌린다.
        if ticket?.isCancelled == true { return .skip }
        let semaphore = DispatchSemaphore(value: 0)
        let box = AnswerBox()
        let destination = destination, move = move
        let window = self.window, job = self.job
        Task { @MainActor in
            box.answer = await ConflictDialog.ask(source: target, target: target, remaining: 1, inProgress: true,
                                                  destination: destination, move: move, window: window, job: job)
            semaphore.signal()
        }
        semaphore.wait()
        // 작업이 이미 진행 중이라 취소할 수 없으면 이 항목을 건너뛴다.
        let policy = box.answer?.policy ?? .skip
        record(policy, for: target)
        if box.answer?.applyToAll ?? true { setApplyToRest(policy) }
        return policy
    }

    private final class AnswerBox: @unchecked Sendable {
        var answer: (policy: ConflictPolicy, applyToAll: Bool)?
    }
}

/// F8 같은 이름 충돌 대화상자. 충돌 항목마다 묻고, "모든 항목에 적용"을 켜면 남은 항목에 같은 결정을 쓴다.
@MainActor
enum ConflictDialog {
    /// 원본을 Core 와 같은 규칙으로 살펴본다. 폴더 병합의 하위 충돌까지 찾으므로 백그라운드에서 부른다.
    nonisolated static func scan(_ sources: [URL], to destination: URL) -> [ConflictCandidate] {
        let destKey = Location.key(destination)
        return sources.map { source in
            let target = destination.appendingPathComponent(source.lastPathComponent)
            if Location.key(source.deletingLastPathComponent()) == destKey {
                return ConflictCandidate(source: source, target: target, kind: .sameFolder)
            }
            guard exists(target) else { return ConflictCandidate(source: source, target: target, kind: .noConflict) }
            if isWholeDirectory(source), isWholeDirectory(target), Location.key(source) != Location.key(target) {
                return ConflictCandidate(source: source, target: target, kind: .merge(mergeConflicts(source, into: target)))
            }
            return ConflictCandidate(source: source, target: target, kind: .item)
        }
    }

    /// 대상 폴더의 볼륨이 대소문자를 구분하는지. Core 는 같은 이름 판정에 이 값을 쓴다.
    nonisolated static func isCaseSensitive(_ destination: URL) -> Bool {
        (try? destination.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) == true
    }

    private nonisolated static func mergeConflicts(_ source: URL, into target: URL) -> [ConflictQuestion] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []).sorted()
        var result: [ConflictQuestion] = []
        for name in names {
            let child = source.appendingPathComponent(name)
            let childTarget = target.appendingPathComponent(name)
            guard exists(childTarget) else { continue }
            if isWholeDirectory(child), isWholeDirectory(childTarget) {
                result += mergeConflicts(child, into: childTarget)
            } else {
                result.append(ConflictQuestion(source: child, target: childTarget))
            }
        }
        return result
    }

    private nonisolated static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// 패키지(.app 등)는 파일처럼 다룬다.
    private nonisolated static func isWholeDirectory(_ url: URL) -> Bool {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        guard type == .typeDirectory else { return false }
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
    }

    /// 원본마다 차례로 묻는다. 취소하면 nil. 진행률 창에서 job 을 취소해도 nil.
    /// 같은 이름의 원본이 여러 개면 Core 가 첫 원본만 묻고 나머지는 둘 다 유지하므로, 남은 원본 중 첫 원본에만 묻는다.
    /// 건너뛰기로 답한 최상위 원본은 작업에서 빼고, 그다음 같은 이름 원본이 그 자리를 이어받는다.
    static func plan(_ candidates: [ConflictCandidate], destination: URL, move: Bool, caseSensitive: Bool,
                     window: NSWindow?, job: ProgressJob? = nil) async -> ConflictPlan? {
        let resolver = ConflictResolver(destination: destination, move: move, window: window, job: job)
        var remaining = candidates.reduce(0) { count, candidate in
            switch candidate.kind {
            case .item: return count + 1
            case .merge(let questions): return count + questions.count
            default: return count
            }
        }
        var claimed = Set<String>()
        var sources: [URL] = []
        for candidate in candidates {
            let normalized = candidate.source.lastPathComponent.precomposedStringWithCanonicalMapping
            let name = caseSensitive ? normalized : normalized.lowercased()
            switch candidate.kind {
            case .sameFolder, .noConflict:
                // Core 는 같은 폴더 원본의 이름도 사용한 이름으로 센다.
                claimed.insert(name)
                sources.append(candidate.source)
            case .item:
                defer { remaining -= 1 }
                if claimed.contains(name) { sources.append(candidate.source); continue }
                guard let policy = await decide(ConflictQuestion(source: candidate.source, target: candidate.target),
                                                remaining: remaining, resolver: resolver, destination: destination,
                                                move: move, window: window, job: job) else { return nil }
                if policy == .skip { continue }
                resolver.record(policy, for: candidate.target)
                claimed.insert(name)
                sources.append(candidate.source)
            case .merge(let questions):
                if !claimed.insert(name).inserted {
                    remaining -= questions.count
                    sources.append(candidate.source)
                    continue
                }
                for question in questions {
                    defer { remaining -= 1 }
                    guard let policy = await decide(question, remaining: remaining, resolver: resolver,
                                                    destination: destination, move: move,
                                                    window: window, job: job) else { return nil }
                    resolver.record(policy, for: question.target)
                }
                sources.append(candidate.source)
            }
        }
        return ConflictPlan(sources: sources, resolver: resolver)
    }

    private static func decide(_ question: ConflictQuestion, remaining: Int, resolver: ConflictResolver,
                               destination: URL, move: Bool, window: NSWindow?, job: ProgressJob?) async -> ConflictPolicy? {
        if job?.isCancelled == true { return nil }
        if let policy = resolver.restPolicy { return policy }
        guard let answer = await ask(source: question.source, target: question.target, remaining: remaining,
                                     inProgress: false, destination: destination, move: move, window: window,
                                     job: job) else { return nil }
        if answer.applyToAll { resolver.setApplyToRest(answer.policy) }
        return answer.policy
    }

    /// 질문·오류 시트를 붙일 창. 작업을 요청한 창이 닫혔으면 다른 열린 탐색기 창을 쓴다.
    /// 닫힌 창은 다시 띄우지 않는다. 쓸 창이 없으면 nil 이고 독립 모달 알림으로 묻는다 (R3).
    static func hostWindow(preferring window: NSWindow?) -> NSWindow? {
        func isOpen(_ window: NSWindow) -> Bool {
            guard let tabs = window.browserTabs else { return false }
            return !tabs.isClosed
        }
        if let window, isOpen(window), window.attachedSheet == nil { return window }
        let others = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        return others.first { $0.isVisible && isOpen($0) && $0.attachedSheet == nil }
    }

    /// 항목 하나에 대한 질문. remaining 은 이 항목을 포함한 남은 충돌 수.
    /// inProgress 면 작업이 이미 시작돼 취소할 수 없으므로 취소 대신 나머지를 건너뛴다.
    /// 진행률 창에서 job 을 취소하면 떠 있는 질문을 닫고 '취소'로 답한다 (P-M1).
    static func ask(source: URL, target: URL, remaining: Int, inProgress: Bool, destination: URL, move: Bool,
                    window: NSWindow?, job: ProgressJob? = nil) async -> (policy: ConflictPolicy, applyToAll: Bool)? {
        if job?.isCancelled == true { return nil }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let relative = target.path.hasPrefix(destination.path + "/")
            ? String(target.path.dropFirst(destination.path.count + 1)) : target.lastPathComponent
        alert.messageText = "대상 폴더에 '\(relative)'이(가) 이미 있습니다."
        let verb = move ? "이동" : "복사"
        var lines = ["'\(destination.lastPathComponent)'(으)로 \(verb)하는 중입니다. 어떻게 할까요?"]
        if source != target { lines.append("원본: \(source.path)") }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "덮어쓰기")
        alert.addButton(withTitle: "건너뛰기")
        alert.addButton(withTitle: "둘 다 유지")
        alert.addButton(withTitle: inProgress ? "나머지 건너뛰기" : "취소")
        alert.buttons[3].keyEquivalent = "\u{1b}"
        if remaining > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "남은 충돌 \(remaining)개 모두에 적용"
            alert.suppressionButton?.state = .off
        }

        job?.cancelHandler = { [weak alert] in
            guard let panel = alert?.window else { return }
            if let parent = panel.sheetParent {
                parent.endSheet(panel, returnCode: .cancel)
            } else if NSApp.modalWindow === panel {
                NSApp.stopModal(withCode: .cancel)
                // 타이머 등 이벤트 밖에서 불렸으면 모달 루프가 다음 이벤트까지 멈추지 않으므로 하나 넣는다.
                if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 subtype: 0, data1: 0, data2: 0) {
                    NSApp.postEvent(wake, atStart: false)
                }
            }
        }
        defer { job?.cancelHandler = nil }
        let response: NSApplication.ModalResponse
        if let host = hostWindow(preferring: window) {
            response = await alert.beginSheetModal(for: host)
        } else {
            response = alert.runModal()
        }
        if job?.isCancelled == true { return nil }
        let applyToAll = alert.suppressionButton?.state == .on && remaining > 1
        switch response {
        case .alertFirstButtonReturn: return (.replace, applyToAll)
        case .alertSecondButtonReturn: return (.skip, applyToAll)
        case .alertThirdButtonReturn: return (.keepBoth, applyToAll)
        default: return nil
        }
    }
}

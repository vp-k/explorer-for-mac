import AppKit
import ExplorerCore

/// 모든 창이 함께 쓰는 설정, 잘라내기 상태, 실행 취소 기록, 빠른 액세스.
@MainActor
final class AppState {
    static let shared = AppState()

    static let settingsChanged = Notification.Name("Explorer.settingsChanged")
    static let clipboardChanged = Notification.Name("Explorer.clipboardChanged")
    static let pinsChanged = Notification.Name("Explorer.pinsChanged")
    static let volumesChanged = Notification.Name("Explorer.volumesChanged")
    /// 파일 작업이 끝났다. userInfo["folders"] 는 바뀐 폴더 [URL], 없으면 전부 다시 읽는다.
    static let filesChanged = Notification.Name("Explorer.filesChanged")

    private let defaults = UserDefaults.standard

    /// V4 숨김 항목 표시.
    var showHidden: Bool {
        didSet { defaults.set(showHidden, forKey: "showHidden"); post(Self.settingsChanged) }
    }

    /// V5 확장자 표시. 기본은 켬.
    var showExtensions: Bool {
        didSet { defaults.set(showExtensions, forKey: "showExtensions"); post(Self.settingsChanged) }
    }

    /// 화면 테마. 보기 > 테마 메뉴에서 고르고 저장한다 (DESIGN 6장).
    enum ThemeMode: Int, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: return "시스템"
            case .light: return "라이트"
            case .dark: return "다크"
            }
        }
    }

    var theme: ThemeMode {
        didSet { defaults.set(theme.rawValue, forKey: "theme"); applyTheme() }
    }

    func applyTheme() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// F2 잘라내기 상태. 시스템 대지와의 연동은 ClipboardBridge 가 맡는다.
    var clipboard = FileClipboard()
    /// 잘라내기를 기록한 시점의 대지 changeCount. 다르면 다른 앱이 대지를 바꾼 것이다.
    var clipboardChangeCount = -1

    private(set) var undoStack: [FileOperationRecord] = []
    private(set) var redoStack: [FileOperationRecord] = []

    /// 모든 창의 파일 작업, 실행 취소, 다시 실행을 차례대로 실행한다.
    let operations = SerialOperationQueue()

    /// N7 빠른 액세스 고정 폴더.
    lazy var pins = PinnedFolderStore(storageURL: Self.supportDirectory.appendingPathComponent("pinned.json"))

    private init() {
        showHidden = defaults.bool(forKey: "showHidden")
        showExtensions = defaults.object(forKey: "showExtensions") as? Bool ?? true
        theme = ThemeMode(rawValue: defaults.integer(forKey: "theme")) ?? .system
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(self, selector: #selector(volumesDidChange(_:)), name: name, object: nil)
        }
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Explorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: 실행 취소 (F7)

    func pushUndo(_ record: FileOperationRecord?) {
        guard let record else { return }
        undoStack.append(record)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// 실행 취소가 성공한 뒤에만 기록을 옮긴다. 큐 안에서만 부르므로 맨 위 기록이 그대로다.
    func completeUndo(redo: FileOperationRecord?) {
        guard !undoStack.isEmpty else { return }
        undoStack.removeLast()
        if let redo { redoStack.append(redo) }
    }

    /// 다시 실행 결과는 다시 실행 기록을 지우지 않고 실행 취소 쪽에 쌓는다.
    func completeRedo(undo: FileOperationRecord?) {
        guard !redoStack.isEmpty else { return }
        redoStack.removeLast()
        if let undo { undoStack.append(undo) }
    }

    // MARK: 빠른 액세스

    func togglePin(_ url: URL) {
        if pins.isPinned(url) { pins.unpin(url) } else { pins.pin(url) }
        post(Self.pinsChanged)
    }

    func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    @objc private func volumesDidChange(_ note: Notification) {
        post(Self.volumesChanged)
    }
}

/// 앞 작업이 끝나야 다음 작업을 시작하는 큐. 작업은 MainActor 에서 시작하고 무거운 일은 직접 백그라운드로 보낸다.
/// 실행 취소처럼 앞 작업의 결과(기록 스택)에 기대는 작업도 순서가 보장된다.
/// 실행 중이거나 기다리는 작업 수를 세어, 앱 종료가 작업을 끊지 않도록 알려 준다 (R1).
@MainActor
final class SerialOperationQueue {
    private var tail: Task<Void, Never>?
    /// 실행 중이거나 차례를 기다리는 작업 수.
    private(set) var pendingCount = 0
    /// 마지막 작업이 끝나 큐가 비었을 때 부른다.
    var onIdle: (() -> Void)?

    var isBusy: Bool { pendingCount > 0 }

    func run<T: Sendable>(_ job: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        pendingCount += 1
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await job()
        }
        tail = Task { @MainActor [weak self] in
            _ = await task.value
            guard let self else { return }
            self.pendingCount -= 1
            guard self.pendingCount == 0 else { return }
            // 작업을 기다리던 쪽의 마무리(목록 갱신 등)가 먼저 돌도록 한 번 미룬다.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.pendingCount == 0 { self.onIdle?() }
                }
            }
        }
        return await task.value
    }
}

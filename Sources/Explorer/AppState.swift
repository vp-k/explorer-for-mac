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

    private let defaults = UserDefaults.standard

    /// V4 숨김 항목 표시.
    var showHidden: Bool {
        didSet { defaults.set(showHidden, forKey: "showHidden"); post(Self.settingsChanged) }
    }

    /// V5 확장자 표시. 기본은 켬.
    var showExtensions: Bool {
        didSet { defaults.set(showExtensions, forKey: "showExtensions"); post(Self.settingsChanged) }
    }

    /// F2 잘라내기 상태. 시스템 대지와의 연동은 ClipboardBridge 가 맡는다.
    var clipboard = FileClipboard()
    /// 잘라내기를 기록한 시점의 대지 changeCount. 다르면 다른 앱이 대지를 바꾼 것이다.
    var clipboardChangeCount = -1

    private(set) var undoStack: [FileOperationRecord] = []
    private(set) var redoStack: [FileOperationRecord] = []

    /// N7 빠른 액세스 고정 폴더.
    lazy var pins = PinnedFolderStore(storageURL: Self.supportDirectory.appendingPathComponent("pinned.json"))

    private init() {
        showHidden = defaults.bool(forKey: "showHidden")
        showExtensions = defaults.object(forKey: "showExtensions") as? Bool ?? true
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

    func popUndo() -> FileOperationRecord? { undoStack.popLast() }
    func popRedo() -> FileOperationRecord? { redoStack.popLast() }

    func pushRedo(_ record: FileOperationRecord?) {
        if let record { redoStack.append(record) }
    }

    /// 다시 실행 결과는 다시 실행 기록을 지우지 않고 실행 취소 쪽에 쌓는다.
    func pushUndoKeepingRedo(_ record: FileOperationRecord?) {
        if let record { undoStack.append(record) }
    }

    // MARK: 빠른 액세스

    func togglePin(_ url: URL) {
        if pins.isPinned(url) { pins.unpin(url) } else { pins.pin(url) }
        post(Self.pinsChanged)
    }

    func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    @objc private func volumesDidChange(_ note: Notification) {
        post(Self.volumesChanged)
    }
}

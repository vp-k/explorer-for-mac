import Foundation
import Darwin

public struct OperationProgressSnapshot: Sendable, Equatable {
    /// 사전 집계한 파일 수. 디렉터리는 제외하고 심볼릭 링크는 한 항목으로 센다.
    public var totalItems: Int
    /// 처리가 끝난 파일 수. 건너뛴 파일도 포함한다.
    public var completedItems: Int
    public var totalBytes: Int64
    /// 처리한 논리 바이트 수. 이름 변경 이동과 건너뛴 파일도 포함한다.
    public var completedBytes: Int64
    public var currentName: String

    public init(totalItems: Int, completedItems: Int, totalBytes: Int64,
                completedBytes: Int64, currentName: String) {
        self.totalItems = totalItems
        self.completedItems = completedItems
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.currentName = currentName
    }
}

/// 한 배치에 하나씩 사용한다. cancel/isCancelled 는 어느 스레드에서든 사용할 수 있다.
/// onUpdate 는 작업을 실행하는 스레드(백그라운드일 수 있음)에서 동기 호출된다.
/// UI 갱신은 메인 스레드로 전달해야 한다. 중간 알림은 0.1초 간격으로 합치며,
/// 시작·첫 바이트·성공 완료 알림은 즉시 전달한다. 취소/실패 롤백은 진행률을 되감지 않는다.
public final class OperationProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let onUpdate: @Sendable (OperationProgressSnapshot) -> Void

    public init(onUpdate: @escaping @Sendable (OperationProgressSnapshot) -> Void) {
        self.onUpdate = onUpdate
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    fileprivate func publish(_ snapshot: OperationProgressSnapshot) { onUpdate(snapshot) }
}

/// Mutable accounting belongs to the operation's thread, independently of the cancellation lock.
final class OperationProgressSession {
    struct Work {
        var items = 0
        var bytes: Int64 = 0
        mutating func add(_ other: Work) { items += other.items; bytes += other.bytes }
    }

    let progress: OperationProgress
    private var inventory: [String: Work] = [:]
    private var sourceDevices: [String: dev_t] = [:]
    private var destinationDevices: [String: dev_t] = [:]
    private(set) var snapshot = OperationProgressSnapshot(totalItems: 0, completedItems: 0,
                                                         totalBytes: 0, completedBytes: 0, currentName: "")
    private var lastUpdate = -Double.infinity
    private var sentBytes = false

    init(_ progress: OperationProgress, sources: [URL]) throws {
        self.progress = progress
        var total = Work()
        for source in sources { total.add(try count(source)) }
        snapshot.totalItems = total.items
        snapshot.totalBytes = total.bytes
        publish(force: true)
        try checkCancellation()
    }

    func checkCancellation() throws {
        if progress.isCancelled { throw FileOperationError.cancelled }
    }

    func work(for source: URL) -> Work { inventory[source.standardizedFileURL.path] ?? Work() }

    /// Reuse the preflight lstat device and inspect each destination directory only once.
    /// lstat also ensures that moving a symlink compares the link's volume, not its target's.
    func isSameVolume(_ source: URL, toDirectory directory: URL) -> Bool {
        guard let sourceDevice = sourceDevices[source.standardizedFileURL.path] else { return false }
        let path = directory.path
        if let device = destinationDevices[path] { return sourceDevice == device }
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        destinationDevices[path] = info.st_dev
        return sourceDevice == info.st_dev
    }

    func begin(_ source: URL) throws {
        try checkCancellation()
        snapshot.currentName = source.lastPathComponent
        publish()
        try checkCancellation()
    }

    func complete(_ source: URL) throws {
        let work = work(for: source)
        update(items: snapshot.completedItems + work.items, bytes: snapshot.completedBytes + work.bytes,
               name: source.lastPathComponent)
        try checkCancellation()
    }

    func update(items: Int, bytes: Int64, name: String) {
        snapshot.completedItems = min(snapshot.totalItems, max(snapshot.completedItems, items))
        snapshot.completedBytes = min(snapshot.totalBytes, max(snapshot.completedBytes, bytes))
        snapshot.currentName = name
        let firstBytes = !sentBytes && snapshot.completedBytes > 0
        if firstBytes { sentBytes = true }
        publish(force: firstBytes)
    }

    func finish() throws {
        try checkCancellation()
        snapshot.completedItems = snapshot.totalItems
        snapshot.completedBytes = snapshot.totalBytes
        publish(force: true)
        try checkCancellation()
    }

    private func publish(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastUpdate >= 0.1 else { return }
        lastUpdate = now
        progress.publish(snapshot)
    }

    private func count(_ url: URL) throws -> Work {
        try checkCancellation()
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        var work = Work()
        if info.st_mode & S_IFMT == S_IFDIR {
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                work.add(try count(url.appendingPathComponent(name)))
            }
        } else {
            work = Work(items: 1, bytes: max(0, Int64(info.st_size)))
        }
        let path = url.standardizedFileURL.path
        inventory[path] = work
        sourceDevices[path] = info.st_dev
        return work
    }

    /// Copy into private staging. Never use COPYFILE_MOVE: originals must survive cancellation.
    func copy(_ source: URL, to target: URL) throws {
        try begin(source)
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let context = CopyContext(session: self)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        let callback: copyfile_callback_t = { what, stage, state, source, _, pointer in
            guard let pointer else { return COPYFILE_QUIT }
            let context = Unmanaged<CopyContext>.fromOpaque(pointer).takeUnretainedValue()
            return context.receive(what, stage, state: state, source: source)
        }
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), pointer) == 0 else {
            throw POSIXError(.EINVAL)
        }
        // Clones suppress byte callbacks. The legacy nil-progress path keeps FileManager's fast copy.
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
        let status = copyfile(source.path, target.path, state, flags)
        let errorCode = context.errorCode ?? errno
        try checkCancellation()
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode), userInfo: [NSFilePathErrorKey: source.path])
        }
        let work = work(for: source)
        update(items: context.baseItems + work.items, bytes: context.baseBytes + work.bytes, name: source.lastPathComponent)
        try checkCancellation()
    }

    private final class CopyContext {
        let session: OperationProgressSession
        let baseItems: Int
        let baseBytes: Int64
        var finished = Work()
        var errorCode: Int32?

        init(session: OperationProgressSession) {
            self.session = session
            baseItems = session.snapshot.completedItems
            baseBytes = session.snapshot.completedBytes
        }

        func receive(_ what: Int32, _ stage: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?) -> Int32 {
            if session.progress.isCancelled { return COPYFILE_QUIT }
            if stage == COPYFILE_ERR {
                errorCode = errno
                return COPYFILE_QUIT
            }
            if let source {
                let url = URL(fileURLWithPath: String(cString: source))
                var copied: off_t = 0
                if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH {
                    finished.add(session.work(for: url))
                } else if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                    if let state { _ = copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) }
                    copied = min(copied, session.work(for: url).bytes)
                }
                session.update(items: baseItems + finished.items, bytes: baseBytes + finished.bytes + copied,
                               name: url.lastPathComponent)
            }
            return session.progress.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
    }
}

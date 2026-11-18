import Foundation

/// 잘라내기/복사 상태. 시스템 대지(NSPasteboard) 연동은 UI 쪽 책임이고,
/// 여기서는 "마지막으로 잘라낸 URL 목록" 을 기억해 붙여넣기 시 이동인지 판단한다.
public struct FileClipboard: Sendable, Equatable {
    public enum Mode: Sendable { case copy, cut }
    public private(set) var urls: [URL] = []
    public private(set) var mode: Mode = .copy
    public init() {}
    public mutating func set(_ urls: [URL], mode: Mode) { self.urls = urls; self.mode = mode }
    public mutating func clear() { urls = []; mode = .copy }
    /// 이 URL 이 잘라내기 상태인가 (목록에서 흐리게 표시).
    public func isCut(_ url: URL) -> Bool { mode == .cut && urls.contains(url) }
}

public enum SizeFormatter {
    /// Windows 자세히 보기 식 크기 표기. KB 단위로 올림하고 천 단위 구분을 넣는다.
    /// 0B → "0 KB", 1B → "1 KB", 1025B → "2 KB", 1_263_616B → "1,234 KB".
    public static func explorerSize(_ bytes: Int64) -> String {
        let bytes = max(0, bytes)
        let kilobytes = bytes / 1024 + (bytes % 1024 == 0 ? 0 : 1)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return "\(formatter.string(from: NSNumber(value: kilobytes)) ?? String(kilobytes)) KB"
    }
    /// 상태 표시줄/속성 창용: "1.5 MB", "3.2 GB".
    public static func humanSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(max(0, bytes))
        var index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = index == 0 ? 0 : 1
        formatter.minimumFractionDigits = 0
        return "\(formatter.string(from: NSNumber(value: value)) ?? String(value)) \(units[index])"
    }
}

public enum WildcardMatcher {
    /// 검색어 매칭. "*", "?" 와일드카드 지원, 없으면 대소문자 무시 부분 일치.
    public static func matches(_ name: String, pattern: String) -> Bool {
        let pattern = pattern.lowercased()
        let name = name.lowercased()
        guard pattern.contains("*") || pattern.contains("?") else { return name.contains(pattern) }
        let text = Array(name)
        let glob = Array(pattern)
        var i = 0, j = 0
        var star: Int?, retry = 0
        while i < text.count {
            if j < glob.count && (glob[j] == "?" || glob[j] == text[i]) { i += 1; j += 1 }
            else if j < glob.count && glob[j] == "*" { star = j; j += 1; retry = i }
            else if let lastStar = star { retry += 1; i = retry; j = lastStar + 1 }
            else { return false }
        }
        while j < glob.count && glob[j] == "*" { j += 1 }
        return j == glob.count
    }
}

/// 하위 폴더까지 이름 검색. 취소 가능, 배치로 결과 전달.
public final class FileSearch: @unchecked Sendable {
    private let root: URL
    private let query: String
    private let showHidden: Bool
    private let lock = NSLock()
    private var cancelled = false
    private var running = false

    public init(root: URL, query: String, showHidden: Bool) {
        self.root = root; self.query = query; self.showHidden = showHidden
    }
    /// 백그라운드 스레드에서 호출하라. onBatch 는 호출한 스레드에서 불린다.
    public func run(batchSize: Int = 200, onBatch: ([FileItem]) -> Void) {
        let canRun = lock.withLock {
            guard !cancelled && !running else { return false }
            running = true
            return true
        }
        guard canRun else { return }
        defer { lock.withLock { running = false } }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: options, errorHandler: { _, _ in true }
        ) else { return }
        var batch: [FileItem] = []
        let limit = max(1, batchSize)
        while !isCancelled, let url = enumerator.nextObject() as? URL {
            guard let item = try? FileItem.load(url) else { continue }
            if !showHidden && item.isHidden { enumerator.skipDescendants(); continue }
            guard WildcardMatcher.matches(item.name, pattern: query) else { continue }
            batch.append(item)
            if batch.count >= limit {
                guard !isCancelled else { return }
                onBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty && !isCancelled { onBatch(batch) }
    }
    public func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }
}

public struct FolderStats: Sendable, Equatable {
    public var totalBytes: Int64 = 0
    public var fileCount: Int = 0
    public var folderCount: Int = 0
    public init() {}
}

public enum FolderSizeCalculator {
    /// 재귀 합계 (속성 창). isCancelled 가 true 면 중단하고 그때까지 합계를 돌려준다.
    public static func stats(for urls: [URL], isCancelled: () -> Bool = { false }) -> FolderStats {
        var result = FolderStats()
        var visited = Set<String>()
        func include(_ url: URL, isRoot: Bool) -> Bool {
            guard !isCancelled() else { return false }
            guard visited.insert(url.standardizedFileURL.path).inserted,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                // The selected container itself is not part of its contents count.
                if !isRoot { result.folderCount += 1 }
                return true
            }
            result.fileCount += 1
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            result.totalBytes = result.totalBytes > Int64.max - bytes ? Int64.max : result.totalBytes + bytes
            return false
        }
        for url in urls {
            guard !isCancelled() else { break }
            guard include(url, isRoot: true),
                  let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: nil, errorHandler: { _, _ in true }
                  ) else { continue }
            while !isCancelled(), let child = enumerator.nextObject() as? URL {
                if !include(child, isRoot: false) { enumerator.skipDescendants() }
            }
        }
        return result
    }
}

public struct VolumeInfo: Hashable, Sendable {
    public let url: URL
    public let name: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let isRemovable: Bool
    public let isInternal: Bool
    public init(url: URL, name: String, totalBytes: Int64, availableBytes: Int64, isRemovable: Bool, isInternal: Bool) {
        self.url = url; self.name = name; self.totalBytes = totalBytes
        self.availableBytes = availableBytes; self.isRemovable = isRemovable; self.isInternal = isInternal
    }
}

public enum VolumeLister {
    /// "내 PC" 에 보일 마운트된 볼륨 (루트 볼륨 포함, 숨김 볼륨 제외).
    public static func volumes() -> [VolumeInfo] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsRemovableKey, .volumeIsInternalKey, .isHiddenKey
        ]
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        var urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        if !urls.contains(where: { $0.path == "/" }) { urls.insert(root, at: 0) }
        var seen = Set<String>()
        return urls.compactMap { url in
            guard seen.insert(url.standardizedFileURL.path).inserted,
                  let values = try? url.resourceValues(forKeys: keys),
                  url.path == "/" || values.isHidden != true else { return nil }
            return VolumeInfo(
                url: url, name: values.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent),
                totalBytes: Int64(values.volumeTotalCapacity ?? 0), availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                isRemovable: values.volumeIsRemovable ?? false, isInternal: values.volumeIsInternal ?? false
            )
        }.sorted {
            if ($0.url.path == "/") != ($1.url.path == "/") { return $0.url.path == "/" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// 빠른 액세스 고정 폴더. JSON 파일에 저장.
public final class PinnedFolderStore: @unchecked Sendable {
    private let storageURL: URL
    private let lock = NSLock()
    private var storedFolders: [URL]

    public init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL), let paths = try? JSONDecoder().decode([String].self, from: data) {
            var seen = Set<String>()
            storedFolders = paths.compactMap { path in
                let url = path.hasPrefix("file://") ? URL(string: path) : URL(fileURLWithPath: path)
                guard let url, url.isFileURL, seen.insert(url.standardizedFileURL.path).inserted else { return nil }
                return url.standardizedFileURL
            }
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            storedFolders = ["Desktop", "Downloads", "Documents", "Pictures"].map { home.appendingPathComponent($0, isDirectory: true) }
        }
    }
    /// 저장 파일이 없으면 기본값: 바탕 화면, 다운로드, 문서, 사진.
    public var folders: [URL] { lock.withLock { storedFolders } }
    public func pin(_ url: URL) {
        guard url.isFileURL else { return }
        lock.withLock {
            let url = url.standardizedFileURL
            guard !storedFolders.contains(where: { $0.path == url.path }) else { return }
            storedFolders.append(url)
            save()
        }
    }
    public func unpin(_ url: URL) {
        lock.withLock {
            storedFolders.removeAll { $0.path == url.standardizedFileURL.path }
            save()
        }
    }
    public func isPinned(_ url: URL) -> Bool { lock.withLock { storedFolders.contains { $0.path == url.standardizedFileURL.path } } }
    public func move(from: Int, to: Int) {
        lock.withLock {
            guard storedFolders.indices.contains(from), storedFolders.indices.contains(to), from != to else { return }
            let folder = storedFolders.remove(at: from)
            storedFolders.insert(folder, at: to)
            save()
        }
    }

    // Called with the lock held so an older snapshot can never overwrite a newer one.
    private func save() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(storedFolders.map(\.path))
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // The public mutation API is nonthrowing; retain the in-memory state on disk errors.
        }
    }
}

/// 폴더 변경 감시 (FSEvents 또는 DispatchSource). 변경 시 main 큐에서 onChange 호출 (0.3초 디바운스).
public final class DirectoryWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ExplorerCore.DirectoryWatcher")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var stopped = false

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { stopped = true; return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke], queue: queue
        )
        self.source = source
        source.setEventHandler { [weak self] in self?.schedule(onChange) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }
    public func stop() {
        let oldSource = lock.withLock {
            stopped = true
            generation &+= 1
            pending?.cancel()
            pending = nil
            let old = source
            source = nil
            return old
        }
        oldSource?.cancel()
    }
    deinit { stop() }

    private func schedule(_ onChange: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard !stopped else { return }
            pending?.cancel()
            generation &+= 1
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let active = self.lock.withLock { !self.stopped && self.generation == token }
                if active { onChange() }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
}

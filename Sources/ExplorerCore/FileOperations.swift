import Foundation
import Darwin

public enum ConflictPolicy: Sendable {
    /// 덮어쓰기
    case replace
    /// 건너뛰기
    case skip
    /// "이름 (2).ext" 로 둘 다 유지
    case keepBoth
}

public enum FileOperationError: LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(String)
    case destinationInsideSource(String)
    case destinationContainsSource(String)
    case notFound(String)
    case cancelled
    /// 영구 삭제가 일부 완료된 뒤 실패했다. deleted 는 삭제가 완료된 최상위 항목들이다.
    case partialDeletion(deleted: [URL], failed: URL, reason: String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidName(let s): return "잘못된 이름입니다: \(s)"
        case .alreadyExists(let s): return "같은 이름의 항목이 이미 있습니다: \(s)"
        case .destinationInsideSource(let s): return "대상 폴더가 원본 폴더 안에 있습니다: \(s)"
        case .destinationContainsSource(let s): return "대상 항목이 원본을 포함하고 있습니다: \(s)"
        case .notFound(let s): return "항목을 찾을 수 없습니다: \(s)"
        case .cancelled: return "파일 작업이 취소되었습니다."
        case .partialDeletion(let deleted, let failed, let reason):
            return "영구 삭제 실패: \(failed.path)\n\(reason)\n삭제 완료:\n\(deleted.map(\.path).joined(separator: "\n"))"
        case .failed(let s): return s
        }
    }
}

/// 실행 취소(Cmd+Z)용 기록.
public enum FileOperationRecord: Sendable, Equatable {
    case copied(created: [URL])
    case moved(pairs: [MovePair])
    case renamed(from: URL, to: URL)
    case trashed(pairs: [MovePair])   // from: 원래 위치, to: 휴지통 또는 같은 볼륨의 숨김 백업 위치
    case created(URL)
    /// 순서대로 완료한 작업들. 실행 취소는 역순으로 수행하며 덮어쓴 항목도 복구한다.
    indirect case compound(records: [FileOperationRecord])
}

public struct MovePair: Sendable, Equatable {
    public let from: URL
    public let to: URL
    public init(from: URL, to: URL) { self.from = from; self.to = to }
}

public struct OperationResult: Sendable {
    public let record: FileOperationRecord?
    /// 결과로 생긴(혹은 이동된) 항목들 — 붙여넣기 후 선택에 쓴다.
    public let resultURLs: [URL]
    public let skipped: [URL]
    public init(record: FileOperationRecord?, resultURLs: [URL], skipped: [URL]) {
        self.record = record; self.resultURLs = resultURLs; self.skipped = skipped
    }
}

public enum FileOperations {
    /// Undo/Redo에서 기록을 완전히 폐기할 때 호출한다. 이 프로세스가 소유한 숨김 백업만 삭제한다.
    /// 다른 유지 중인 기록에서도 사용하는 기록은 폐기하지 말 것. 반복 호출은 안전하다.
    @discardableResult
    public static func discardBackups(for record: FileOperationRecord) throws -> [URL] {
        try FileOperationArtifacts.shared.discardBackups(for: record)
    }

    /// 앱 시작 시 백그라운드에서 호출한다. 소유 기록과 파일 식별자가 일치하는 종료된 세션만 정리한다.
    /// 최소 24시간 보존하며, 완료가 확인되지 않은 원본 백업은 복구용으로 남긴다.
    @discardableResult
    public static func cleanupStaleArtifacts(olderThan date: Date) throws -> [URL] {
        try FileOperationArtifacts.shared.cleanupStaleArtifacts(olderThan: date)
    }

    /// 같은 폴더로 복사하면 Windows 처럼 "이름 - 복사본.ext", "이름 - 복사본 (2).ext".
    public static func copy(_ sources: [URL], to destination: URL, conflict: ConflictPolicy) throws -> OperationResult {
        try copy(sources, to: destination, conflict: { _ in conflict })
    }

    /// 폴더끼리는 재귀 병합하고 파일/패키지 충돌마다 정책을 선택한다.
    /// 같은 폴더 복사와 배치 내 파일 이름 충돌은 질문 없이 복사본을 만든다. 같은 이름 폴더는 모두 병합한다.
    public static func copy(_ sources: [URL], to destination: URL, conflict: (URL) -> ConflictPolicy) throws -> OperationResult {
        try copy(sources, to: destination, conflict: conflict, progress: nil)
    }

    /// 진행률/취소 지원 복사. 취소 시 이번 배치 전체를 롤백한 뒤 cancelled 를 던진다.
    public static func copy(_ sources: [URL], to destination: URL, conflict: (URL) -> ConflictPolicy,
                            progress: OperationProgress?) throws -> OperationResult {
        try transfer(sources, to: destination, moving: false, conflict: conflict, progress: progress)
    }
    /// 같은 폴더로 이동은 아무 것도 하지 않는다. 폴더를 자기 하위로 옮기면 destinationInsideSource.
    public static func move(_ sources: [URL], to destination: URL, conflict: ConflictPolicy) throws -> OperationResult {
        try move(sources, to: destination, conflict: { _ in conflict })
    }

    /// 폴더끼리는 재귀 병합하고 파일/패키지 충돌마다 정책을 선택한다.
    /// 배치 안에서 이미 사용한 파일 이름은 질문 없이 둘 다 유지한다. 같은 이름 폴더는 모두 병합한다.
    public static func move(_ sources: [URL], to destination: URL, conflict: (URL) -> ConflictPolicy) throws -> OperationResult {
        try move(sources, to: destination, conflict: conflict, progress: nil)
    }

    /// 진행률/취소 지원 이동. 같은 볼륨에서는 이름 변경 후 항목 단위로 보고한다.
    public static func move(_ sources: [URL], to destination: URL, conflict: (URL) -> ConflictPolicy,
                            progress: OperationProgress?) throws -> OperationResult {
        try transfer(sources, to: destination, moving: true, conflict: conflict, progress: progress)
    }

    /// 볼륨 정보를 읽을 수 없으면 false. 존재하지 않는 경로는 가장 가까운 상위 항목으로 비교한다.
    public static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let lhs = volumeIdentifier(for: a), let rhs = volumeIdentifier(for: b) else { return false }
        return lhs.isEqual(rhs)
    }
    /// 휴지통으로 이동 (FileManager.trashItem).
    public static func trash(_ urls: [URL]) throws -> OperationResult {
        try trash(urls, progress: nil)
    }

    /// 진행률/취소 지원 휴지통 이동. 취소 시 완료한 항목도 원래 위치로 복원한다.
    public static func trash(_ urls: [URL], progress: OperationProgress?) throws -> OperationResult {
        if progress?.isCancelled == true { throw FileOperationError.cancelled }
        for url in urls { try requireItem(url) }
        let session = try progress.map { try OperationProgressSession($0, sources: urls) }
        var pairs: [MovePair] = []
        do {
            for url in urls {
                try session?.begin(url)
                let target = try trashItemURL(url)
                pairs.append(MovePair(from: url, to: target))
                try session?.complete(url)
            }
            try session?.finish()
        } catch {
            try rollbackMoves(pairs, after: error)
        }
        return OperationResult(record: pairs.isEmpty ? nil : .trashed(pairs: pairs), resultURLs: pairs.map(\.to), skipped: [])
    }
    /// 영구 삭제 (Shift+Delete). 일부 완료 후 실패하면 partialDeletion 에 삭제 목록을 담는다.
    public static func deletePermanently(_ urls: [URL]) throws {
        for url in urls { try requireItem(url) }
        var deleted: [URL] = []
        for url in urls {
            do { try manager.removeItem(at: url) }
            catch {
                guard !deleted.isEmpty else { throw error }
                throw FileOperationError.partialDeletion(deleted: deleted, failed: url, reason: error.localizedDescription)
            }
            deleted.append(url)
        }
    }
    /// 이름 바꾸기. 빈 이름, "/", ":" 포함, "." ".." 은 invalidName. 대소문자만 바꾸는 것은 허용.
    public static func rename(_ url: URL, to newName: String) throws -> OperationResult {
        try validateName(newName)
        try requireItem(url)
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        if url.lastPathComponent == newName { return OperationResult(record: nil, resultURLs: [url], skipped: []) }
        let caseOnly = url.lastPathComponent.caseInsensitiveCompare(newName) == .orderedSame
        if exists(target) && !(caseOnly && sameLocation(url, target)) {
            throw FileOperationError.alreadyExists(target.path)
        }
        if caseOnly {
            // A temporary hop also works on case-insensitive volumes where a direct rename may be a no-op.
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".explorer-rename-\(UUID().uuidString)")
            try manager.moveItem(at: url, to: temporary)
            do { try manager.moveItem(at: temporary, to: target) }
            catch { try rollbackMoves([MovePair(from: url, to: temporary)], after: error) }
        } else {
            try manager.moveItem(at: url, to: target)
        }
        return OperationResult(record: .renamed(from: url, to: target), resultURLs: [target], skipped: [])
    }
    /// "새 폴더", "새 폴더 (2)" ...
    public static func createFolder(in directory: URL, baseName: String = "새 폴더") throws -> OperationResult {
        try validateName(baseName)
        try requireDirectory(directory)
        let name = availableName(baseName, in: directory, isDirectory: true)
        let target = directory.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        return OperationResult(record: .created(target), resultURLs: [target], skipped: [])
    }
    /// 빈 파일. "새 텍스트 문서.txt", "새 텍스트 문서 (2).txt" ...
    public static func createFile(in directory: URL, baseName: String = "새 텍스트 문서.txt") throws -> OperationResult {
        try validateName(baseName)
        try requireDirectory(directory)
        let name = availableName(baseName, in: directory, isDirectory: false)
        let target = directory.appendingPathComponent(name)
        try Data().write(to: target, options: .withoutOverwriting)
        return OperationResult(record: .created(target), resultURLs: [target], skipped: [])
    }
    /// directory 안에서 겹치지 않는 이름. "a.txt" → "a (2).txt", 폴더 "x" → "x (2)".
    public static func uniqueName(_ name: String, in directory: URL) -> String {
        availableName(name, in: directory, isDirectory: hasWholeDirectoryName(directory.appendingPathComponent(name)))
    }
    /// 선택 항목을 ZIP 최상위에 압축한다. 첫 항목의 이름으로 ZIP 이름을 정하며 macOS 메타데이터는 제외한다.
    /// 비 ASCII 엔트리는 로컬/중앙 헤더의 UTF-8 플래그를 모두 설정한다.
    public static func compress(_ urls: [URL], in directory: URL) throws -> OperationResult {
        guard let first = urls.first else { throw FileOperationError.failed("압축할 항목이 없습니다.") }
        try requireDirectory(directory)
        for url in urls { try requireItem(url) }
        let stem = nameParts(first.lastPathComponent, isDirectory: isDirectoryItem(first)).stem
        let archive = directory.appendingPathComponent(availableName(stem + ".zip", in: directory, isDirectory: false))
        let temporary = try temporaryDirectory(in: directory, excluding: urls)
        defer { try? manager.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("archive.zip")
        var arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl"]
        if urls.count == 1 {
            if isDirectoryItem(first) { arguments.append("--keepParent") }
            arguments += [first.path, output.path]
        } else {
            // ditto accepts one source. Clone the selection on the destination volume when supported.
            let contents = temporary.appendingPathComponent("contents", isDirectory: true)
            try manager.createDirectory(at: contents, withIntermediateDirectories: false)
            for url in urls {
                let target = contents.appendingPathComponent(url.lastPathComponent)
                guard !exists(target) else { throw FileOperationError.alreadyExists(target.path) }
                try stageArchiveItem(url, at: target)
            }
            arguments += [contents.path, output.path]
        }
        try runDitto(arguments)
        try ZIPFilenameEncoding.markUTF8(in: output)
        try manager.moveItem(at: output, to: archive)
        return OperationResult(record: .created(archive), resultURLs: [archive], skipped: [])
    }
    /// zip 을 같은 이름 폴더로 풀기 (ditto -x -k).
    public static func extract(_ zip: URL, to directory: URL) throws -> OperationResult {
        try requireItem(zip)
        try requireDirectory(directory)
        let stem = zip.deletingPathExtension().lastPathComponent
        try validateName(stem)
        let name = availableName(stem, in: directory, isDirectory: true)
        let target = directory.appendingPathComponent(name, isDirectory: true)
        let temporary = try temporaryDirectory(in: directory)
        defer { try? manager.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("contents", isDirectory: true)
        try manager.createDirectory(at: output, withIntermediateDirectories: false)
        try runDitto(["-x", "-k", zip.path, output.path])
        try manager.moveItem(at: output, to: target)
        return OperationResult(record: .created(target), resultURLs: [target], skipped: [])
    }
    /// 실행 취소. 되돌린 뒤의 기록(다시 실행용)을 돌려준다.
    @discardableResult
    public static func undo(_ record: FileOperationRecord) throws -> FileOperationRecord? {
        try undo(record, trashItem: trashItemURL)
    }

    // Internal injection point to exercise filesystems that cannot provide a Trash directory.
    static func undo(_ record: FileOperationRecord, trashItem: @escaping (URL) throws -> URL) throws -> FileOperationRecord? {
        try FileOperationArtifacts.shared.protectBackups(referencedBy: record)
        let inverse = try performUndo(record, excluding: backupExclusions(for: record), trashItem: trashItem)
        FileOperationArtifacts.shared.commitBackups(referencedBy: inverse)
        return inverse
    }

    private static func performUndo(_ record: FileOperationRecord, excluding: [URL],
                                    trashItem: @escaping (URL) throws -> URL) throws -> FileOperationRecord? {
        switch record {
        case .compound(let records):
            return try undoCompound(records, excluding: excluding, trashItem: trashItem)
        case .copied(let urls):
            return try preserveForUndo(urls, excluding: excluding, trashItem: trashItem)
        case .created(let url):
            return try preserveForUndo([url], excluding: excluding, trashItem: trashItem)
        case .renamed(let from, let to):
            try requireDirectory(from.deletingLastPathComponent())
            return try rename(to, to: from.lastPathComponent).record
        case .moved(let pairs), .trashed(let pairs):
            guard !pairs.isEmpty else { return nil }
            // Check the complete batch before restoring anything. Never overwrite a newly created item.
            for pair in pairs {
                try requireItem(pair.to)
                try requireDirectory(pair.from.deletingLastPathComponent())
                guard !exists(pair.from) else { throw FileOperationError.alreadyExists(pair.from.path) }
            }
            var restored: [MovePair] = []
            do {
                for pair in pairs.reversed() {
                    try manager.moveItem(at: pair.to, to: pair.from)
                    restored.append(MovePair(from: pair.to, to: pair.from))
                }
            } catch { try rollbackMoves(restored, after: error) }
            return .moved(pairs: restored)
        }
    }

    private static let manager = FileManager.default

    private static func exists(_ url: URL) -> Bool {
        (try? manager.attributesOfItem(atPath: url.path)) != nil
    }

    private static func requireItem(_ url: URL) throws {
        guard url.isFileURL, exists(url) else { throw FileOperationError.notFound(url.path) }
    }

    private static func requireDirectory(_ url: URL) throws {
        try requireItem(url)
        guard try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw FileOperationError.failed("폴더가 아닙니다: \(url.path)")
        }
    }

    private static func temporaryDirectory(in directory: URL, excluding sources: [URL] = []) throws -> URL {
        var parent = directory.standardizedFileURL.resolvingSymlinksInPath()
        // If the ZIP is being created inside its source, stage outside that tree to avoid archiving ourselves.
        while sources.contains(where: { isDirectoryItem($0) && contains(parent, in: $0) }) {
            guard parent.standardizedFileURL.path != "/" else {
                throw FileOperationError.destinationInsideSource(directory.path)
            }
            parent.deleteLastPathComponent()
        }
        let url = parent.appendingPathComponent(".explorer-archive-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private static func stageArchiveItem(_ source: URL, at target: URL) throws {
        // COPYFILE_CLONE falls back to copying on filesystems without clone support; links remain links.
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_CLONE)
        guard copyfile(source.path, target.path, nil, flags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: source.path])
        }
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain before waiting, so even a large diagnostic cannot fill the pipe and block ditto.
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = String(data: diagnostics, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FileOperationError.failed(message.isEmpty ? "압축 작업에 실패했습니다 (\(process.terminationStatus))." : message)
        }
    }

    private static func sameLocation(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path { return true }
        guard let lhs = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let rhs = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return lhs.isEqual(rhs) && isSameVolume(a, b)
    }

    private static func volumeIdentifier(for url: URL) -> (any NSObjectProtocol)? {
        guard url.isFileURL else { return nil }
        var candidate = url.standardizedFileURL
        while true {
            if let identifier = try? candidate.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier { return identifier }
            guard candidate.path != "/" else { return nil }
            candidate.deleteLastPathComponent()
        }
    }

    private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw FileOperationError.invalidName(name)
        }
    }

    private static func rollbackMoves(_ pairs: [MovePair], after original: Error) throws -> Never {
        var failures: [String] = []
        for pair in pairs.reversed() {
            do { try manager.moveItem(at: pair.to, to: pair.from) }
            catch { failures.append("\(pair.to.path): \(error.localizedDescription)") }
        }
        guard failures.isEmpty else {
            throw FileOperationError.failed("\(original.localizedDescription)\n복구 실패: \(failures.joined(separator: "\n"))")
        }
        throw original
    }

    private static func nameParts(_ name: String, isDirectory: Bool) -> (stem: String, suffix: String) {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    private static func availableName(_ name: String, in directory: URL, isDirectory: Bool) -> String {
        guard exists(directory.appendingPathComponent(name)) else { return name }
        let parts = nameParts(name, isDirectory: isDirectory)
        var number = 2
        while exists(directory.appendingPathComponent("\(parts.stem) (\(number))\(parts.suffix)")) { number += 1 }
        return "\(parts.stem) (\(number))\(parts.suffix)"
    }

    private static func isDirectoryItem(_ url: URL) -> Bool {
        (try? manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    // Packages are opaque items: retain their extension and apply file conflict policies.
    private static func hasWholeDirectoryName(_ url: URL) -> Bool {
        isDirectoryItem(url) && (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
    }

    private static func contains(_ child: URL, in parent: URL) -> Bool {
        let root = parent.standardizedFileURL.resolvingSymlinksInPath().path
        let path = child.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func rejectDescendant(_ destination: URL, of source: URL) throws {
        guard isDirectoryItem(source) else { return }
        let parent = source.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = destination.standardizedFileURL.resolvingSymlinksInPath()
        while true {
            if sameLocation(parent, candidate) { throw FileOperationError.destinationInsideSource(destination.path) }
            guard candidate.path != "/" else { return }
            candidate.deleteLastPathComponent()
        }
    }

    /// Index resolved paths and their proper ancestors once, rather than resolving every pair.
    /// Keep this case sensitive, like contains(_:in:); String equality handles Unicode equivalence.
    private struct PathRelationships {
        private var paths = Set<String>()
        private var ancestors = Set<String>()

        func hasDescendant(of path: String) -> Bool { ancestors.contains(path) }

        func overlaps(_ path: String) -> Bool {
            if paths.contains(path) || ancestors.contains(path) { return true }
            return Self.parents(of: path).contains { paths.contains($0) }
        }

        mutating func insert(_ path: String) {
            guard paths.insert(path).inserted else { return }
            ancestors.formUnion(Self.parents(of: path))
        }

        private static func parents(of path: String) -> [String] {
            guard path != "/" else { return [] }
            var result: [String] = []
            var end = path.endIndex
            while let slash = path[..<end].lastIndex(of: "/") {
                if slash == path.startIndex { result.append("/"); break }
                result.append(String(path[..<slash]))
                end = slash
            }
            return result
        }
    }

    private struct ResourceIdentity: Hashable {
        let volume: AnyHashable
        let item: AnyHashable

        init?(_ values: URLResourceValues?) {
            guard let values,
                  let volume = values.volumeIdentifier as? AnyHashable,
                  let item = values.fileResourceIdentifier as? AnyHashable else { return nil }
            self.volume = volume
            self.item = item
        }
    }

    /// Results can share an inode (hard links) or a resolved path (symlinks and merged folders).
    private struct ResultLocations {
        private var paths = Set<String>()
        private var identities = Set<ResourceIdentity>()
        private var fallback: [URL] = []
        private var items: [URL] = []

        mutating func insert(_ url: URL) -> Bool {
            let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey, .fileResourceIdentifierKey, .isSymbolicLinkKey])
            // A link's resolved path can change when a later batch item creates or moves its target.
            if values?.isSymbolicLink == true {
                guard !items.contains(where: { sameLocation($0, url) }) else { return false }
                fallback.append(url)
                items.append(url)
                return true
            }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let identity = ResourceIdentity(values)
            let duplicate = paths.contains(path) || identity.map { identities.contains($0) } == true
                || fallback.contains { sameLocation($0, url) }
            guard !duplicate else { return false }
            paths.insert(path)
            if let identity { identities.insert(identity) }
            else { fallback.append(url) }
            items.append(url)
            return true
        }
    }

    private struct TransferState {
        let sources: [URL]
        var backupExclusions: [URL]
        let trashItem: (URL) throws -> URL
        let progress: OperationProgressSession?
        var records: [FileOperationRecord] = []
        var skipped: [URL] = []
        var rollback: [() throws -> Void] = []
        var names = Set<String>()
        var writtenItems: [URL] = []
        private var reservationDirectories: [URL: (path: String, caseSensitive: Bool)] = [:]

        mutating func reserve(_ target: URL) -> Bool {
            let directory = target.deletingLastPathComponent()
            let info: (path: String, caseSensitive: Bool)
            if let cached = reservationDirectories[directory] { info = cached }
            else {
                let parent = directory.standardizedFileURL.resolvingSymlinksInPath()
                info = (parent.path, (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                    .volumeSupportsCaseSensitiveNames) == true)
                reservationDirectories[directory] = info
            }
            let name = target.lastPathComponent.precomposedStringWithCanonicalMapping
            let path = (info.path == "/" ? "/" + name : info.path + "/" + name).precomposedStringWithCanonicalMapping
            return !names.insert(info.caseSensitive ? path : path.lowercased()).inserted
        }

        init(sources: [URL], backupExclusions: [URL], trashItem: @escaping (URL) throws -> URL,
             progress: OperationProgressSession?) {
            self.sources = sources
            self.backupExclusions = backupExclusions
            self.trashItem = trashItem
            self.progress = progress
        }
    }

    /// Every completed step has an inverse, including displaced items and merged source directories.
    static func transfer(_ sources: [URL], to destination: URL, moving: Bool,
                         conflict: (URL) -> ConflictPolicy,
                         trashItem: @escaping (URL) throws -> URL = trashItemURL,
                         progress: OperationProgress? = nil) throws -> OperationResult {
        if progress?.isCancelled == true { throw FileOperationError.cancelled }
        try requireDirectory(destination)
        var sameParents: [URL: Bool] = [:]
        var sourceRelationships: PathRelationships?
        for source in sources {
            if progress?.isCancelled == true { throw FileOperationError.cancelled }
            try requireItem(source)
            try rejectDescendant(destination, of: source)
            // Same-parent copies choose a fresh name; same-parent moves leave the item in place.
            let parent = source.deletingLastPathComponent()
            let sameParent = sameParents[parent] ?? sameLocation(parent, destination)
            sameParents[parent] = sameParent
            if sameParent { continue }
            let target = destination.appendingPathComponent(source.lastPathComponent)
            if isDirectoryItem(target) {
                if sourceRelationships == nil {
                    var relationships = PathRelationships()
                    for url in sources { relationships.insert(url.standardizedFileURL.resolvingSymlinksInPath().path) }
                    sourceRelationships = relationships
                }
                if sourceRelationships?.hasDescendant(of: target.standardizedFileURL.resolvingSymlinksInPath().path) == true {
                    throw FileOperationError.destinationContainsSource(target.path)
                }
            }
        }
        let session = try progress.map { try OperationProgressSession($0, sources: sources) }
        var state = TransferState(sources: sources, backupExclusions: sources, trashItem: trashItem, progress: session)
        var urls: [URL] = []
        var locations = ResultLocations()
        do {
            for source in sources {
                let sameParent = sameParents[source.deletingLastPathComponent()] == true
                if moving && sameParent {
                    state.skipped.append(source)
                    try session?.complete(source)
                    continue
                }
                let wholeName = hasWholeDirectoryName(source)
                var target = destination.appendingPathComponent(source.lastPathComponent)
                if !moving && sameParent {
                    let parts = nameParts(source.lastPathComponent, isDirectory: wholeName)
                    let name = availableName("\(parts.stem) - 복사본\(parts.suffix)", in: destination, isDirectory: wholeName)
                    target = destination.appendingPathComponent(name)
                }
                if let completed = try transferItem(source, to: target, moving: moving,
                                                    conflict: conflict, state: &state),
                   locations.insert(completed) {
                    urls.append(completed)
                }
            }
            try session?.finish()
        } catch {
            try rollBack(state.rollback, after: error)
        }
        let record = combinedRecord(state.records)
        FileOperationArtifacts.shared.commitBackups(referencedBy: record)
        return OperationResult(record: record, resultURLs: urls, skipped: state.skipped)
    }

    private static func transferItem(_ source: URL, to proposed: URL, moving: Bool,
                                     conflict: (URL) -> ConflictPolicy, state: inout TransferState) throws -> URL? {
        try state.progress?.begin(source)
        var target = proposed
        state.backupExclusions.append(target)
        let duplicate = state.reserve(target)
        if exists(target) {
            // Finder metadata never needs a conflict dialog. Preserve the source for undo when moving.
            if source.lastPathComponent == ".DS_Store", target.lastPathComponent == ".DS_Store",
               !isDirectoryItem(source), !isDirectoryItem(target), !sameLocation(source, target) {
                if moving { try displaceToTrash(source, state: &state) }
                try state.progress?.complete(source)
                return nil
            }
            let selectedSource = state.sources.contains { sameLocation($0, target) }
            if !selectedSource && hasWholeDirectoryName(source) && hasWholeDirectoryName(target) {
                guard !sameLocation(source, target) else { throw FileOperationError.alreadyExists(target.path) }
                try mergeDirectory(source, into: target, moving: moving, conflict: conflict, state: &state)
                return target
            }
            // A whole directory transferred earlier also owns every child now being merged into it.
            let alreadyWritten = state.writtenItems.contains {
                sameLocation($0, target) || (isDirectoryItem($0) && contains(target, in: $0))
            }
            let keepBoth = selectedSource || duplicate || alreadyWritten
            let policy = keepBoth ? .keepBoth : conflict(target)
            try state.progress?.checkCancellation()
            switch policy {
            case .skip:
                state.skipped.append(source)
                try state.progress?.complete(source)
                return nil
            case .keepBoth:
                target = target.deletingLastPathComponent().appendingPathComponent(
                    availableName(target.lastPathComponent, in: target.deletingLastPathComponent(),
                                  isDirectory: hasWholeDirectoryName(source)))
            case .replace:
                guard !sameLocation(source, target) else { throw FileOperationError.alreadyExists(target.path) }
                try displaceToTrash(target, state: &state)
            }
        }
        state.backupExclusions.append(target)
        try state.progress?.checkCancellation()
        try transferUnoccupiedItem(source, to: target, moving: moving, state: &state)
        _ = state.reserve(target)
        state.writtenItems.append(target)
        return target
    }

    private static func mergeDirectory(_ source: URL, into target: URL, moving: Bool,
                                       conflict: (URL) -> ConflictPolicy, state: inout TransferState) throws {
        let children = try manager.contentsOfDirectory(atPath: source.path).sorted()
        for name in children {
            let child = source.appendingPathComponent(name)
            _ = try transferItem(child, to: target.appendingPathComponent(child.lastPathComponent), moving: moving,
                                 conflict: conflict, state: &state)
        }
        if moving, try manager.contentsOfDirectory(atPath: source.path).isEmpty {
            try state.progress?.checkCancellation()
            // Preserve the empty container so undo restores its metadata before restoring children.
            try displaceToTrash(source, state: &state)
        }
    }

    private static func displaceToTrash(_ url: URL, state: inout TransferState) throws {
        try state.progress?.checkCancellation()
        let pair = try preserveForUndo(url, excluding: state.backupExclusions, trashItem: state.trashItem)
        state.records.append(.trashed(pairs: [pair]))
        state.rollback.append { try manager.moveItem(at: pair.to, to: pair.from) }
    }

    private static func trashItemURL(_ url: URL) throws -> URL {
        let parent = url.deletingLastPathComponent()
        let metadata = parent.appendingPathComponent(".DS_Store")
        // macOS may remove the parent's .DS_Store when trashing its last ordinary item.
        // Stage under a hidden directory so this cleanup never touches retained metadata.
        let staging = parent.appendingPathComponent(".explorer-trash-\(UUID().uuidString)", isDirectory: true)
        let stageItem = url.lastPathComponent != ".DS_Store" && exists(metadata) && !isDirectoryItem(metadata)
        let input: URL
        if stageItem {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            do {
                input = staging.appendingPathComponent(url.lastPathComponent)
                try manager.moveItem(at: url, to: input)
            } catch { try? manager.removeItem(at: staging); throw error }
        } else { input = url }
        defer {
            if stageItem, (try? manager.contentsOfDirectory(atPath: staging.path).isEmpty) == true {
                try? manager.removeItem(at: staging)
            }
        }
        var result: NSURL?
        do { try manager.trashItem(at: input, resultingItemURL: &result) }
        catch {
            if stageItem { try rollbackMoves([MovePair(from: url, to: input)], after: error) }
            throw error
        }
        guard let target = result as URL? else {
            throw FileOperationError.failed("휴지통 위치를 확인할 수 없습니다: \(url.path)")
        }
        return target
    }

    private static func preserveForUndo(_ url: URL, excluding: [URL],
                                       trashItem: (URL) throws -> URL) throws -> MovePair {
        if url.lastPathComponent == ".DS_Store" {
            return try hiddenBackup(url, excluding: excluding)
        }
        do { return MovePair(from: url, to: try trashItem(url)) }
        catch {
            let trashError = error
            guard exists(url) else { throw trashError }
            do { return try hiddenBackup(url, excluding: excluding) }
            catch {
                throw FileOperationError.failed("\(trashError.localizedDescription)\n숨김 백업 실패: \(error.localizedDescription)")
            }
        }
    }

    private static func hiddenBackup(_ url: URL, excluding: [URL]) throws -> MovePair {
        var parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        // Keep backups outside every source/destination tree: merging must not pick them up,
        // and restoring or removing a container must not relocate another record's backup.
        while excluding.contains(where: { contains(parent, in: $0) }) {
            guard parent.path != "/" else { throw FileOperationError.failed("안전한 백업 폴더가 없습니다: \(url.path)") }
            parent.deleteLastPathComponent()
        }
        guard isSameVolume(url, parent) else {
            throw FileOperationError.failed("같은 볼륨에 백업 폴더가 없습니다: \(url.path)")
        }
        let backup = try FileOperationArtifacts.shared.makeBackup(of: url, in: parent)
        return MovePair(from: url, to: backup)
    }

    private static func preserveForUndo(_ urls: [URL], excluding: [URL],
                                       trashItem: (URL) throws -> URL) throws -> FileOperationRecord? {
        for url in urls { try requireItem(url) }
        var pairs: [MovePair] = []
        do {
            for url in urls { pairs.append(try preserveForUndo(url, excluding: excluding, trashItem: trashItem)) }
        } catch { try rollbackMoves(pairs, after: error) }
        return pairs.isEmpty ? nil : .trashed(pairs: pairs)
    }

    private static func backupExclusions(for record: FileOperationRecord) -> [URL] {
        switch record {
        case .copied(let urls): return urls
        case .created(let url): return [url]
        case .moved(let pairs), .trashed(let pairs): return pairs.flatMap { [$0.from, $0.to] }
        case .renamed(let from, let to): return [from, to]
        case .compound(let records): return records.flatMap { backupExclusions(for: $0) }
        }
    }

    private static func transferUnoccupiedItem(_ source: URL, to target: URL, moving: Bool,
                                              state: inout TransferState) throws {
        if moving && (state.progress?.isSameVolume(source, toDirectory: target.deletingLastPathComponent()) ?? true) {
            try manager.moveItem(at: source, to: target)
            state.records.append(.moved(pairs: [MovePair(from: source, to: target)]))
            state.rollback.append { try manager.moveItem(at: target, to: source) }
            try state.progress?.complete(source)
        } else {
            let container = try FileOperationArtifacts.shared.makeCopyStaging(in: target.deletingLastPathComponent())
            defer { try? FileOperationArtifacts.shared.removeCopyStaging(container) }
            let staging = container.appendingPathComponent("payload")
            if let progress = state.progress { try progress.copy(source, to: staging) }
            else { try manager.copyItem(at: source, to: staging) }
            try state.progress?.checkCancellation()
            try manager.moveItem(at: staging, to: target)
            state.records.append(.copied(created: [target]))
            state.rollback.append { try manager.removeItem(at: target) }
            if moving {
                // Cross-volume moves retain the original in a reversible same-volume backup.
                try displaceToTrash(source, state: &state)
            }
            try state.progress?.checkCancellation()
        }
    }

    private static func combinedRecord(_ records: [FileOperationRecord]) -> FileOperationRecord? {
        guard !records.isEmpty else { return nil }
        if records.count == 1 { return records[0] }
        let allCopied = records.allSatisfy { if case .copied = $0 { return true }; return false }
        let allMoved = records.allSatisfy { if case .moved = $0 { return true }; return false }
        guard allCopied || allMoved else { return .compound(records: records) }
        // A directory copied first can receive more batch children through merging. Its inverse
        // must run after the child inverses; flattening these into one batch loses that ordering.
        var relationships = PathRelationships()
        for record in records {
            let paths = backupExclusions(for: record).map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            if paths.contains(where: { relationships.overlaps($0) }) { return .compound(records: records) }
            for path in paths { relationships.insert(path) }
        }
        if allCopied {
            return .copied(created: records.flatMap { if case .copied(let urls) = $0 { return urls }; return [] })
        }
        return .moved(pairs: records.flatMap { if case .moved(let pairs) = $0 { return pairs }; return [] })
    }

    private static func undoCompound(_ records: [FileOperationRecord], excluding: [URL],
                                     trashItem: @escaping (URL) throws -> URL) throws -> FileOperationRecord? {
        // Check before moving anything into Trash: a missing backup's old name could otherwise be reused.
        for record in records { try requireUndoItems(record) }
        var inverses: [FileOperationRecord] = []
        do {
            for record in records.reversed() {
                if let inverse = try performUndo(record, excluding: excluding, trashItem: trashItem) { inverses.append(inverse) }
            }
        } catch {
            try rollBack(inverses.map { record in
                { _ = try performUndo(record, excluding: excluding, trashItem: trashItem) }
            }, after: error)
        }
        // These steps may share paths (restoring an old item after removing its replacement).
        // Preserve their order rather than collapsing them into a batch of independent moves.
        guard !inverses.isEmpty else { return nil }
        return inverses.count == 1 ? inverses[0] : .compound(records: inverses)
    }

    private static func requireUndoItems(_ record: FileOperationRecord) throws {
        switch record {
        case .copied(let urls): for url in urls { try requireItem(url) }
        case .created(let url): try requireItem(url)
        case .moved(let pairs), .trashed(let pairs): for pair in pairs { try requireItem(pair.to) }
        case .renamed(_, let to): try requireItem(to)
        case .compound(let records): for child in records { try requireUndoItems(child) }
        }
    }

    private static func rollBack(_ actions: [() throws -> Void], after original: Error) throws -> Never {
        var failures: [String] = []
        for action in actions.reversed() {
            do { try action() }
            catch { failures.append(error.localizedDescription) }
        }
        guard failures.isEmpty else {
            throw FileOperationError.failed("\(original.localizedDescription)\n복구 실패: \(failures.joined(separator: "\n"))")
        }
        throw original
    }
}

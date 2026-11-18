import Foundation

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
    case notFound(String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidName(let s): return "잘못된 이름입니다: \(s)"
        case .alreadyExists(let s): return "같은 이름의 항목이 이미 있습니다: \(s)"
        case .destinationInsideSource(let s): return "대상 폴더가 원본 폴더 안에 있습니다: \(s)"
        case .notFound(let s): return "항목을 찾을 수 없습니다: \(s)"
        case .failed(let s): return s
        }
    }
}

/// 실행 취소(Cmd+Z)용 기록.
public enum FileOperationRecord: Sendable, Equatable {
    case copied(created: [URL])
    case moved(pairs: [MovePair])
    case renamed(from: URL, to: URL)
    case trashed(pairs: [MovePair])   // from: 원래 위치, to: 휴지통 위치
    case created(URL)
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
    /// 같은 폴더로 복사하면 Windows 처럼 "이름 - 복사본.ext", "이름 - 복사본 (2).ext".
    public static func copy(_ sources: [URL], to destination: URL, conflict: ConflictPolicy) throws -> OperationResult {
        try copy(sources, to: destination, conflict: { _ in conflict })
    }

    /// 충돌한 대상 URL마다 정책을 선택한다. 같은 폴더 복사는 충돌 질문 없이 복사본을 만든다.
    public static func copy(_ sources: [URL], to destination: URL, conflict: (URL) -> ConflictPolicy) throws -> OperationResult {
        try transfer(sources, to: destination, moving: false, conflict: conflict)
    }
    /// 같은 폴더로 이동은 아무 것도 하지 않는다. 폴더를 자기 하위로 옮기면 destinationInsideSource.
    public static func move(_ sources: [URL], to destination: URL, conflict: ConflictPolicy) throws -> OperationResult {
        try move(sources, to: destination, conflict: { _ in conflict })
    }

    /// 충돌한 대상 URL마다 정책을 선택한다.
    public static func move(_ sources: [URL], to destination: URL, conflict: (URL) -> ConflictPolicy) throws -> OperationResult {
        try transfer(sources, to: destination, moving: true, conflict: conflict)
    }

    /// 볼륨 정보를 읽을 수 없으면 false. 존재하지 않는 경로는 가장 가까운 상위 항목으로 비교한다.
    public static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let lhs = volumeIdentifier(for: a), let rhs = volumeIdentifier(for: b) else { return false }
        return lhs.isEqual(rhs)
    }
    /// 휴지통으로 이동 (FileManager.trashItem).
    public static func trash(_ urls: [URL]) throws -> OperationResult {
        for url in urls { try requireItem(url) }
        var pairs: [MovePair] = []
        do {
            for url in urls {
                var result: NSURL?
                try manager.trashItem(at: url, resultingItemURL: &result)
                guard let target = result as URL? else {
                    throw FileOperationError.failed("휴지통 위치를 확인할 수 없습니다: \(url.path)")
                }
                pairs.append(MovePair(from: url, to: target))
            }
        } catch {
            try rollbackMoves(pairs, after: error)
        }
        return OperationResult(record: pairs.isEmpty ? nil : .trashed(pairs: pairs), resultURLs: pairs.map(\.to), skipped: [])
    }
    /// 영구 삭제 (Shift+Delete).
    public static func deletePermanently(_ urls: [URL]) throws {
        for url in urls { try requireItem(url) }
        for url in urls { try manager.removeItem(at: url) }
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
        availableName(name, in: directory, isDirectory: isDirectoryItem(directory.appendingPathComponent(name)))
    }
    /// 압축 (ditto -c -k --sequesterRsrc --keepParent). 하나면 "이름.zip", 여러 개면 "압축.zip".
    public static func compress(_ urls: [URL], in directory: URL) throws -> OperationResult {
        guard let first = urls.first else { throw FileOperationError.failed("압축할 항목이 없습니다.") }
        try requireDirectory(directory)
        for url in urls { try requireItem(url) }
        let stem = urls.count == 1 ? nameParts(first.lastPathComponent, isDirectory: isDirectoryItem(first)).stem : "압축"
        let archive = directory.appendingPathComponent(availableName(stem + ".zip", in: directory, isDirectory: false))
        let temporary = try temporaryDirectory()
        defer { try? manager.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("archive.zip")
        var arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent"]
        if urls.count == 1 {
            arguments += [first.path, output.path]
        } else {
            // ditto accepts only one archive source. Stage the selection under a stable parent name.
            let contents = temporary.appendingPathComponent("압축", isDirectory: true)
            try manager.createDirectory(at: contents, withIntermediateDirectories: false)
            for url in urls {
                let target = contents.appendingPathComponent(url.lastPathComponent)
                guard !exists(target) else { throw FileOperationError.alreadyExists(target.path) }
                try manager.copyItem(at: url, to: target)
            }
            arguments += [contents.path, output.path]
        }
        try runDitto(arguments)
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
        let temporary = try temporaryDirectory()
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
        switch record {
        case .copied(let urls):
            return try trash(urls).record
        case .created(let url):
            return try trash([url]).record
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

    private static func temporaryDirectory() throws -> URL {
        let url = manager.temporaryDirectory.appendingPathComponent("ExplorerCore-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
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

    /// Every completed step has an inverse, so a failed batch does not strand unrecorded changes.
    private static func transfer(_ sources: [URL], to destination: URL, moving: Bool,
                                 conflict: (URL) -> ConflictPolicy) throws -> OperationResult {
        try requireDirectory(destination)
        for source in sources {
            try requireItem(source)
            try rejectDescendant(destination, of: source)
        }
        var pairs: [MovePair] = []
        var skipped: [URL] = []
        var backups: [MovePair] = []
        var rollback: [() throws -> Void] = []
        do {
            for source in sources {
                let sameParent = sameLocation(source.deletingLastPathComponent(), destination)
                if moving && sameParent { skipped.append(source); continue }
                let directory = isDirectoryItem(source)
                var target = destination.appendingPathComponent(source.lastPathComponent, isDirectory: directory)
                if !moving && sameParent {
                    let parts = nameParts(source.lastPathComponent, isDirectory: directory)
                    let name = availableName("\(parts.stem) - 복사본\(parts.suffix)", in: destination, isDirectory: directory)
                    target = destination.appendingPathComponent(name, isDirectory: directory)
                } else if exists(target) {
                    switch conflict(target) {
                    case .skip: skipped.append(source); continue
                    case .keepBoth:
                        target = destination.appendingPathComponent(
                            availableName(source.lastPathComponent, in: destination, isDirectory: directory), isDirectory: directory)
                    case .replace:
                        // A symlink alias or hard link must never cause the source to be removed.
                        guard !sameLocation(source, target) else { throw FileOperationError.alreadyExists(target.path) }
                        let backup = destination.appendingPathComponent(".explorer-backup-\(UUID().uuidString)")
                        try manager.moveItem(at: target, to: backup)
                        backups.append(MovePair(from: target, to: backup))
                        let original = target
                        rollback.append { try manager.moveItem(at: backup, to: original) }
                    }
                }
                if moving { try manager.moveItem(at: source, to: target) }
                else {
                    let staging = destination.appendingPathComponent(".explorer-copy-\(UUID().uuidString)")
                    defer { try? manager.removeItem(at: staging) }
                    try manager.copyItem(at: source, to: staging)
                    try manager.moveItem(at: staging, to: target)
                }
                let completedTarget = target
                rollback.append {
                    if moving { try manager.moveItem(at: completedTarget, to: source) }
                    else { try manager.removeItem(at: completedTarget) }
                }
                pairs.append(MovePair(from: source, to: target))
            }
        } catch {
            var rollbackErrors: [String] = []
            for action in rollback.reversed() {
                do { try action() }
                catch { rollbackErrors.append(error.localizedDescription) }
            }
            if !rollbackErrors.isEmpty {
                throw FileOperationError.failed("\(error.localizedDescription)\n복구 실패: \(rollbackErrors.joined(separator: "\n"))")
            }
            throw error
        }
        for backup in backups { try? manager.removeItem(at: backup.to) }
        let urls = pairs.map(\.to)
        let record: FileOperationRecord? = pairs.isEmpty ? nil : (moving ? .moved(pairs: pairs) : .copied(created: urls))
        return OperationResult(record: record, resultURLs: urls, skipped: skipped)
    }
}

import Foundation
import Darwin

/// A durable ownership journal, rather than a recursive search for similarly named user files.
/// Each process holds its session's flock until exit; cleanup never enters a live session.
final class FileOperationArtifacts {
    static let shared = FileOperationArtifacts(directory: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Explorer/OperationArtifacts/v1", isDirectory: true))

    private enum Kind: String, Codable { case backup, copy }

    private struct Identity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let volumeUUID: String?

        init(at url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            device = info.st_dev
            inode = info.st_ino
            birthSeconds = Int64(info.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
            volumeUUID = try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        }

        static func == (lhs: Identity, rhs: Identity) -> Bool {
            // Device numbers may change when an external volume is remounted after restart.
            let sameVolume: Bool
            if let volume = lhs.volumeUUID { sameVolume = volume == rhs.volumeUUID }
            else { sameVolume = rhs.volumeUUID == nil && lhs.device == rhs.device }
            return sameVolume && lhs.inode == rhs.inode && lhs.birthSeconds == rhs.birthSeconds
                && lhs.birthNanoseconds == rhs.birthNanoseconds
        }
    }

    private struct Entry: Codable {
        let id: UUID
        let kind: Kind
        let path: String
        let identity: Identity
        let createdAt: Date
        // An interrupted backup may be the only copy of a displaced original. Keep it for recovery.
        var committed: Bool

        var url: URL { URL(fileURLWithPath: path, isDirectory: kind == .copy) }
        var hasValidName: Bool { url.lastPathComponent == ".explorer-\(kind.rawValue)-\(id.uuidString)" }
    }

    private let directory: URL
    private let now: () -> Date
    private let lock = NSLock()
    private var session: URL?
    private var sessionDescriptor: Int32 = -1
    private var entries: [String: Entry] = [:]
    private let manager = FileManager.default

    init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    deinit { if sessionDescriptor >= 0 { close(sessionDescriptor) } }

    /// The container is journaled before copying begins. Its payload always starts as a copy.
    func makeCopyStaging(in parent: URL) throws -> URL {
        try lock.withLock {
            let id = UUID()
            let url = parent.appendingPathComponent(".explorer-copy-\(id.uuidString)", isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            do { try register(id: id, kind: .copy, url: url, identity: Identity(at: url)) }
            catch { try? manager.removeItem(at: url); throw error }
            return url
        }
    }

    func removeCopyStaging(_ url: URL) throws {
        try lock.withLock {
            guard let entry = entries[url.path], entry.kind == .copy else { return }
            let manifest = manifestURL(for: entry)
            _ = try remove(entry, manifest: manifest)
            if !manager.fileExists(atPath: manifest.path) { entries.removeValue(forKey: entry.path) }
        }
    }

    /// Journal before the rename so a crash can never leave an unowned full backup.
    func makeBackup(of source: URL, in parent: URL) throws -> URL {
        try lock.withLock {
            let id = UUID()
            let url = parent.appendingPathComponent(".explorer-backup-\(id.uuidString)")
            try register(id: id, kind: .backup, url: url, identity: Identity(at: source))
            do { try manager.moveItem(at: source, to: url) }
            catch {
                if !manager.fileExists(atPath: url.path) {
                    try? manager.removeItem(at: manifestURL(for: entries[url.path]!))
                    entries.removeValue(forKey: url.path)
                }
                throw error
            }
            return url
        }
    }

    /// Failure to update a journal leaves a conservative, non-collectable recovery backup.
    /// Keep missing entries too: an inverse record can reuse the same path during Redo.
    func commitBackups(referencedBy record: FileOperationRecord?) {
        guard let record else { return }
        lock.withLock {
            for path in Self.paths(in: record) {
                guard var entry = entries[path], entry.kind == .backup, !entry.committed,
                      (try? Identity(at: entry.url)) == entry.identity else { continue }
                entry.committed = true
                if (try? write(entry)) != nil { entries[path] = entry }
            }
        }
    }

    /// Undo can recreate a previously committed backup path. If interrupted, that path must
    /// become a recovery artifact again until the complete inverse has succeeded.
    func protectBackups(referencedBy record: FileOperationRecord) throws {
        try lock.withLock {
            for path in Self.paths(in: record) {
                guard var entry = entries[path], entry.kind == .backup, entry.committed else { continue }
                entry.committed = false
                try write(entry)
                entries[path] = entry
            }
        }
    }

    /// Only this session's registered backups are eligible, including nested compound records.
    func discardBackups(for record: FileOperationRecord) throws -> [URL] {
        try lock.withLock {
            var removed: [URL] = []
            for path in Self.paths(in: record).sorted() {
                guard let entry = entries[path], entry.kind == .backup else { continue }
                let manifest = manifestURL(for: entry)
                if try remove(entry, manifest: manifest) { removed.append(entry.url) }
                if !manager.fileExists(atPath: manifest.path) { entries.removeValue(forKey: path) }
            }
            return removed
        }
    }

    /// Only dead sessions, a minimum 24-hour grace period, and positively identified artifacts.
    /// Pending backups, malformed journals, replaced paths and offline volumes are left untouched.
    func cleanupStaleArtifacts(olderThan date: Date) throws -> [URL] {
        try lock.withLock {
            guard manager.fileExists(atPath: directory.path) else { return [] }
            let cutoff = min(date, now().addingTimeInterval(-86_400))
            var removed: [URL] = []
            for candidate in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: candidate.lastPathComponent) != nil,
                      isDirectoryWithoutFollowingLinks(candidate) else { continue }
                let descriptor = open(candidate.appendingPathComponent("session.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { continue }
                defer { close(descriptor) }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
                for manifest in try manager.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil)
                    where manifest.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: manifest),
                          let entry = try? JSONDecoder().decode(Entry.self, from: data),
                          manifest.deletingPathExtension().lastPathComponent == entry.id.uuidString,
                          entry.path.hasPrefix("/"), entry.url.standardizedFileURL.path == entry.path,
                          entry.hasValidName, entry.createdAt < cutoff,
                          entry.kind == .copy || entry.committed else { continue }
                    if try remove(entry, manifest: manifest) { removed.append(entry.url) }
                }
                // Keep the tiny lock file: unlinking it could allow a second cleaner to lock a
                // different inode for this same session while the first cleaner is still inside.
            }
            return removed
        }
    }

    private func register(id: UUID, kind: Kind, url: URL, identity: Identity) throws {
        try ensureSession()
        let entry = Entry(id: id, kind: kind, path: url.standardizedFileURL.path,
                          identity: identity, createdAt: now(), committed: false)
        try write(entry)
        entries[entry.path] = entry
    }

    private func ensureSession() throws {
        guard session == nil else { return }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.appendingPathComponent("session.lock").path,
                              O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        session = url
        sessionDescriptor = descriptor
    }

    private func manifestURL(for entry: Entry) -> URL {
        session!.appendingPathComponent(entry.id.uuidString + ".json")
    }

    private func write(_ entry: Entry) throws {
        try JSONEncoder().encode(entry).write(to: manifestURL(for: entry), options: .atomic)
    }

    /// Never follow an artifact symlink or delete a replacement that only shares its name.
    private func remove(_ entry: Entry, manifest: URL) throws -> Bool {
        let identity: Identity
        do { identity = try Identity(at: entry.url) }
        catch let error as POSIXError where error.code == .ENOENT {
            if manager.fileExists(atPath: entry.url.deletingLastPathComponent().path) {
                try manager.removeItem(at: manifest)
            }
            return false
        }
        guard identity == entry.identity else { return false }
        try manager.removeItem(at: entry.url)
        try manager.removeItem(at: manifest)
        return true
    }

    private func isDirectoryWithoutFollowingLinks(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func paths(in record: FileOperationRecord) -> Set<String> {
        switch record {
        case .compound(let records): return records.reduce(into: []) { $0.formUnion(paths(in: $1)) }
        case .moved(let pairs), .trashed(let pairs):
            return Set(pairs.flatMap { [$0.from.standardizedFileURL.path, $0.to.standardizedFileURL.path] })
        case .copied(let urls): return Set(urls.map { $0.standardizedFileURL.path })
        case .created(let url): return [url.standardizedFileURL.path]
        case .renamed(let from, let to): return [from.standardizedFileURL.path, to.standardizedFileURL.path]
        }
    }
}

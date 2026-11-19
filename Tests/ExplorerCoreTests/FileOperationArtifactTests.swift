import Foundation
import XCTest
@testable import ExplorerCore

final class FileOperationArtifactTests: TemporaryDirectoryTestCase {
    private var journal: URL { root.appendingPathComponent("journal", isDirectory: true) }
    private var oldDate: Date { Date().addingTimeInterval(-3 * 86_400) }

    func testDiscardOnlyRemovesOwnedBackupsInNestedRecordsAndIsIdempotent() throws {
        let source = try file("source/x", "new")
        let target = try file("destination/x", "old")
        let unrelated = try file("destination/.explorer-backup-\(UUID().uuidString)", "user file")
        let result = try FileOperations.transfer([source], to: target.deletingLastPathComponent(), moving: false,
                                                 conflict: { _ in .replace }, trashItem: unavailableTrash)
        let record = try XCTUnwrap(result.record)
        let backups = backupURLs(record)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try text(XCTUnwrap(backups.first)), "old")
        let nested = FileOperationRecord.compound(records: [record, .compound(records: [record, .created(unrelated)])])
        XCTAssertEqual(Set(try FileOperations.discardBackups(for: nested)), Set(backups))
        XCTAssertEqual(try FileOperations.discardBackups(for: nested), [])
        XCTAssertEqual(try text(source), "new")
        XCTAssertEqual(try text(target), "new")
        XCTAssertEqual(try text(unrelated), "user file")
    }

    func testBackupsSurviveUndoRedoUntilCurrentRecordIsDiscarded() throws {
        let source = try file("source/x", "new")
        let target = try file("destination/x", "old")
        let result = try FileOperations.transfer([source], to: target.deletingLastPathComponent(), moving: false,
                                                 conflict: { _ in .replace }, trashItem: unavailableTrash)
        var record = try XCTUnwrap(result.record)
        for _ in 0..<3 {
            record = try XCTUnwrap(FileOperations.undo(record, trashItem: unavailableTrash))
            XCTAssertEqual(try text(target), "old")
            record = try XCTUnwrap(FileOperations.undo(record, trashItem: unavailableTrash))
            XCTAssertEqual(try text(target), "new")
        }
        XCTAssertFalse(try FileOperations.discardBackups(for: record).isEmpty)
        XCTAssertEqual(try text(source), "new")
        XCTAssertEqual(try text(target), "new")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["x"])
    }

    func testDiscardDoesNotEmptySystemTrash() throws {
        let source = try file("source/x", "original")
        let result = try FileOperations.trash([source])
        remember(result.record)
        XCTAssertEqual(try FileOperations.discardBackups(for: XCTUnwrap(result.record)), [])
        _ = try undo(result)
        XCTAssertEqual(try text(source), "original")
    }

    func testCrossVolumeMoveFallbackBackupsSupportUndoRedoAndDiscard() throws {
        let image = root.appendingPathComponent("artifact-volume.dmg")
        let mount = try folder("mounted")
        try hdiutil(["create", "-quiet", "-size", "20m", "-fs", "APFS", "-volname", "ExplorerArtifacts", image.path])
        try hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer {
            do { try hdiutil(["detach", "-quiet", mount.path]) }
            catch { XCTFail("Failed to detach artifact test volume: \(error)") }
        }
        let first = try file("source/first", "first original")
        let second = try file("source/second", "second original")
        XCTAssertFalse(FileOperations.isSameVolume(first, mount))
        let result = try FileOperations.transfer([first, second], to: mount, moving: true,
                                                 conflict: { _ in .replace }, trashItem: unavailableTrash,
                                                 progress: OperationProgress { _ in })
        var record = try XCTUnwrap(result.record)
        let backups = backupURLs(record)
        XCTAssertEqual(backups.count, 2)
        XCTAssertTrue(backups.allSatisfy { FileOperations.isSameVolume($0, first.deletingLastPathComponent()) })
        XCTAssertFalse(exists(first))
        XCTAssertFalse(exists(second))
        record = try XCTUnwrap(FileOperations.undo(record, trashItem: unavailableTrash))
        XCTAssertEqual(try text(first), "first original")
        XCTAssertEqual(try text(second), "second original")
        record = try XCTUnwrap(FileOperations.undo(record, trashItem: unavailableTrash))
        XCTAssertEqual(Set(try FileOperations.discardBackups(for: record)), Set(backups))
        XCTAssertEqual(try names(in: first.deletingLastPathComponent()), [])
        XCTAssertEqual(try text(mount.appendingPathComponent("first")), "first original")
        XCTAssertEqual(try text(mount.appendingPathComponent("second")), "second original")
        XCTAssertEqual(try names(in: mount).filter { $0.hasPrefix(".explorer-") }, [])
    }

    func testStaleCopyStagingIsRecoveredAfterSessionEndsWithOriginalPreserved() throws {
        let original = try file("source/original", "original bytes")
        let destination = try folder("destination")
        let old = oldDate
        var owner: FileOperationArtifacts? = FileOperationArtifacts(directory: journal, now: { old })
        let staging = try XCTUnwrap(owner).makeCopyStaging(in: destination)
        try manager.copyItem(at: original, to: staging.appendingPathComponent("payload"))
        // Dropping the owner releases the same OS lease that process exit releases. The next
        // instance has no in-memory ownership information and must recover from the journal.
        owner = nil
        let cleaner = FileOperationArtifacts(directory: journal)
        XCTAssertEqual(try cleaner.cleanupStaleArtifacts(olderThan: Date()), [staging])
        XCTAssertFalse(exists(staging))
        XCTAssertEqual(try text(original), "original bytes")
        XCTAssertEqual(try cleaner.cleanupStaleArtifacts(olderThan: Date()), [])
    }

    func testStaleCommittedBackupIsCollectedButInterruptedBackupIsKept() throws {
        let completed = try file("source/completed", "completed original")
        let interrupted = try file("source/interrupted", "only remaining original")
        let old = oldDate
        var owner: FileOperationArtifacts? = FileOperationArtifacts(directory: journal, now: { old })
        let retained = try XCTUnwrap(owner).makeBackup(of: completed, in: completed.deletingLastPathComponent())
        let pending = try XCTUnwrap(owner).makeBackup(of: interrupted, in: interrupted.deletingLastPathComponent())
        owner?.commitBackups(referencedBy: .trashed(pairs: [MovePair(from: completed, to: retained)]))
        owner = nil
        let cleaner = FileOperationArtifacts(directory: journal)
        XCTAssertEqual(try cleaner.cleanupStaleArtifacts(olderThan: Date()), [retained])
        XCTAssertFalse(exists(retained))
        XCTAssertEqual(try text(pending), "only remaining original")
    }

    func testLiveSessionIsProtectedEvenForVeryOldArtifacts() throws {
        let original = try file("source/original", "original")
        let old = oldDate
        let owner = FileOperationArtifacts(directory: journal, now: { old })
        let staging = try owner.makeCopyStaging(in: folder("destination"))
        let backup = try owner.makeBackup(of: original, in: original.deletingLastPathComponent())
        let record = FileOperationRecord.trashed(pairs: [MovePair(from: original, to: backup)])
        owner.commitBackups(referencedBy: record)
        let cleaner = FileOperationArtifacts(directory: journal)
        XCTAssertEqual(try cleaner.cleanupStaleArtifacts(olderThan: Date()), [])
        XCTAssertTrue(exists(staging))
        XCTAssertEqual(try text(backup), "original")
        try owner.removeCopyStaging(staging)
        XCTAssertEqual(try owner.discardBackups(for: record), [backup])
    }

    func testRecentDeadSessionIsProtectedEvenWithFutureCutoff() throws {
        var owner: FileOperationArtifacts? = FileOperationArtifacts(directory: journal)
        let staging = try XCTUnwrap(owner).makeCopyStaging(in: folder("destination"))
        owner = nil
        let cleaner = FileOperationArtifacts(directory: journal)
        XCTAssertEqual(try cleaner.cleanupStaleArtifacts(olderThan: Date().addingTimeInterval(86_400)), [])
        XCTAssertTrue(exists(staging))
    }

    func testInterruptedUndoProtectsPreviouslyCommittedBackup() throws {
        let original = try file("source/original", "recovery bytes")
        let old = oldDate
        var owner: FileOperationArtifacts? = FileOperationArtifacts(directory: journal, now: { old })
        let backup = try XCTUnwrap(owner).makeBackup(of: original, in: original.deletingLastPathComponent())
        let record = FileOperationRecord.trashed(pairs: [MovePair(from: original, to: backup)])
        owner?.commitBackups(referencedBy: record)
        try owner?.protectBackups(referencedBy: record)
        owner = nil
        XCTAssertEqual(try FileOperationArtifacts(directory: journal).cleanupStaleArtifacts(olderThan: Date()), [])
        XCTAssertEqual(try text(backup), "recovery bytes")
    }

    func testRequestedCutoffCanRetainArtifactsBeyondMinimumGrace() throws {
        let old = oldDate
        var owner: FileOperationArtifacts? = FileOperationArtifacts(directory: journal, now: { old })
        let staging = try XCTUnwrap(owner).makeCopyStaging(in: folder("destination"))
        owner = nil
        let cleaner = FileOperationArtifacts(directory: journal)
        XCTAssertEqual(try cleaner.cleanupStaleArtifacts(olderThan: old.addingTimeInterval(-1)), [])
        XCTAssertTrue(exists(staging))
        XCTAssertEqual(try cleaner.cleanupStaleArtifacts(olderThan: old.addingTimeInterval(1)), [staging])
    }

    func testCleanupLeavesUnregisteredLookalikesAndReplacementInodesUntouched() throws {
        let destination = try folder("destination")
        let lookalike = try file("destination/.explorer-copy-\(UUID().uuidString)", "user file")
        let old = oldDate
        var owner: FileOperationArtifacts? = FileOperationArtifacts(directory: journal, now: { old })
        let staging = try XCTUnwrap(owner).makeCopyStaging(in: destination)
        let movedAside = root.appendingPathComponent("moved-aside")
        try manager.moveItem(at: staging, to: movedAside)
        try Data("replacement".utf8).write(to: staging)
        owner = nil
        let cleaner = FileOperationArtifacts(directory: journal)
        XCTAssertEqual(try cleaner.cleanupStaleArtifacts(olderThan: Date()), [])
        XCTAssertEqual(try text(lookalike), "user file")
        XCTAssertEqual(try text(staging), "replacement")
        XCTAssertTrue(exists(movedAside))
    }

    func testCleanupDoesNotFollowReplacedStagingSymlink() throws {
        let original = try file("source/original", "keep")
        let old = oldDate
        var owner: FileOperationArtifacts? = FileOperationArtifacts(directory: journal, now: { old })
        let staging = try XCTUnwrap(owner).makeCopyStaging(in: folder("destination"))
        try manager.moveItem(at: staging, to: root.appendingPathComponent("moved-aside"))
        try manager.createSymbolicLink(at: staging, withDestinationURL: original.deletingLastPathComponent())
        owner = nil
        XCTAssertEqual(try FileOperationArtifacts(directory: journal).cleanupStaleArtifacts(olderThan: Date()), [])
        XCTAssertEqual(try text(original), "keep")
        XCTAssertTrue(exists(staging))
    }

    func testOwnedSymlinkBackupRemovalPreservesItsTarget() throws {
        let target = try file("source/target", "keep target")
        let link = target.deletingLastPathComponent().appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        let owner = FileOperationArtifacts(directory: journal)
        let backup = try owner.makeBackup(of: link, in: link.deletingLastPathComponent())
        XCTAssertEqual(try owner.discardBackups(for: .trashed(pairs: [MovePair(from: link, to: backup)])), [backup])
        XCTAssertEqual(try text(target), "keep target")
    }

    func testMalformedJournalCannotAuthorizeDeletion() throws {
        let old = oldDate
        var owner: FileOperationArtifacts? = FileOperationArtifacts(directory: journal, now: { old })
        let staging = try XCTUnwrap(owner).makeCopyStaging(in: folder("destination"))
        owner = nil
        let session = try XCTUnwrap(manager.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil).first)
        let manifest = try XCTUnwrap(manager.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        try Data("broken journal".utf8).write(to: manifest)
        XCTAssertEqual(try FileOperationArtifacts(directory: journal).cleanupStaleArtifacts(olderThan: Date()), [])
        XCTAssertTrue(exists(staging))
    }

    private func unavailableTrash(_ url: URL) throws -> URL { throw CocoaError(.featureUnsupported) }

    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let diagnostics = Pipe()
        process.standardOutput = diagnostics
        process.standardError = diagnostics
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FileOperationError.failed("hdiutil: \(String(decoding: data, as: UTF8.self))")
        }
    }

    private func backupURLs(_ record: FileOperationRecord) -> [URL] {
        switch record {
        case .trashed(let pairs): return pairs.map(\.to)
        case .compound(let records): return records.flatMap(backupURLs)
        default: return []
        }
    }
}

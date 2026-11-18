import Foundation
import XCTest
@testable import ExplorerCore

final class CoreReverificationTests: TemporaryDirectoryTestCase {
    func testSelectedDestinationFileIsProtectedInEitherBatchOrder() throws {
        for moving in [false, true] {
            for reversed in [false, true] {
                let prefix = "\(moving)-\(reversed)"
                let incoming = try file("\(prefix)/source/x.txt", "A")
                let selected = try file("\(prefix)/destination/x.txt", "D")
                let sources = reversed ? [selected, incoming] : [incoming, selected]
                let destination = selected.deletingLastPathComponent()
                let result = try transfer(sources, to: destination, moving: moving) { _ in
                    XCTFail("A selected original must be protected without asking")
                    return .replace
                }
                XCTAssertEqual(try text(selected), "D")
                XCTAssertEqual(try text(destination.appendingPathComponent("x (2).txt")), "A")
                if !moving { XCTAssertEqual(try text(destination.appendingPathComponent("x - 복사본.txt")), "D") }
                let redo = try undo(result)
                XCTAssertEqual(try names(in: destination), ["x.txt"])
                XCTAssertEqual(try text(incoming), "A")
                XCTAssertEqual(try text(selected), "D")
                remember(try FileOperations.undo(redo))
                XCTAssertEqual(try text(selected), "D")
                XCTAssertEqual(try text(destination.appendingPathComponent("x (2).txt")), "A")
            }
        }
    }

    func testSelectedDestinationFolderIsKeptIntactInsteadOfMerged() throws {
        for moving in [false, true] {
            let prefix = String(moving)
            let incoming = try folder("\(prefix)/source/tree")
            try file("\(prefix)/source/tree/x", "A")
            let selected = try folder("\(prefix)/destination/tree")
            try file("\(prefix)/destination/tree/x", "D")
            let destination = selected.deletingLastPathComponent()
            let result = try transfer([incoming, selected], to: destination, moving: moving) { _ in
                XCTFail("A selected folder must remain intact")
                return .replace
            }
            XCTAssertEqual(try text(selected.appendingPathComponent("x")), "D")
            XCTAssertEqual(try text(destination.appendingPathComponent("tree (2)/x")), "A")
            if !moving { XCTAssertEqual(try text(destination.appendingPathComponent("tree - 복사본/x")), "D") }
            _ = try undo(result)
            XCTAssertEqual(try names(in: destination), ["tree"])
            XCTAssertEqual(try text(incoming.appendingPathComponent("x")), "A")
            XCTAssertEqual(try text(selected.appendingPathComponent("x")), "D")
        }
    }

    func testDSStoreCollisionKeepsDestinationWithoutPromptAndMoveCanFinish() throws {
        for moving in [false, true] {
            let prefix = String(moving)
            let source = try folder("\(prefix)/source/tree")
            try file("\(prefix)/source/tree/.DS_Store", "source metadata")
            try file("\(prefix)/source/tree/new", "new")
            let target = try folder("\(prefix)/destination/tree")
            try file("\(prefix)/destination/tree/.DS_Store", "destination metadata")
            let result = try transfer([source], to: target.deletingLastPathComponent(), moving: moving) { _ in
                XCTFail(".DS_Store must not trigger a conflict dialog")
                return .skip
            }
            XCTAssertTrue(result.skipped.isEmpty)
            XCTAssertEqual(exists(source), !moving)
            XCTAssertEqual(try text(target.appendingPathComponent(".DS_Store")), "destination metadata")
            XCTAssertEqual(try names(in: target), [".DS_Store", "new"])
            let redo = try undo(result)
            XCTAssertEqual(try text(source.appendingPathComponent(".DS_Store")), "source metadata")
            XCTAssertEqual(try text(source.appendingPathComponent("new")), "new")
            XCTAssertEqual(try names(in: target), [".DS_Store"])
            remember(try FileOperations.undo(redo))
            XCTAssertEqual(exists(source), !moving)
            XCTAssertEqual(try text(target.appendingPathComponent(".DS_Store")), "destination metadata")
        }
    }

    func testDuplicateFoldersMergeIntoExistingOrNewTargetWithProtectedChildren() throws {
        for moving in [false, true] {
            for existing in [false, true] {
                for policy in [ConflictPolicy.replace, .skip, .keepBoth] {
                    let prefix = "\(moving)-\(existing)-\(policy)"
                    let first = try folder("\(prefix)/first/tree")
                    let second = try folder("\(prefix)/second/tree")
                    try file("\(prefix)/first/tree/sub/x.txt", "A")
                    try file("\(prefix)/second/tree/sub/x.txt", "B")
                    try file("\(prefix)/second/tree/other", "other")
                    let destination = try folder("\(prefix)/destination")
                    let target = destination.appendingPathComponent("tree")
                    if existing { try file("\(prefix)/destination/tree/sub/keep", "keep") }
                    let result = try transfer([first, second], to: destination, moving: moving) { _ in
                        XCTFail("Batch file collisions must keep both without asking")
                        return policy
                    }
                    XCTAssertEqual(result.resultURLs.map(\.path), [target.path])
                    XCTAssertEqual(try names(in: destination), ["tree"])
                    XCTAssertEqual(try text(target.appendingPathComponent("sub/x.txt")), "A")
                    XCTAssertEqual(try text(target.appendingPathComponent("sub/x (2).txt")), "B")
                    XCTAssertEqual(try text(target.appendingPathComponent("other")), "other")
                    var record = try XCTUnwrap(result.record)
                    for _ in 0..<3 {
                        record = try XCTUnwrap(remember(FileOperations.undo(record)))
                        XCTAssertEqual(try text(first.appendingPathComponent("sub/x.txt")), "A")
                        XCTAssertEqual(try text(second.appendingPathComponent("sub/x.txt")), "B")
                        XCTAssertEqual(try names(in: destination), existing ? ["tree"] : [])
                        if existing { XCTAssertEqual(try names(in: target.appendingPathComponent("sub")), ["keep"]) }
                        record = try XCTUnwrap(remember(FileOperations.undo(record)))
                        XCTAssertEqual(try text(target.appendingPathComponent("sub/x.txt")), "A")
                        XCTAssertEqual(try text(target.appendingPathComponent("sub/x (2).txt")), "B")
                    }
                }
            }
        }
    }

    func testMergedChildGeneratedNamesAreReservedAcrossTheBatch() throws {
        for moving in [false, true] {
            let prefix = String(moving)
            let first = try folder("\(prefix)/first/tree")
            let second = try folder("\(prefix)/second/tree")
            let third = try folder("\(prefix)/third/tree")
            try file("\(prefix)/first/tree/sub/a.txt", "A")
            try file("\(prefix)/second/tree/sub/a.txt", "B")
            try file("\(prefix)/third/tree/sub/a (2).txt", "C")
            let target = try folder("\(prefix)/destination/tree/sub")
            let result = try transfer([first, second, third], to: target.deletingLastPathComponent().deletingLastPathComponent(),
                                      moving: moving) { _ in XCTFail("A batch result cannot be replaced"); return .replace }
            let names = ["a.txt", "a (2).txt", "a (2) (2).txt"]
            XCTAssertEqual(try names.map { try text(target.appendingPathComponent($0)) }, ["A", "B", "C"])
            _ = try undo(result)
            XCTAssertEqual(try self.names(in: target), [])
            XCTAssertEqual(try text(first.appendingPathComponent("sub/a.txt")), "A")
            XCTAssertEqual(try text(second.appendingPathComponent("sub/a.txt")), "B")
            XCTAssertEqual(try text(third.appendingPathComponent("sub/a (2).txt")), "C")
        }
    }

    func testTrashFailureUsesHiddenSameVolumeBackupForReplaceAndUndoRedo() throws {
        for moving in [false, true] {
            let prefix = String(moving)
            let source = try file("\(prefix)/source/x", "new")
            let target = try file("\(prefix)/destination/x", "old")
            let result = try FileOperations.transfer([source], to: target.deletingLastPathComponent(), moving: moving,
                                                     conflict: { _ in .replace }, trashItem: unavailableTrash)
            remember(result.record)
            let backup = try XCTUnwrap(backups(in: XCTUnwrap(result.record)).first)
            XCTAssertEqual(backup.from, target)
            XCTAssertTrue(backup.to.lastPathComponent.hasPrefix(".explorer-backup-"))
            XCTAssertTrue(FileOperations.isSameVolume(target, backup.to))
            XCTAssertEqual(try text(backup.to), "old")
            XCTAssertEqual(try visibleBackupNames(in: target.deletingLastPathComponent()), ["x"])
            var record = try XCTUnwrap(result.record)
            for _ in 0..<3 {
                record = try XCTUnwrap(remember(FileOperations.undo(record, trashItem: unavailableTrash)))
                XCTAssertEqual(try text(target), "old")
                XCTAssertEqual(try text(source), "new")
                record = try XCTUnwrap(remember(FileOperations.undo(record, trashItem: unavailableTrash)))
                XCTAssertEqual(try text(target), "new")
                XCTAssertEqual(exists(source), !moving)
            }
        }
    }

    func testTrashFailureDoesNotLeaveBackupsInsideMergedSourceContainers() throws {
        let source = try folder("source/tree")
        try folder("source/tree/sub/empty")
        try file("source/tree/sub/x", "new")
        try file("source/tree/.DS_Store", "source metadata")
        let target = try folder("destination/tree")
        try folder("destination/tree/sub/empty")
        try file("destination/tree/sub/x", "old")
        try file("destination/tree/.DS_Store", "destination metadata")
        let result = try FileOperations.transfer([source], to: target.deletingLastPathComponent(), moving: true,
                                                 conflict: { _ in .replace }, trashItem: unavailableTrash)
        remember(result.record)
        XCTAssertFalse(exists(source))
        XCTAssertEqual(try names(in: target), [".DS_Store", "sub"])
        for pair in backups(in: try XCTUnwrap(result.record)) {
            XCTAssertTrue(pair.to.lastPathComponent.hasPrefix(".explorer-backup-"))
            XCTAssertFalse(pair.to.path.hasPrefix(source.path + "/"))
            XCTAssertFalse(pair.to.path.hasPrefix(target.path + "/"))
            XCTAssertTrue(FileOperations.isSameVolume(pair.from, pair.to))
        }
        var record = try XCTUnwrap(result.record)
        for _ in 0..<3 {
            record = try XCTUnwrap(remember(FileOperations.undo(record, trashItem: unavailableTrash)))
            XCTAssertEqual(try text(source.appendingPathComponent("sub/x")), "new")
            XCTAssertTrue(exists(source.appendingPathComponent("sub/empty")))
            XCTAssertEqual(try text(source.appendingPathComponent(".DS_Store")), "source metadata")
            XCTAssertEqual(try text(target.appendingPathComponent("sub/x")), "old")
            record = try XCTUnwrap(remember(FileOperations.undo(record, trashItem: unavailableTrash)))
            XCTAssertFalse(exists(source))
            XCTAssertEqual(try text(target.appendingPathComponent("sub/x")), "new")
        }
    }

    func testTrashFailureDuringCopyMergeUndoKeepsRelatedBackupsStable() throws {
        let first = try folder("first/tree")
        let second = try folder("second/tree")
        try file("first/tree/sub/a", "A")
        try file("second/tree/sub/b", "B")
        let destination = try folder("destination")
        let result = try FileOperations.transfer([first, second], to: destination, moving: false,
                                                 conflict: { _ in .replace }, trashItem: unavailableTrash)
        remember(result.record)
        var record = try XCTUnwrap(result.record)
        for _ in 0..<3 {
            record = try XCTUnwrap(remember(FileOperations.undo(record, trashItem: unavailableTrash)))
            XCTAssertEqual(try visibleBackupNames(in: destination), [])
            record = try XCTUnwrap(remember(FileOperations.undo(record, trashItem: unavailableTrash)))
            XCTAssertEqual(try names(in: destination.appendingPathComponent("tree/sub")), ["a", "b"])
            XCTAssertEqual(try text(destination.appendingPathComponent("tree/sub/a")), "A")
            XCTAssertEqual(try text(destination.appendingPathComponent("tree/sub/b")), "B")
        }
    }

    func testTransferFailureRollsBackHiddenBackupsAndCompletedChanges() throws {
        for moving in [false, true] {
            let prefix = String(moving)
            let source = try folder("\(prefix)/source/tree")
            try file("\(prefix)/source/tree/a", "new A")
            let missing = try file("\(prefix)/source/tree/b", "new B")
            let target = try folder("\(prefix)/destination/tree")
            try file("\(prefix)/destination/tree/a", "old A")
            try file("\(prefix)/destination/tree/b", "old B")
            XCTAssertThrowsError(try FileOperations.transfer([source], to: target.deletingLastPathComponent(), moving: moving,
                                                            conflict: { url in
                if url.lastPathComponent == "b" { try? self.manager.removeItem(at: missing) }
                return .replace
            }, trashItem: unavailableTrash))
            XCTAssertEqual(try text(source.appendingPathComponent("a")), "new A")
            XCTAssertEqual(try text(target.appendingPathComponent("a")), "old A")
            XCTAssertEqual(try text(target.appendingPathComponent("b")), "old B")
            XCTAssertEqual(try names(in: root.appendingPathComponent(prefix)), ["destination", "source"])
        }
    }

    func testCaseSensitiveMergedSiblingsKeepBothOnAnInsensitiveVolume() throws {
        try withVolume(caseSensitive: true) { sourceVolume in
            try withVolume(caseSensitive: false) { destinationVolume in
                for moving in [false, true] {
                    for policy in [ConflictPolicy.replace, .skip, .keepBoth] {
                        let prefix = "\(moving)-\(policy)"
                        let source = sourceVolume.appendingPathComponent(prefix + "/tree")
                        let destination = destinationVolume.appendingPathComponent(prefix)
                        let target = destination.appendingPathComponent("tree")
                        try manager.createDirectory(at: source, withIntermediateDirectories: true)
                        try manager.createDirectory(at: target, withIntermediateDirectories: true)
                        try Data("UPPER".utf8).write(to: source.appendingPathComponent("A.txt"))
                        try Data("lower".utf8).write(to: source.appendingPathComponent("a.txt"))
                        try Data("old".utf8).write(to: target.appendingPathComponent("a.txt"))
                        var asked = 0
                        let result = try transfer([source], to: destination, moving: moving) { _ in
                            asked += 1
                            return policy
                        }
                        XCTAssertEqual(asked, 1)
                        let expected = policy == .replace ? ["UPPER", "lower"]
                            : policy == .skip ? ["old", "lower"] : ["old", "UPPER", "lower"]
                        XCTAssertEqual(Set(try names(in: target).map { try text(target.appendingPathComponent($0)) }), Set(expected))
                        let redo = try undo(result)
                        XCTAssertEqual(try text(source.appendingPathComponent("A.txt")), "UPPER")
                        XCTAssertEqual(try text(source.appendingPathComponent("a.txt")), "lower")
                        XCTAssertEqual(try names(in: target).map { $0.lowercased() }, ["a.txt"])
                        XCTAssertEqual(try text(target.appendingPathComponent("a.txt")), "old")
                        remember(try FileOperations.undo(redo))
                        XCTAssertEqual(Set(try names(in: target).map { try text(target.appendingPathComponent($0)) }), Set(expected))
                    }
                }
            }
        }
    }

    func testTrashFailureCanBackUpAtTheDestinationVolumeRoot() throws {
        try withVolume(caseSensitive: false) { destination in
            let source = try file("source/x", "new")
            let target = destination.appendingPathComponent("x")
            try Data("old".utf8).write(to: target)
            let result = try FileOperations.transfer([source], to: destination, moving: false,
                                                     conflict: { _ in .replace }, trashItem: unavailableTrash)
            let backup = try XCTUnwrap(backups(in: XCTUnwrap(result.record)).first)
            XCTAssertEqual(backup.to.deletingLastPathComponent().path, destination.path)
            XCTAssertTrue(FileOperations.isSameVolume(target, backup.to))
            XCTAssertEqual(try text(backup.to), "old")
            let redo = try XCTUnwrap(FileOperations.undo(XCTUnwrap(result.record), trashItem: unavailableTrash))
            XCTAssertEqual(try text(target), "old")
            _ = try FileOperations.undo(redo, trashItem: unavailableTrash)
            XCTAssertEqual(try text(target), "new")
        }
    }

    private func transfer(_ sources: [URL], to destination: URL, moving: Bool,
                          conflict: (URL) -> ConflictPolicy) throws -> OperationResult {
        let result = try moving ? FileOperations.move(sources, to: destination, conflict: conflict)
            : FileOperations.copy(sources, to: destination, conflict: conflict)
        remember(result.record)
        return result
    }

    private func unavailableTrash(_ url: URL) throws -> URL {
        throw CocoaError(.featureUnsupported, userInfo: [NSFilePathErrorKey: url.path])
    }

    private func visibleBackupNames(in url: URL) throws -> [String] {
        try names(in: url).filter { !$0.hasPrefix(".explorer-backup-") }
    }

    private func withVolume(caseSensitive: Bool, _ action: (URL) throws -> Void) throws {
        let name = "volume-\(UUID().uuidString)"
        let image = root.appendingPathComponent(name + ".dmg")
        let mount = try folder(name)
        try hdiutil(["create", "-quiet", "-size", "20m", "-fs", caseSensitive ? "Case-sensitive APFS" : "APFS",
                     "-volname", name, image.path])
        try hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer {
            do { try hdiutil(["detach", "-quiet", mount.path]) }
            catch { XCTFail("Failed to detach test volume: \(error)") }
        }
        XCTAssertEqual(try mount.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames,
                       caseSensitive)
        try action(mount)
    }

    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw FileOperationError.failed("hdiutil \(arguments.first ?? ""): \(String(decoding: data, as: UTF8.self))")
        }
    }

    private func backups(in record: FileOperationRecord) -> [MovePair] {
        switch record {
        case .trashed(let pairs): return pairs
        case .compound(let records): return records.flatMap { backups(in: $0) }
        default: return []
        }
    }
}

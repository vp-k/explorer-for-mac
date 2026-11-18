import Foundation
import XCTest
@testable import ExplorerCore

final class FileOperationsRegressionTests: TemporaryDirectoryTestCase {
    func testReplaceCopyAndMoveRestoreDisplacedFileOnUndoAndRedo() throws {
        for moving in [false, true] {
            let prefix = moving ? "move" : "copy"
            let source = try file("\(prefix)/source/a.txt", "new")
            let target = try file("\(prefix)/destination/a.txt", "old")
            let result = try transfer([source], to: target.deletingLastPathComponent(), moving: moving, policy: .replace)
            remember(result.record)
            let displaced = trashPairs(in: try XCTUnwrap(result.record))
            XCTAssertEqual(displaced.map(\.from), [target])
            XCTAssertEqual(try text(XCTUnwrap(displaced.first).to), "old")
            XCTAssertFalse(try XCTUnwrap(displaced.first).to.path.hasPrefix(target.deletingLastPathComponent().path + "/"))
            XCTAssertEqual(try text(target), "new")
            let redo = try undo(result)
            XCTAssertEqual(try text(target), "old")
            XCTAssertEqual(try text(source), "new")
            let undoAgain = try XCTUnwrap(remember(FileOperations.undo(redo)))
            XCTAssertEqual(try text(target), "new")
            XCTAssertEqual(exists(source), !moving)
            remember(try FileOperations.undo(undoAgain))
            XCTAssertEqual(try text(target), "old")
        }
    }

    func testDirectoryFileTypeReplacementsCanBeUndone() throws {
        for moving in [false, true] {
            for sourceIsDirectory in [false, true] {
                let prefix = "\(moving)-\(sourceIsDirectory)"
                let source: URL
                let target: URL
                if sourceIsDirectory {
                    source = try folder("\(prefix)/source/item")
                    try file("\(prefix)/source/item/new", "new")
                    target = try file("\(prefix)/destination/item", "old")
                } else {
                    source = try file("\(prefix)/source/item", "new")
                    target = try folder("\(prefix)/destination/item")
                    try file("\(prefix)/destination/item/old", "old")
                }
                let result = try transfer([source], to: target.deletingLastPathComponent(), moving: moving, policy: .replace)
                remember(result.record)
                XCTAssertEqual(try text(sourceIsDirectory ? target.appendingPathComponent("new") : target), "new")
                let redo = try undo(result)
                XCTAssertEqual(try text(sourceIsDirectory ? target : target.appendingPathComponent("old")), "old")
                remember(try FileOperations.undo(redo))
                XCTAssertEqual(try text(sourceIsDirectory ? target.appendingPathComponent("new") : target), "new")
            }
        }
    }

    func testRecursiveMergeAsksForEachFileAndSupportsUndoRedo() throws {
        for moving in [false, true] {
            let prefix = moving ? "move" : "copy"
            let source = try folder("\(prefix)/source/tree")
            let destination = try folder("\(prefix)/destination")
            let target = try folder("\(prefix)/destination/tree")
            for name in ["a", "b", "c"] {
                try file("\(prefix)/source/tree/sub/\(name)", "new \(name)")
                try file("\(prefix)/destination/tree/sub/\(name)", "old \(name)")
            }
            try file("\(prefix)/source/tree/newdir/d", "new d")
            try folder("\(prefix)/source/tree/empty")
            try file("\(prefix)/destination/tree/sub/keep", "keep")
            var asked: [URL] = []
            let choose: (URL) -> ConflictPolicy = { url in
                asked.append(url)
                switch url.lastPathComponent {
                case "a": return .replace
                case "b": return .skip
                default: return .keepBoth
                }
            }
            let result = try moving ? FileOperations.move([source], to: destination, conflict: choose)
                : FileOperations.copy([source], to: destination, conflict: choose)
            remember(result.record)
            XCTAssertEqual(asked, ["a", "b", "c"].map { target.appendingPathComponent("sub/\($0)") })
            XCTAssertEqual(result.resultURLs, [target])
            XCTAssertEqual(result.skipped, [source.appendingPathComponent("sub/b")])
            XCTAssertEqual(try text(target.appendingPathComponent("sub/a")), "new a")
            XCTAssertEqual(try text(target.appendingPathComponent("sub/b")), "old b")
            XCTAssertEqual(try text(target.appendingPathComponent("sub/c (2)")), "new c")
            XCTAssertEqual(try text(target.appendingPathComponent("sub/keep")), "keep")
            if moving { XCTAssertEqual(try names(in: source), ["sub"]) }
            let redo = try undo(result)
            XCTAssertEqual(try names(in: source), ["empty", "newdir", "sub"])
            XCTAssertEqual(try names(in: target), ["sub"])
            XCTAssertEqual(try names(in: target.appendingPathComponent("sub")), ["a", "b", "c", "keep"])
            for name in ["a", "b", "c"] {
                XCTAssertEqual(try text(target.appendingPathComponent("sub/\(name)")), "old \(name)")
                XCTAssertEqual(try text(source.appendingPathComponent("sub/\(name)")), "new \(name)")
            }
            remember(try FileOperations.undo(redo))
            XCTAssertEqual(try text(target.appendingPathComponent("sub/a")), "new a")
            XCTAssertEqual(try text(target.appendingPathComponent("newdir/d")), "new d")
        }
    }

    func testCompleteMoveMergeRestoresRemovedSourceContainers() throws {
        let source = try folder("source/tree")
        try file("source/tree/sub/new", "new")
        try folder("source/tree/empty")
        let destination = try folder("destination")
        try folder("destination/tree/sub")
        try folder("destination/tree/empty")
        try file("destination/tree/keep", "keep")
        let result = try FileOperations.move([source], to: destination) { _ in
            XCTFail("Folder collisions must merge without asking")
            return .skip
        }
        remember(result.record)
        XCTAssertFalse(exists(source))
        let redo = try undo(result)
        XCTAssertEqual(try text(source.appendingPathComponent("sub/new")), "new")
        XCTAssertTrue(exists(source.appendingPathComponent("empty")))
        XCTAssertEqual(try names(in: destination.appendingPathComponent("tree/sub")), [])
        XCTAssertEqual(try text(destination.appendingPathComponent("tree/keep")), "keep")
        remember(try FileOperations.undo(redo))
        XCTAssertFalse(exists(source))
        XCTAssertEqual(try text(destination.appendingPathComponent("tree/sub/new")), "new")
    }

    func testAllFolderPoliciesMergeAndApplyOnlyToFileCollisions() throws {
        for policy in [ConflictPolicy.replace, .skip, .keepBoth] {
            let prefix = String(describing: policy)
            let source = try folder("\(prefix)/source/tree")
            try file("\(prefix)/source/tree/same", "new")
            try file("\(prefix)/source/tree/new", "new only")
            let target = try folder("\(prefix)/destination/tree")
            try file("\(prefix)/destination/tree/same", "old")
            try file("\(prefix)/destination/tree/keep", "keep")
            let result = try FileOperations.copy([source], to: target.deletingLastPathComponent(), conflict: policy)
            remember(result.record)
            XCTAssertEqual(result.resultURLs, [target])
            XCTAssertEqual(try text(target.appendingPathComponent("keep")), "keep")
            XCTAssertEqual(try text(target.appendingPathComponent("new")), "new only")
            let same = policy == .replace ? "new" : "old"
            XCTAssertEqual(try text(target.appendingPathComponent("same")), same)
            if policy == .keepBoth { XCTAssertEqual(try text(target.appendingPathComponent("same (2)")), "new") }
        }
    }

    func testBatchDuplicateNamesKeepBothForEveryPolicyAndUndo() throws {
        for moving in [false, true] {
            for policy in [ConflictPolicy.replace, .skip, .keepBoth] {
                let prefix = "\(moving)-\(policy)"
                let a = try file("\(prefix)/first/a.txt", "A")
                let b = try file("\(prefix)/second/a.txt", "B")
                let target = try file("\(prefix)/destination/a.txt", "old")
                var asked = 0
                let choose: (URL) -> ConflictPolicy = { _ in asked += 1; return policy }
                let result = try moving ? FileOperations.move([a, b], to: target.deletingLastPathComponent(), conflict: choose)
                    : FileOperations.copy([a, b], to: target.deletingLastPathComponent(), conflict: choose)
                remember(result.record)
                XCTAssertEqual(asked, 1)
                XCTAssertEqual(Set(result.resultURLs).count, result.resultURLs.count)
                let second = try XCTUnwrap(result.resultURLs.last)
                XCTAssertNotEqual(second, target)
                XCTAssertEqual(try text(second), "B")
                let redo = try undo(result)
                XCTAssertEqual(try text(a), "A")
                XCTAssertEqual(try text(b), "B")
                XCTAssertEqual(try text(target), "old")
                XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["a.txt"])
                remember(try FileOperations.undo(redo))
                XCTAssertEqual(try text(second), "B")
            }
        }
    }

    func testBatchDuplicateDirectoriesAreKeptSeparatelyAndUndo() throws {
        for moving in [false, true] {
            let prefix = String(moving)
            let a = try folder("\(prefix)/first/tree")
            let b = try folder("\(prefix)/second/tree")
            try file("\(prefix)/first/tree/a", "A")
            try file("\(prefix)/second/tree/b", "B")
            let destination = try folder("\(prefix)/destination")
            let result = try transfer([a, b], to: destination, moving: moving, policy: .replace)
            XCTAssertEqual(result.resultURLs.map(\.lastPathComponent), ["tree", "tree (2)"])
            XCTAssertEqual(try text(destination.appendingPathComponent("tree/a")), "A")
            XCTAssertEqual(try text(destination.appendingPathComponent("tree (2)/b")), "B")
            _ = try undo(result)
            XCTAssertEqual(try text(a.appendingPathComponent("a")), "A")
            XCTAssertEqual(try text(b.appendingPathComponent("b")), "B")
            XCTAssertEqual(try names(in: destination), [])
        }
    }

    func testBatchGeneratedNamesCannotBeOverwrittenByLaterSources() throws {
        for moving in [false, true] {
            let prefix = String(moving)
            let a = try file("\(prefix)/first/a.txt", "A")
            let b = try file("\(prefix)/second/a.txt", "B")
            let c = try file("\(prefix)/third/a (2).txt", "C")
            let destination = try folder("\(prefix)/destination")
            let result = try transfer([a, b, c], to: destination, moving: moving, policy: .replace)
            XCTAssertEqual(result.resultURLs.map(\.lastPathComponent), ["a.txt", "a (2).txt", "a (2) (2).txt"])
            XCTAssertEqual(try result.resultURLs.map { try text($0) }, ["A", "B", "C"])
            _ = try undo(result)
            XCTAssertEqual(try text(a), "A")
            XCTAssertEqual(try text(b), "B")
            XCTAssertEqual(try text(c), "C")
            XCTAssertEqual(try names(in: destination), [])
        }
    }

    func testPackageCopyNamesRetainExtensionAndKeepBothDoesNotMerge() throws {
        let source = try folder("source/Foo.app")
        try file("source/Foo.app/Contents/new", "new")
        let first = try resultURL(FileOperations.copy([source], to: source.deletingLastPathComponent(), conflict: .replace))
        let second = try resultURL(FileOperations.copy([source], to: source.deletingLastPathComponent(), conflict: .replace))
        XCTAssertEqual(first.lastPathComponent, "Foo - 복사본.app")
        XCTAssertEqual(second.lastPathComponent, "Foo - 복사본 (2).app")
        let destination = try folder("destination")
        try file("destination/Foo.app/Contents/old", "old")
        let kept = try resultURL(FileOperations.copy([source], to: destination, conflict: .keepBoth))
        XCTAssertEqual(kept.lastPathComponent, "Foo (2).app")
        XCTAssertEqual(FileOperations.uniqueName("Foo.app", in: destination), "Foo (3).app")
        XCTAssertEqual(try names(in: kept.appendingPathComponent("Contents")), ["new"])
        XCTAssertEqual(try names(in: destination.appendingPathComponent("Foo.app/Contents")), ["old"])
    }

    func testRejectAncestorTargetBeforeAskingOrChangingAnySource() throws {
        let first = try file("source/first", "first")
        let source = try file("destination/x/x", "inside")
        let destination = root.appendingPathComponent("destination")
        let target = destination.appendingPathComponent("x")
        for moving in [false, true] {
            assertOperationError(.destinationContainsSource(target.path)) {
                let choose: (URL) -> ConflictPolicy = { _ in XCTFail("Preflight must reject before asking"); return .replace }
                _ = try moving ? FileOperations.move([first, source], to: destination, conflict: choose)
                    : FileOperations.copy([first, source], to: destination, conflict: choose)
            }
            XCTAssertEqual(try text(first), "first")
            XCTAssertEqual(try text(source), "inside")
            XCTAssertEqual(try names(in: destination), ["x"])
        }
    }

    func testSameParentSelectionDoesNotRejectAnOriginalFolderThatWillNotBeReplaced() throws {
        let directory = try folder("tree")
        let nested = try file("tree/data.txt", "data")
        let copied = try FileOperations.copy([directory, nested], to: root, conflict: .replace)
        XCTAssertEqual(copied.resultURLs.map(\.lastPathComponent), ["tree - 복사본", "data.txt"])
        _ = try undo(copied)
        let moved = try FileOperations.move([directory, nested], to: root, conflict: .replace)
        XCTAssertEqual(moved.skipped, [directory])
        XCTAssertEqual(moved.resultURLs.map(\.lastPathComponent), ["data.txt"])
        _ = try undo(moved)
        XCTAssertEqual(try text(nested), "data")
        XCTAssertEqual(try names(in: root), ["tree"])
    }

    func testMergeMoveFailureRestoresCompletedChildrenAndContainers() throws {
        let source = try folder("source/tree")
        try file("source/tree/a/new", "new")
        let disappearing = try file("source/tree/b", "new b")
        let destination = try folder("destination")
        try folder("destination/tree/a")
        try file("destination/tree/b", "old b")
        XCTAssertThrowsError(try FileOperations.move([source], to: destination) { _ in
            try? self.manager.removeItem(at: disappearing)
            return .replace
        })
        XCTAssertEqual(try text(source.appendingPathComponent("a/new")), "new")
        XCTAssertEqual(try names(in: destination.appendingPathComponent("tree/a")), [])
        XCTAssertEqual(try text(destination.appendingPathComponent("tree/b")), "old b")
        XCTAssertEqual(try names(in: destination), ["tree"])
    }

    func testCompoundUndoRejectsMissingBackupBeforeTrashCanReuseItsName() throws {
        let source = try file("source/a", "new")
        let target = try file("destination/a", "old")
        let result = try FileOperations.copy([source], to: target.deletingLastPathComponent(), conflict: .replace)
        remember(result.record)
        let displaced = try XCTUnwrap(trashPairs(in: XCTUnwrap(result.record)).first)
        try manager.removeItem(at: displaced.to)
        XCTAssertThrowsError(try FileOperations.undo(XCTUnwrap(result.record)))
        XCTAssertEqual(try text(target), "new")
        XCTAssertEqual(try text(source), "new")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["a"])
    }

    func testCompoundUndoFailureRollsBackCompletedUndoSteps() throws {
        let a = try file("source/a", "new a")
        let b = try file("source/b", "new b")
        let destination = try folder("destination")
        let target = try file("destination/a", "old a")
        let result = try FileOperations.move([a, b], to: destination, conflict: .replace)
        remember(result.record)
        try file("source/a", "occupied")
        assertOperationError(.alreadyExists(a.path)) { _ = try FileOperations.undo(XCTUnwrap(result.record)) }
        XCTAssertEqual(try text(a), "occupied")
        XCTAssertFalse(exists(b))
        XCTAssertEqual(try text(target), "new a")
        XCTAssertEqual(try text(destination.appendingPathComponent("b")), "new b")
        XCTAssertEqual(try names(in: destination), ["a", "b"])
    }

    func testPermanentDeletePartialFailureReportsCompletedPaths() throws {
        let parent = try folder("parent")
        let child = try file("parent/child", "child")
        let untouched = try file("untouched", "keep")
        XCTAssertThrowsError(try FileOperations.deletePermanently([parent, child, untouched])) { error in
            guard case FileOperationError.partialDeletion(let deleted, let failed, let reason) = error else {
                return XCTFail("Missing partial deletion detail: \(error)")
            }
            XCTAssertEqual(deleted, [parent])
            XCTAssertEqual(failed, child)
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(error.localizedDescription.contains(parent.path))
        }
        XCTAssertFalse(exists(parent))
        XCTAssertEqual(try text(untouched), "keep")
    }

    private func transfer(_ sources: [URL], to destination: URL, moving: Bool,
                          policy: ConflictPolicy) throws -> OperationResult {
        try moving ? FileOperations.move(sources, to: destination, conflict: policy)
            : FileOperations.copy(sources, to: destination, conflict: policy)
    }

    private func trashPairs(in record: FileOperationRecord) -> [MovePair] {
        switch record {
        case .trashed(let pairs): return pairs
        case .compound(let records): return records.flatMap { trashPairs(in: $0) }
        default: return []
        }
    }
}

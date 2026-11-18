import Foundation
import XCTest
@testable import ExplorerCore

final class FileOperationsTransferTests: TemporaryDirectoryTestCase {
    func testCopyFilePreservesSourceAndRecordsDestination() throws {
        let source = try file("source/report.txt", "original")
        let destination = try folder("destination")
        let result = try FileOperations.copy([source], to: destination, conflict: .replace)
        let target = destination.appendingPathComponent("report.txt")
        XCTAssertEqual(result.resultURLs, [target])
        XCTAssertEqual(result.record, .copied(created: [target]))
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertEqual(try text(source), "original")
        XCTAssertEqual(try text(target), "original")
    }

    func testCopyDirectoryRecursively() throws {
        let source = try folder("source")
        try file("source/nested/report.txt", "nested")
        let target = try resultURL(FileOperations.copy([source], to: folder("destination"), conflict: .replace))
        XCTAssertEqual(try text(target.appendingPathComponent("nested/report.txt")), "nested")
    }

    func testCopyToSameFolderCreatesNumberedCopy() throws {
        let source = try file("report.txt")
        let first = try resultURL(FileOperations.copy([source], to: root, conflict: .skip))
        let second = try resultURL(FileOperations.copy([source], to: root, conflict: .replace))
        XCTAssertEqual(first.lastPathComponent, "report - 복사본.txt")
        XCTAssertEqual(second.lastPathComponent, "report - 복사본 (2).txt")
        XCTAssertEqual(try text(source), try text(second))
    }

    func testCopyDottedDirectoryPreservesItsWholeName() throws {
        let source = try folder("release.v1")
        let target = try resultURL(FileOperations.copy([source], to: root, conflict: .keepBoth))
        XCTAssertEqual(target.lastPathComponent, "release.v1 - 복사본")
    }

    func testCopyReplaceReplacesWholeDirectory() throws {
        let source = try folder("source/data")
        try file("source/data/new.txt", "new")
        let destination = try folder("destination")
        try file("destination/data/old.txt", "old")
        let target = try resultURL(FileOperations.copy([source], to: destination, conflict: .replace))
        XCTAssertEqual(try names(in: target), ["new.txt"])
        XCTAssertEqual(try names(in: destination), ["data"])
        XCTAssertTrue(exists(source))
    }

    func testCopySkipPreservesExistingContentAndHasNoUndo() throws {
        let source = try file("source/a.txt", "new")
        let target = try file("destination/a.txt", "old")
        let result = try FileOperations.copy([source], to: target.deletingLastPathComponent(), conflict: .skip)
        XCTAssertEqual(try text(target), "old")
        XCTAssertEqual(result.skipped, [source])
        XCTAssertNil(result.record)
        XCTAssertTrue(result.resultURLs.isEmpty)
    }

    func testCopyKeepBothFindsNextAvailableNumber() throws {
        let source = try file("source/a.txt", "new")
        let target = try file("destination/a.txt", "old")
        try file("destination/a (2).txt", "older")
        let result = try FileOperations.copy([source], to: target.deletingLastPathComponent(), conflict: .keepBoth)
        XCTAssertEqual(try resultURL(result).lastPathComponent, "a (3).txt")
        XCTAssertEqual(try text(target), "old")
    }

    func testCopyConflictClosureChoosesEachDestinationIndependently() throws {
        let a = try file("source/a.txt", "new a")
        let b = try file("source/b.txt", "new b")
        let c = try file("source/c.txt", "new c")
        let d = try file("source/d.txt", "new d")
        let destination = try folder("destination")
        for name in ["a", "b", "c"] { try file("destination/\(name).txt", "old \(name)") }
        var asked: [URL] = []
        let result = try FileOperations.copy([a, b, c, d], to: destination) { target in
            asked.append(target)
            switch target.lastPathComponent {
            case "a.txt": return .replace
            case "b.txt": return .skip
            default: return .keepBoth
            }
        }
        XCTAssertEqual(asked.map(\.lastPathComponent), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(Set(result.resultURLs.map(\.lastPathComponent)), ["a.txt", "c (2).txt", "d.txt"])
        XCTAssertEqual(result.skipped, [b])
        XCTAssertEqual(try text(destination.appendingPathComponent("a.txt")), "new a")
        XCTAssertEqual(try text(destination.appendingPathComponent("b.txt")), "old b")
        XCTAssertEqual(try text(destination.appendingPathComponent("c.txt")), "old c")
    }

    func testSameFolderCopyDoesNotAskConflictClosure() throws {
        let source = try file("a")
        _ = try FileOperations.copy([source], to: root) { _ in
            XCTFail("A same-folder copy should choose a copy name automatically")
            return .skip
        }
    }

    func testMoveRecordsBothLocations() throws {
        let source = try file("source/a.txt", "moved")
        let destination = try folder("destination")
        let result = try FileOperations.move([source], to: destination, conflict: .replace)
        let target = destination.appendingPathComponent("a.txt")
        XCTAssertEqual(result.record, .moved(pairs: [MovePair(from: source, to: target)]))
        XCTAssertFalse(exists(source))
        XCTAssertEqual(try text(target), "moved")
    }

    func testMoveToSameFolderDoesNothing() throws {
        let source = try file("a.txt", "same")
        let result = try FileOperations.move([source], to: root, conflict: .replace)
        XCTAssertNil(result.record)
        XCTAssertTrue(result.resultURLs.isEmpty)
        XCTAssertEqual(result.skipped, [source])
        XCTAssertEqual(try text(source), "same")
    }

    func testMoveConflictPolicies() throws {
        for (label, policy) in [("replace", ConflictPolicy.replace), ("skip", .skip), ("keep", .keepBoth)] {
            let source = try file("\(label)/source/a.txt", "new")
            let target = try file("\(label)/destination/a.txt", "old")
            let result = try FileOperations.move([source], to: target.deletingLastPathComponent(), conflict: policy)
            switch policy {
            case .replace:
                XCTAssertFalse(exists(source))
                XCTAssertEqual(try text(target), "new")
            case .skip:
                XCTAssertTrue(exists(source))
                XCTAssertEqual(result.skipped, [source])
                XCTAssertNil(result.record)
            case .keepBoth:
                XCTAssertFalse(exists(source))
                XCTAssertEqual(try resultURL(result).lastPathComponent, "a (2).txt")
                XCTAssertEqual(try text(target), "old")
            }
        }
    }

    func testMoveClosureReceivesOnlyConflicts() throws {
        let a = try file("source/a")
        let b = try file("source/b")
        try file("destination/a")
        let destination = root.appendingPathComponent("destination")
        var asked: [URL] = []
        let result = try FileOperations.move([a, b], to: destination) { target in asked.append(target); return .skip }
        XCTAssertEqual(asked, [destination.appendingPathComponent("a")])
        XCTAssertEqual(result.skipped, [a])
        XCTAssertEqual(result.resultURLs, [destination.appendingPathComponent("b")])
    }

    func testMoveRejectsOwnDescendantBeforeMovingAnySource() throws {
        let source = try folder("tree")
        let descendant = try folder("tree/sub")
        let other = try file("other.txt")
        assertOperationError(.destinationInsideSource(descendant.path)) {
            _ = try FileOperations.move([other, source], to: descendant, conflict: .replace)
        }
        XCTAssertTrue(exists(other))
        XCTAssertTrue(exists(source))
    }

    func testCopyAlsoRejectsRecursiveDestinationAndSymlinkAliases() throws {
        let source = try folder("tree")
        let descendant = try folder("tree/sub")
        let alias = root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: descendant)
        assertOperationError(.destinationInsideSource(alias.path)) {
            _ = try FileOperations.copy([source], to: alias, conflict: .replace)
        }
    }

    func testSimilarPrefixDirectoryIsNotADescendant() throws {
        let source = try folder("tree")
        let destination = try folder("tree-other")
        _ = try FileOperations.move([source], to: destination, conflict: .replace)
        XCTAssertTrue(exists(destination.appendingPathComponent("tree")))
    }

    func testMissingSourcePreflightLeavesEarlierSourcesUntouched() throws {
        let source = try file("source/a")
        let missing = root.appendingPathComponent("missing")
        let destination = try folder("destination")
        assertOperationError(.notFound(missing.path)) {
            _ = try FileOperations.move([source, missing], to: destination, conflict: .replace)
        }
        XCTAssertTrue(exists(source))
        XCTAssertEqual(try names(in: destination), [])
    }

    func testCopyRollsBackEarlierReplacementWhenLaterSourceDisappears() throws {
        let a = try file("source/a", "new a")
        let b = try file("source/b", "new b")
        try file("destination/a", "old a")
        try file("destination/b", "old b")
        let destination = root.appendingPathComponent("destination")
        XCTAssertThrowsError(try FileOperations.copy([a, b], to: destination) { target in
            if target.lastPathComponent == "b" { try? self.manager.removeItem(at: b) }
            return .replace
        })
        XCTAssertEqual(try text(destination.appendingPathComponent("a")), "old a")
        XCTAssertEqual(try text(destination.appendingPathComponent("b")), "old b")
        XCTAssertEqual(try names(in: destination), ["a", "b"])
        XCTAssertTrue(exists(a))
    }

    func testMoveRollsBackEarlierMoveWhenLaterSourceDisappears() throws {
        let a = try file("source/a", "a")
        let b = try file("source/b", "b")
        try file("destination/b", "old")
        let destination = root.appendingPathComponent("destination")
        XCTAssertThrowsError(try FileOperations.move([a, b], to: destination) { _ in
            try? self.manager.removeItem(at: b)
            return .replace
        })
        XCTAssertEqual(try text(a), "a")
        XCTAssertEqual(try text(destination.appendingPathComponent("b")), "old")
        XCTAssertEqual(try names(in: destination), ["b"])
    }

    func testCopyDanglingSymlinkAndAvoidCollidingWithOne() throws {
        let link = root.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("missing"))
        let destination = try folder("destination")
        let copied = try resultURL(FileOperations.copy([link], to: destination, conflict: .replace))
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: copied.path), root.appendingPathComponent("missing").path)
        let again = try resultURL(FileOperations.copy([link], to: destination, conflict: .keepBoth))
        XCTAssertEqual(again.lastPathComponent, "link (2)")
    }

    func testSameVolumeUsesExistingAncestorsAndRejectsRemoteURLs() throws {
        let a = try file("a")
        let b = try folder("b")
        XCTAssertTrue(FileOperations.isSameVolume(a, b))
        XCTAssertTrue(FileOperations.isSameVolume(a, b.appendingPathComponent("new/deep/file")))
        XCTAssertFalse(FileOperations.isSameVolume(a, try XCTUnwrap(URL(string: "https://example.com"))))
    }
}

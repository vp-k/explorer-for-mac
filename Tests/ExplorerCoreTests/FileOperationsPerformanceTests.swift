import Foundation
import XCTest
@testable import ExplorerCore

final class FileOperationsPerformanceTests: TemporaryDirectoryTestCase {
    // Override only for manual release measurements; the regular debug suite exercises 2,000 items.
    private var itemCount: Int {
        max(1, Int(ProcessInfo.processInfo.environment["EXPLORER_PERF_COUNT"] ?? "") ?? 2_000)
    }

    func testLargeMoveAndUndoHaveLinearBatchCost() throws {
        let sources = try makeSources(count: itemCount)
        let destination = try folder("destination")
        var start = ProcessInfo.processInfo.systemUptime
        let result = try FileOperations.move(sources, to: destination, conflict: .keepBoth)
        let moveSeconds = ProcessInfo.processInfo.systemUptime - start
        print("PERF \(sources.count) move \(moveSeconds)")
        XCTAssertLessThan(moveSeconds, 15, "Batch moves must not compare every pair of paths")
        XCTAssertEqual(result.resultURLs.count, sources.count)
        guard case .moved(let pairs) = try XCTUnwrap(result.record) else {
            return XCTFail("Independent moves should share one undo batch")
        }
        XCTAssertEqual(pairs.count, sources.count)
        XCTAssertEqual(try names(in: sources[0].deletingLastPathComponent()), [])
        XCTAssertEqual(try names(in: destination).count, sources.count)

        start = ProcessInfo.processInfo.systemUptime
        let redo = try XCTUnwrap(FileOperations.undo(XCTUnwrap(result.record)))
        let undoSeconds = ProcessInfo.processInfo.systemUptime - start
        print("PERF \(sources.count) undo-move \(undoSeconds)")
        XCTAssertLessThan(undoSeconds, 15)
        XCTAssertEqual(try names(in: destination), [])
        XCTAssertEqual(try names(in: sources[0].deletingLastPathComponent()).count, sources.count)
        XCTAssertEqual(try text(sources[0]), "x")
        XCTAssertEqual(try text(sources[sources.count - 1]), "x")

        _ = try FileOperations.undo(redo)
        XCTAssertEqual(try names(in: destination).count, sources.count)
    }

    func testLargeCopyHasLinearBatchCost() throws {
        let sources = try makeSources(count: itemCount)
        let destination = try folder("destination")
        let start = ProcessInfo.processInfo.systemUptime
        let result = try FileOperations.copy(sources, to: destination, conflict: .keepBoth)
        let seconds = ProcessInfo.processInfo.systemUptime - start
        print("PERF \(sources.count) copy \(seconds)")
        XCTAssertLessThan(seconds, 15, "Batch copies must not compare every pair of paths")
        XCTAssertEqual(result.resultURLs.count, sources.count)
        guard case .copied(let created) = try XCTUnwrap(result.record) else {
            return XCTFail("Independent copies should share one undo batch")
        }
        XCTAssertEqual(created, result.resultURLs)
        XCTAssertEqual(try names(in: sources[0].deletingLastPathComponent()).count, sources.count)
        XCTAssertEqual(try names(in: destination).count, sources.count)
        XCTAssertEqual(try text(result.resultURLs[0]), "x")
        XCTAssertEqual(try text(result.resultURLs[sources.count - 1]), "x")
    }

    func testMoveResultsStillDeduplicateHardLinks() throws {
        let first = try file("source/a", "linked")
        let second = first.deletingLastPathComponent().appendingPathComponent("b")
        try manager.linkItem(at: first, to: second)
        let destination = try folder("destination")
        let result = try FileOperations.move([first, second], to: destination, conflict: .keepBoth)
        XCTAssertEqual(result.resultURLs, [destination.appendingPathComponent("a")])
        XCTAssertEqual(try names(in: destination), ["a", "b"])
        _ = try FileOperations.undo(XCTUnwrap(result.record))
        XCTAssertEqual(try text(first), "linked")
        XCTAssertEqual(try text(second), "linked")
    }

    func testMoveResultsStillDeduplicateSymlinkAliases() throws {
        let target = try file("target", "linked")
        let first = root.appendingPathComponent("source/a")
        let second = root.appendingPathComponent("source/b")
        try folder("source")
        try manager.createSymbolicLink(at: first, withDestinationURL: target)
        try manager.createSymbolicLink(at: second, withDestinationURL: target)
        let destination = try folder("destination")
        let result = try FileOperations.move([first, second], to: destination, conflict: .keepBoth)
        XCTAssertEqual(result.resultURLs, [destination.appendingPathComponent("a")])
        XCTAssertEqual(try names(in: destination), ["a", "b"])
        _ = try FileOperations.undo(XCTUnwrap(result.record))
        XCTAssertTrue(exists(first))
        XCTAssertTrue(exists(second))
    }

    func testResultSymlinkIsResolvedAgainAfterLaterItemsCreateItsTarget() throws {
        let source = try folder("source")
        let destination = try folder("destination")
        let link = source.appendingPathComponent("link")
        let target = try file("source/target", "linked")
        try manager.createSymbolicLink(at: link, withDestinationURL: destination.appendingPathComponent("target"))
        let result = try FileOperations.move([link, target], to: destination, conflict: .keepBoth)
        XCTAssertEqual(result.resultURLs, [destination.appendingPathComponent("link")])
        XCTAssertEqual(try text(result.resultURLs[0]), "linked")
        _ = try FileOperations.undo(XCTUnwrap(result.record))
        XCTAssertTrue(exists(link))
        XCTAssertEqual(try text(target), "linked")
    }

    func testCanonicalEquivalentBatchNamesKeepBothWithoutPrompting() throws {
        for moving in [false, true] {
            let prefix = String(moving)
            let first = try file("\(prefix)/first/caf\u{00e9}.txt", "composed")
            let second = try file("\(prefix)/second/cafe\u{0301}.txt", "decomposed")
            let destination = try folder("\(prefix)/destination")
            let choose: (URL) -> ConflictPolicy = { _ in
                XCTFail("Canonical-equivalent batch names must automatically keep both")
                return .replace
            }
            let result = try moving ? FileOperations.move([first, second], to: destination, conflict: choose)
                : FileOperations.copy([first, second], to: destination, conflict: choose)
            XCTAssertEqual(result.resultURLs.map(\.lastPathComponent), ["caf\u{00e9}.txt", "caf\u{00e9} (2).txt"])
            XCTAssertEqual(try result.resultURLs.map { try text($0) }, ["composed", "decomposed"])
            _ = try undo(result)
            XCTAssertEqual(try names(in: destination), [])
            XCTAssertEqual(try text(first), "composed")
            XCTAssertEqual(try text(second), "decomposed")
        }
    }

    private func makeSources(count: Int) throws -> [URL] {
        let source = try folder("source")
        return try (0..<count).map { index in
            let url = source.appendingPathComponent("f\(index).txt")
            try Data("x".utf8).write(to: url)
            return url
        }
    }
}

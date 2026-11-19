import Darwin
import Foundation
import XCTest
@testable import ExplorerCore

final class OperationProgressTests: TemporaryDirectoryTestCase {
    func testCopyCountsNestedFilesPackagesLinksAndEmptyDirectories() throws {
        let source = try folder("source/tree")
        try folder("source/tree/empty")
        try file("source/tree/a", "abc")
        try file("source/tree/sub/b", "12345")
        let package = try folder("source/App.app")
        try file("source/App.app/Contents/item", "data")
        let link = source.appendingPathComponent("link")
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "a")
        let recorder = ProgressRecorder()
        let result = try FileOperations.copy([source, package], to: folder("destination"), conflict: { _ in .replace },
                                             progress: recorder.progress)
        assertComplete(recorder.snapshots, items: 4, bytes: 13)
        XCTAssertEqual(try text(result.resultURLs[0].appendingPathComponent("sub/b")), "12345")
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: result.resultURLs[0].appendingPathComponent("link").path), "a")
        _ = try undo(result)
        XCTAssertEqual(try names(in: root.appendingPathComponent("destination")), [])
    }

    func testMergedCopyCountsSkippedFilesAndReplacementsExactlyOnce() throws {
        let source = try folder("source/tree")
        try file("source/tree/a", "new")
        try file("source/tree/b", "skipped")
        try file("source/tree/sub/c", "c")
        try file("destination/tree/a", "old")
        try file("destination/tree/b", "keep")
        let recorder = ProgressRecorder()
        let result = try FileOperations.copy([source], to: root.appendingPathComponent("destination"), conflict: {
            $0.lastPathComponent == "b" ? .skip : .replace
        }, progress: recorder.progress)
        assertComplete(recorder.snapshots, items: 3, bytes: 11)
        XCTAssertEqual(result.skipped.map(\.lastPathComponent), ["b"])
        XCTAssertEqual(try text(root.appendingPathComponent("destination/tree/b")), "keep")
        _ = try undo(result)
        XCTAssertEqual(try text(root.appendingPathComponent("destination/tree/a")), "old")
    }

    func testMoveUsesRecursiveFileCountsAndUndoPreservesOriginals() throws {
        let source = try folder("source/tree")
        try file("source/tree/a", "abc")
        try file("source/tree/sub/b", "de")
        let recorder = ProgressRecorder()
        let result = try FileOperations.move([source], to: folder("destination"), conflict: { _ in .replace },
                                             progress: recorder.progress)
        assertComplete(recorder.snapshots, items: 2, bytes: 5)
        XCTAssertFalse(exists(source))
        _ = try undo(result)
        XCTAssertEqual(try text(source.appendingPathComponent("sub/b")), "de")
    }

    func testSameParentMoveAndEmptyBatchReachExactFinalValues() throws {
        let source = try file("source/a", "abc")
        let recorder = ProgressRecorder()
        let result = try FileOperations.move([source], to: source.deletingLastPathComponent(), conflict: { _ in .replace },
                                             progress: recorder.progress)
        XCTAssertNil(result.record)
        assertComplete(recorder.snapshots, items: 1, bytes: 3)
        for moving in [false, true] {
            let empty = ProgressRecorder()
            if moving {
                _ = try FileOperations.move([], to: root, conflict: { _ in .skip }, progress: empty.progress)
            } else {
                _ = try FileOperations.copy([], to: root, conflict: { _ in .skip }, progress: empty.progress)
            }
            assertComplete(empty.snapshots, items: 0, bytes: 0)
        }
    }

    func testTrashReportsNestedCountsAndSupportsUndo() throws {
        let source = try folder("source/tree")
        try file("source/tree/a", "abc")
        try file("source/tree/sub/b", "de")
        let recorder = ProgressRecorder()
        let result = try FileOperations.trash([source], progress: recorder.progress)
        remember(result.record)
        assertComplete(recorder.snapshots, items: 2, bytes: 5)
        XCTAssertFalse(exists(source))
        _ = try FileOperations.undo(XCTUnwrap(result.record))
        XCTAssertEqual(try text(source.appendingPathComponent("sub/b")), "de")
    }

    func testPrecancelledCopyMoveAndTrashDoNotMutateAnything() throws {
        let source = try file("source/a", "original")
        let destination = try folder("destination")
        let progress = OperationProgress { _ in XCTFail("A precancelled operation must not start") }
        progress.cancel()
        XCTAssertTrue(progress.isCancelled)
        assertOperationError(.cancelled) {
            _ = try FileOperations.copy([source], to: destination, conflict: { _ in .replace }, progress: progress)
        }
        assertOperationError(.cancelled) {
            _ = try FileOperations.move([source], to: destination, conflict: { _ in .replace }, progress: progress)
        }
        assertOperationError(.cancelled) { _ = try FileOperations.trash([source], progress: progress) }
        XCTAssertEqual(try text(source), "original")
        XCTAssertEqual(try names(in: destination), [])
    }

    func testCancellationFromInitialUpdatePreventsCopy() throws {
        let source = try file("source/a")
        let recorder = ProgressRecorder(cancelWhen: { _ in true })
        assertOperationError(.cancelled) {
            _ = try FileOperations.copy([source], to: folder("destination"), conflict: { _ in .replace },
                                         progress: recorder.progress)
        }
        XCTAssertTrue(exists(source))
        XCTAssertEqual(try names(in: root.appendingPathComponent("destination")), [])
    }

    func testMidBatchMoveAndTrashCancellationRestoreCompletedItems() throws {
        for trashing in [false, true] {
            let prefix = String(trashing)
            let a = try file("\(prefix)/source/a", "first")
            let b = try file("\(prefix)/source/b", "second")
            let destination = try folder("\(prefix)/destination")
            let recorder = ProgressRecorder(cancelWhen: { $0.completedItems > 0 })
            assertOperationError(.cancelled) {
                if trashing { _ = try FileOperations.trash([a, b], progress: recorder.progress) }
                else {
                    _ = try FileOperations.move([a, b], to: destination, conflict: { _ in .replace },
                                                 progress: recorder.progress)
                }
            }
            XCTAssertEqual(try text(a), "first")
            XCTAssertEqual(try text(b), "second")
            XCTAssertEqual(try names(in: destination), [])
        }
    }

    func testCancelledTrashPreservesSelectedParentDSStore() throws {
        let ordinary = try file("source/a", "original")
        let metadata = try file("source/.DS_Store", "metadata")
        let recorder = ProgressRecorder(cancelWhen: { $0.completedItems > 0 })
        assertOperationError(.cancelled) {
            _ = try FileOperations.trash([ordinary, metadata], progress: recorder.progress)
        }
        XCTAssertEqual(try text(ordinary), "original")
        XCTAssertEqual(try text(metadata), "metadata")
        XCTAssertEqual(try names(in: ordinary.deletingLastPathComponent()), [".DS_Store", "a"])
    }

    func testCancelledMergeRestoresCopiedOrMovedChildrenAndDisplacedTargets() throws {
        for moving in [false, true] {
            let prefix = String(moving)
            let source = try folder("\(prefix)/source/tree")
            try file("\(prefix)/source/tree/a", "new A")
            try file("\(prefix)/source/tree/b", "new B")
            try file("\(prefix)/destination/tree/a", "old A")
            try file("\(prefix)/destination/tree/b", "old B")
            let destination = root.appendingPathComponent("\(prefix)/destination")
            let recorder = ProgressRecorder()
            let conflict: (URL) -> ConflictPolicy = { target in
                if target.lastPathComponent == "b" { recorder.progress.cancel() }
                return .replace
            }
            assertOperationError(.cancelled) {
                if moving {
                    _ = try FileOperations.move([source], to: destination, conflict: conflict, progress: recorder.progress)
                } else {
                    _ = try FileOperations.copy([source], to: destination, conflict: conflict, progress: recorder.progress)
                }
            }
            XCTAssertEqual(try text(source.appendingPathComponent("a")), "new A")
            XCTAssertEqual(try text(source.appendingPathComponent("b")), "new B")
            XCTAssertEqual(try text(destination.appendingPathComponent("tree/a")), "old A")
            XCTAssertEqual(try text(destination.appendingPathComponent("tree/b")), "old B")
            XCTAssertEqual(try names(in: destination.appendingPathComponent("tree")), ["a", "b"])
        }
    }

    func testNonSparse200MiBCopyReportsIntermediateBytesAndPreservesMetadata() throws {
        let source = try largeFile("source/large.bin", megabytes: 200)
        var info = stat()
        XCTAssertEqual(lstat(source.path, &info), 0)
        XCTAssertGreaterThanOrEqual(info.st_blocks * 512, 200 * 1_048_576)
        let attribute = Data("attribute".utf8)
        XCTAssertEqual(attribute.withUnsafeBytes {
            setxattr(source.path, "com.apple.metadata:ExplorerProgressTest", $0.baseAddress, $0.count, 0, 0)
        }, 0)
        // A slow first observer simulates a long-running copy while keeping this test small.
        let recorder = ProgressRecorder(pauseAtFirstBytes: true)
        let result = try FileOperations.copy([source], to: folder("destination"), conflict: { _ in .replace },
                                             progress: recorder.progress)
        let snapshots = recorder.snapshots
        assertComplete(snapshots, items: 1, bytes: 200 * 1_048_576)
        let partial = snapshots.filter { $0.completedBytes > 0 && $0.completedBytes < $0.totalBytes }
        XCTAssertGreaterThanOrEqual(partial.count, 2)
        XCTAssertTrue(partial.allSatisfy { $0.currentName == "large.bin" && $0.completedItems == 0 })
        let target = try resultURL(result)
        XCTAssertEqual(try Data(contentsOf: target, options: .mappedIfSafe), try Data(contentsOf: source, options: .mappedIfSafe))
        XCTAssertEqual(getxattr(target.path, "com.apple.metadata:ExplorerProgressTest", nil, 0, 0, 0), attribute.count)
        let times = recorder.times
        // Start, first byte and terminal snapshots are explicitly exempt from throttling.
        for index in 3..<(times.count - 1) { XCTAssertGreaterThanOrEqual(times[index] - times[index - 1], 0.099) }
        print("PROGRESS 200MiB partial-byte-updates \(partial.count), all-updates \(snapshots.count)")
    }

    func testCancellingLargeCopyRollsBackEarlierItemAndRestoresReplacedFile() throws {
        let first = try file("source/a", "completed first")
        let source = try largeFile("source/large.bin", megabytes: 200)
        let destination = try folder("destination")
        let original = try file("destination/large.bin", "old target")
        let recorder = ProgressRecorder(cancelWhen: {
            $0.currentName == "large.bin" && $0.completedBytes > Int64("completed first".utf8.count)
        }, pauseAfterEachUpdate: true)
        assertOperationError(.cancelled) {
            _ = try FileOperations.copy([first, source], to: destination, conflict: { _ in .replace },
                                         progress: recorder.progress)
        }
        XCTAssertEqual(try text(first), "completed first")
        XCTAssertEqual(try manager.attributesOfItem(atPath: source.path)[.size] as? Int64, 200 * 1_048_576)
        XCTAssertEqual(try text(original), "old target")
        XCTAssertEqual(try names(in: destination), ["large.bin"])
        XCTAssertTrue(recorder.snapshots.contains { $0.currentName == "large.bin" && $0.completedBytes < $0.totalBytes })
    }

    func testCancellationFromFinalCallbackRollsBackWholeBatch() throws {
        let source = try file("source/a", "original")
        let destination = try folder("destination")
        let recorder = ProgressRecorder(cancelWhen: { $0.completedItems == $0.totalItems && $0.completedItems > 0 })
        assertOperationError(.cancelled) {
            _ = try FileOperations.copy([source], to: destination, conflict: { _ in .replace }, progress: recorder.progress)
        }
        XCTAssertEqual(try text(source), "original")
        XCTAssertEqual(try names(in: destination), [])
    }

    func testCancellationIsThreadSafeAndDoesNotHoldLockDuringObserver() {
        let progress = OperationProgress { _ in }
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            if index.isMultiple(of: 2) { progress.cancel() }
            else { _ = progress.isCancelled }
        }
        XCTAssertTrue(progress.isCancelled)
    }

    func testCrossVolumeMoveReportsBytesRollsBackCancellationAndSupportsUndoRedo() throws {
        let image = root.appendingPathComponent("progress-volume.dmg")
        let mount = try folder("mounted")
        try hdiutil(["create", "-quiet", "-size", "64m", "-fs", "APFS", "-volname", "ExplorerProgress", image.path])
        try hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer {
            do { try hdiutil(["detach", "-quiet", mount.path]) }
            catch { XCTFail("Failed to detach progress test volume: \(error)") }
        }
        let first = try file("source/a", "first")
        let source = try largeFile("source/large.bin", megabytes: 16)
        let original = mount.appendingPathComponent("large.bin")
        try Data("old target".utf8).write(to: original)
        XCTAssertFalse(FileOperations.isSameVolume(source, mount))
        let cancelling = ProgressRecorder(cancelWhen: {
            $0.currentName == "large.bin" && $0.completedBytes > 5
        }, pauseAfterEachUpdate: true)
        assertOperationError(.cancelled) {
            _ = try FileOperations.move([first, source], to: mount, conflict: { _ in .replace }, progress: cancelling.progress)
        }
        XCTAssertEqual(try text(first), "first")
        XCTAssertEqual(try text(original), "old target")
        XCTAssertTrue(exists(source))
        XCTAssertEqual(try names(in: mount).filter { !$0.hasPrefix(".") }, ["large.bin"])

        let recorder = ProgressRecorder(pauseAtFirstBytes: true)
        let result = try FileOperations.move([first, source], to: mount, conflict: { _ in .replace }, progress: recorder.progress)
        remember(result.record)
        assertComplete(recorder.snapshots, items: 2, bytes: 16 * 1_048_576 + 5)
        XCTAssertTrue(recorder.snapshots.contains { $0.completedBytes > 0 && $0.completedBytes < $0.totalBytes })
        XCTAssertFalse(exists(first))
        XCTAssertFalse(exists(source))
        let redo = try undo(result)
        XCTAssertEqual(try text(first), "first")
        XCTAssertTrue(exists(source))
        XCTAssertEqual(try text(original), "old target")
        let inverse = try XCTUnwrap(remember(FileOperations.undo(redo)))
        XCTAssertFalse(exists(first))
        XCTAssertFalse(exists(source))
        XCTAssertEqual(try text(mount.appendingPathComponent("a")), "first")
        remember(try FileOperations.undo(inverse))
        XCTAssertTrue(exists(source))
        XCTAssertEqual(try text(original), "old target")
    }

    func testProgressEnabledThousandItemMoveKeepsLinearCost() throws {
        let source = try folder("source")
        let sources = try (0..<1_000).map { index -> URL in
            let url = source.appendingPathComponent("f\(index)")
            try Data("x".utf8).write(to: url)
            return url
        }
        let destination = try folder("destination")
        let recorder = ProgressRecorder()
        let start = ProcessInfo.processInfo.systemUptime
        let result = try FileOperations.move(sources, to: destination, conflict: { _ in .keepBoth }, progress: recorder.progress)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("PERF 1000 progress-move \(elapsed)")
        XCTAssertLessThan(elapsed, 15)
        assertComplete(recorder.snapshots, items: 1_000, bytes: 1_000)
        _ = try undo(result)
    }

    private func largeFile(_ path: String, megabytes: Int) throws -> URL {
        let url = try file(path, "")
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var block = Data(count: 1_048_576)
        block.withUnsafeMutableBytes { if let pointer = $0.baseAddress { arc4random_buf(pointer, $0.count) } }
        for _ in 0..<megabytes { try output.write(contentsOf: block) }
        return url
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
        guard process.terminationStatus == 0 else {
            throw FileOperationError.failed("hdiutil: \(String(decoding: data, as: UTF8.self))")
        }
    }

    private func assertComplete(_ snapshots: [OperationProgressSnapshot], items: Int, bytes: Int64,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(snapshots.isEmpty, file: file, line: line)
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.totalItems, items, file: file, line: line)
            XCTAssertEqual(snapshot.totalBytes, bytes, file: file, line: line)
            XCTAssertLessThanOrEqual(snapshot.completedItems, items, file: file, line: line)
            XCTAssertLessThanOrEqual(snapshot.completedBytes, bytes, file: file, line: line)
        }
        for (previous, next) in zip(snapshots, snapshots.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.completedItems, next.completedItems, file: file, line: line)
            XCTAssertLessThanOrEqual(previous.completedBytes, next.completedBytes, file: file, line: line)
        }
        XCTAssertEqual(snapshots.last?.completedItems, items, file: file, line: line)
        XCTAssertEqual(snapshots.last?.completedBytes, bytes, file: file, line: line)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OperationProgressSnapshot] = []
    private var timestamps: [TimeInterval] = []
    private let cancelWhen: @Sendable (OperationProgressSnapshot) -> Bool
    private let pauseAtFirstBytes: Bool
    private let pauseAfterEachUpdate: Bool
    private var paused = false
    lazy var progress = OperationProgress { [weak self] in self?.receive($0) }

    init(cancelWhen: @escaping @Sendable (OperationProgressSnapshot) -> Bool = { _ in false },
         pauseAtFirstBytes: Bool = false, pauseAfterEachUpdate: Bool = false) {
        self.cancelWhen = cancelWhen
        self.pauseAtFirstBytes = pauseAtFirstBytes
        self.pauseAfterEachUpdate = pauseAfterEachUpdate
    }

    var snapshots: [OperationProgressSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
    var times: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return timestamps }

    private func receive(_ snapshot: OperationProgressSnapshot) {
        lock.lock()
        values.append(snapshot)
        timestamps.append(ProcessInfo.processInfo.systemUptime)
        let pause = pauseAtFirstBytes && !paused && snapshot.completedBytes > 0
        if pause { paused = true }
        lock.unlock()
        if cancelWhen(snapshot) { progress.cancel() }
        if pause || pauseAfterEachUpdate { Thread.sleep(forTimeInterval: 0.12) }
    }
}

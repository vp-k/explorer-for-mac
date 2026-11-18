import Foundation
import XCTest
@testable import ExplorerCore

final class DirectoryWatcherTests: TemporaryDirectoryTestCase {
    func testWatchesResolvedSymlinkAndSystemTmpPaths() throws {
        let real = try folder("real")
        let link = root.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: real)
        let tmpRoot = URL(fileURLWithPath: "/tmp").appendingPathComponent("ExplorerCoreWatcher-\(UUID().uuidString)")
        try manager.createDirectory(at: tmpRoot, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: tmpRoot) }
        for (index, watched) in [link, tmpRoot].enumerated() {
            let change = expectation(description: "Resolved path \(index)")
            let signal = WatchSignal(change)
            let watcher = DirectoryWatcher(url: watched) { signal.receive() }
            defer { watcher.stop() }
            settleEvents()
            signal.arm()
            try Data("created".utf8).write(to: watched.appendingPathComponent("new\(index).txt"))
            wait(for: [change], timeout: 4)
        }
    }

    func testIgnoresDeepSubtreeCreationContentMetadataRenameAndDeletion() throws {
        try folder("child/a/b/c")
        let existing = try file("child/a/b/c/existing", "before")
        let change = expectation(description: "Deep events are ignored")
        change.isInverted = true
        let signal = WatchSignal(change)
        let watcher = DirectoryWatcher(url: root) { signal.receive() }
        defer { watcher.stop() }
        settleEvents()
        signal.arm()
        try file("child/a/b/c/new", "new")
        try Data("after".utf8).write(to: existing)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: existing.path)
        let renamed = existing.deletingLastPathComponent().appendingPathComponent("renamed")
        try manager.moveItem(at: existing, to: renamed)
        try manager.removeItem(at: renamed)
        wait(for: [change], timeout: 1.5)
        XCTAssertEqual(signal.count, 0)
    }

    func testDirectDirectoryMetadataAndWatchedRootMetadataStillNotify() throws {
        let child = try folder("child")
        for changed in [root!, child] {
            let change = expectation(description: "Visible directory metadata changed")
            let signal = WatchSignal(change)
            let watcher = DirectoryWatcher(url: root) { signal.receive() }
            defer { watcher.stop() }
            settleEvents()
            signal.arm()
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: changed.path)
            wait(for: [change], timeout: 4)
        }
    }

    func testAncestorRenameAndSymlinkRootDeletionStillNotify() throws {
        for renameAncestor in [true, false] {
            let prefix = String(renameAncestor)
            let watched = try folder("\(prefix)/parent/watched")
            let link = root.appendingPathComponent("link-\(prefix)")
            try manager.createSymbolicLink(at: link, withDestinationURL: watched)
            let change = expectation(description: "Resolved root invalidated")
            let signal = WatchSignal(change)
            let watcher = DirectoryWatcher(url: link) { signal.receive() }
            defer { watcher.stop() }
            settleEvents()
            signal.arm()
            if renameAncestor {
                try manager.moveItem(at: watched.deletingLastPathComponent(),
                                     to: root.appendingPathComponent("\(prefix)/renamed-parent"))
            } else { try manager.removeItem(at: watched) }
            wait(for: [change], timeout: 4)
        }
    }

    func testDetectsExistingFileContentChangesOnMainQueue() throws {
        let existing = try file("existing.txt", "before")
        let change = expectation(description: "Content changed")
        let signal = WatchSignal(change)
        let watcher = DirectoryWatcher(url: root) { signal.receive() }
        defer { watcher.stop() }
        settleEvents()
        signal.arm()
        let handle = try FileHandle(forWritingTo: existing)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 65, count: 5000))
        try handle.close()
        wait(for: [change], timeout: 4)
        XCTAssertTrue(signal.receivedOnMain)
    }

    func testDetectsExistingFileModificationDateChanges() throws {
        let existing = try file("existing.txt")
        let change = expectation(description: "Metadata changed")
        let signal = WatchSignal(change)
        let watcher = DirectoryWatcher(url: root) { signal.receive() }
        defer { watcher.stop() }
        settleEvents()
        signal.arm()
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: existing.path)
        wait(for: [change], timeout: 4)
    }

    func testDetectsCreationRenameAndDeletion() throws {
        let directory = try folder("watched")
        for action in ["create", "rename", "delete"] {
            let change = expectation(description: action)
            let signal = WatchSignal(change)
            let watcher = DirectoryWatcher(url: directory) { signal.receive() }
            settleEvents()
            signal.arm()
            switch action {
            case "create": try file("watched/new.txt")
            case "rename":
                try manager.moveItem(at: directory.appendingPathComponent("new.txt"),
                                     to: directory.appendingPathComponent("renamed.txt"))
            default: try manager.removeItem(at: directory.appendingPathComponent("renamed.txt"))
            }
            wait(for: [change], timeout: 4)
            watcher.stop()
        }
    }

    func testDebouncesBurstForAtLeastPointThreeSeconds() throws {
        let change = expectation(description: "Debounced burst")
        let signal = WatchSignal(change)
        let watcher = DirectoryWatcher(url: root) { signal.receive() }
        defer { watcher.stop() }
        settleEvents()
        signal.arm()
        for index in 0..<5 { try file("new\(index).txt") }
        let finished = Date()
        wait(for: [change], timeout: 4)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(signal.firstDate).timeIntervalSince(finished), 0.28)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(signal.count, 1)
    }

    func testStopCancelsPendingCallbacksAndIsIdempotent() throws {
        let change = expectation(description: "No callback after stop")
        change.isInverted = true
        let signal = WatchSignal(change)
        let watcher = DirectoryWatcher(url: root) { signal.receive() }
        settleEvents()
        signal.arm()
        try file("new.txt")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        watcher.stop()
        watcher.stop()
        try file("later.txt")
        wait(for: [change], timeout: 0.8)
    }

    func testDeinitializationStopsCallbacks() throws {
        let change = expectation(description: "No callback after deinit")
        change.isInverted = true
        var watcher: DirectoryWatcher? = DirectoryWatcher(url: root) { change.fulfill() }
        weak let weakWatcher = watcher
        watcher = nil
        XCTAssertNil(weakWatcher)
        try file("new.txt")
        wait(for: [change], timeout: 0.8)
    }

    func testNotifiesWhenWatchedRootIsRenamedOrDeleted() throws {
        for rename in [true, false] {
            let directory = try folder(rename ? "renamed-root" : "deleted-root")
            let change = expectation(description: "Root changed")
            let signal = WatchSignal(change)
            let watcher = DirectoryWatcher(url: directory) { signal.receive() }
            settleEvents()
            signal.arm()
            if rename {
                try manager.moveItem(at: directory, to: root.appendingPathComponent("new-root-name"))
            } else { try manager.removeItem(at: directory) }
            wait(for: [change], timeout: 4)
            watcher.stop()
        }
    }

    private func settleEvents() { RunLoop.main.run(until: Date().addingTimeInterval(0.6)) }
}

private final class WatchSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var armed = false
    private var dates: [Date] = []
    private var allOnMain = true
    init(_ expectation: XCTestExpectation) { self.expectation = expectation }
    func arm() { lock.withLock { armed = true } }
    func receive() {
        let first = lock.withLock {
            guard armed else { return false }
            dates.append(Date())
            allOnMain = allOnMain && Thread.isMainThread
            return dates.count == 1
        }
        if first { expectation.fulfill() }
    }
    var count: Int { lock.withLock { dates.count } }
    var firstDate: Date? { lock.withLock { dates.first } }
    var receivedOnMain: Bool { lock.withLock { allOnMain && !dates.isEmpty } }
}

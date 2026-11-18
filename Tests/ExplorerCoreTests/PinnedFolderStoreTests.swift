import Foundation
import XCTest
@testable import ExplorerCore

final class PinnedFolderStoreTests: TemporaryDirectoryTestCase {
    private var storage: URL { root.appendingPathComponent("settings/pins.json") }

    private func emptyStore() throws -> PinnedFolderStore {
        try manager.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: storage)
        return PinnedFolderStore(storageURL: storage)
    }

    func testMissingOrCorruptFileUsesDefaultFolders() throws {
        let home = manager.homeDirectoryForCurrentUser
        let expected = ["Desktop", "Downloads", "Documents", "Pictures"].map { home.appendingPathComponent($0).path }
        XCTAssertEqual(PinnedFolderStore(storageURL: storage).folders.map(\.path), expected)
        try file("settings/pins.json", "broken JSON")
        XCTAssertEqual(PinnedFolderStore(storageURL: storage).folders.map(\.path), expected)
    }

    func testPinPersistsAndReloadsWithoutDuplicates() throws {
        let store = try emptyStore()
        let a = try folder("a")
        let b = try folder("b")
        store.pin(a)
        store.pin(b)
        store.pin(a.appendingPathComponent("./"))
        XCTAssertEqual(store.folders.map(\.path), [a.path, b.path])
        let reloaded = PinnedFolderStore(storageURL: storage)
        XCTAssertEqual(reloaded.folders.map(\.path), [a.path, b.path])
        XCTAssertTrue(reloaded.isPinned(a))
        XCTAssertTrue(reloaded.isPinned(a.appendingPathComponent("./")))
    }

    func testUnpinAndReorderArePersisted() throws {
        let store = try emptyStore()
        let a = try folder("a")
        let b = try folder("b")
        let c = try folder("c")
        for url in [a, b, c] { store.pin(url) }
        store.move(from: 0, to: 2)
        XCTAssertEqual(store.folders.map(\.path), [b.path, c.path, a.path])
        store.move(from: -1, to: 0)
        store.move(from: 0, to: 99)
        store.unpin(c)
        XCTAssertFalse(store.isPinned(c))
        XCTAssertEqual(PinnedFolderStore(storageURL: storage).folders.map(\.path), [b.path, a.path])
    }

    func testLoadSupportsLegacyFileURLsAndDeduplicatesNormalizedPaths() throws {
        let a = try folder("a")
        let b = try folder("b")
        let values = [a.path, a.absoluteString, a.appendingPathComponent("./").path, b.absoluteString]
        try manager.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: storage)
        XCTAssertEqual(PinnedFolderStore(storageURL: storage).folders.map(\.path), [a.path, b.path])
    }

    func testPinRejectsRemoteURL() throws {
        let store = try emptyStore()
        store.pin(try XCTUnwrap(URL(string: "https://example.com/folder")))
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(PinnedFolderStore(storageURL: storage).folders.isEmpty)
    }

    func testFirstMutationCreatesStorageParentDirectories() throws {
        let store = PinnedFolderStore(storageURL: storage)
        let a = try folder("a")
        store.pin(a)
        XCTAssertTrue(exists(storage))
        XCTAssertTrue(PinnedFolderStore(storageURL: storage).isPinned(a))
        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: storage))
        XCTAssertEqual(paths.last, a.path)
    }
}

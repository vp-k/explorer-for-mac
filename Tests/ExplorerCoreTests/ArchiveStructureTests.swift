import Darwin
import Foundation
import XCTest
@testable import ExplorerCore

final class ArchiveStructureTests: TemporaryDirectoryTestCase {
    func testSingleFileZipContainsOnlySelectedItemAndNoMacMetadata() throws {
        let source = try file("source/a.txt", "data")
        try addExtendedAttribute(to: source)
        let zip = try resultURL(FileOperations.compress([source], in: folder("archives")))
        XCTAssertEqual(try entries(in: zip), ["a.txt"])
    }

    func testSingleFolderZipPreservesFolderAtTopLevelWithoutMacMetadata() throws {
        let source = try folder("source/tree")
        let nested = try file("source/tree/sub/a.txt", "data")
        try addExtendedAttribute(to: nested)
        let zip = try resultURL(FileOperations.compress([source], in: folder("archives")))
        let listing = try entries(in: zip)
        XCTAssertTrue(listing.contains("tree/sub/a.txt"))
        XCTAssertTrue(listing.allSatisfy { $0.hasPrefix("tree/") })
        XCTAssertFalse(listing.contains { $0.contains("__MACOSX") || $0.contains("._") })
    }

    func testMultipleSelectionHasEachItemAtTopLevelAndUsesFirstNameWithNumbering() throws {
        let source = try file("source/a.txt", "A")
        try addExtendedAttribute(to: source)
        let directory = try folder("elsewhere/tree")
        try file("elsewhere/tree/sub/b.txt", "B")
        let archives = try folder("archives")
        try file("archives/a.zip", "keep")
        let zip = try resultURL(FileOperations.compress([source, directory], in: archives))
        XCTAssertEqual(zip.lastPathComponent, "a (2).zip")
        let listing = try entries(in: zip)
        XCTAssertTrue(listing.contains("a.txt"))
        XCTAssertTrue(listing.contains("tree/sub/b.txt"))
        XCTAssertTrue(listing.allSatisfy { $0 == "a.txt" || $0.hasPrefix("tree/") })
        XCTAssertEqual(try names(in: archives), ["a (2).zip", "a.zip"])
    }

    func testArchiveStagingWithinSourceDoesNotIncludeTemporaryFiles() throws {
        let tree = try folder("tree")
        try file("tree/a.txt", "A")
        let other = try file("other/b.txt", "B")
        let zip = try resultURL(FileOperations.compress([tree, other], in: tree))
        let listing = try entries(in: zip)
        XCTAssertTrue(listing.contains("tree/a.txt"))
        XCTAssertTrue(listing.contains("b.txt"))
        XCTAssertFalse(listing.contains { $0.contains(".explorer-") || $0.contains(".zip") })
        XCTAssertEqual(try names(in: tree), ["a.txt", "tree.zip"])
        XCTAssertEqual(try names(in: root), ["other", "tree"])
    }

    func testCloneStagingPreservesSymbolicLinksWithoutTraversingThem() throws {
        let source = try file("source/a.txt", "A")
        let link = root.appendingPathComponent("source/link")
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "a.txt")
        let archives = try folder("archives")
        let zip = try resultURL(FileOperations.compress([source, link], in: archives))
        XCTAssertEqual(Set(try entries(in: zip)), ["a.txt", "link"])
        let output = try resultURL(FileOperations.extract(zip, to: archives))
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: output.appendingPathComponent("link").path), "a.txt")
        XCTAssertEqual(try names(in: archives), ["a", "a.zip"])
    }

    func testArchiveInsideSourceThroughDirectoryAliasExcludesStaging() throws {
        let source = try folder("tree")
        try file("tree/a.txt", "A")
        let alias = root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: source)
        let zip = try resultURL(FileOperations.compress([source], in: alias))
        XCTAssertEqual(try entries(in: zip), ["tree/", "tree/a.txt"])
        XCTAssertEqual(try names(in: source), ["a.txt", "tree.zip"])
    }

    private func addExtendedAttribute(to url: URL) throws {
        let data = Data("metadata".utf8)
        let status = data.withUnsafeBytes { bytes in
            setxattr(url.path, "com.apple.metadata:ExplorerCoreTests", bytes.baseAddress, bytes.count, 0, 0)
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func entries(in zip: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", zip.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

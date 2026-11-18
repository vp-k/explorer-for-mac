import Foundation
import XCTest
@testable import ExplorerCore

final class FilesystemSupportTests: TemporaryDirectoryTestCase {
    func testFileItemLoadsFileMetadataAndDirectoryKinds() throws {
        let source = try file("REPORT.TXT", "12345")
        let item = try FileItem.load(source)
        XCTAssertEqual(item.url, source.standardizedFileURL)
        XCTAssertEqual(item.name, "REPORT.TXT")
        XCTAssertEqual(item.size, 5)
        XCTAssertEqual(item.fileExtension, "txt")
        XCTAssertFalse(item.isDirectory)
        XCTAssertFalse(item.isHidden)
        XCTAssertFalse(item.isSymlink)
        XCTAssertNotNil(item.dateCreated)
        XCTAssertNotNil(item.dateModified)
        XCTAssertFalse(item.typeDescription.isEmpty)
        let directory = try FileItem.load(folder("directory"))
        XCTAssertTrue(directory.isDirectory)
        XCTAssertTrue(directory.isNavigable)
        XCTAssertNil(directory.size)
        XCTAssertEqual(directory.typeDescription, "파일 폴더")
        let package = try FileItem.load(folder("Example.app"))
        XCTAssertTrue(package.isPackage)
        XCTAssertFalse(package.isNavigable)
    }

    func testFileItemSymlinkFollowsTargetKindAndPreservesLinkURL() throws {
        let target = try folder("target")
        let link = root.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        let item = try FileItem.load(link)
        XCTAssertTrue(item.isSymlink)
        XCTAssertTrue(item.isDirectory)
        XCTAssertTrue(item.isNavigable)
        XCTAssertEqual(item.url.path, link.path)
        XCTAssertEqual(item.name, "link")
    }

    func testDirectoryListerFiltersHiddenAndReturnsOnlyDirectChildren() throws {
        try file("visible.txt")
        try file(".hidden.txt")
        try file("nested/child.txt")
        let visible = try DirectoryLister.contents(of: root, showHidden: false)
        XCTAssertEqual(Set(visible.map(\.name)), ["visible.txt", "nested"])
        let all = try DirectoryLister.contents(of: root, showHidden: true)
        XCTAssertEqual(Set(all.map(\.name)), ["visible.txt", ".hidden.txt", "nested"])
        XCTAssertTrue(try XCTUnwrap(all.first { $0.name == ".hidden.txt" }).isHidden)
    }

    func testFileSearchRecursesBatchesAndFiltersHidden() throws {
        try file("a.txt")
        try file("nested/B.TXT")
        try file("nested/c.pdf")
        try file(".hidden.txt")
        try file(".hidden-dir/d.txt")
        var batches: [[FileItem]] = []
        FileSearch(root: root, query: "*.txt", showHidden: false).run(batchSize: 1) { batches.append($0) }
        XCTAssertEqual(batches.map(\.count), [1, 1])
        XCTAssertEqual(Set(batches.flatMap { $0 }.map(\.name)), ["a.txt", "B.TXT"])
        var all: [FileItem] = []
        FileSearch(root: root, query: "*.txt", showHidden: true).run { all += $0 }
        XCTAssertEqual(Set(all.map(\.name)), ["a.txt", "B.TXT", ".hidden.txt", "d.txt"])
    }

    func testFileSearchSkipsPackageContents() throws {
        try file("Example.app/Contents/secret.txt")
        try file("visible.txt")
        var results: [FileItem] = []
        FileSearch(root: root, query: "*.txt", showHidden: true).run { results += $0 }
        XCTAssertEqual(results.map(\.name), ["visible.txt"])
    }

    func testFileSearchCancellationBeforeRunDoesNotDeliverResults() throws {
        try file("a.txt")
        let search = FileSearch(root: root, query: "", showHidden: true)
        search.cancel()
        search.run { _ in XCTFail("Cancelled search delivered a batch") }
    }

    func testFileSearchCancellationFromBatchStopsImmediately() throws {
        for number in 0..<12 { try file("file\(number).txt") }
        let search = FileSearch(root: root, query: "*.txt", showHidden: true)
        var count = 0
        search.run(batchSize: 1) { batch in count += batch.count; search.cancel() }
        XCTAssertEqual(count, 1)
        search.run { _ in XCTFail("A cancelled search ran again") }
    }

    func testFileSearchFlushesPartialBatchAndClampsBatchSize() throws {
        for number in 0..<3 { try file("file\(number).txt") }
        var batchCounts: [Int] = []
        FileSearch(root: root, query: "file", showHidden: true).run(batchSize: 2) { batchCounts.append($0.count) }
        XCTAssertEqual(batchCounts, [2, 1])
        var zeroCounts: [Int] = []
        FileSearch(root: root, query: "file", showHidden: true).run(batchSize: 0) { zeroCounts.append($0.count) }
        XCTAssertEqual(zeroCounts, [1, 1, 1])
    }

    func testFolderSizeCountsNestedContentsAndHiddenFiles() throws {
        let directory = try folder("data")
        try file("data/a", "abc")
        try file("data/sub/b", "12345")
        try file("data/.hidden", "x")
        let stats = FolderSizeCalculator.stats(for: [directory])
        XCTAssertEqual(stats.totalBytes, 9)
        XCTAssertEqual(stats.fileCount, 3)
        XCTAssertEqual(stats.folderCount, 1)
    }

    func testFolderSizeDeduplicatesOverlappingSelections() throws {
        let directory = try folder("data")
        let nested = try file("data/sub/a", "abc")
        let stats = FolderSizeCalculator.stats(for: [directory, nested, directory])
        XCTAssertEqual(stats.totalBytes, 3)
        XCTAssertEqual(stats.fileCount, 1)
        XCTAssertEqual(stats.folderCount, 1)
    }

    func testFolderSizeCancellationReturnsPartialOrEmptyTotals() throws {
        let directory = try folder("data")
        for index in 0..<8 { try file("data/\(index)", "a") }
        XCTAssertEqual(FolderSizeCalculator.stats(for: [directory], isCancelled: { true }), FolderStats())
        var polls = 0
        let partial = FolderSizeCalculator.stats(for: [directory]) { polls += 1; return polls > 8 }
        XCTAssertGreaterThan(partial.fileCount, 0)
        XCTAssertLessThan(partial.fileCount, 8)
        XCTAssertEqual(partial.totalBytes, Int64(partial.fileCount))
    }

    func testFolderSizeDoesNotFollowSymlinkCycles() throws {
        let directory = try folder("data")
        let target = try file("data/a", "abc")
        let link = directory.appendingPathComponent("cycle")
        try manager.createSymbolicLink(at: link, withDestinationURL: directory)
        let stats = FolderSizeCalculator.stats(for: [directory])
        let linkSize = (try manager.attributesOfItem(atPath: link.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertEqual(stats.fileCount, 2)
        XCTAssertEqual(stats.folderCount, 0)
        XCTAssertEqual(stats.totalBytes, 3 + linkSize)
        XCTAssertEqual(FolderSizeCalculator.stats(for: [target]).totalBytes, 3)
    }

    func testFolderSizeFollowsSelectedRootLinksAndDeduplicatesTargets() throws {
        let directory = try folder("target")
        let targetFile = try file("target/sub/data", String(repeating: "a", count: 1000))
        let directoryLink = root.appendingPathComponent("directory-link")
        let fileLink = root.appendingPathComponent("file-link")
        try manager.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
        try manager.createSymbolicLink(at: fileLink, withDestinationURL: targetFile)
        let viaLink = FolderSizeCalculator.stats(for: [directoryLink])
        XCTAssertEqual(viaLink.totalBytes, 1000)
        XCTAssertEqual(viaLink.fileCount, 1)
        XCTAssertEqual(viaLink.folderCount, 1)
        XCTAssertEqual(FolderSizeCalculator.stats(for: [directoryLink, directory, fileLink]), viaLink)
        XCTAssertEqual(FolderSizeCalculator.stats(for: [fileLink]).totalBytes, 1000)
    }

    func testSearchMatchesNFDNamesWithNFCSubstringAndWildcardQueries() throws {
        let name = "한글문서.txt".decomposedStringWithCanonicalMapping
        let source = try file("source/" + name, "data")
        for query in ["한글", "한글*.txt"] {
            var results: [FileItem] = []
            FileSearch(root: source.deletingLastPathComponent(), query: query, showHidden: false).run { results += $0 }
            XCTAssertEqual(results.map(\.url), [source])
        }
        XCTAssertTrue(WildcardMatcher.matches(name, pattern: "한"))
    }

    func testNFCRenameOfNFDNameIsNoOpAndPinnedFolderIsNotDuplicated() throws {
        let source = try file("가.txt".decomposedStringWithCanonicalMapping, "keep")
        let result = try FileOperations.rename(source, to: "가.txt".precomposedStringWithCanonicalMapping)
        XCTAssertNil(result.record)
        XCTAssertEqual(try text(source), "keep")
        let directory = try folder("폴더".decomposedStringWithCanonicalMapping)
        let store = PinnedFolderStore(storageURL: root.appendingPathComponent("pins.json"))
        store.pin(directory)
        store.pin(root.appendingPathComponent("폴더".precomposedStringWithCanonicalMapping))
        XCTAssertEqual(store.folders.filter { $0.lastPathComponent == "폴더" }.count, 1)
    }
}

import Foundation
import XCTest
@testable import ExplorerCore

final class NavigationSortingTests: TemporaryDirectoryTestCase {
    private func item(_ name: String, directory: Bool = false, package: Bool = false,
                      size: Int64? = nil, type: String = "파일", date: Date? = nil) -> FileItem {
        FileItem(url: root.appendingPathComponent(name), name: name, isDirectory: directory, isPackage: package,
                 isHidden: false, isSymlink: false, size: size, dateModified: date, dateCreated: date,
                 typeDescription: type, fileExtension: URL(fileURLWithPath: name).pathExtension)
    }

    func testNaturalNameSortIsCaseInsensitiveAndNumeric() {
        let items = [item("file10.txt"), item("File2.txt"), item("file1.txt")]
        XCTAssertEqual(FileSorter.sorted(items, by: SortOrder()).map(\.name), ["file1.txt", "File2.txt", "file10.txt"])
        XCTAssertEqual(FileSorter.sorted(items, by: SortOrder(ascending: false)).map(\.name), ["file10.txt", "File2.txt", "file1.txt"])
    }

    func testFoldersStayFirstInBothSortDirectionsButPackagesAreFiles() {
        let items = [item("a.app", directory: true, package: true), item("z-folder", directory: true), item("b.txt")]
        for ascending in [true, false] {
            let result = FileSorter.sorted(items, by: SortOrder(ascending: ascending))
            XCTAssertEqual(result.first?.name, "z-folder")
            XCTAssertEqual(Set(result.dropFirst().map(\.name)), ["a.app", "b.txt"])
        }
        let mixed = FileSorter.sorted(items, by: SortOrder(foldersFirst: false))
        XCTAssertEqual(mixed.map(\.name), ["a.app", "b.txt", "z-folder"])
    }

    func testSizeSortUsesNameForEqualSizes() {
        let items = [item("file10", size: 10), item("large", size: 30), item("file2", size: 10)]
        XCTAssertEqual(FileSorter.sorted(items, by: SortOrder(key: .size)).map(\.name), ["file2", "file10", "large"])
        XCTAssertEqual(FileSorter.sorted(items, by: SortOrder(key: .size, ascending: false)).map(\.name), ["large", "file10", "file2"])
    }

    func testDateAndTypeSortWithMissingValues() {
        let early = Date(timeIntervalSince1970: 10)
        let late = Date(timeIntervalSince1970: 20)
        let items = [item("late", type: "Z", date: late), item("missing", type: "B"), item("early", type: "A", date: early)]
        for key in [SortKey.dateCreated, .dateModified] {
            XCTAssertEqual(FileSorter.sorted(items, by: SortOrder(key: key)).map(\.name), ["missing", "early", "late"])
        }
        XCTAssertEqual(FileSorter.sorted(items, by: SortOrder(key: .type)).map(\.name), ["early", "missing", "late"])
    }

    func testSortOrderCodableRoundTrip() throws {
        let order = SortOrder(key: .size, ascending: false, foldersFirst: false)
        XCTAssertEqual(try JSONDecoder().decode(SortOrder.self, from: JSONEncoder().encode(order)), order)
    }

    func testHistoryBackForwardAndBoundaries() {
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        let c = root.appendingPathComponent("c")
        var history = NavigationHistory(start: a)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goBack())
        XCTAssertNil(history.goForward())
        history.visit(b)
        history.visit(c)
        XCTAssertEqual(history.backStack, [a, b])
        XCTAssertEqual(history.goBack(), b)
        XCTAssertEqual(history.goBack(), a)
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.forwardStack, [c, b])
        XCTAssertEqual(history.goForward(), b)
        XCTAssertEqual(history.goForward(), c)
        XCTAssertNil(history.goForward())
        XCTAssertEqual(history.current, c)
    }

    func testHistoryVisitDiscardsForwardHistoryAndIgnoresSameLocation() {
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        let c = root.appendingPathComponent("c")
        var history = NavigationHistory(start: a)
        history.visit(b)
        _ = history.goBack()
        history.visit(root.appendingPathComponent("a/./"))
        XCTAssertEqual(history.forwardStack, [b])
        XCTAssertTrue(history.backStack.isEmpty)
        history.visit(c)
        XCTAssertTrue(history.forwardStack.isEmpty)
        XCTAssertEqual(history.backStack, [a])
        XCTAssertEqual(history.current, c)
    }

    func testResolverSupportsHomePrefixesAndBackslashes() {
        let home = manager.homeDirectoryForCurrentUser.standardizedFileURL
        for input in ["~", "~/.", "$HOME", "${HOME}/.", "%USERPROFILE%", "%userprofile%\\."] {
            XCTAssertEqual(AddressResolver.resolve(input, relativeTo: root)?.path, home.path, input)
        }
        XCTAssertEqual(AddressResolver.resolve(home.path.replacingOccurrences(of: "/", with: "\\"), relativeTo: root)?.path, home.path)
    }

    func testResolverSupportsRelativeAbsoluteQuotedAndFileURLs() throws {
        let source = try file("folder with spaces/한글.txt")
        let parent = source.deletingLastPathComponent()
        for input in [source.path, "  \"\(source.path)\"  ", "'\(source.path)'", source.absoluteString] {
            XCTAssertEqual(AddressResolver.resolve(input, relativeTo: root)?.path, source.standardizedFileURL.path)
        }
        XCTAssertEqual(AddressResolver.resolve("folder with spaces/한글.txt", relativeTo: root)?.path, source.path)
        XCTAssertEqual(AddressResolver.resolve("../folder with spaces/한글.txt", relativeTo: parent)?.path, source.path)
        XCTAssertEqual(AddressResolver.resolve("folder with spaces\\한글.txt", relativeTo: root)?.path, source.path)
    }

    func testResolverRejectsMissingEmptyAndRemoteFileURL() {
        for input in ["", "  ", "\"\"", "does-not-exist-\(UUID().uuidString)", "file://remote.invalid/tmp", "https://example.com"] {
            XCTAssertNil(AddressResolver.resolve(input, relativeTo: root), input)
        }
    }

    func testResolverKnownFolderAliasesUseHomeInsteadOfBase() {
        let aliases = [("바탕 화면", "Desktop"), ("Desktop", "Desktop"), ("다운로드", "Downloads"),
                       ("downloads", "Downloads"), ("문서", "Documents"), ("Documents", "Documents")]
        for (alias, folder) in aliases {
            let expected = manager.homeDirectoryForCurrentUser.appendingPathComponent(folder)
            let resolved = AddressResolver.resolve(alias, relativeTo: root)
            if manager.fileExists(atPath: expected.path) { XCTAssertEqual(resolved?.path, expected.path) }
            else { XCTAssertNil(resolved) }
        }
    }

    func testBreadcrumbsStartAtHomeForHomeDescendants() {
        let home = manager.homeDirectoryForCurrentUser
        let crumbs = AddressResolver.breadcrumbs(for: home.appendingPathComponent("Documents/project"))
        XCTAssertEqual(crumbs.map(\.title), ["홈", "Documents", "project"])
        XCTAssertEqual(crumbs.first?.url.path, home.path)
        XCTAssertEqual(crumbs.last?.url.path, home.appendingPathComponent("Documents/project").path)
    }

    func testBreadcrumbsStartAtVolumeOrFilesystemRoot() {
        let volume = AddressResolver.breadcrumbs(for: URL(fileURLWithPath: "/Volumes/USB/folder"))
        XCTAssertEqual(volume.map(\.title), ["USB", "folder"])
        XCTAssertEqual(volume.first?.url.path, "/Volumes/USB")
        let outside = AddressResolver.breadcrumbs(for: URL(fileURLWithPath: "/opt/project"))
        XCTAssertEqual(outside.map(\.title), ["Macintosh HD", "opt", "project"])
        XCTAssertEqual(outside.first?.url.path, "/")
        XCTAssertEqual(AddressResolver.breadcrumbs(for: URL(fileURLWithPath: "/")).count, 1)
    }

    func testParentAndDisplayPathNormalizeDotComponents() {
        let path = root.appendingPathComponent("folder/../other")
        XCTAssertEqual(AddressResolver.parent(of: path)?.path, root.path)
        XCTAssertEqual(AddressResolver.displayPath(for: path), root.appendingPathComponent("other").path)
        XCTAssertNil(AddressResolver.parent(of: URL(fileURLWithPath: "/")))
    }
}

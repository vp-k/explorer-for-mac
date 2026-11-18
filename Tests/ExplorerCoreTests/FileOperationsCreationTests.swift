import Foundation
import XCTest
@testable import ExplorerCore

final class FileOperationsCreationTests: TemporaryDirectoryTestCase {
    func testRenameChangesNameAndRecordsBothPaths() throws {
        let source = try file("old.txt", "original")
        let result = try FileOperations.rename(source, to: "new.txt")
        let target = root.appendingPathComponent("new.txt")
        XCTAssertEqual(result.resultURLs, [target])
        XCTAssertEqual(result.record, .renamed(from: source, to: target))
        XCTAssertFalse(exists(source))
        XCTAssertEqual(try text(target), "original")
    }

    func testRenameRejectsInvalidNamesWithoutChangingSource() throws {
        let source = try file("source")
        for name in ["", " ", ".", "..", "a/b", "a:b", "nul\0name"] {
            assertOperationError(.invalidName(name)) { _ = try FileOperations.rename(source, to: name) }
            XCTAssertTrue(exists(source))
        }
        XCTAssertEqual(try names(in: root), ["source"])
    }

    func testRenameRejectsExistingNameWithoutOverwriting() throws {
        let source = try file("source", "source")
        let target = try file("target", "target")
        assertOperationError(.alreadyExists(target.path)) { _ = try FileOperations.rename(source, to: "target") }
        XCTAssertEqual(try text(source), "source")
        XCTAssertEqual(try text(target), "target")
    }

    func testRenameRejectsDanglingSymlinkCollision() throws {
        let source = try file("source")
        let target = root.appendingPathComponent("target")
        try manager.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("missing"))
        assertOperationError(.alreadyExists(target.path)) { _ = try FileOperations.rename(source, to: "target") }
    }

    func testCaseOnlyRenameUsesRequestedSpellingAndCanBeUndone() throws {
        let source = try file("Report.TXT", "case")
        let result = try FileOperations.rename(source, to: "report.txt")
        XCTAssertEqual(try names(in: root), ["report.txt"])
        XCTAssertEqual(try text(resultURL(result)), "case")
        let inverse = try undo(result)
        XCTAssertEqual(try names(in: root), ["Report.TXT"])
        _ = try FileOperations.undo(inverse)
        XCTAssertEqual(try names(in: root), ["report.txt"])
    }

    func testRenameToIdenticalNameIsNoOp() throws {
        let source = try file("source")
        let result = try FileOperations.rename(source, to: "source")
        XCTAssertNil(result.record)
        XCTAssertEqual(result.resultURLs, [source])
    }

    func testCreateFolderUsesNumberingAndRecordsCreation() throws {
        let first = try FileOperations.createFolder(in: root)
        let second = try FileOperations.createFolder(in: root)
        let third = try FileOperations.createFolder(in: root)
        XCTAssertEqual(try resultURL(first).lastPathComponent, "새 폴더")
        XCTAssertEqual(try resultURL(second).lastPathComponent, "새 폴더 (2)")
        XCTAssertEqual(try resultURL(third).lastPathComponent, "새 폴더 (3)")
        XCTAssertEqual(first.record, .created(try resultURL(first)))
        XCTAssertTrue(try FileItem.load(resultURL(second)).isDirectory)
    }

    func testCreateFileUsesNumberingAndIsEmpty() throws {
        let first = try FileOperations.createFile(in: root)
        let second = try FileOperations.createFile(in: root)
        let third = try FileOperations.createFile(in: root)
        XCTAssertEqual(try resultURL(first).lastPathComponent, "새 텍스트 문서.txt")
        XCTAssertEqual(try resultURL(second).lastPathComponent, "새 텍스트 문서 (2).txt")
        XCTAssertEqual(try resultURL(third).lastPathComponent, "새 텍스트 문서 (3).txt")
        XCTAssertEqual(try Data(contentsOf: resultURL(first)).count, 0)
        XCTAssertEqual(second.record, .created(try resultURL(second)))
    }

    func testCreateFolderWithDottedNameKeepsSuffixWithFolderName() throws {
        _ = try FileOperations.createFolder(in: root, baseName: "release.v1")
        let second = try FileOperations.createFolder(in: root, baseName: "release.v1")
        XCTAssertEqual(try resultURL(second).lastPathComponent, "release.v1 (2)")
    }

    func testCreateCannotEscapeDirectory() throws {
        for name in ["../escaped", "/absolute", "a:b", ".."] {
            assertOperationError(.invalidName(name)) { _ = try FileOperations.createFile(in: root, baseName: name) }
            assertOperationError(.invalidName(name)) { _ = try FileOperations.createFolder(in: root, baseName: name) }
        }
    }

    func testCreateDoesNotOverwriteAnExistingItemOfAnotherType() throws {
        let original = try file("새 폴더", "keep")
        let folder = try resultURL(FileOperations.createFolder(in: root))
        XCTAssertEqual(folder.lastPathComponent, "새 폴더 (2)")
        XCTAssertEqual(try text(original), "keep")
        try self.folder("새 텍스트 문서.txt")
        let file = try resultURL(FileOperations.createFile(in: root))
        XCTAssertEqual(file.lastPathComponent, "새 텍스트 문서 (2).txt")
    }

    func testUniqueNameHandlesExtensionsDotfilesAndFolders() throws {
        XCTAssertEqual(FileOperations.uniqueName("free.txt", in: root), "free.txt")
        try file("a.tar.gz")
        try file("a.tar (2).gz")
        XCTAssertEqual(FileOperations.uniqueName("a.tar.gz", in: root), "a.tar (3).gz")
        try file(".gitignore")
        XCTAssertEqual(FileOperations.uniqueName(".gitignore", in: root), ".gitignore (2)")
        try folder("release.v1")
        XCTAssertEqual(FileOperations.uniqueName("release.v1", in: root), "release.v1 (2)")
        try file("plain")
        XCTAssertEqual(FileOperations.uniqueName("plain", in: root), "plain (2)")
    }

    func testUniqueNameFillsFirstNumberingGap() throws {
        try file("a.txt")
        try file("a (3).txt")
        XCTAssertEqual(FileOperations.uniqueName("a.txt", in: root), "a (2).txt")
    }

    func testOperationsRejectMissingAndNonDirectoryDestination() throws {
        let source = try file("source")
        let missing = root.appendingPathComponent("missing")
        assertOperationError(.notFound(missing.path)) { _ = try FileOperations.createFile(in: missing) }
        XCTAssertThrowsError(try FileOperations.createFolder(in: source))
        XCTAssertThrowsError(try FileOperations.copy([source], to: source, conflict: .replace))
        XCTAssertThrowsError(try FileOperations.move([source], to: source, conflict: .replace))
        assertOperationError(.notFound(missing.path)) { _ = try FileOperations.rename(missing, to: "new") }
    }

    func testDeletePermanentlyRemovesFilesDirectoriesAndLinks() throws {
        let source = try file("source")
        let folder = try self.folder("folder/nested").deletingLastPathComponent()
        let target = try file("target", "keep")
        let link = root.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        try FileOperations.deletePermanently([source, folder, link])
        XCTAssertFalse(exists(source))
        XCTAssertFalse(exists(folder))
        XCTAssertFalse(exists(link))
        XCTAssertEqual(try text(target), "keep")
    }

    func testDeletePreflightsMissingItemsBeforeRemovingAnything() throws {
        let source = try file("source")
        let missing = root.appendingPathComponent("missing")
        assertOperationError(.notFound(missing.path)) { try FileOperations.deletePermanently([source, missing]) }
        XCTAssertTrue(exists(source))
    }

    func testEmptyTransferAndTrashHaveNoUndoRecord() throws {
        XCTAssertNil(try FileOperations.copy([], to: root, conflict: .replace).record)
        XCTAssertNil(try FileOperations.move([], to: root, conflict: .replace).record)
        XCTAssertNil(try FileOperations.trash([]).record)
        try FileOperations.deletePermanently([])
    }
}

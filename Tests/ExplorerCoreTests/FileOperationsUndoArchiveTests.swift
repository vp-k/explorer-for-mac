import Foundation
import XCTest
@testable import ExplorerCore

final class FileOperationsUndoArchiveTests: TemporaryDirectoryTestCase {
    func testTrashAndUndoRestoresFileAndDirectory() throws {
        let file = try self.file("ExplorerCore-trash-\(UUID().uuidString).txt", "restore")
        let folder = try self.folder("ExplorerCore-trash-\(UUID().uuidString)")
        try self.file(folder.lastPathComponent + "/nested/data", "nested")
        let result = try FileOperations.trash([file, folder])
        remember(result.record)
        XCTAssertFalse(exists(file))
        XCTAssertFalse(exists(folder))
        guard case .trashed(let pairs) = try XCTUnwrap(result.record) else { return XCTFail("Missing trash record") }
        XCTAssertEqual(pairs.map(\.from), [file, folder])
        XCTAssertEqual(result.resultURLs, pairs.map(\.to))
        for pair in pairs { XCTAssertTrue(exists(pair.to)) }
        let redo = try undo(result)
        XCTAssertEqual(try text(file), "restore")
        XCTAssertEqual(try text(folder.appendingPathComponent("nested/data")), "nested")
        remember(try FileOperations.undo(redo))
        XCTAssertFalse(exists(file))
        XCTAssertFalse(exists(folder))
    }

    func testCopyUndoAndRedoPreservesContent() throws {
        let source = try file("source/a", "copied")
        let destination = try folder("destination")
        let result = try FileOperations.copy([source], to: destination, conflict: .replace)
        let copied = try resultURL(result)
        let redo = try undo(result)
        XCTAssertFalse(exists(copied))
        XCTAssertEqual(try text(source), "copied")
        let undoAgain = try XCTUnwrap(remember(FileOperations.undo(redo)))
        XCTAssertEqual(try text(copied), "copied")
        remember(try FileOperations.undo(undoAgain))
        XCTAssertFalse(exists(copied))
    }

    func testMoveUndoAndRedoRestoresAllSources() throws {
        let a = try file("source/a", "a")
        let b = try file("source/b", "b")
        let destination = try folder("destination")
        let result = try FileOperations.move([a, b], to: destination, conflict: .replace)
        let redo = try undo(result)
        XCTAssertEqual(try text(a), "a")
        XCTAssertEqual(try text(b), "b")
        XCTAssertEqual(try names(in: destination), [])
        remember(try FileOperations.undo(redo))
        XCTAssertFalse(exists(a))
        XCTAssertFalse(exists(b))
        XCTAssertEqual(try names(in: destination), ["a", "b"])
    }

    func testRenameUndoAndRedo() throws {
        let source = try file("before", "renamed")
        let result = try FileOperations.rename(source, to: "after")
        let redo = try undo(result)
        XCTAssertEqual(try text(source), "renamed")
        XCTAssertFalse(exists(root.appendingPathComponent("after")))
        _ = try FileOperations.undo(redo)
        XCTAssertFalse(exists(source))
        XCTAssertEqual(try text(root.appendingPathComponent("after")), "renamed")
    }

    func testCreateFolderUndoAndRedoPreservesAddedContents() throws {
        let result = try FileOperations.createFolder(in: root)
        let created = try resultURL(result)
        try Data("later".utf8).write(to: created.appendingPathComponent("later.txt"))
        let redo = try undo(result)
        XCTAssertFalse(exists(created))
        remember(try FileOperations.undo(redo))
        XCTAssertEqual(try text(created.appendingPathComponent("later.txt")), "later")
    }

    func testCreateFileUndoAndRedoPreservesEdits() throws {
        let result = try FileOperations.createFile(in: root)
        let created = try resultURL(result)
        try Data("edited".utf8).write(to: created)
        let redo = try undo(result)
        XCTAssertFalse(exists(created))
        remember(try FileOperations.undo(redo))
        XCTAssertEqual(try text(created), "edited")
    }

    func testUndoMoveRefusesToOverwriteNewFileAndDoesNotPartiallyRestore() throws {
        let a = try file("source/a", "original a")
        let b = try file("source/b", "original b")
        let destination = try folder("destination")
        let result = try FileOperations.move([a, b], to: destination, conflict: .replace)
        try file("source/a", "new file")
        assertOperationError(.alreadyExists(a.path)) { _ = try FileOperations.undo(XCTUnwrap(result.record)) }
        XCTAssertEqual(try text(a), "new file")
        XCTAssertFalse(exists(b))
        XCTAssertEqual(try names(in: destination), ["a", "b"])
    }

    func testUndoRenameRefusesExistingOriginalName() throws {
        let source = try file("before", "original")
        let result = try FileOperations.rename(source, to: "after")
        try file("before", "new")
        assertOperationError(.alreadyExists(source.path)) { _ = try FileOperations.undo(XCTUnwrap(result.record)) }
        XCTAssertEqual(try text(source), "new")
        XCTAssertEqual(try text(root.appendingPathComponent("after")), "original")
    }

    func testUndoEmptyRecordsDoesNothing() throws {
        XCTAssertNil(try FileOperations.undo(.copied(created: [])))
        XCTAssertNil(try FileOperations.undo(.moved(pairs: [])))
        XCTAssertNil(try FileOperations.undo(.trashed(pairs: [])))
    }

    func testCompressSingleFileAndExtractRoundTripWithUnicodeAndSpaces() throws {
        let source = try file("source/한글 report.txt", "압축 내용\nsecond line")
        let archives = try folder("archives")
        let compressed = try FileOperations.compress([source], in: archives)
        let zip = try resultURL(compressed)
        XCTAssertEqual(zip.lastPathComponent, "한글 report.zip")
        XCTAssertEqual(compressed.record, .created(zip))
        let extracted = try FileOperations.extract(zip, to: archives)
        let output = try resultURL(extracted)
        XCTAssertEqual(output.lastPathComponent, "한글 report")
        XCTAssertEqual(extracted.record, .created(output))
        XCTAssertEqual(try text(output.appendingPathComponent(source.lastPathComponent)), try text(source))
    }

    func testCompressDirectoryKeepsParentAndNestedContents() throws {
        let source = try folder("source/tree.v1")
        try file("source/tree.v1/sub/data.txt", "nested")
        let archives = try folder("archives")
        let zip = try resultURL(FileOperations.compress([source], in: archives))
        XCTAssertEqual(zip.lastPathComponent, "tree.v1.zip")
        let extracted = try resultURL(FileOperations.extract(zip, to: archives))
        XCTAssertEqual(try text(extracted.appendingPathComponent("tree.v1/sub/data.txt")), "nested")
    }

    func testCompressMultipleSelectionAndExtractRoundTrip() throws {
        let a = try file("source/a.txt", "a")
        let directory = try folder("source/tree")
        try file("source/tree/sub/b.txt", "b")
        let archives = try folder("archives")
        let zip = try resultURL(FileOperations.compress([a, directory], in: archives))
        XCTAssertEqual(zip.lastPathComponent, "a.zip")
        let extracted = try resultURL(FileOperations.extract(zip, to: archives))
        XCTAssertEqual(try text(extracted.appendingPathComponent("a.txt")), "a")
        XCTAssertEqual(try text(extracted.appendingPathComponent("tree/sub/b.txt")), "b")
    }

    func testArchiveAndExtractionUseUniqueNamesWithoutOverwriting() throws {
        let source = try file("source/a.txt", "source")
        let archives = try folder("archives")
        let existing = try file("archives/a.zip", "keep archive")
        let zip = try resultURL(FileOperations.compress([source], in: archives))
        XCTAssertEqual(zip.lastPathComponent, "a (2).zip")
        try folder("archives/a (2)")
        let output = try resultURL(FileOperations.extract(zip, to: archives))
        XCTAssertEqual(output.lastPathComponent, "a (2) (2)")
        XCTAssertEqual(try text(existing), "keep archive")
    }

    func testCompressInsideSourceDoesNotArchiveItsOwnOutput() throws {
        let source = try folder("tree")
        try file("tree/data.txt", "data")
        let zip = try resultURL(FileOperations.compress([source], in: source))
        let output = try resultURL(FileOperations.extract(zip, to: folder("extracted")))
        XCTAssertEqual(try names(in: output.appendingPathComponent("tree")), ["data.txt"])
    }

    func testArchiveCreationAndExtractionCanBeUndoneAndRedone() throws {
        let source = try file("source/a.txt", "a")
        let archives = try folder("archives")
        let compressed = try FileOperations.compress([source], in: archives)
        let zip = try resultURL(compressed)
        let redoZip = try undo(compressed)
        XCTAssertFalse(exists(zip))
        remember(try FileOperations.undo(redoZip))
        let extracted = try FileOperations.extract(zip, to: archives)
        let output = try resultURL(extracted)
        let redoExtraction = try undo(extracted)
        XCTAssertFalse(exists(output))
        remember(try FileOperations.undo(redoExtraction))
        XCTAssertEqual(try text(output.appendingPathComponent("a.txt")), "a")
    }

    func testInvalidArchiveDoesNotLeaveOutputDirectory() throws {
        let zip = try file("broken.zip", "not a zip")
        let destination = try folder("destination")
        XCTAssertThrowsError(try FileOperations.extract(zip, to: destination))
        XCTAssertEqual(try names(in: destination), [])
    }

    func testCompressEmptySelectionAndDuplicateNamesFailWithoutOutput() throws {
        let destination = try folder("archives")
        XCTAssertThrowsError(try FileOperations.compress([], in: destination))
        let a = try file("first/a.txt", "first")
        let b = try file("second/a.txt", "second")
        XCTAssertThrowsError(try FileOperations.compress([a, b], in: destination))
        XCTAssertEqual(try names(in: destination), [])
        XCTAssertEqual(try text(a), "first")
        XCTAssertEqual(try text(b), "second")
    }
}

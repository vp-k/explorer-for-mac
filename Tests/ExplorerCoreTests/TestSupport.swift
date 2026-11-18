import Foundation
import XCTest
@testable import ExplorerCore

class TemporaryDirectoryTestCase: XCTestCase {
    let manager = FileManager.default
    var root: URL!
    private var cleanupURLs: [URL] = []

    override func setUpWithError() throws {
        root = manager.temporaryDirectory.appendingPathComponent("ExplorerCoreTests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() where manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        if let root, manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
        cleanupURLs = []
        root = nil
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "contents") throws -> URL {
        let url = root.appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { (try? manager.attributesOfItem(atPath: url.path)) != nil }
    func names(in directory: URL) throws -> [String] { try manager.contentsOfDirectory(atPath: directory.path).sorted() }
    func resultURL(_ result: OperationResult) throws -> URL { try XCTUnwrap(result.resultURLs.first) }

    @discardableResult
    func remember(_ record: FileOperationRecord?) -> FileOperationRecord? {
        switch record {
        case .trashed(let pairs), .moved(let pairs): cleanupURLs += pairs.map(\.to)
        case .compound(let records): for record in records { remember(record) }
        default: break
        }
        return record
    }

    func undo(_ result: OperationResult) throws -> FileOperationRecord {
        let inverse = try FileOperations.undo(XCTUnwrap(result.record))
        return try XCTUnwrap(remember(inverse))
    }

    func assertOperationError(_ expected: FileOperationError, file: StaticString = #filePath, line: UInt = #line,
                              _ action: () throws -> Void) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? FileOperationError, expected, file: file, line: line)
        }
    }
}

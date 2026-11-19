import Foundation
import XCTest
@testable import ExplorerCore

final class ZIPFilenameEncodingTests: TemporaryDirectoryTestCase {
    func testKoreanSingleFileHasUTF8FlagsAndRoundTripsWithDefaultDecoders() throws {
        let source = try file("source/한글 문서.txt", "한글 내용")
        let archives = try folder("archives")
        let zip = try resultURL(FileOperations.compress([source], in: archives))
        XCTAssertEqual(zip.lastPathComponent, "한글 문서.zip")
        XCTAssertEqual(try validatedEntries(zip), ["한글 문서.txt"])
        let extracted = try resultURL(FileOperations.extract(zip, to: archives))
        XCTAssertEqual(try text(extracted.appendingPathComponent("한글 문서.txt")), "한글 내용")
    }

    func testKoreanDirectoryAndMixedNamesKeepOriginalTopLevelStructure() throws {
        let source = try folder("source/자료")
        try file("source/자료/sub/한글😀.txt", "한글")
        try file("source/자료/ascii.txt", "ASCII")
        let zip = try resultURL(FileOperations.compress([source], in: folder("archives")))
        let entries = try validatedEntries(zip)
        XCTAssertTrue(entries.contains("자료/sub/한글😀.txt"))
        XCTAssertTrue(entries.contains("자료/ascii.txt"))
        XCTAssertTrue(entries.allSatisfy { $0.hasPrefix("자료/") })
        let output = try resultURL(FileOperations.extract(zip, to: folder("extracted")))
        XCTAssertEqual(try text(output.appendingPathComponent("자료/sub/한글😀.txt")), "한글")
    }

    func testMultipleSelectionWithKoreanAndDecomposedNamesHasNoWrapperOrMetadata() throws {
        let first = try file("one/첫 파일.txt", "first")
        let second = try file("two/cafe\u{0301}.txt", "second")
        let third = try file("three/plain.txt", "third")
        let directory = try folder("four/폴더")
        try file("four/폴더/안쪽.txt", "nested")
        let zip = try resultURL(FileOperations.compress([first, second, third, directory], in: folder("archives")))
        XCTAssertEqual(zip.lastPathComponent, "첫 파일.zip")
        let entries = try validatedEntries(zip)
        XCTAssertTrue(entries.contains("첫 파일.txt"))
        XCTAssertTrue(entries.contains("café.txt"))
        XCTAssertTrue(entries.contains("plain.txt"))
        XCTAssertTrue(entries.contains("폴더/안쪽.txt"))
        XCTAssertTrue(entries.allSatisfy { !$0.contains("__MACOSX") })
        let output = try resultURL(FileOperations.extract(zip, to: folder("extracted")))
        XCTAssertEqual(try text(output.appendingPathComponent("첫 파일.txt")), "first")
        XCTAssertEqual(try text(output.appendingPathComponent("café.txt")), "second")
        XCTAssertEqual(try text(output.appendingPathComponent("plain.txt")), "third")
    }

    func testASCIIArchiveStaysReadableAndRepatchingIsIdempotent() throws {
        let source = try file("source/ascii.txt", "PK\u{3}\u{4} fake header PK\u{1}\u{2}")
        let zip = try resultURL(FileOperations.compress([source], in: folder("archives")))
        let before = try Data(contentsOf: zip)
        try ZIPFilenameEncoding.markUTF8(in: zip)
        XCTAssertEqual(try Data(contentsOf: zip), before)
        XCTAssertEqual(try validatedEntries(zip), ["ascii.txt"])
    }

    func testZIP64OffsetsAndCountsArePatchedWithoutLoadingFileData() throws {
        let zip = root.appendingPathComponent("zip64.zip")
        _ = try python(#"""
        import struct, sys, zlib
        name = '한글.txt'.encode('utf-8')
        data = b'ZIP64 payload'
        crc = zlib.crc32(data)
        local = struct.pack('<I5H3I2H', 0x04034b50, 45, 0, 0, 0, 0, crc, len(data), len(data), len(name), 0) + name + data
        extra = struct.pack('<HHQQQ', 1, 24, len(data), len(data), 0)
        central = struct.pack('<I6H3I5H2I', 0x02014b50, 45, 45, 0, 0, 0, 0, crc, 0xffffffff, 0xffffffff, len(name), len(extra), 0, 0, 0, 0, 0xffffffff) + name + extra
        position = len(local) + len(central)
        end64 = struct.pack('<IQ2H2I4Q', 0x06064b50, 44, 45, 45, 0, 0, 1, 1, len(central), len(local))
        locator = struct.pack('<IIQI', 0x07064b50, 0, position, 1)
        end = struct.pack('<I4H2IH', 0x06054b50, 0, 0, 0xffff, 0xffff, 0xffffffff, 0xffffffff, 0)
        open(sys.argv[1], 'wb').write(local + central + end64 + locator + end)
        """#, arguments: [zip.path])
        try ZIPFilenameEncoding.markUTF8(in: zip)
        XCTAssertEqual(try validatedEntries(zip), ["한글.txt"])
    }

    func testInvalidArchiveFailsWithoutPublishingAnOutput() throws {
        let invalid = try file("broken.zip", "not a zip")
        XCTAssertThrowsError(try ZIPFilenameEncoding.markUTF8(in: invalid))
        XCTAssertEqual(try text(invalid), "not a zip")
    }

    func testLateInvalidHeaderOrEncodingLeavesAllOriginalBytesUnchanged() throws {
        // The first entry is valid UTF-8 but unflagged. The old one-pass patcher modified it
        // before discovering a broken second entry, including failures in its ZIP64 extra data.
        for failure in ["central", "local", "name", "comment", "zip64", "ascii-local", "count"] {
            let zip = root.appendingPathComponent("late-\(failure).zip")
            _ = try python(#"""
            import struct, sys, zipfile
            path, failure = sys.argv[1:]
            with zipfile.ZipFile(path, 'w') as z:
                z.writestr('첫째.txt', b'first payload')
                z.writestr('second.txt' if failure == 'ascii-local' else '둘째.txt', b'second payload')
            data = bytearray(open(path, 'rb').read())
            end = data.rfind(b'PK\x05\x06')
            central = struct.unpack_from('<I', data, end + 16)[0]
            positions = []
            cursor = central
            for _ in range(2):
                positions.append(cursor)
                local = struct.unpack_from('<I', data, cursor + 42)[0]
                struct.pack_into('<H', data, cursor + 8, 0)
                struct.pack_into('<H', data, local + 6, 0)
                sizes = struct.unpack_from('<3H', data, cursor + 28)
                cursor += 46 + sum(sizes)
            second = positions[1]
            local = struct.unpack_from('<I', data, second + 42)[0]
            if failure == 'central':
                data[second] = 0
            elif failure in ('local', 'ascii-local'):
                data[local] = 0
            elif failure == 'name':
                data[second + 46] = 0xff
            elif failure == 'comment':
                struct.pack_into('<H', data, second + 32, 1)
                data.insert(cursor, 0xff)
                end += 1
                struct.pack_into('<I', data, end + 12, len(data) - 22 - central)
            elif failure == 'zip64':
                struct.pack_into('<I', data, second + 42, 0xffffffff)
            elif failure == 'count':
                struct.pack_into('<2H', data, end + 8, 1, 1)
            open(path, 'wb').write(data)
            """#, arguments: [zip.path, failure])
            let before = try Data(contentsOf: zip)
            XCTAssertThrowsError(try ZIPFilenameEncoding.markUTF8(in: zip), failure)
            XCTAssertEqual(try Data(contentsOf: zip), before, failure)
        }
    }

    func testValidUnflaggedUTF8EntriesArePatchedOnlyAtFlagBytes() throws {
        let zip = root.appendingPathComponent("unflagged.zip")
        _ = try python(#"""
        import struct, sys, zipfile
        path = sys.argv[1]
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr('한글.txt', b'payload')
            z.writestr('plain.txt', b'ASCII payload')
        data = bytearray(open(path, 'rb').read())
        local, central = data.index(b'PK\x03\x04'), data.index(b'PK\x01\x02')
        struct.pack_into('<H', data, local + 6, 0)
        struct.pack_into('<H', data, central + 8, 0)
        open(path, 'wb').write(data)
        """#, arguments: [zip.path])
        let before = try Data(contentsOf: zip)
        try ZIPFilenameEncoding.markUTF8(in: zip)
        let after = try Data(contentsOf: zip)
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(zipBytesChanged(before, after), 2)
        XCTAssertEqual(try validatedEntries(zip), ["한글.txt", "plain.txt"])
        try ZIPFilenameEncoding.markUTF8(in: zip)
        XCTAssertEqual(try Data(contentsOf: zip), after)
    }

    private func zipBytesChanged(_ before: Data, _ after: Data) -> Int {
        zip(before, after).filter { $0 != $1 }.count
    }

    func testLateWriteFailureLeavesOriginalArchiveUnchangedAndRemovesStaging() throws {
        let source = try file("source/한글.txt", "payload")
        let archives = try folder("archives")
        let archive = try resultURL(FileOperations.compress([source], in: archives))
        var before = try Data(contentsOf: archive)
        let local = try XCTUnwrap(before.range(of: Data([0x50, 0x4b, 0x03, 0x04]))).lowerBound
        let central = try XCTUnwrap(before.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
        before[local + 7] &= ~UInt8(0x08)
        before[central + 9] &= ~UInt8(0x08)
        try before.write(to: archive)
        var writes = 0
        XCTAssertThrowsError(try ZIPFilenameEncoding.markUTF8(in: archive, writeFlag: { file, offset, data in
            writes += 1
            if writes == 2 { throw POSIXError(.ENOSPC) }
            try file.seek(toOffset: offset)
            try file.write(contentsOf: data)
        })) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENOSPC)
        }
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertEqual(try names(in: archives), [archive.lastPathComponent])
    }

    private func validatedEntries(_ zip: URL) throws -> [String] {
        let output = root.appendingPathComponent("python-extracted-\(UUID().uuidString)")
        let data = try python(#"""
        import json, struct, sys, unicodedata, zipfile
        archive, output = sys.argv[1:]
        with zipfile.ZipFile(archive) as z, open(archive, 'rb') as raw:
            names = []
            for info in z.infolist():
                # No metadata_encoding override: use Python's standard EFS/CP437 decoder.
                name = unicodedata.normalize('NFC', info.filename)
                assert '__MACOSX' not in name, name
                names.append(name)
                raw.seek(info.header_offset)
                header = raw.read(30)
                assert header[:4] == b'PK\x03\x04'
                local_flags = struct.unpack_from('<H', header, 6)[0]
                if any(ord(c) > 127 for c in info.filename):
                    assert info.flag_bits & 0x800, (name, 'central', info.flag_bits)
                    assert local_flags & 0x800, (name, 'local', local_flags)
                    length = struct.unpack_from('<H', header, 26)[0]
                    assert raw.read(length).decode('utf-8') == info.filename
            assert z.testzip() is None
            z.extractall(output)
            print(json.dumps(names, ensure_ascii=False))
        """#, arguments: [zip.path, output.path])
        return try JSONDecoder().decode([String].self, from: data)
    }

    private func python(_ script: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
        guard process.terminationStatus == 0 else { throw FileOperationError.failed(String(decoding: diagnostics, as: UTF8.self)) }
        return data
    }
}

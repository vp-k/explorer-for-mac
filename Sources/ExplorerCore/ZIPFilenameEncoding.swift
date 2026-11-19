import Foundation

/// Patches only header flags, using the central directory rather than scanning compressed data.
/// File data is never loaded into memory. ZIP64 directory counts/offsets are supported as well.
enum ZIPFilenameEncoding {
    static func markUTF8(in url: URL) throws {
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        let invalid = FileOperationError.failed("ZIP 파일 이름 헤더를 확인할 수 없습니다.")

        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= size, UInt64(count) <= size - offset else { throw invalid }
            try file.seek(toOffset: offset)
            var result = Data()
            while result.count < count {
                guard let data = try file.read(upToCount: count - result.count), !data.isEmpty else { throw invalid }
                result.append(data)
            }
            return result
        }

        func setFlag(at offset: UInt64, flags: UInt64) throws {
            let value = flags | 0x800
            try file.seek(toOffset: offset)
            try file.write(contentsOf: Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]))
        }

        guard size >= 22 else { throw invalid }
        let tailStart = size - min(size, 65_535 + 22)
        let tail = try read(tailStart, Int(size - tailStart))
        guard let endIndex = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail.number(at: $0, length: 4) == 0x06054b50
                && $0 + 22 + Int(tail.number(at: $0 + 20, length: 2)) == tail.count
        }) else { throw invalid }
        let end = tailStart + UInt64(endIndex)
        let eocd = tail.subdata(in: endIndex..<(endIndex + 22))
        guard eocd.number(at: 4, length: 2) == 0, eocd.number(at: 6, length: 2) == 0 else { throw invalid }
        var count = eocd.number(at: 10, length: 2)
        var directorySize = eocd.number(at: 12, length: 4)
        var directoryOffset = eocd.number(at: 16, length: 4)
        if count == 0xffff || directorySize == 0xffff_ffff || directoryOffset == 0xffff_ffff {
            guard end >= 20 else { throw invalid }
            let locator = try read(end - 20, 20)
            guard locator.number(at: 0, length: 4) == 0x07064b50,
                  locator.number(at: 4, length: 4) == 0,
                  locator.number(at: 16, length: 4) == 1 else { throw invalid }
            let zip64 = try read(locator.number(at: 8, length: 8), 56)
            guard zip64.number(at: 0, length: 4) == 0x06064b50,
                  zip64.number(at: 16, length: 4) == 0, zip64.number(at: 20, length: 4) == 0,
                  zip64.number(at: 24, length: 8) == zip64.number(at: 32, length: 8) else { throw invalid }
            count = zip64.number(at: 32, length: 8)
            directorySize = zip64.number(at: 40, length: 8)
            directoryOffset = zip64.number(at: 48, length: 8)
        } else if eocd.number(at: 8, length: 2) != count { throw invalid }
        guard directoryOffset <= end, directorySize <= end - directoryOffset,
              count <= directorySize / 46 else { throw invalid }
        let directoryEnd = directoryOffset + directorySize
        var position = directoryOffset
        for _ in 0..<count {
            guard position <= directoryEnd, directoryEnd - position >= 46 else { throw invalid }
            let header = try read(position, 46)
            guard header.number(at: 0, length: 4) == 0x02014b50 else { throw invalid }
            let nameSize = Int(header.number(at: 28, length: 2))
            let extraSize = Int(header.number(at: 30, length: 2))
            let commentSize = Int(header.number(at: 32, length: 2))
            let entrySize = UInt64(46 + nameSize + extraSize + commentSize)
            guard entrySize <= directoryEnd - position else { throw invalid }
            let name = try read(position + 46, nameSize)
            if name.contains(where: { $0 >= 0x80 }) {
                guard String(data: name, encoding: .utf8) != nil else { throw invalid }
                let comment = try read(position + 46 + UInt64(nameSize + extraSize), commentSize)
                guard String(data: comment, encoding: .utf8) != nil else { throw invalid }
                var localOffset = header.number(at: 42, length: 4)
                if localOffset == 0xffff_ffff {
                    let extra = try read(position + 46 + UInt64(nameSize), extraSize)
                    var cursor = 0
                    var found = false
                    while cursor + 4 <= extra.count {
                        let tag = extra.number(at: cursor, length: 2)
                        let length = Int(extra.number(at: cursor + 2, length: 2))
                        cursor += 4
                        guard length <= extra.count - cursor else { throw invalid }
                        if tag == 1 {
                            let skip = (header.number(at: 24, length: 4) == 0xffff_ffff ? 8 : 0)
                                + (header.number(at: 20, length: 4) == 0xffff_ffff ? 8 : 0)
                            guard skip + 8 <= length else { throw invalid }
                            localOffset = extra.number(at: cursor + skip, length: 8)
                            found = true
                            break
                        }
                        cursor += length
                    }
                    guard found else { throw invalid }
                }
                guard localOffset < directoryOffset, directoryOffset - localOffset >= 30 else { throw invalid }
                let local = try read(localOffset, 30)
                guard local.number(at: 0, length: 4) == 0x04034b50,
                      local.number(at: 26, length: 2) == UInt64(nameSize),
                      try read(localOffset + 30, nameSize) == name else { throw invalid }
                try setFlag(at: localOffset + 6, flags: local.number(at: 6, length: 2))
                try setFlag(at: position + 8, flags: header.number(at: 8, length: 2))
            }
            position += entrySize
        }
        try file.synchronize()
    }
}

private extension Data {
    /// Callers validate fixed header/extra-field bounds before reading each little-endian value.
    func number(at offset: Int, length: Int) -> UInt64 {
        (0..<length).reduce(UInt64(0)) { $0 | UInt64(self[offset + $1]) << ($1 * 8) }
    }
}

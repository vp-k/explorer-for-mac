import Foundation

/// 잘라내기/복사 상태. 시스템 대지(NSPasteboard) 연동은 UI 쪽 책임이고,
/// 여기서는 "마지막으로 잘라낸 URL 목록" 을 기억해 붙여넣기 시 이동인지 판단한다.
public struct FileClipboard: Sendable, Equatable {
    public enum Mode: Sendable { case copy, cut }
    public private(set) var urls: [URL] = []
    public private(set) var mode: Mode = .copy
    public init() {}
    public mutating func set(_ urls: [URL], mode: Mode) { self.urls = urls; self.mode = mode }
    public mutating func clear() { urls = []; mode = .copy }
    /// 이 URL 이 잘라내기 상태인가 (목록에서 흐리게 표시).
    public func isCut(_ url: URL) -> Bool { mode == .cut && urls.contains(url) }
}

public enum SizeFormatter {
    /// Windows 자세히 보기 식 크기 표기. KB 단위로 올림하고 천 단위 구분을 넣는다.
    /// 0B → "0 KB", 1B → "1 KB", 1025B → "2 KB", 1_263_616B → "1,234 KB".
    public static func explorerSize(_ bytes: Int64) -> String { fatalError("TODO core") }
    /// 상태 표시줄/속성 창용: "1.5 MB", "3.2 GB".
    public static func humanSize(_ bytes: Int64) -> String { fatalError("TODO core") }
}

public enum WildcardMatcher {
    /// 검색어 매칭. "*", "?" 와일드카드 지원, 없으면 대소문자 무시 부분 일치.
    public static func matches(_ name: String, pattern: String) -> Bool { fatalError("TODO core") }
}

/// 하위 폴더까지 이름 검색. 취소 가능, 배치로 결과 전달.
public final class FileSearch: @unchecked Sendable {
    public init(root: URL, query: String, showHidden: Bool) { fatalError("TODO core") }
    /// 백그라운드 스레드에서 호출하라. onBatch 는 호출한 스레드에서 불린다.
    public func run(batchSize: Int = 200, onBatch: ([FileItem]) -> Void) { fatalError("TODO core") }
    public func cancel() { fatalError("TODO core") }
}

public struct FolderStats: Sendable, Equatable {
    public var totalBytes: Int64 = 0
    public var fileCount: Int = 0
    public var folderCount: Int = 0
    public init() {}
}

public enum FolderSizeCalculator {
    /// 재귀 합계 (속성 창). isCancelled 가 true 면 중단하고 그때까지 합계를 돌려준다.
    public static func stats(for urls: [URL], isCancelled: () -> Bool = { false }) -> FolderStats { fatalError("TODO core") }
}

public struct VolumeInfo: Hashable, Sendable {
    public let url: URL
    public let name: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let isRemovable: Bool
    public let isInternal: Bool
    public init(url: URL, name: String, totalBytes: Int64, availableBytes: Int64, isRemovable: Bool, isInternal: Bool) {
        self.url = url; self.name = name; self.totalBytes = totalBytes
        self.availableBytes = availableBytes; self.isRemovable = isRemovable; self.isInternal = isInternal
    }
}

public enum VolumeLister {
    /// "내 PC" 에 보일 마운트된 볼륨 (루트 볼륨 포함, 숨김 볼륨 제외).
    public static func volumes() -> [VolumeInfo] { fatalError("TODO core") }
}

/// 빠른 액세스 고정 폴더. JSON 파일에 저장.
public final class PinnedFolderStore: @unchecked Sendable {
    public init(storageURL: URL) { fatalError("TODO core") }
    /// 저장 파일이 없으면 기본값: 바탕 화면, 다운로드, 문서, 사진.
    public var folders: [URL] { fatalError("TODO core") }
    public func pin(_ url: URL) { fatalError("TODO core") }
    public func unpin(_ url: URL) { fatalError("TODO core") }
    public func isPinned(_ url: URL) -> Bool { fatalError("TODO core") }
    public func move(from: Int, to: Int) { fatalError("TODO core") }
}

/// 폴더 변경 감시 (FSEvents 또는 DispatchSource). 변경 시 main 큐에서 onChange 호출 (0.3초 디바운스).
public final class DirectoryWatcher: @unchecked Sendable {
    public init(url: URL, onChange: @escaping @Sendable () -> Void) { fatalError("TODO core") }
    public func stop() { fatalError("TODO core") }
}

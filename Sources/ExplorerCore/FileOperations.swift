import Foundation

public enum ConflictPolicy: Sendable {
    /// 덮어쓰기
    case replace
    /// 건너뛰기
    case skip
    /// "이름 (2).ext" 로 둘 다 유지
    case keepBoth
}

public enum FileOperationError: LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(String)
    case destinationInsideSource(String)
    case notFound(String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidName(let s): return "잘못된 이름입니다: \(s)"
        case .alreadyExists(let s): return "같은 이름의 항목이 이미 있습니다: \(s)"
        case .destinationInsideSource(let s): return "대상 폴더가 원본 폴더 안에 있습니다: \(s)"
        case .notFound(let s): return "항목을 찾을 수 없습니다: \(s)"
        case .failed(let s): return s
        }
    }
}

/// 실행 취소(Cmd+Z)용 기록.
public enum FileOperationRecord: Sendable, Equatable {
    case copied(created: [URL])
    case moved(pairs: [MovePair])
    case renamed(from: URL, to: URL)
    case trashed(pairs: [MovePair])   // from: 원래 위치, to: 휴지통 위치
    case created(URL)
}

public struct MovePair: Sendable, Equatable {
    public let from: URL
    public let to: URL
    public init(from: URL, to: URL) { self.from = from; self.to = to }
}

public struct OperationResult: Sendable {
    public let record: FileOperationRecord?
    /// 결과로 생긴(혹은 이동된) 항목들 — 붙여넣기 후 선택에 쓴다.
    public let resultURLs: [URL]
    public let skipped: [URL]
    public init(record: FileOperationRecord?, resultURLs: [URL], skipped: [URL]) {
        self.record = record; self.resultURLs = resultURLs; self.skipped = skipped
    }
}

public enum FileOperations {
    /// 같은 폴더로 복사하면 Windows 처럼 "이름 - 복사본.ext", "이름 - 복사본 (2).ext".
    public static func copy(_ sources: [URL], to destination: URL, conflict: ConflictPolicy) throws -> OperationResult { fatalError("TODO core") }
    /// 같은 폴더로 이동은 아무 것도 하지 않는다. 폴더를 자기 하위로 옮기면 destinationInsideSource.
    public static func move(_ sources: [URL], to destination: URL, conflict: ConflictPolicy) throws -> OperationResult { fatalError("TODO core") }
    /// 휴지통으로 이동 (FileManager.trashItem).
    public static func trash(_ urls: [URL]) throws -> OperationResult { fatalError("TODO core") }
    /// 영구 삭제 (Shift+Delete).
    public static func deletePermanently(_ urls: [URL]) throws { fatalError("TODO core") }
    /// 이름 바꾸기. 빈 이름, "/", ":" 포함, "." ".." 은 invalidName. 대소문자만 바꾸는 것은 허용.
    public static func rename(_ url: URL, to newName: String) throws -> OperationResult { fatalError("TODO core") }
    /// "새 폴더", "새 폴더 (2)" ...
    public static func createFolder(in directory: URL, baseName: String = "새 폴더") throws -> OperationResult { fatalError("TODO core") }
    /// 빈 파일. "새 텍스트 문서.txt", "새 텍스트 문서 (2).txt" ...
    public static func createFile(in directory: URL, baseName: String = "새 텍스트 문서.txt") throws -> OperationResult { fatalError("TODO core") }
    /// directory 안에서 겹치지 않는 이름. "a.txt" → "a (2).txt", 폴더 "x" → "x (2)".
    public static func uniqueName(_ name: String, in directory: URL) -> String { fatalError("TODO core") }
    /// 압축 (ditto -c -k --sequesterRsrc --keepParent). 하나면 "이름.zip", 여러 개면 "압축.zip".
    public static func compress(_ urls: [URL], in directory: URL) throws -> OperationResult { fatalError("TODO core") }
    /// zip 을 같은 이름 폴더로 풀기 (ditto -x -k).
    public static func extract(_ zip: URL, to directory: URL) throws -> OperationResult { fatalError("TODO core") }
    /// 실행 취소. 되돌린 뒤의 기록(다시 실행용)을 돌려준다.
    @discardableResult
    public static func undo(_ record: FileOperationRecord) throws -> FileOperationRecord? { fatalError("TODO core") }
}

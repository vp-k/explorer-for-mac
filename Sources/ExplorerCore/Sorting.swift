import Foundation

public enum SortKey: String, CaseIterable, Codable, Sendable {
    case name, dateModified, type, size, dateCreated
}

public struct SortOrder: Equatable, Codable, Sendable {
    public var key: SortKey
    public var ascending: Bool
    /// Windows 처럼 폴더를 항상 파일 앞에 둔다 (오름/내림차순 모두).
    public var foldersFirst: Bool
    public init(key: SortKey = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key; self.ascending = ascending; self.foldersFirst = foldersFirst
    }
}

public enum FileSorter {
    /// 이름 비교는 자연 정렬(file2 < file10, 대소문자 무시). 동률이면 이름으로 2차 정렬.
    public static func sorted(_ items: [FileItem], by order: SortOrder) -> [FileItem] { fatalError("TODO core") }
}

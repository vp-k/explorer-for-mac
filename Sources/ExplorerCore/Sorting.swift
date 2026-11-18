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
    public static func sorted(_ items: [FileItem], by order: SortOrder) -> [FileItem] {
        items.sorted { lhs, rhs in
            if order.foldersFirst && lhs.isNavigable != rhs.isNavigable { return lhs.isNavigable }
            let comparison: ComparisonResult
            switch order.key {
            case .name: comparison = compareNames(lhs.name, rhs.name)
            case .type: comparison = compareNames(lhs.typeDescription, rhs.typeDescription)
            case .size: comparison = compare(lhs.size ?? -1, rhs.size ?? -1)
            case .dateModified: comparison = compare(lhs.dateModified ?? .distantPast, rhs.dateModified ?? .distantPast)
            case .dateCreated: comparison = compare(lhs.dateCreated ?? .distantPast, rhs.dateCreated ?? .distantPast)
            }
            var result = comparison == .orderedSame ? compareNames(lhs.name, rhs.name) : comparison
            if result == .orderedSame { result = lhs.url.path.compare(rhs.url.path, options: .literal) }
            return order.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compareNames(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive], locale: Locale.current)
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }
}

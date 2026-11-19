import Foundation

/// 뒤로/앞으로 기록. 브라우저와 같은 규칙: 새 위치 방문 시 앞으로 기록은 버린다.
public struct NavigationHistory: Sendable {
    public private(set) var current: URL
    public private(set) var backStack: [URL] = []
    public private(set) var forwardStack: [URL] = []
    public init(start: URL) { current = start }
    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
    /// 같은 위치 재방문은 기록하지 않는다.
    public mutating func visit(_ url: URL) {
        guard url.standardizedFileURL.path != current.standardizedFileURL.path else { return }
        backStack.append(current)
        current = url
        forwardStack.removeAll()
    }
    public mutating func goBack() -> URL? {
        guard let url = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = url
        return url
    }
    public mutating func goForward() -> URL? {
        guard let url = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = url
        return url
    }
}

public struct Breadcrumb: Hashable, Sendable {
    public let title: String
    public let url: URL
    public init(title: String, url: URL) { self.title = title; self.url = url }
}

public enum AddressResolver {
    /// 주소 표시줄 입력을 폴더/파일 URL 로 바꾼다. 존재하지 않으면 nil.
    /// 지원: 절대경로, ~ / ~/x, $HOME, %USERPROFILE%, file:// URL, 역슬래시(\\ → /),
    /// 따옴표 제거, 상대경로(base 기준), "바탕 화면/Desktop/다운로드/Downloads/문서/Documents" 같은 별칭.
    public static func resolve(_ input: String, relativeTo base: URL) -> URL? {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, let first = path.first, first == "\"" || first == "'", path.last == first {
            path = String(path.dropFirst().dropLast())
        }
        guard !path.isEmpty else { return nil }
        path = path.replacingOccurrences(of: "\\", with: "/")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url: URL
        if path.lowercased().hasPrefix("file://") {
            guard let file = URL(string: path), file.isFileURL,
                  file.host == nil || file.host == "" || file.host == "localhost" else { return nil }
            url = file
        } else {
            for prefix in ["%USERPROFILE%", "$HOME", "${HOME}", "~"] {
                if path.caseInsensitiveCompare(prefix) == .orderedSame ||
                    path.lowercased().hasPrefix(prefix.lowercased() + "/") {
                    path = home.path + path.dropFirst(prefix.count)
                    break
                }
            }
            let aliases = ["바탕 화면": "Desktop", "Desktop": "Desktop", "다운로드": "Downloads",
                           "Downloads": "Downloads", "문서": "Documents", "Documents": "Documents"]
            let first = String(path.prefix { $0 != "/" })
            if let alias = aliases.first(where: { $0.key.caseInsensitiveCompare(first) == .orderedSame })?.value {
                path = home.appendingPathComponent(alias).path + path.dropFirst(first.count)
            }
            url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        }
        let result = url.standardizedFileURL
        return FileManager.default.fileExists(atPath: result.path) ? result : nil
    }

    /// 상위 폴더. 루트("/")면 nil.
    public static func parent(of url: URL) -> URL? {
        let normalized = url.standardizedFileURL
        return normalized.path == "/" ? nil : normalized.deletingLastPathComponent()
    }

    /// 주소 표시줄 경로 버튼. 홈 폴더 아래는 [홈, ...], 그 밖은 [Macintosh HD(/), ...].
    /// /Volumes/X 아래는 [X, ...].
    public static func breadcrumbs(for url: URL) -> [Breadcrumb] {
        let path = url.standardizedFileURL.pathComponents
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let homeParts = home.pathComponents
        var root: URL
        var result: [Breadcrumb]
        var remaining: ArraySlice<String>
        if path.starts(with: homeParts) {
            root = home
            result = [Breadcrumb(title: CL("홈"), url: root)]
            remaining = path.dropFirst(homeParts.count)
        } else if path.count >= 3 && path[1] == "Volumes" {
            root = URL(fileURLWithPath: "/Volumes").appendingPathComponent(path[2], isDirectory: true)
            result = [Breadcrumb(title: path[2], url: root)]
            remaining = path.dropFirst(3)
        } else {
            root = URL(fileURLWithPath: "/", isDirectory: true)
            result = [Breadcrumb(title: "Macintosh HD", url: root)]
            remaining = path.dropFirst()
        }
        for component in remaining {
            root.appendPathComponent(component, isDirectory: true)
            result.append(Breadcrumb(title: component, url: root))
        }
        return result
    }

    /// 주소 표시줄 편집 모드에 보여줄 문자열 (전체 POSIX 경로).
    public static func displayPath(for url: URL) -> String { url.standardizedFileURL.path }
}

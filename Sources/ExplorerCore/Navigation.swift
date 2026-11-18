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
    public mutating func visit(_ url: URL) { fatalError("TODO core") }
    public mutating func goBack() -> URL? { fatalError("TODO core") }
    public mutating func goForward() -> URL? { fatalError("TODO core") }
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
    public static func resolve(_ input: String, relativeTo base: URL) -> URL? { fatalError("TODO core") }

    /// 상위 폴더. 루트("/")면 nil.
    public static func parent(of url: URL) -> URL? { fatalError("TODO core") }

    /// 주소 표시줄 경로 버튼. 홈 폴더 아래는 [홈, ...], 그 밖은 [Macintosh HD(/), ...].
    /// /Volumes/X 아래는 [X, ...].
    public static func breadcrumbs(for url: URL) -> [Breadcrumb] { fatalError("TODO core") }

    /// 주소 표시줄 편집 모드에 보여줄 문자열 (전체 POSIX 경로).
    public static func displayPath(for url: URL) -> String { fatalError("TODO core") }
}

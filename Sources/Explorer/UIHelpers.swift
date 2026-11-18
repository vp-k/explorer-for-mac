import AppKit
import ExplorerCore

/// "내 Mac" 같은 가상 위치와 표준 폴더.
enum Location {
    /// 내 Mac 화면. 파일 URL 이 아니므로 기록에만 쓰인다.
    static let thisMac = URL(string: "explorer:thismac")!

    static func isThisMac(_ url: URL) -> Bool { url.scheme == "explorer" }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func standard(_ dir: FileManager.SearchPathDirectory) -> URL? {
        FileManager.default.urls(for: dir, in: .userDomainMask).first
    }

    static var trash: URL? { standard(.trashDirectory) }

    /// 내 Mac 화면과 이동 메뉴에 보이는 표준 폴더.
    static var standardFolders: [(title: String, url: URL)] {
        let dirs: [(String, FileManager.SearchPathDirectory)] = [
            ("바탕 화면", .desktopDirectory), ("문서", .documentDirectory),
            ("다운로드", .downloadsDirectory), ("사진", .picturesDirectory),
            ("음악", .musicDirectory), ("동영상", .moviesDirectory),
        ]
        var result = dirs.compactMap { title, dir in standard(dir).map { (title, $0) } }
        result.append(("홈", home))
        return result
    }

    /// 경로 비교용 키. 디렉터리 URL 의 끝 "/" 차이를 없앤다.
    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    static func same(_ a: URL, _ b: URL) -> Bool { key(a) == key(b) }
}

enum UI {
    static func symbol(_ name: String, _ label: String? = nil) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
    }

    @MainActor
    static func toolButton(_ symbolName: String, tip: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(image: symbol(symbolName, tip), target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return button
    }

    @MainActor
    static func label(_ text: String = "", size: CGFloat = NSFont.systemFontSize, bold: Bool = false,
                      color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// 버튼 바로 아래에 메뉴를 띄운다.
    @MainActor
    static func popUp(_ menu: NSMenu, below view: NSView) {
        let y = view.isFlipped ? view.bounds.height + 2 : -2
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }

    @MainActor
    static func pin(_ child: NSView, to parent: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

/// 시스템 파일 아이콘 캐시 (V10).
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for url: URL) -> NSImage {
        let key = url.path
        if let image = cache[key] { return image }
        let image = NSWorkspace.shared.icon(forFile: key)
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = image
        return image
    }

    func invalidate() { cache.removeAll() }
}

@MainActor
enum Formats {
    /// Windows 자세히 보기 식 날짜: "2026-11-01 오후 3:24".
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy-MM-dd a h:mm"
        return f
    }()

    static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 EEEE, a h:mm:ss"
        return f
    }()

    static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func dateString(_ date: Date?) -> String { date.map { Formats.date.string(from: $0) } ?? "" }

    static func bytes(_ value: Int64) -> String {
        number.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 확장자 표시 끔(V5)이면 파일 이름에서 확장자를 뺀다.
    static func displayName(_ item: FileItem, showExtensions: Bool) -> String {
        if showExtensions || item.isNavigable || item.fileExtension.isEmpty { return item.name }
        let base = (item.name as NSString).deletingPathExtension
        return base.isEmpty ? item.name : base
    }

    /// 검색 결과의 "폴더" 열. 홈 아래는 ~ 로 줄인다.
    static func folderPath(_ url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

/// 백그라운드 작업 취소 플래그.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

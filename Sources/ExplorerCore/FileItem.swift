import Foundation
import UniformTypeIdentifiers

/// 목록에 표시되는 파일/폴더 한 항목.
public struct FileItem: Hashable, Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    /// .app 같은 번들. 탐색기에서는 파일처럼 취급한다(더블클릭 시 실행).
    public let isPackage: Bool
    public let isHidden: Bool
    public let isSymlink: Bool
    /// 파일 크기(바이트). 폴더는 nil.
    public let size: Int64?
    public let dateModified: Date?
    public let dateCreated: Date?
    /// "파일 폴더", "PNG 파일", "텍스트 문서" 같은 Windows 식 형식 설명.
    public let typeDescription: String
    /// 소문자 확장자, 없으면 "".
    public let fileExtension: String

    public init(url: URL, name: String, isDirectory: Bool, isPackage: Bool, isHidden: Bool,
                isSymlink: Bool, size: Int64?, dateModified: Date?, dateCreated: Date?,
                typeDescription: String, fileExtension: String) {
        self.url = url; self.name = name; self.isDirectory = isDirectory; self.isPackage = isPackage
        self.isHidden = isHidden; self.isSymlink = isSymlink; self.size = size
        self.dateModified = dateModified; self.dateCreated = dateCreated
        self.typeDescription = typeDescription; self.fileExtension = fileExtension
    }

    /// 폴더처럼 들어갈 수 있는 항목인가 (디렉터리이면서 패키지가 아님).
    public var isNavigable: Bool { isDirectory && !isPackage }

    /// 디스크에서 메타데이터를 읽어 만든다. 심볼릭 링크는 대상의 종류를 따른다.
    public static func load(_ url: URL) throws -> FileItem {
        let url = url.standardizedFileURL
        let own = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isHiddenKey])
        let target = own.isSymbolicLink == true ? url.resolvingSymlinksInPath() : url
        let values = try target.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .contentTypeKey
        ])
        let directory = values.isDirectory == true
        let package = values.isPackage == true
        let ext = url.pathExtension.lowercased()
        let type = values.contentType ?? UTType(filenameExtension: ext)
        return FileItem(
            url: url, name: url.lastPathComponent, isDirectory: directory, isPackage: package,
            isHidden: own.isHidden == true || url.lastPathComponent.hasPrefix("."),
            isSymlink: own.isSymbolicLink == true,
            size: directory ? nil : values.fileSize.map(Int64.init),
            dateModified: values.contentModificationDate, dateCreated: values.creationDate,
            typeDescription: directory && !package ? CL("파일 폴더") : (type?.localizedDescription ?? CL("파일")),
            fileExtension: ext
        )
    }
}

public enum DirectoryLister {
    /// 폴더의 직속 항목. showHidden=false 면 숨김(점 파일, hidden 플래그) 제외.
    public static func contents(of url: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isHiddenKey, .isDirectoryKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        return try urls.map { try FileItem.load($0) }.filter { showHidden || !$0.isHidden }
    }
}

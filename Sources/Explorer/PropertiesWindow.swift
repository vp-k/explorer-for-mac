import AppKit
import ExplorerCore

/// F13 속성 창. 폴더 크기는 백그라운드에서 재귀 계산한다.
@MainActor
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [PropertiesWindowController] = []

    static func show(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = PropertiesWindowController(urls: urls)
        openControllers.append(controller)
        controller.window?.center()
        controller.showWindow(nil)
    }

    private let urls: [URL]
    private let token = CancelToken()
    private let sizeValue = UI.label(L("계산 중…"))
    private let containsValue = UI.label(L("계산 중…"))

    private init(urls: [URL]) {
        self.urls = urls
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        build(in: panel)
        calculate()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(in panel: NSPanel) {
        let items = urls.compactMap { try? FileItem.load($0) }
        let single = urls.count == 1 ? items.first : nil
        let title = single?.name ?? L(count: urls.count)
        panel.title = L("%@ 속성", title)

        let icon = NSImageView(image: IconCache.shared.icon(for: urls[0]))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let nameField = NSTextField(string: title)
        nameField.isEditable = false
        nameField.isSelectable = true
        nameField.translatesAutoresizingMaskIntoConstraints = false

        var rows: [[NSView]] = [[icon, nameField]]
        let kinds = Set(items.map(\.typeDescription))
        rows.append([caption(L("종류:")), value(kinds.count == 1 ? kinds.first! : L("여러 종류"))])
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        rows.append([caption(L("위치:")), value(parents.count == 1 ? parents.first! : L("여러 위치"), selectable: true)])
        rows.append([caption(L("크기:")), sizeValue])
        if items.contains(where: \.isNavigable) || urls.count > 1 {
            rows.append([caption(L("내용:")), containsValue])
        }
        if let single {
            rows.append([caption(L("만든 날짜:")), value(single.dateCreated.map { Formats.longDate.string(from: $0) } ?? "")])
            rows.append([caption(L("수정한 날짜:")), value(single.dateModified.map { Formats.longDate.string(from: $0) } ?? "")])
            var attributes: [String] = []
            if single.isHidden { attributes.append(L("숨김")) }
            if single.isSymlink { attributes.append(L("바로 가기(심볼릭 링크)")) }
            if !FileManager.default.isWritableFile(atPath: single.url.path) { attributes.append(L("읽기 전용")) }
            if !attributes.isEmpty { rows.append([caption(L("특성:")), value(attributes.joined(separator: ", "))]) }
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 0).bottomPadding = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let ok = NSButton(title: L("확인"), target: self, action: #selector(closeWindow(_:)))
        ok.keyEquivalent = "\r"
        ok.translatesAutoresizingMaskIntoConstraints = false

        guard let content = panel.contentView else { return }
        content.addSubview(grid)
        content.addSubview(ok)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            ok.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            ok.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 20),
            ok.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func caption(_ text: String) -> NSTextField {
        UI.label(text, color: .secondaryLabelColor)
    }

    private func value(_ text: String, selectable: Bool = false) -> NSTextField {
        let field = UI.label(text)
        field.isSelectable = selectable
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = text
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        return field
    }

    private func calculate() {
        let urls = urls
        let token = token
        Task { [weak self] in
            let stats = await Task.detached(priority: .utility) {
                FolderSizeCalculator.stats(for: urls, isCancelled: { token.isCancelled })
            }.value
            guard let self, !token.isCancelled else { return }
            self.sizeValue.stringValue = L("%1$@ (%2$@ 바이트)", SizeFormatter.humanSize(stats.totalBytes), Formats.bytes(stats.totalBytes))
            self.containsValue.stringValue = L("파일 %1$@개, 폴더 %2$@개", Formats.bytes(Int64(stats.fileCount)), Formats.bytes(Int64(stats.folderCount)))
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.performClose(sender)
    }

    func windowWillClose(_ notification: Notification) {
        token.cancel()
        Self.openControllers.removeAll { $0 === self }
    }
}

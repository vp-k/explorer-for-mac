import AppKit
import ExplorerCore

/// N4·N5 주소 표시줄. 평소에는 경로 버튼, 편집 모드에서는 텍스트 입력.
@MainActor
final class AddressBar: NSView, NSTextFieldDelegate {
    var onNavigate: ((URL) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onEditingEnded: (() -> Void)?

    private let iconView = NSImageView()
    private let crumbStack = NSStackView()
    private let editField = NSTextField()
    private var path = ""
    private var crumbs: [Breadcrumb] = []
    private(set) var isEditing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.control
        layer?.borderWidth = 1
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("주소 표시줄"))

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        crumbStack.orientation = .horizontal
        crumbStack.spacing = 0
        crumbStack.detachesHiddenViews = true
        crumbStack.translatesAutoresizingMaskIntoConstraints = false
        crumbStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(crumbStack)

        editField.translatesAutoresizingMaskIntoConstraints = false
        editField.isBordered = false
        editField.drawsBackground = false
        editField.focusRingType = .none
        editField.font = .systemFont(ofSize: Theme.Font.body)
        editField.textColor = Theme.primaryText
        editField.lineBreakMode = .byTruncatingHead
        editField.cell?.isScrollable = true
        editField.delegate = self
        editField.isHidden = true
        editField.setAccessibilityLabel(L("주소"))
        addSubview(editField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.Metric.addressBoxHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            crumbStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            crumbStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            crumbStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            editField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            editField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            editField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// 평소에는 바탕색만, 편집 중에는 강조색 테두리 (DESIGN 2장 accent: 포커스 테두리).
    private func updateColors() {
        layer?.backgroundColor = Theme.cg(Theme.fieldBackground, in: self)
        layer?.borderColor = Theme.cg(isEditing ? Theme.accent : Theme.divider, in: self)
        layer?.borderWidth = isEditing ? 1.5 : 1
    }

    // MARK: 경로 버튼

    func setLocation(crumbs: [Breadcrumb], path: String, icon: NSImage) {
        let pathChanged = self.path != path
        self.crumbs = crumbs
        self.path = path
        iconView.image = icon
        for view in crumbStack.arrangedSubviews { view.removeFromSuperview() }
        for (index, crumb) in crumbs.enumerated() {
            // 경로 조각. 마우스를 올리면 hoverFill (DESIGN 4장).
            let button = ThemedButton(title: crumb.title, symbol: nil, target: self, action: #selector(crumbClicked(_:)))
            button.horizontalPadding = 6
            button.tag = index
            button.lineBreakMode = .byTruncatingMiddle
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.toolTip = crumb.url.path
            crumbStack.addArrangedSubview(button)

            // 조각 사이의 › . 누르면 하위 폴더 메뉴 (N4).
            let chevron = ThemedButton(title: "›", symbol: nil, target: self, action: #selector(chevronClicked(_:)))
            chevron.font = .systemFont(ofSize: 15, weight: .regular)
            chevron.horizontalPadding = 3
            chevron.fixedSize = NSSize(width: 18, height: 26)
            chevron.setAccessibilityLabel(L("하위 폴더"))
            chevron.tag = index
            chevron.toolTip = L("%@의 하위 폴더", crumb.title)
            crumbStack.addArrangedSubview(chevron)
            // 좁으면 앞쪽 조각부터 숨긴다.
            let priority = NSStackView.VisibilityPriority(rawValue: Float(500 + index * 10))
            crumbStack.setVisibilityPriority(index == crumbs.count - 1 ? .mustHold : priority, for: button)
            crumbStack.setVisibilityPriority(index == crumbs.count - 1 ? .mustHold : priority, for: chevron)
        }
        // 위치가 그대로면 편집 중인 입력을 덮어쓰지 않는다. 탭을 다시 붙일 때도 이 함수가 불린다.
        if isEditing, pathChanged { editField.stringValue = path }
    }

    @objc private func crumbClicked(_ sender: NSButton) {
        guard crumbs.indices.contains(sender.tag) else { return }
        onNavigate?(crumbs[sender.tag].url)
    }

    /// `>` 를 누르면 그 폴더의 하위 폴더 메뉴. 폴더는 백그라운드에서 읽고 다 읽으면 메뉴를 띄운다.
    @objc private func chevronClicked(_ sender: NSButton) {
        guard crumbs.indices.contains(sender.tag) else { return }
        let base = crumbs[sender.tag].url
        let showHidden = AppState.shared.showHidden
        let path = self.path
        Task { [weak self, weak sender] in
            let entries = await Task.detached(priority: .userInitiated) { () -> [(String, URL)] in
                if Location.isThisMac(base) {
                    return VolumeLister.volumes().map { ($0.name, $0.url) }
                }
                let folders = ((try? DirectoryLister.contents(of: base, showHidden: showHidden)) ?? []).filter(\.isNavigable)
                return FileSorter.sorted(folders, by: ExplorerCore.SortOrder()).map { ($0.name, $0.url) }
            }.value
            // 읽는 사이 다른 폴더로 갔거나 창이 닫혔으면 띄우지 않는다.
            guard let self, let sender, sender.window != nil, self.path == path, !self.isEditing else { return }
            self.showFolderMenu(entries, below: sender)
        }
    }

    /// 한 메뉴에 아이콘과 함께 넣는 폴더 수. 나머지는 잘라 버리지 않고 "더 보기" 하위 메뉴에 묶어 넣는다 (L2).
    private static let menuPageSize = 200

    private func showFolderMenu(_ entries: [(String, URL)], below sender: NSButton) {
        let menu = NSMenu()
        for (title, url) in entries.prefix(Self.menuPageSize) {
            addFolderItem(to: menu, title: title, url: url)
        }
        var rest = entries.dropFirst(Self.menuPageSize)
        if !rest.isEmpty {
            menu.addItem(.separator())
            var parent = menu
            while !rest.isEmpty {
                let page = rest.prefix(Self.menuPageSize)
                rest = rest.dropFirst(Self.menuPageSize)
                let more = NSMenuItem(title: L("더 보기 (%d개 더)", page.count + rest.count), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for (title, url) in page {
                    addFolderItem(to: submenu, title: title, url: url, icon: false)
                }
                more.submenu = submenu
                parent.addItem(more)
                if !rest.isEmpty { submenu.addItem(.separator()) }
                parent = submenu
            }
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: L("하위 폴더 없음"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        UI.popUp(menu, below: sender)
    }

    /// icon 이 false 면 파일마다 아이콘을 읽지 않고 일반 폴더 기호를 쓴다.
    private func addFolderItem(to menu: NSMenu, title: String, url: URL, icon withIcon: Bool = true) {
        let item = NSMenuItem(title: title, action: #selector(menuFolderChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        let icon = withIcon ? IconCache.shared.icon(for: url).copy() as? NSImage : UI.symbol("folder")
        icon?.size = NSSize(width: 16, height: 16)
        item.image = icon
        menu.addItem(item)
    }

    @objc private func menuFolderChosen(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onNavigate?(url) }
    }

    // MARK: 편집 모드

    /// 경로 버튼 사이 빈 곳을 누르면 편집 모드.
    override func mouseDown(with event: NSEvent) {
        if !isEditing { beginEditing() } else { super.mouseDown(with: event) }
    }

    func beginEditing(text: String? = nil) {
        isEditing = true
        crumbStack.isHidden = true
        editField.isHidden = false
        editField.stringValue = text ?? path
        updateColors()
        window?.makeFirstResponder(editField)
        editField.currentEditor()?.selectAll(nil)
    }

    /// 편집 중인 입력과 선택 범위. 탭을 바꿨다 돌아올 때 이어서 편집하는 데 쓴다.
    struct Draft {
        let text: String
        let selection: NSRange
    }

    var draft: Draft? {
        guard isEditing else { return nil }
        let editor = editField.currentEditor()
        let text = editor?.string ?? editField.stringValue
        return Draft(text: text, selection: editor?.selectedRange ?? NSRange(location: (text as NSString).length, length: 0))
    }

    func resumeEditing(_ draft: Draft) {
        beginEditing(text: draft.text)
        let length = (draft.text as NSString).length
        let location = min(draft.selection.location, length)
        editField.currentEditor()?.selectedRange = NSRange(location: location,
                                                           length: min(draft.selection.length, length - location))
    }

    private func endEditing() {
        guard isEditing else { return }
        isEditing = false
        editField.isHidden = true
        crumbStack.isHidden = false
        updateColors()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        let text = editField.stringValue
        endEditing()
        if movement == .return {
            onSubmit?(text)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            editField.stringValue = path
            endEditing()
            onEditingEnded?()
            return true
        }
        return false
    }
}

/// 오른쪽 둥근 검색 상자. NSSearchField 의 기본 테두리를 끄고 주소 상자와 같은 모양으로 감싼다.
@MainActor
final class SearchBox: NSView {
    let field: ThemedSearchField
    private var isFocused = false

    init(field: ThemedSearchField) {
        self.field = field
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.control
        translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: Theme.Font.body)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.Metric.addressBoxHeight),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        field.onFocusChange = { [weak self] focused in
            self?.isFocused = focused
            self?.updateColors()
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// 상자 어디를 눌러도 입력을 시작한다.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    private func updateColors() {
        layer?.backgroundColor = Theme.cg(Theme.fieldBackground, in: self)
        layer?.borderColor = Theme.cg(isFocused ? Theme.accent : Theme.divider, in: self)
        layer?.borderWidth = isFocused ? 1.5 : 1
    }
}

/// 입력을 시작하고 끝낼 때 알려 주는 검색 칸. 검색 상자 테두리 색에 쓴다.
@MainActor
final class ThemedSearchField: NSSearchField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

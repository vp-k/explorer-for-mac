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
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        setAccessibilityRole(.group)
        setAccessibilityLabel("주소 표시줄")

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
        editField.lineBreakMode = .byTruncatingHead
        editField.cell?.isScrollable = true
        editField.delegate = self
        editField.isHidden = true
        editField.setAccessibilityLabel("주소")
        addSubview(editField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            crumbStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            crumbStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            crumbStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            editField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
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

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = (isEditing ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).cgColor
        }
    }

    // MARK: 경로 버튼

    func setLocation(crumbs: [Breadcrumb], path: String, icon: NSImage) {
        self.crumbs = crumbs
        self.path = path
        iconView.image = icon
        for view in crumbStack.arrangedSubviews { view.removeFromSuperview() }
        for (index, crumb) in crumbs.enumerated() {
            let button = NSButton(title: crumb.title, target: self, action: #selector(crumbClicked(_:)))
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.tag = index
            button.lineBreakMode = .byTruncatingMiddle
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.toolTip = crumb.url.path
            crumbStack.addArrangedSubview(button)

            let chevron = NSButton(image: UI.symbol("chevron.right", "하위 폴더"), target: self,
                                   action: #selector(chevronClicked(_:)))
            chevron.bezelStyle = .accessoryBarAction
            chevron.showsBorderOnlyWhileMouseInside = true
            chevron.imageScaling = .scaleProportionallyDown
            chevron.tag = index
            chevron.toolTip = "\(crumb.title)의 하위 폴더"
            crumbStack.addArrangedSubview(chevron)
            // 좁으면 앞쪽 조각부터 숨긴다.
            let priority = NSStackView.VisibilityPriority(rawValue: Float(500 + index * 10))
            crumbStack.setVisibilityPriority(index == crumbs.count - 1 ? .mustHold : priority, for: button)
            crumbStack.setVisibilityPriority(index == crumbs.count - 1 ? .mustHold : priority, for: chevron)
        }
        if isEditing { editField.stringValue = path }
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
                return FileSorter.sorted(folders, by: ExplorerCore.SortOrder()).prefix(200).map { ($0.name, $0.url) }
            }.value
            // 읽는 사이 다른 폴더로 갔거나 창이 닫혔으면 띄우지 않는다.
            guard let self, let sender, sender.window != nil, self.path == path, !self.isEditing else { return }
            self.showFolderMenu(entries, below: sender)
        }
    }

    private func showFolderMenu(_ entries: [(String, URL)], below sender: NSButton) {
        let menu = NSMenu()
        for (title, url) in entries {
            addFolderItem(to: menu, title: title, url: url)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "하위 폴더 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        UI.popUp(menu, below: sender)
    }

    private func addFolderItem(to menu: NSMenu, title: String, url: URL) {
        let item = NSMenuItem(title: title, action: #selector(menuFolderChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        let icon = IconCache.shared.icon(for: url).copy() as? NSImage
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

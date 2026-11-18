import AppKit

/// 명령 모음: 새로 만들기, 잘라내기·복사·붙여넣기·이름 바꾸기·삭제, 정렬, 보기, 더 보기.
@MainActor
final class CommandBar: NSView {
    private weak var browser: BrowserViewController?
    private var newButton: NSButton!
    private var cutButton: NSButton!
    private var copyButton: NSButton!
    private var pasteButton: NSButton!
    private var renameButton: NSButton!
    private var deleteButton: NSButton!

    init(browser: BrowserViewController) {
        self.browser = browser
        super.init(frame: .zero)
        typealias B = BrowserViewController

        newButton = textButton("새로 만들기", symbol: "plus.circle", action: #selector(showNewMenu(_:)), target: self)
        cutButton = UI.toolButton("scissors", tip: "잘라내기 (⌘X)", target: browser, action: #selector(B.cut(_:)))
        copyButton = UI.toolButton("doc.on.doc", tip: "복사 (⌘C)", target: browser, action: #selector(B.copy(_:)))
        pasteButton = UI.toolButton("doc.on.clipboard", tip: "붙여넣기 (⌘V)", target: browser, action: #selector(B.paste(_:)))
        renameButton = UI.toolButton("pencil", tip: "이름 바꾸기 (F2)", target: browser, action: #selector(B.renameSelection(_:)))
        deleteButton = UI.toolButton("trash", tip: "삭제 (Delete)", target: browser, action: #selector(B.moveToTrash(_:)))
        let sortButton = textButton("정렬", symbol: "arrow.up.arrow.down", action: #selector(showSortMenu(_:)), target: self)
        let viewButton = textButton("보기", symbol: "rectangle.grid.1x2", action: #selector(showViewMenu(_:)), target: self)
        let moreButton = UI.toolButton("ellipsis", tip: "자세히 보기", target: self, action: #selector(showMoreMenu(_:)))

        let stack = NSStackView(views: [newButton, separator(), cutButton, copyButton, pasteButton, renameButton,
                                        deleteButton, separator(), sortButton, viewButton, separator(), moreButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func textButton(_ title: String, symbol: String, action: Selector, target: AnyObject) -> NSButton {
        let button = NSButton(title: title, image: UI.symbol(symbol, title), target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageLeading
        return button
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    func update(hasSelection: Bool, singleSelection: Bool, canPaste: Bool, canCreate: Bool) {
        newButton.isEnabled = canCreate
        cutButton.isEnabled = hasSelection
        copyButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        renameButton.isEnabled = singleSelection
        pasteButton.isEnabled = canPaste
    }

    @objc private func showNewMenu(_ sender: NSButton) {
        if let menu = browser?.newMenu() { UI.popUp(menu, below: sender) }
    }

    @objc private func showSortMenu(_ sender: NSButton) {
        if let menu = browser?.sortMenu() { UI.popUp(menu, below: sender) }
    }

    @objc private func showViewMenu(_ sender: NSButton) {
        if let menu = browser?.viewMenu() { UI.popUp(menu, below: sender) }
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        if let menu = browser?.moreMenu() { UI.popUp(menu, below: sender) }
    }
}

/// V6 상태 표시줄과 보기 전환 버튼.
@MainActor
final class StatusBar: NSView {
    var onModeChange: ((ViewMode) -> Void)?
    private let countLabel = UI.label("", size: NSFont.smallSystemFontSize)
    private let selectionLabel = UI.label("", size: NSFont.smallSystemFontSize)
    private let activityLabel = UI.label("", size: NSFont.smallSystemFontSize, color: .secondaryLabelColor)
    private let modeControl = NSSegmentedControl()

    override init(frame: NSRect) {
        super.init(frame: frame)
        modeControl.segmentCount = 2
        modeControl.setImage(UI.symbol("list.bullet", "자세히"), forSegment: 0)
        modeControl.setImage(UI.symbol("square.grid.2x2", "큰 아이콘"), forSegment: 1)
        modeControl.setToolTip("자세히 (⌘1)", forSegment: 0)
        modeControl.setToolTip("큰 아이콘 (⌘4)", forSegment: 1)
        modeControl.trackingMode = .selectOne
        modeControl.segmentStyle = .texturedSquare
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        for view in [countLabel, selectionLabel, activityLabel, modeControl] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionLabel.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 24),
            selectionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityLabel.leadingAnchor.constraint(equalTo: selectionLabel.trailingAnchor, constant: 24),
            activityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeControl.leadingAnchor, constant: -12),
            modeControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            modeControl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(count: Int, selectedCount: Int, selectedSize: String?) {
        countLabel.stringValue = "\(count)개 항목"
        if selectedCount > 0 {
            selectionLabel.stringValue = "\(selectedCount)개 항목 선택함" + (selectedSize.map { " \($0)" } ?? "")
        } else {
            selectionLabel.stringValue = ""
        }
    }

    func setActivity(_ text: String?) {
        activityLabel.stringValue = text ?? ""
    }

    func setMode(_ mode: ViewMode) {
        modeControl.selectedSegment = mode == .details ? 0 : (mode == .largeIcons ? 1 : -1)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        onModeChange?(sender.selectedSegment == 0 ? .details : .largeIcons)
    }
}

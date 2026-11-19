import AppKit

/// 명령 모음: "새로 만들기" 강조 버튼, 잘라내기·복사·붙여넣기·이름 바꾸기·삭제 아이콘 묶음, 구분선,
/// "정렬 ▾" "보기 ▾" "···" 순서 (DESIGN 1장).
@MainActor
final class CommandBar: FillView {
    private weak var browser: BrowserViewController?
    private var newButton: ThemedButton!
    private var cutButton: NSButton!
    private var copyButton: NSButton!
    private var pasteButton: NSButton!
    private var renameButton: NSButton!
    private var deleteButton: NSButton!

    init(browser: BrowserViewController) {
        self.browser = browser
        super.init(Theme.toolbarBackground)
        bottomDivider = true
        typealias B = BrowserViewController

        newButton = ThemedButton(title: "새로 만들기", symbol: Theme.symbol("plus", "새로 만들기", size: 12, weight: .semibold),
                                 target: self, action: #selector(showNewMenu(_:)))
        newButton.isAccent = true
        newButton.showsMenuIndicator = true
        newButton.horizontalPadding = 12
        newButton.font = .systemFont(ofSize: Theme.Font.body, weight: .medium)
        cutButton = UI.toolButton("scissors", tip: "잘라내기 (⌘X)", target: browser, action: #selector(B.cut(_:)))
        copyButton = UI.toolButton("doc.on.doc", tip: "복사 (⌘C)", target: browser, action: #selector(B.copy(_:)))
        pasteButton = UI.toolButton("doc.on.clipboard", tip: "붙여넣기 (⌘V)", target: browser, action: #selector(B.paste(_:)))
        renameButton = UI.toolButton("character.cursor.ibeam", tip: "이름 바꾸기 (F2)", target: browser,
                                     action: #selector(B.renameSelection(_:)))
        deleteButton = UI.toolButton("trash", tip: "삭제 (Delete)", target: browser, action: #selector(B.moveToTrash(_:)))
        let sortButton = textButton("정렬", symbol: "arrow.up.arrow.down", action: #selector(showSortMenu(_:)))
        let viewButton = textButton("보기", symbol: "rectangle.grid.1x2", action: #selector(showViewMenu(_:)))
        let moreButton = UI.toolButton("ellipsis", tip: "자세히 보기", target: self, action: #selector(showMoreMenu(_:)))

        let stack = NSStackView(views: [newButton, separator(), cutButton, copyButton, pasteButton, renameButton,
                                        deleteButton, separator(), sortButton, viewButton, separator(), moreButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.setCustomSpacing(10, after: newButton)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func textButton(_ title: String, symbol: String, action: Selector) -> ThemedButton {
        let button = ThemedButton(title: title, symbol: Theme.commandSymbol(symbol, title), target: self, action: action)
        button.showsMenuIndicator = true
        return button
    }

    private func separator() -> NSView {
        let line = FillView(Theme.divider)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 13),
            holder.heightAnchor.constraint(equalToConstant: 20),
            line.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
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

/// V6 상태 표시줄과 보기 전환 버튼. 높이 24, 글자 11 (DESIGN 4장).
@MainActor
final class StatusBar: FillView {
    var onModeChange: ((ViewMode) -> Void)?
    private let countLabel = UI.label("", size: Theme.Font.status)
    private let selectionLabel = UI.label("", size: Theme.Font.status)
    private let activityLabel = UI.label("", size: Theme.Font.status, color: Theme.secondaryText)
    private let detailsButton = ThemedButton(symbol: Theme.symbol("list.bullet", "자세히", size: 11), tip: "자세히 (⌘1)",
                                             target: nil, action: nil)
    private let iconsButton = ThemedButton(symbol: Theme.symbol("square.grid.2x2", "큰 아이콘", size: 11),
                                           tip: "큰 아이콘 (⌘4)", target: nil, action: nil)

    init() {
        super.init(Theme.contentBackground)
        topDivider = true
        for (button, tag) in [(detailsButton, 0), (iconsButton, 1)] {
            button.tag = tag
            button.target = self
            button.action = #selector(modeChanged(_:))
            button.fixedSize = NSSize(width: 26, height: 20)
            button.setAccessibilityRole(.radioButton)
        }
        let modeStack = NSStackView(views: [detailsButton, iconsButton])
        modeStack.spacing = 2
        modeStack.translatesAutoresizingMaskIntoConstraints = false

        for view in [countLabel, selectionLabel, activityLabel, modeStack] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionLabel.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 24),
            selectionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityLabel.leadingAnchor.constraint(equalTo: selectionLabel.trailingAnchor, constant: 24),
            activityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeStack.leadingAnchor, constant: -12),
            modeStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            modeStack.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        detailsButton.isToggled = mode == .details
        iconsButton.isToggled = mode == .largeIcons
        detailsButton.setAccessibilityValue(mode == .details)
        iconsButton.setAccessibilityValue(mode == .largeIcons)
    }

    @objc private func modeChanged(_ sender: NSButton) {
        onModeChange?(sender.tag == 0 ? .details : .largeIcons)
    }
}

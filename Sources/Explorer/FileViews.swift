import AppKit
import ExplorerCore

/// 자세히 보기 표. 키 입력, 우클릭, 가운데 클릭을 목록 컨트롤러로 넘긴다.
@MainActor
final class FileTableView: NSTableView {
    weak var listController: FileListController?
    /// 마우스를 올린 행. 없으면 -1.
    private(set) var hoveredRow = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["hover"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["hover": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHoveredRow(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(-1)
    }

    /// 스크롤하면 마우스 아래 행이 바뀐다.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(visibleRect.contains(point) ? row(at: point) : -1)
    }

    private func setHoveredRow(_ row: Int) {
        guard row != hoveredRow else { return }
        hoveredRow = row
        enumerateAvailableRowViews { view, index in (view as? ThemedRowView)?.isHovered = index == row }
    }

    override func keyDown(with event: NSEvent) {
        if listController?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
        return listController?.contextMenu(at: row >= 0 ? row : nil)
    }

    /// N8 가운데 클릭으로 폴더를 새 탭에 연다.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 { listController?.open(index: row, inNewTab: true) }
            return
        }
        super.otherMouseDown(with: event)
    }
}

/// 목록·아이콘 보기.
@MainActor
final class FileCollectionView: NSCollectionView {
    weak var listController: FileListController?
    private var typeBuffer = ""
    private var lastTypeTime: TimeInterval = 0

    override func keyDown(with event: NSEvent) {
        if listController?.handleKey(event) == true { return }
        if typeSelect(event) { return }
        super.keyDown(with: event)
    }

    private func typeSelect(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty, let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return false }
        if event.timestamp - lastTypeTime > 1 { typeBuffer = "" }
        lastTypeTime = event.timestamp
        typeBuffer += chars
        return listController?.typeSelect(typeBuffer) ?? false
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            listController?.open(index: indexPath.item, inNewTab: false)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
        return listController?.contextMenu(at: indexPath?.item)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            if let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
                listController?.open(index: indexPath.item, inNewTab: true)
            }
            return
        }
        super.otherMouseDown(with: event)
    }
}

/// 아이콘 보기 칸 하나. 목록 보기에서는 작은 아이콘과 이름을 가로로 놓는다.
@MainActor
final class FileIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileIconItem")
    private var mode: ViewMode = .mediumIcons

    static func itemSize(for mode: ViewMode) -> NSSize {
        switch mode {
        case .list: return NSSize(width: 240, height: Theme.Metric.rowHeight)
        case .mediumIcons, .details: return NSSize(width: 104, height: 100)
        case .largeIcons: return NSSize(width: 150, height: 160)
        }
    }

    private static func iconSide(for mode: ViewMode) -> CGFloat {
        switch mode {
        case .list: return 16
        case .mediumIcons, .details: return 48
        case .largeIcons: return 96
        }
    }

    override func loadView() {
        let container = FileIconCellView()
        container.wantsLayer = true
        container.layer?.cornerRadius = Theme.Radius.selection
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: Theme.Font.body)
        text.textColor = Theme.primaryText
        text.lineBreakMode = .byTruncatingTail
        container.addSubview(image)
        container.addSubview(text)
        container.owner = self
        imageView = image
        textField = text
        view = container
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    func configure(name: String, icon: NSImage, mode: ViewMode, alpha: CGFloat) {
        self.mode = mode
        imageView?.image = icon
        guard let text = textField else { return }
        text.stringValue = name
        text.toolTip = name
        if mode == .list {
            text.alignment = .left
            text.maximumNumberOfLines = 1
            text.cell?.wraps = false
        } else {
            text.alignment = .center
            text.maximumNumberOfLines = 2
            text.cell?.wraps = true
        }
        text.cell?.truncatesLastVisibleLine = true
        view.alphaValue = alpha
        view.needsLayout = true
        updateHighlight()
    }

    /// FileIconCellView.layout 에서 부른다.
    func layoutSubviews(in bounds: NSRect) {
        guard let image = imageView, let text = textField else { return }
        let side = Self.iconSide(for: mode)
        if mode == .list {
            image.frame = NSRect(x: 4, y: (bounds.height - side) / 2, width: side, height: side)
            text.frame = NSRect(x: side + 8, y: (bounds.height - 17) / 2, width: bounds.width - side - 12, height: 17)
        } else {
            let top = bounds.height - side - 8
            image.frame = NSRect(x: (bounds.width - side) / 2, y: top, width: side, height: side)
            text.frame = NSRect(x: 6, y: 4, width: bounds.width - 12, height: max(top - 6, 17))
        }
    }

    override var isSelected: Bool { didSet { updateHighlight() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateHighlight() } }
    var isHovered = false { didSet { if isHovered != oldValue { updateHighlight() } } }

    /// 카드 hover 와 선택 하이라이트 (DESIGN 4장 아이콘 보기). 창이 비활성이면 선택은 회색.
    func updateHighlight() {
        let selected = isSelected || highlightState == .forSelection
        let color: NSColor?
        if selected {
            let active = view.window?.isKeyWindow ?? true
            color = !active ? Theme.inactiveSelectionFill : (isHovered ? Theme.selectionHoverFill : Theme.selectionFill)
        } else {
            color = isHovered ? Theme.hoverFill : nil
        }
        view.layer?.backgroundColor = color.map { Theme.cg($0, in: view) }
    }
}

@MainActor
final class FileIconCellView: NSView {
    weak var owner: FileIconItem?
    override func layout() {
        super.layout()
        owner?.layoutSubviews(in: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { owner?.isHovered = true }
    override func mouseExited(with event: NSEvent) { owner?.isHovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.updateHighlight()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: name, object: window)
        }
        owner?.updateHighlight()
    }

    @objc private func windowKeyChanged(_ note: Notification) { owner?.updateHighlight() }
}

/// F3 인라인 이름 바꾸기. 확장자를 뺀 부분만 선택하고 Enter 로 확정, Esc 로 취소한다.
@MainActor
final class RenameEditor: NSObject, NSTextFieldDelegate {
    private let field: NSTextField
    private let original: String
    /// 확장자를 숨긴 상태(V5)면 확정할 때 다시 붙일 확장자.
    private let hiddenExtension: String
    private let selectLength: Int
    private var finished = false
    private var cancelling = false
    var onCommit: ((String) -> Void)?
    var onEnd: (() -> Void)?

    init(field: NSTextField, item: FileItem, showExtensions: Bool) {
        self.field = field
        let shown = Formats.displayName(item, showExtensions: showExtensions)
        original = shown
        hiddenExtension = shown == item.name ? "" : String(item.name.dropFirst(shown.count))
        if item.isNavigable || item.fileExtension.isEmpty || shown != item.name {
            selectLength = (shown as NSString).length
        } else {
            let base = (shown as NSString).deletingPathExtension
            selectLength = (base.isEmpty ? shown : base as String).utf16.count
        }
        super.init()
    }

    func begin() {
        field.stringValue = original
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = Theme.contentBackground
        field.isBezeled = false
        field.focusRingType = .exterior
        field.delegate = self
        guard field.window?.makeFirstResponder(field) == true else { finish(commit: false); return }
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: selectLength)
    }

    func cancel() {
        guard !finished else { return }
        cancelling = true
        field.abortEditing()
        finish(commit: false)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finish(commit: !cancelling)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.delegate = nil
        field.isEditable = false
        field.drawsBackground = false
        field.stringValue = original
        onEnd?()
        guard commit, !text.isEmpty, text != original else { return }
        let newName = text + hiddenExtension
        let handler = onCommit
        // 편집이 끝난 뒤 목록을 다시 읽도록 한 박자 늦춘다.
        DispatchQueue.main.async { handler?(newName) }
    }
}

/// 얇은 열 머리글: 바탕은 목록과 같고 열 사이와 아래에 구분선만 둔다 (DESIGN 4장).
@MainActor
final class ThemedHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.contentBackground.setFill()
        bounds.fill()
        super.draw(dirtyRect)
        Theme.divider.setFill()
        NSRect(x: 0, y: isFlipped ? bounds.maxY - 1 : 0, width: bounds.width, height: 1).fill()
    }
}

@MainActor
final class ThemedHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.contentBackground.setFill()
        cellFrame.fill()
        // 열 사이에만 구분선을 긋는다. 맨 오른쪽 열 끝은 비워 둔다.
        let table = (controlView as? NSTableHeaderView)?.tableView
        let isLast = table?.tableColumns.last(where: { !$0.isHidden })?.headerCell === self
        if !isLast {
            Theme.divider.setFill()
            NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 6, width: 1, height: cellFrame.height - 12).fill()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Theme.Font.secondary),
            .foregroundColor: Theme.secondaryText, .paragraphStyle: style,
        ]
        let titleRect = alignment == .right
            ? NSRect(x: cellFrame.minX + 24, y: cellFrame.midY - 8, width: cellFrame.width - 24 - Theme.Space.l, height: 16)
            : NSRect(x: cellFrame.minX + 10, y: cellFrame.midY - 8, width: cellFrame.width - 34, height: 16)
        (stringValue as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: attributes)
        guard let table = (controlView as? NSTableHeaderView)?.tableView,
              let column = table.tableColumns.first(where: { $0.headerCell === self }),
              let key = column.sortDescriptorPrototype?.key,
              let descriptor = table.sortDescriptors.first, descriptor.key == key else { return }
        // 정렬 중인 열: 작은 꺾쇠.
        let name = descriptor.ascending ? "chevron.up" : "chevron.down"
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            .applying(.init(paletteColors: [Theme.secondaryText]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        let x = alignment == .right ? cellFrame.minX + 8 : cellFrame.maxX - size.width - 10
        image.draw(in: NSRect(x: x, y: cellFrame.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

import AppKit
import ExplorerCore

/// 자세히 보기 표. 키 입력, 우클릭, 가운데 클릭을 목록 컨트롤러로 넘긴다.
@MainActor
final class FileTableView: NSTableView {
    weak var listController: FileListController?

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
        case .list: return NSSize(width: 240, height: 22)
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
        container.layer?.cornerRadius = 4
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        container.addSubview(image)
        container.addSubview(text)
        container.owner = self
        imageView = image
        textField = text
        view = container
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
            let top = bounds.height - side - 6
            image.frame = NSRect(x: (bounds.width - side) / 2, y: top, width: side, height: side)
            text.frame = NSRect(x: 4, y: 2, width: bounds.width - 8, height: max(top - 4, 17))
        }
    }

    override var isSelected: Bool { didSet { updateHighlight() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateHighlight() } }

    private func updateHighlight() {
        let on = isSelected || highlightState == .forSelection
        view.layer?.backgroundColor = on ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).cgColor : nil
    }
}

@MainActor
final class FileIconCellView: NSView {
    weak var owner: FileIconItem?
    override func layout() {
        super.layout()
        owner?.layoutSubviews(in: bounds)
    }
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
        field.backgroundColor = .textBackgroundColor
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

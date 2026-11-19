import AppKit
import ExplorerCore

/// N10 내 Mac 화면: "폴더"와 "장치 및 드라이브" 두 구역 (DESIGN 4장).
@MainActor
final class ThisMacView: NSView {
    var onOpen: ((URL) -> Void)?
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private let stack = NSStackView()
    private(set) var itemCount = 0

    /// 내 Mac 아이콘. 탭, 주소 상자, 탐색 창이 함께 쓴다.
    static var computerIcon: NSImage {
        let image = Theme.symbol("desktopcomputer", L("내 Mac"), size: 13)
        return image.withSymbolConfiguration(.init(paletteColors: [Theme.accent])) ?? image
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.contentBackground
        UI.pin(scroll, to: self)
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        let folders = Location.standardFolders
        let volumes = VolumeLister.volumes()
        itemCount = folders.count + volumes.count

        addSection(L("폴더 (%d)", folders.count))
        addRows(folders.map { folder in
            CardView(title: folder.title, subtitle: nil, icon: IconCache.shared.icon(for: folder.url),
                     url: folder.url, volume: nil)
        })
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last ?? stack)
        addSection(L("장치 및 드라이브 (%d)", volumes.count))
        addRows(volumes.map { volume in
            CardView(title: volume.name, subtitle: CapacityBar.caption(for: volume),
                     icon: IconCache.shared.icon(for: volume.url), url: volume.url, volume: volume)
        })
    }

    /// 구역 제목과 그 오른쪽으로 이어지는 구분선.
    private func addSection(_ title: String) {
        let label = UI.label(title, size: Theme.Font.body, bold: true)
        let line = FillView(Theme.divider)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let header = NSStackView(views: [label, line])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }

    private func addRows(_ cards: [CardView]) {
        for card in cards { card.onOpen = { [weak self] url in self?.onOpen?(url) } }
        let perRow = 3
        var index = 0
        while index < cards.count {
            let row = NSStackView(views: Array(cards[index..<min(index + perRow, cards.count)]))
            row.orientation = .horizontal
            row.spacing = 8
            stack.addArrangedSubview(row)
            index += perRow
        }
    }
}

@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 폴더·드라이브 카드. 마우스를 올리면 hoverFill, 클릭하면 연다.
/// 드라이브 카드는 아이콘, 이름, 용량 막대, "N GB 중 M GB 사용 가능" (DESIGN 4장).
@MainActor
final class CardView: NSView {
    var onOpen: ((URL) -> Void)?
    private let url: URL
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(title: String, subtitle: String?, icon: NSImage, url: URL, volume: VolumeInfo?) {
        self.url = url
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        toolTip = url.path

        let image = NSImageView(image: icon)
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        let name = UI.label(title, size: Theme.Font.body)
        let column = NSStackView(views: [name])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.translatesAutoresizingMaskIntoConstraints = false
        if let volume {
            let bar = CapacityBar(volume: volume)
            column.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalToConstant: 180).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        }
        if let subtitle {
            column.addArrangedSubview(UI.label(subtitle, size: Theme.Font.secondary, color: Theme.secondaryText))
        }
        addSubview(image)
        addSubview(column)
        let side: CGFloat = volume == nil ? 40 : 44
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: volume == nil ? 240 : 280),
            heightAnchor.constraint(equalToConstant: volume == nil ? 56 : 72),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: side),
            image.heightAnchor.constraint(equalToConstant: side),
            column.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 12),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered || isPressed else { return }
        (isPressed ? Theme.pressedFill : Theme.hoverFill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.card, yRadius: Theme.Radius.card).fill()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?(url) }
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func accessibilityPerformPress() -> Bool {
        onOpen?(url)
        return true
    }
}

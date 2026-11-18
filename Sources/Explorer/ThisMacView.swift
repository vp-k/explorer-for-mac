import AppKit
import ExplorerCore

/// N10 내 Mac 화면: 표준 폴더와 드라이브 카드(용량 막대).
@MainActor
final class ThisMacView: NSView {
    var onOpen: ((URL) -> Void)?
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private let stack = NSStackView()
    private(set) var itemCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        UI.pin(scroll, to: self)
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        let folders = Location.standardFolders
        let volumes = VolumeLister.volumes()
        itemCount = folders.count + volumes.count

        stack.addArrangedSubview(UI.label("폴더 (\(folders.count))", bold: true))
        addRows(folders.map { folder in
            CardView(title: folder.title, subtitle: nil, icon: IconCache.shared.icon(for: folder.url),
                     url: folder.url, volume: nil)
        })
        stack.addArrangedSubview(UI.label("장치 및 드라이브 (\(volumes.count))", bold: true))
        addRows(volumes.map { volume in
            CardView(title: volume.name, subtitle: CapacityBar.caption(for: volume),
                     icon: IconCache.shared.icon(for: volume.url), url: volume.url, volume: volume)
        })
    }

    private func addRows(_ cards: [CardView]) {
        for card in cards { card.onOpen = { [weak self] url in self?.onOpen?(url) } }
        let perRow = 3
        var index = 0
        while index < cards.count {
            let row = NSStackView(views: Array(cards[index..<min(index + perRow, cards.count)]))
            row.orientation = .horizontal
            row.spacing = 10
            stack.addArrangedSubview(row)
            index += perRow
        }
    }
}

@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 폴더·드라이브 카드. 클릭하면 연다.
@MainActor
final class CardView: NSView {
    var onOpen: ((URL) -> Void)?
    private let url: URL

    init(title: String, subtitle: String?, icon: NSImage, url: URL, volume: VolumeInfo?) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        toolTip = url.path

        let image = NSImageView(image: icon)
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        let name = UI.label(title)
        let column = NSStackView(views: [name])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        if let volume {
            let bar = CapacityBar(volume: volume)
            column.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalToConstant: 170).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 8).isActive = true
        }
        if let subtitle {
            column.addArrangedSubview(UI.label(subtitle, size: NSFont.smallSystemFontSize, color: .secondaryLabelColor))
        }
        addSubview(image)
        addSubview(column)
        let side: CGFloat = volume == nil ? 32 : 40
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 250),
            heightAnchor.constraint(equalToConstant: volume == nil ? 48 : 64),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: side),
            image.heightAnchor.constraint(equalToConstant: side),
            column.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?(url) }
    }

    override func mouseDown(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        onOpen?(url)
        return true
    }
}

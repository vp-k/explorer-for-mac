import AppKit

/// 제목 표시줄 자리의 탭 줄 (DESIGN 4장). 탭마다 폴더 아이콘, 이름, 닫기 버튼이 있고 끝에 "+" 버튼이 있다.
/// 활성 탭은 아래 도구 영역과 같은 색으로 이어진다. 빈 곳을 끌면 창이 움직이고 두 번 누르면 확대/축소한다.
/// 탭은 하위 뷰 없이 직접 그리고 누른 위치로 어느 부분인지 가린다.
@MainActor
final class TabStripView: NSView {
    struct Tab {
        var title: String
        var icon: NSImage
        var toolTip: String
    }

    /// 탭 내용(아이콘·이름)의 세로 중심. 신호등 버튼도 이 높이에 맞춘다.
    static let tabCenterFromTop: CGFloat = 23
    /// 신호등 버튼이 차지하는 왼쪽 폭.
    static let trafficLightInset: CGFloat = 84
    private static let tabTop: CGFloat = 6
    private static let maxTabWidth: CGFloat = 240
    private static let minTabWidth: CGFloat = 72
    private static let plusWidth: CGFloat = 36

    var tabs: [Tab] = [] { didSet { tabsChanged() } }
    var selectedIndex = 0 { didSet { needsDisplay = true; updateAccessibility() } }
    var leadingInset: CGFloat = TabStripView.trafficLightInset { didSet { needsDisplay = true; updateToolTips() } }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?

    private enum Part: Equatable { case tab(Int), close(Int), plus, none }
    private var hovered: Part = .none { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed: Part = .none { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var accessibilityTabs: [TabAccessibilityElement] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("탭")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 배치

    private var tabWidth: CGFloat {
        let available = bounds.width - leadingInset - Self.plusWidth - 16
        guard !tabs.isEmpty else { return Self.maxTabWidth }
        return max(Self.minTabWidth, min(Self.maxTabWidth, (available / CGFloat(tabs.count)).rounded(.down)))
    }

    private func tabRect(_ index: Int) -> NSRect {
        NSRect(x: leadingInset + CGFloat(index) * tabWidth, y: Self.tabTop,
               width: tabWidth, height: bounds.height - Self.tabTop)
    }

    private func closeRect(_ index: Int) -> NSRect {
        let tab = tabRect(index)
        return NSRect(x: tab.maxX - 30, y: Self.tabCenterFromTop - 11, width: 22, height: 22)
    }

    private func showsClose(_ index: Int) -> Bool {
        index == selectedIndex || tabWidth >= 110 || hovered == .tab(index) || hovered == .close(index)
    }

    private var plusRect: NSRect {
        let x = tabs.isEmpty ? leadingInset : tabRect(tabs.count - 1).maxX + 4
        return NSRect(x: x, y: Self.tabCenterFromTop - 14, width: Self.plusWidth - 4, height: 28)
    }

    private func part(at point: NSPoint) -> Part {
        if plusRect.contains(point) { return .plus }
        for index in tabs.indices where tabRect(index).contains(point) {
            if showsClose(index), closeRect(index).insetBy(dx: -2, dy: -2).contains(point) { return .close(index) }
            return .tab(index)
        }
        return .none
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateToolTips()
        updateAccessibility()
    }

    private func tabsChanged() {
        if case .tab(let i) = hovered, i >= tabs.count { hovered = .none }
        if case .close(let i) = hovered, i >= tabs.count { hovered = .none }
        needsDisplay = true
        updateToolTips()
        updateAccessibility()
    }

    private func updateToolTips() {
        removeAllToolTips()
        for (index, tab) in tabs.enumerated() { addToolTip(tabRect(index), owner: tab.toolTip as NSString, userData: nil) }
        addToolTip(plusRect, owner: "새 탭 (⌘T)" as NSString, userData: nil)
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        let active = window?.isKeyWindow ?? true
        for index in tabs.indices where index != selectedIndex { drawTab(index, active: active) }
        if tabs.indices.contains(selectedIndex) { drawTab(selectedIndex, active: active) }
        drawPlus()
    }

    private func drawTab(_ index: Int, active: Bool) {
        let rect = tabRect(index)
        let selected = index == selectedIndex
        if selected {
            let path = Self.activeTabPath(rect)
            Theme.toolbarBackground.setFill()
            path.fill()
            Theme.divider.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            if hovered == .tab(index) || hovered == .close(index) || pressed == .tab(index) {
                let fill = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 3).offsetBy(dx: 0, dy: -3),
                                        xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
                Theme.hoverFill.setFill()
                fill.fill()
            } else if index + 1 != selectedIndex, index + 1 < tabs.count,
                      hovered != .tab(index + 1), hovered != .close(index + 1) {
                // 이웃한 비활성 탭 사이의 짧은 구분선.
                Theme.divider.setFill()
                NSRect(x: rect.maxX - 0.5, y: Self.tabCenterFromTop - 8, width: 1, height: 16).fill()
            }
        }

        let tab = tabs[index]
        let iconRect = NSRect(x: rect.minX + 12, y: Self.tabCenterFromTop - 8, width: 16, height: 16)
        tab.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: active || selected ? 1 : 0.7,
                      respectFlipped: true, hints: nil)

        let close = showsClose(index)
        let textRight = close ? closeRect(index).minX - 4 : rect.maxX - 10
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let color = selected ? Theme.primaryText : Theme.primaryText.withAlphaComponent(0.78)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Theme.Font.secondary, weight: selected ? .medium : .regular),
            .foregroundColor: active ? color : Theme.secondaryText, .paragraphStyle: style,
        ]
        let textHeight: CGFloat = 16
        let textRect = NSRect(x: iconRect.maxX + 8, y: Self.tabCenterFromTop - textHeight / 2,
                              width: max(0, textRight - iconRect.maxX - 8), height: textHeight)
        (tab.title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: attributes)

        if close {
            let closeRect = closeRect(index)
            if hovered == .close(index) || pressed == .close(index) {
                (pressed == .close(index) ? Theme.pressedFill : Theme.hoverFill).setFill()
                NSBezierPath(roundedRect: closeRect, xRadius: 4, yRadius: 4).fill()
            }
            drawSymbol("xmark", size: 10, in: closeRect, color: Theme.primaryText.withAlphaComponent(0.85))
        }
    }

    /// 위 모서리는 둥글고 아래 양끝은 바깥으로 휘어 도구 영역과 이어지는 활성 탭 모양.
    private static func activeTabPath(_ rect: NSRect) -> NSBezierPath {
        let r = Theme.Radius.card, flare: CGFloat = 6
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX - flare, y: rect.maxY))
        path.curve(to: NSPoint(x: rect.minX, y: rect.maxY - flare),
                   controlPoint1: NSPoint(x: rect.minX, y: rect.maxY), controlPoint2: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + r))
        path.curve(to: NSPoint(x: rect.minX + r, y: rect.minY),
                   controlPoint1: NSPoint(x: rect.minX, y: rect.minY), controlPoint2: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
        path.curve(to: NSPoint(x: rect.maxX, y: rect.minY + r),
                   controlPoint1: NSPoint(x: rect.maxX, y: rect.minY), controlPoint2: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - flare))
        path.curve(to: NSPoint(x: rect.maxX + flare, y: rect.maxY),
                   controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY), controlPoint2: NSPoint(x: rect.maxX, y: rect.maxY))
        // 아래 변은 열어 두어 구분선이 그려지지 않게 한다.
        return path
    }

    private func drawPlus() {
        let rect = plusRect
        if hovered == .plus || pressed == .plus {
            (pressed == .plus ? Theme.pressedFill : Theme.hoverFill).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control).fill()
        }
        drawSymbol("plus", size: 13, in: rect, color: Theme.primaryText)
    }

    private func drawSymbol(_ name: String, size: CGFloat, in rect: NSRect, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: name, object: window)
        }
    }

    @objc private func windowKeyChanged(_ note: Notification) { needsDisplay = true }

    override func mouseMoved(with event: NSEvent) {
        hovered = part(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { hovered = .none }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = part(at: point)
        switch hit {
        case .none:
            if event.clickCount == 2 {
                Self.performTitlebarDoubleClick(window)
            } else {
                window?.performDrag(with: event)
            }
        case .tab(let index):
            onSelect?(index)
            trackTabDrag(from: index, event: event)
        case .close, .plus:
            trackButton(hit)
        }
    }

    /// 탭을 좌우로 끌어 순서를 바꾼다.
    private func trackTabDrag(from index: Int, event: NSEvent) {
        guard tabs.count > 1, let window else { return }
        var current = index
        let startX = convert(event.locationInWindow, from: nil).x
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let x = convert(next.locationInWindow, from: nil).x
            guard abs(x - startX) > 4 else { continue }
            let target = Int(((x - leadingInset) / tabWidth).rounded(.down))
            let clamped = max(0, min(tabs.count - 1, target))
            if clamped != current {
                onMove?(current, clamped)
                current = clamped
            }
        }
    }

    private func trackButton(_ hit: Part) {
        guard let window else { return }
        pressed = hit
        var inside = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = part(at: convert(next.locationInWindow, from: nil)) == hit
            pressed = inside ? hit : .none
            if next.type == .leftMouseUp { break }
        }
        pressed = .none
        guard inside else { return }
        switch hit {
        case .close(let index): onClose?(index)
        case .plus: onNew?()
        default: break
        }
    }

    /// N8 가운데 클릭으로 탭을 닫는다.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        switch part(at: convert(event.locationInWindow, from: nil)) {
        case .tab(let index), .close(let index): onClose?(index)
        case .none: onNew?()
        default: break
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
    }

    /// 시스템 설정(제목 표시줄을 두 번 클릭)을 따른다.
    static func performTitlebarDoubleClick(_ window: NSWindow?) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.performMiniaturize(nil)
        case "None": break
        default: window?.performZoom(nil)
        }
    }

    // MARK: 손쉬운 사용

    private func updateAccessibility() {
        accessibilityTabs = tabs.indices.map { index in
            let element = TabAccessibilityElement(strip: self, index: index)
            element.setAccessibilityLabel(tabs[index].title)
            element.setAccessibilityFrameInParentSpace(tabRect(index))
            element.setAccessibilityValue(index == selectedIndex ? 1 : 0)
            return element
        }
        setAccessibilityChildren(accessibilityTabs)
    }

    fileprivate func pressTab(_ index: Int) { onSelect?(index) }
}

@MainActor
private final class TabAccessibilityElement: NSAccessibilityElement {
    weak var strip: TabStripView?
    let index: Int

    init(strip: TabStripView, index: Int) {
        self.strip = strip
        self.index = index
        super.init()
        setAccessibilityParent(strip)
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(.tabButtonSubrole)
    }

    override func accessibilityPerformPress() -> Bool {
        strip?.pressTab(index)
        return true
    }
}

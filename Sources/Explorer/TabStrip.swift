import AppKit

/// 제목 표시줄 자리의 탭 줄 (DESIGN 4장). 탭마다 폴더 아이콘, 이름, 닫기 버튼이 있고 끝에 "+" 버튼이 있다.
/// 활성 탭은 아래 도구 영역과 같은 색으로 이어진다. 빈 곳을 끌면 창이 움직이고 두 번 누르면 확대/축소한다.
/// 탭은 하위 뷰 없이 직접 그리고 누른 위치로 어느 부분인지 가린다.
/// 탭이 많으면 최소 폭까지 줄이고, 그래도 넘치면 탭 영역만 가로로 스크롤한다. "+" 버튼은 오른쪽 끝에 고정하고
/// 활성 탭은 항상 보이게 스크롤을 맞춘다 (RD-M2). 넘칠 때만 탭 영역 양끝에 좌우 화살표 버튼이 생긴다 (DESIGN 6장).
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
    /// 활성 탭은 닫기 버튼이 늘 보이므로 이름이 몇 글자 보이도록 더 넓게 둔다.
    private static let minSelectedTabWidth: CGFloat = 128
    private static let plusWidth: CGFloat = 36
    private static let arrowWidth: CGFloat = 28

    var tabs: [Tab] = [] { didSet { tabsChanged() } }
    var selectedIndex = 0 { didSet { layoutChanged() } }
    var leadingInset: CGFloat = TabStripView.trafficLightInset { didSet { layoutChanged() } }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?

    private enum Part: Equatable { case tab(Int), close(Int), plus, scrollLeft, scrollRight, none }
    private var hovered: Part = .none { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed: Part = .none { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var accessibilityTabs: [TabAccessibilityElement] = []
    /// 탭이 넘칠 때 탭 영역을 왼쪽으로 민 정도.
    private var scrollOffset: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(L("탭"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 배치

    /// "+" 버튼 자리를 뺀 폭. 화살표 버튼 자리는 빼기 전이다.
    private var stripWidth: CGFloat {
        max(0, bounds.width - leadingInset - Self.plusWidth - 16)
    }

    /// 최소 폭으로 줄여도 탭이 다 들어가지 않는다. 이때만 좌우 화살표를 보인다.
    private var overflows: Bool {
        guard !tabs.isEmpty else { return false }
        return CGFloat(tabs.count - 1) * Self.minTabWidth + Self.minSelectedTabWidth > stripWidth
    }

    /// 첫 탭이 시작하는 x. 넘치면 왼쪽 화살표 자리만큼 민다.
    private var tabsStart: CGFloat {
        leadingInset + (overflows ? Self.arrowWidth : 0)
    }

    /// 탭을 놓을 수 있는 폭. "+" 버튼과 화살표 자리는 뺀다.
    private var availableWidth: CGFloat {
        max(0, stripWidth - (overflows ? Self.arrowWidth * 2 : 0))
    }

    /// 비활성 탭 폭. 모든 탭이 같은 폭이지만 활성 탭이 최소 폭보다 좁아지면 활성 탭만 넓힌다.
    private var tabWidth: CGFloat {
        guard !tabs.isEmpty else { return Self.maxTabWidth }
        let even = (availableWidth / CGFloat(tabs.count)).rounded(.down)
        guard even < Self.minSelectedTabWidth, tabs.count > 1 else {
            return max(Self.minTabWidth, min(Self.maxTabWidth, even))
        }
        let rest = ((availableWidth - Self.minSelectedTabWidth) / CGFloat(tabs.count - 1)).rounded(.down)
        return max(Self.minTabWidth, min(Self.maxTabWidth, rest))
    }

    private var selectedTabWidth: CGFloat {
        max(tabWidth, min(Self.minSelectedTabWidth, availableWidth))
    }

    private func width(of index: Int) -> CGFloat {
        index == selectedIndex ? selectedTabWidth : tabWidth
    }

    /// 스크롤 전 탭의 왼쪽 위치. 활성 탭 뒤의 탭은 넓어진 만큼 민다.
    private func tabStart(_ index: Int) -> CGFloat {
        CGFloat(index) * tabWidth + (index > selectedIndex ? selectedTabWidth - tabWidth : 0)
    }

    private var totalTabsWidth: CGFloat {
        tabs.isEmpty ? 0 : tabStart(tabs.count - 1) + width(of: tabs.count - 1)
    }

    private var maxScrollOffset: CGFloat {
        max(0, totalTabsWidth - availableWidth)
    }

    /// 탭이 보이는 영역. 넘치는 탭은 이 밖으로 잘린다. 활성 탭 아래 양끝의 휜 부분만큼 왼쪽을 더 둔다.
    private var tabArea: NSRect {
        NSRect(x: tabsStart - 6, y: 0, width: availableWidth + 8, height: bounds.height)
    }

    private func tabRect(_ index: Int) -> NSRect {
        NSRect(x: tabsStart + tabStart(index) - scrollOffset, y: Self.tabTop,
               width: width(of: index), height: bounds.height - Self.tabTop)
    }

    private func closeRect(_ index: Int) -> NSRect {
        let tab = tabRect(index)
        return NSRect(x: tab.maxX - 30, y: Self.tabCenterFromTop - 11, width: 22, height: 22)
    }

    private func showsClose(_ index: Int) -> Bool {
        index == selectedIndex || tabWidth >= 110 || hovered == .tab(index) || hovered == .close(index)
    }

    private var plusRect: NSRect {
        let x = tabs.isEmpty ? leadingInset
            : overflows ? rightArrowRect.maxX + 4 : min(tabRect(tabs.count - 1).maxX, tabsStart + availableWidth) + 4
        return NSRect(x: x, y: Self.tabCenterFromTop - 14, width: Self.plusWidth - 4, height: 28)
    }

    private var leftArrowRect: NSRect {
        NSRect(x: leadingInset, y: Self.tabCenterFromTop - 12, width: Self.arrowWidth - 4, height: 24)
    }

    private var rightArrowRect: NSRect {
        NSRect(x: tabsStart + availableWidth + 4, y: Self.tabCenterFromTop - 12, width: Self.arrowWidth - 4, height: 24)
    }

    private func part(at point: NSPoint) -> Part {
        if plusRect.contains(point) { return .plus }
        if overflows {
            if leftArrowRect.contains(point) { return .scrollLeft }
            if rightArrowRect.contains(point) { return .scrollRight }
        }
        guard tabArea.contains(point) else { return .none }
        for index in tabs.indices where tabRect(index).contains(point) {
            if showsClose(index), closeRect(index).insetBy(dx: -2, dy: -2).contains(point) { return .close(index) }
            return .tab(index)
        }
        return .none
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChanged()
    }

    private func tabsChanged() {
        if case .tab(let i) = hovered, i >= tabs.count { hovered = .none }
        if case .close(let i) = hovered, i >= tabs.count { hovered = .none }
        layoutChanged()
    }

    /// 폭이나 탭 수가 바뀌었다. 스크롤을 다시 맞추고 다시 그린다.
    private func layoutChanged() {
        revealSelected()
        needsDisplay = true
        updateToolTips()
        updateAccessibility()
    }

    /// 활성 탭이 탭 영역 안에 다 보이도록 스크롤한다.
    private func revealSelected() {
        var offset = min(scrollOffset, maxScrollOffset)
        if tabs.indices.contains(selectedIndex) {
            let start = tabStart(selectedIndex), end = start + selectedTabWidth
            if start < offset { offset = start }
            if end > offset + availableWidth { offset = end - availableWidth }
        }
        setScrollOffset(offset)
    }

    private func setScrollOffset(_ offset: CGFloat) {
        let clamped = max(0, min(maxScrollOffset, offset.rounded()))
        guard clamped != scrollOffset else { return }
        scrollOffset = clamped
        needsDisplay = true
        updateToolTips()
        updateAccessibility()
    }

    /// 탭이 넘칠 때 휠이나 트랙패드로 탭 영역을 좌우로 민다.
    override func scrollWheel(with event: NSEvent) {
        guard maxScrollOffset > 0 else { return super.scrollWheel(with: event) }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let step = event.hasPreciseScrollingDeltas ? delta : delta * 20
        setScrollOffset(scrollOffset - step)
        hovered = part(at: convert(event.locationInWindow, from: nil))
    }

    private func updateToolTips() {
        removeAllToolTips()
        let area = tabArea
        for (index, tab) in tabs.enumerated() {
            let rect = tabRect(index).intersection(area)
            if !rect.isEmpty { addToolTip(rect, owner: tab.toolTip as NSString, userData: nil) }
        }
        addToolTip(plusRect, owner: L("새 탭 (⌘T)") as NSString, userData: nil)
        if overflows {
            addToolTip(leftArrowRect, owner: L("이전 탭 보기") as NSString, userData: nil)
            addToolTip(rightArrowRect, owner: L("다음 탭 보기") as NSString, userData: nil)
        }
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        let active = window?.isKeyWindow ?? true
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: tabArea).addClip()
        for index in tabs.indices where index != selectedIndex { drawTab(index, active: active) }
        if tabs.indices.contains(selectedIndex) { drawTab(selectedIndex, active: active) }
        NSGraphicsContext.restoreGraphicsState()
        if overflows {
            drawButton(.scrollLeft, symbol: "chevron.left", in: leftArrowRect, enabled: scrollOffset > 0)
            drawButton(.scrollRight, symbol: "chevron.right", in: rightArrowRect, enabled: scrollOffset < maxScrollOffset)
        }
        drawButton(.plus, symbol: "plus", in: plusRect, enabled: true)
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

    /// "+" 와 좌우 화살표 버튼. 끝까지 밀었으면 화살표를 흐리게 그린다.
    private func drawButton(_ part: Part, symbol: String, in rect: NSRect, enabled: Bool) {
        if enabled, hovered == part || pressed == part {
            (pressed == part ? Theme.pressedFill : Theme.hoverFill).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control).fill()
        }
        let color = enabled ? Theme.primaryText : Theme.primaryText.withAlphaComponent(Theme.disabledAlpha)
        drawSymbol(symbol, size: part == .plus ? 13 : 11, in: rect, color: color)
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
        case .close, .plus, .scrollLeft, .scrollRight:
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
            let offset = x - tabsStart + scrollOffset
            let target = tabs.indices.last { tabStart($0) <= offset } ?? 0
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
        case .scrollLeft: setScrollOffset(scrollOffset - tabWidth)
        case .scrollRight: setScrollOffset(scrollOffset + tabWidth)
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

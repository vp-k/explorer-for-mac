import AppKit

/// 디자인 기준서(docs/DESIGN.md) 2·3장의 색과 크기. 모든 화면은 여기 토큰만 쓴다.
/// 색은 라이트/다크 동적 NSColor 라 외형이 바뀌면 저절로 바뀐다. CGColor 로 쓸 때만 다시 칠해야 한다.
@MainActor
enum Theme {
    // MARK: 색

    static let accent = dynamic(light: hex(0x005FB8), dark: hex(0x60CDFF))
    static let windowBackground = dynamic(light: hex(0xF3F3F3), dark: hex(0x202020))
    static let toolbarBackground = dynamic(light: hex(0xF9F9F9), dark: hex(0x2C2C2C))
    /// 탭 줄 바탕. 도구 영역과 대비가 분명하도록 windowBackground 보다 한 단계 진하다 (DESIGN 6장).
    static let tabStripBackground = dynamic(light: hex(0xE8E8E8), dark: hex(0x1B1B1B))
    static let contentBackground = dynamic(light: hex(0xFFFFFF), dark: hex(0x191919))
    static let hoverFill = dynamic(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.06))
    /// 누르고 있는 버튼. hoverFill 보다 한 단계 진하다.
    static let pressedFill = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.10))
    static let selectionFill = dynamic(light: hex(0xCCE4F7), dark: hex(0x0F3A5A))
    /// 선택한 행 위에 마우스를 올렸을 때.
    static let selectionHoverFill = dynamic(light: hex(0xBBDBF4), dark: hex(0x134669))
    /// 창이 비활성일 때의 선택.
    static let inactiveSelectionFill = dynamic(light: hex(0xE5E5E5), dark: hex(0x3A3A3A))
    static let primaryText = dynamic(light: hex(0x1A1A1A), dark: hex(0xF3F3F3))
    static let secondaryText = dynamic(light: hex(0x5D5D5D), dark: hex(0xA0A0A0))
    static let divider = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
    /// 비활성 명령 아이콘·글자의 불투명도 (DESIGN 6장).
    static let disabledAlpha: CGFloat = 0.3
    /// 주소 상자·검색 상자 바탕. 도구 영역보다 한 단계 밝다(다크에서는 어둡다).
    static let fieldBackground = dynamic(light: hex(0xFFFFFF), dark: hex(0x1F1F1F))
    static let folderBody = hex(0xFFC83D)
    static let folderTab = hex(0xE8A82A)
    static let driveCritical = hex(0xC42B1C)

    /// 사용률 90% 이상이면 빨간색 (Windows 와 같다).
    static func driveBar(usedFraction: Double) -> NSColor {
        usedFraction >= 0.9 ? driveCritical : accent
    }

    // MARK: 크기

    enum Radius {
        static let control: CGFloat = 6
        static let selection: CGFloat = 4
        static let card: CGFloat = 8
    }

    enum Font {
        static let body: CGFloat = 13
        static let secondary: CGFloat = 12
        static let status: CGFloat = 11
    }

    /// 4·8·12·16 간격 체계 (DESIGN 6장).
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    enum Metric {
        static let tabStripHeight: CGFloat = 40
        static let addressRowHeight: CGFloat = 44
        static let addressBoxHeight: CGFloat = 32
        static let commandBarHeight: CGFloat = 40
        static let statusBarHeight: CGFloat = 24
        static let rowHeight: CGFloat = 28
        static let navIndent: CGFloat = 16
    }

    // MARK: 도우미

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 동적 색을 이 외형으로 풀어 CGColor 로 바꾼다. 레이어 색에 쓴다.
    static func cg(_ color: NSColor, in view: NSView) -> CGColor {
        var result = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }

    /// 명령 모음 아이콘: 계층형 기호에 강조색을 은은하게 섞는다.
    static func commandSymbol(_ name: String, _ label: String? = nil, size: CGFloat = 15) -> NSImage {
        let tint = NSColor(name: nil) { appearance in
            let base = isDark(appearance) ? hex(0xE6E6E6) : hex(0x2B2B2B)
            let accentColor = isDark(appearance) ? hex(0x60CDFF) : hex(0x005FB8)
            return base.blended(withFraction: 0.35, of: accentColor) ?? base
        }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        return image.withSymbolConfiguration(config) ?? image
    }

    /// 단색 기호. 색은 그리는 쪽(contentTintColor)이 정한다.
    static func symbol(_ name: String, _ label: String? = nil, size: CGFloat = 13,
                       weight: NSFont.Weight = .regular) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? image
    }
}

// MARK: - 노란 폴더

/// Windows 식 노란 폴더를 코드로 그린다. 그린 결과는 픽셀 크기별로 캐시한다.
/// 반환하는 NSImage 는 그릴 때마다 대상 픽셀 크기(Retina 배율 포함)에 맞는 캐시 비트맵을 쓴다.
@MainActor
enum FolderIcon {
    private static var images: [String: NSImage] = [:]
    private static var bitmaps: [String: CGImage] = [:]

    /// glyph 는 표준 폴더(문서·다운로드 등) 위에 얹는 SF Symbol 이름.
    static func image(glyph: String? = nil) -> NSImage {
        let key = glyph ?? ""
        if let image = images[key] { return image }
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            MainActor.assumeIsolated { draw(in: rect, glyph: glyph) }
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = L("폴더")
        images[key] = image
        return image
    }

    /// 표준 폴더에 얹을 기호.
    static func glyph(for url: URL) -> String? {
        let key = Location.key(url)
        if key == Location.key(Location.home) { return "house.fill" }
        if key == Location.key(URL(fileURLWithPath: "/Applications")) { return "square.grid.2x2.fill" }
        let map: [(FileManager.SearchPathDirectory, String)] = [
            (.desktopDirectory, "menubar.dock.rectangle"), (.documentDirectory, "doc.text.fill"),
            (.downloadsDirectory, "arrow.down"), (.picturesDirectory, "photo.fill"),
            (.musicDirectory, "music.note"), (.moviesDirectory, "film.fill"),
        ]
        for (dir, symbol) in map where Location.standard(dir).map(Location.key) == key { return symbol }
        return nil
    }

    private static func draw(in rect: NSRect, glyph: String?) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = context.userSpaceToDeviceSpaceTransform.a
        let pixels = max(1, Int((rect.width * max(scale, 1)).rounded()))
        let key = "\(glyph ?? "")@\(pixels)"
        let bitmap: CGImage
        if let cached = bitmaps[key] {
            bitmap = cached
        } else {
            guard let made = render(pixels: pixels, glyph: glyph) else { return }
            if bitmaps.count > 64 { bitmaps.removeAll() }
            bitmaps[key] = made
            bitmap = made
        }
        context.interpolationQuality = .high
        context.draw(bitmap, in: rect)
    }

    private static func render(pixels: Int, glyph: String?) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        drawFolder(side: CGFloat(pixels), glyph: glyph)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// side × side 정사각형(아래가 y=0)에 그린다. 작은 크기에서는 세부를 줄인다.
    private static func drawFolder(side s: CGFloat, glyph: String?) {
        let small = s < 24
        let left = s * 0.06, right = s * 0.94
        let bottom = s * (small ? 0.12 : 0.14), top = s * (small ? 0.86 : 0.84)
        let radius = max(1, s * 0.06)

        // 뒤판과 탭
        let back = NSBezierPath()
        let tabWidth = (right - left) * 0.42
        let tabTop = top
        let bodyTop = top - s * 0.09
        back.move(to: NSPoint(x: left, y: bottom + radius))
        back.line(to: NSPoint(x: left, y: tabTop - radius))
        back.curve(to: NSPoint(x: left + radius, y: tabTop), controlPoint1: NSPoint(x: left, y: tabTop),
                   controlPoint2: NSPoint(x: left, y: tabTop))
        back.line(to: NSPoint(x: left + tabWidth - s * 0.04, y: tabTop))
        back.line(to: NSPoint(x: left + tabWidth + s * 0.05, y: bodyTop))
        back.line(to: NSPoint(x: right - radius, y: bodyTop))
        back.curve(to: NSPoint(x: right, y: bodyTop - radius), controlPoint1: NSPoint(x: right, y: bodyTop),
                   controlPoint2: NSPoint(x: right, y: bodyTop))
        back.line(to: NSPoint(x: right, y: bottom + radius))
        back.curve(to: NSPoint(x: right - radius, y: bottom), controlPoint1: NSPoint(x: right, y: bottom),
                   controlPoint2: NSPoint(x: right, y: bottom))
        back.line(to: NSPoint(x: left + radius, y: bottom))
        back.curve(to: NSPoint(x: left, y: bottom + radius), controlPoint1: NSPoint(x: left, y: bottom),
                   controlPoint2: NSPoint(x: left, y: bottom))
        back.close()
        Theme.folderTab.setFill()
        back.fill()

        // 안쪽 종이
        if !small {
            let paper = NSBezierPath(roundedRect: NSRect(x: left + s * 0.08, y: bottom + s * 0.1,
                                                         width: right - left - s * 0.16, height: bodyTop - bottom - s * 0.04),
                                     xRadius: radius * 0.6, yRadius: radius * 0.6)
            NSColor.white.withAlphaComponent(0.95).setFill()
            paper.fill()
        }

        // 앞판: 위가 조금 밝은 그러데이션
        let frontTop = bodyTop - s * (small ? 0.1 : 0.12)
        let front = NSBezierPath(roundedRect: NSRect(x: left, y: bottom, width: right - left, height: frontTop - bottom),
                                 xRadius: radius, yRadius: radius)
        let light = Theme.hex(0xFFD45A), body = Theme.folderBody
        NSGradient(starting: light, ending: body)?.draw(in: front, angle: -90)
        if !small {
            // 앞판 윗선 강조
            NSGraphicsContext.saveGraphicsState()
            front.addClip()
            NSColor.white.withAlphaComponent(0.45).setFill()
            NSRect(x: left, y: frontTop - max(1, s * 0.015), width: right - left, height: max(1, s * 0.015)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // 표준 폴더 기호
        if let glyph, s >= 14, let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil) {
            let pointSize = (frontTop - bottom) * 0.52
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                .applying(.init(paletteColors: [Theme.hex(0x9A6200).withAlphaComponent(0.85)]))
            if let tinted = symbol.withSymbolConfiguration(config) {
                let size = tinted.size
                let origin = NSPoint(x: (s - size.width) / 2, y: bottom + (frontTop - bottom - size.height) / 2)
                tinted.draw(in: NSRect(origin: origin, size: size))
            }
        }
    }
}

// MARK: - 재질

/// 탭 줄과 탐색 창의 Mica 느낌 바탕: 창 뒤 반투명 재질 위에 windowBackground 를 옅게 덮는다.
@MainActor
final class MicaView: NSVisualEffectView {
    private let tint = NSView()
    private let tintAlpha: CGFloat
    private let tintColor: NSColor

    init(tintAlpha: CGFloat = 0.78, color: NSColor? = nil) {
        self.tintAlpha = tintAlpha
        tintColor = color ?? Theme.windowBackground
        super.init(frame: .zero)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        tint.wantsLayer = true
        UI.pin(tint, to: self)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        tint.layer?.backgroundColor = Theme.cg(tintColor.withAlphaComponent(tintAlpha), in: self)
    }
}

/// 한 가지 색으로 칠하는 바탕. 색은 외형이 바뀌면 다시 칠한다.
@MainActor
class FillView: NSView {
    var fillColor: NSColor { didSet { needsDisplay = true } }
    /// 아래쪽에 구분선을 긋는다.
    var bottomDivider = false { didSet { needsDisplay = true } }
    var topDivider = false { didSet { needsDisplay = true } }

    init(_ color: NSColor) {
        fillColor = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        bounds.fill()
        Theme.divider.setFill()
        let y = isFlipped ? bounds.maxY - 1 : 0
        if bottomDivider { NSRect(x: 0, y: y, width: bounds.width, height: 1).fill() }
        if topDivider { NSRect(x: 0, y: isFlipped ? 0 : bounds.maxY - 1, width: bounds.width, height: 1).fill() }
    }
}

// MARK: - 버튼

/// 테두리 없이 마우스를 올리면 hoverFill, 누르면 pressedFill 을 칠하는 버튼.
/// circle 이면 원형(주소 줄 ← → ↑ ⟳), accent 면 옅은 강조 배경에 강조색 글자를 쓰는 버튼(새로 만들기)이다.
@MainActor
class ThemedButton: NSButton {
    enum Shape { case rounded, circle }
    var shape: Shape = .rounded { didSet { needsDisplay = true } }
    var isAccent = false { didSet { updateTint(); needsDisplay = true } }
    /// 켜진 상태(보기 전환 등)면 선택 색을 칠한다.
    var isToggled = false { didSet { needsDisplay = true } }
    /// 글자 옆에 붙이는 아래 화살표(▾).
    var showsMenuIndicator = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }
    var horizontalPadding: CGFloat = 8 { didSet { invalidateIntrinsicContentSize() } }
    var fixedSize: NSSize? { didSet { invalidateIntrinsicContentSize() } }

    convenience init(symbol: NSImage, tip: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        image = symbol
        title = ""
        imagePosition = .imageOnly
        self.target = target
        self.action = action
        toolTip = tip
        setAccessibilityLabel(tip)
    }

    convenience init(title: String, symbol: NSImage?, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        image = symbol
        imagePosition = symbol == nil ? .noImage : .imageLeading
        self.target = target
        self.action = action
        setAccessibilityLabel(title)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        font = .systemFont(ofSize: Theme.Font.body)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateTint() {
        contentTintColor = isAccent ? Theme.accent : Theme.primaryText
    }

    override var intrinsicContentSize: NSSize {
        if let fixedSize { return fixedSize }
        var width = horizontalPadding * 2
        let hasTitle = !title.isEmpty
        if let image, imagePosition != .noImage { width += image.size.width }
        if hasTitle {
            if image != nil, imagePosition != .noImage { width += 6 }
            width += (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 13)]).width.rounded(.up)
        }
        if showsMenuIndicator { width += 14 }
        return NSSize(width: max(width, 28), height: 30)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // 누른 채 밖으로 나가 놓았을 수 있다.
        isHovered = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let path: NSBezierPath
        switch shape {
        case .circle:
            let side = min(rect.width, rect.height)
            path = NSBezierPath(ovalIn: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        case .rounded:
            path = NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
        }
        if isAccent {
            // 꽉 찬 파랑 대신 accent 12% 바탕 (DESIGN 6장). 마우스를 올리면 18%, 누르면 24%.
            let alpha: CGFloat = !isEnabled ? 0.06 : isHighlighted ? 0.24 : isHovered ? 0.18 : 0.12
            Theme.accent.withAlphaComponent(alpha).setFill()
            path.fill()
        } else if isEnabled, isHighlighted {
            Theme.pressedFill.setFill(); path.fill()
        } else if isToggled {
            Theme.selectionFill.setFill(); path.fill()
        } else if isEnabled, isHovered {
            Theme.hoverFill.setFill(); path.fill()
        }

        let textColor: NSColor = isAccent ? Theme.accent : Theme.primaryText
        let alpha: CGFloat = isEnabled ? 1 : Theme.disabledAlpha
        var titleSize = NSSize.zero
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13),
                                                         .foregroundColor: textColor.withAlphaComponent(alpha)]
        if !title.isEmpty { titleSize = (title as NSString).size(withAttributes: attributes) }
        let imageSize = (imagePosition == .noImage ? nil : image?.size) ?? .zero
        let gap: CGFloat = imageSize.width > 0 && titleSize.width > 0 ? 6 : 0
        let indicator: CGFloat = showsMenuIndicator ? 14 : 0
        let total = imageSize.width + gap + titleSize.width + indicator
        var x = (rect.width - total) / 2
        if let image, imageSize.width > 0 {
            let imageRect = NSRect(x: x.rounded(), y: ((rect.height - imageSize.height) / 2).rounded(),
                                   width: imageSize.width, height: imageSize.height)
            if image.isTemplate {
                tinted(image, textColor).draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: alpha,
                                              respectFlipped: true, hints: nil)
            } else {
                image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            }
            x += imageSize.width + gap
        }
        if titleSize.width > 0 {
            (title as NSString).draw(at: NSPoint(x: x, y: (rect.height - titleSize.height) / 2), withAttributes: attributes)
            x += titleSize.width
        }
        if showsMenuIndicator {
            let chevron = tinted(Theme.symbol("chevron.down", size: 9, weight: .semibold), textColor)
            let size = chevron.size
            chevron.draw(in: NSRect(x: x + 14 - size.width - 1, y: ((rect.height - size.height) / 2).rounded(),
                                    width: size.width, height: size.height),
                         from: .zero, operation: .sourceOver, fraction: alpha * 0.8, respectFlipped: true, hints: nil)
        }
    }

    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        let result = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return result
    }
}

/// 영역 사이 구분선 색을 토큰으로 칠하는 분할 보기.
@MainActor
final class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.divider }
}

// MARK: - 선택 행

/// 둥근 사각 선택 하이라이트(반경 4)와 hover 를 칠하는 행 (DESIGN 1장 선택 표시).
/// showsAccentBar 면 선택 항목 왼쪽에 짧은 세로 강조 막대를 둔다(탐색 창).
@MainActor
final class ThemedRowView: NSTableRowView {
    var showsAccentBar = false
    var horizontalInset: CGFloat = 4
    /// 위쪽 여백. 이만큼은 하이라이트를 칠하지 않는다(탐색 창 섹션 머리글 위 간격).
    var topInset: CGFloat = 0
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isEmphasized: Bool { get { false } set {} }

    private var highlightRect: NSRect {
        var rect = bounds
        rect.size.height -= topInset
        if isFlipped { rect.origin.y += topInset }
        return rect.insetBy(dx: horizontalInset, dy: 1)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        Theme.hoverFill.setFill()
        NSBezierPath(roundedRect: highlightRect, xRadius: Theme.Radius.selection, yRadius: Theme.Radius.selection).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let active = window?.isKeyWindow == true
        let color = !active ? Theme.inactiveSelectionFill : (isHovered ? Theme.selectionHoverFill : Theme.selectionFill)
        color.setFill()
        let rect = highlightRect
        NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.selection, yRadius: Theme.Radius.selection).fill()
        if showsAccentBar {
            (active ? Theme.accent : Theme.secondaryText).setFill()
            let bar = NSRect(x: rect.minX, y: rect.midY - 8, width: 3, height: 16)
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

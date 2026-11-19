import AppKit
import ExplorerCore

/// 백그라운드 작업과 진행률 창 사이의 다리. Core 의 OperationProgress 를 만들어 주고 취소를 전한다.
/// 한 작업이 Core 를 여러 번 부르면(복제) 배치마다 새 OperationProgress 를 만들고 앞 배치의 양을 더해 보인다.
/// onUpdate 는 백그라운드 스레드에서 오므로 최신 값만 남기고 메인 스레드 전달은 한 번에 하나만 걸어 둔다.
final class ProgressTicket: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    private var current: OperationProgress?
    private var base = OperationProgressSnapshot(totalItems: 0, completedItems: 0, totalBytes: 0,
                                                 completedBytes: 0, currentName: "")
    private var latest: OperationProgressSnapshot?
    private var deliveryScheduled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let progress = lock.withLock { () -> OperationProgress? in
            cancelled = true
            return current
        }
        progress?.cancel()
    }

    /// Core 호출마다 하나씩 만든다. 이미 취소했으면 처음부터 취소된 것을 준다.
    func makeProgress() -> OperationProgress {
        let progress = OperationProgress { [weak self] snapshot in self?.receive(snapshot) }
        let wasCancelled = lock.withLock { () -> Bool in
            if let latest {
                base.totalItems = latest.totalItems
                base.completedItems = latest.totalItems
                base.totalBytes = latest.totalBytes
                base.completedBytes = latest.totalBytes
            }
            current = progress
            return cancelled
        }
        if wasCancelled { progress.cancel() }
        return progress
    }

    /// 메인 스레드에서 가장 최근 값을 꺼낸다.
    func take() -> OperationProgressSnapshot? {
        lock.withLock {
            deliveryScheduled = false
            return latest
        }
    }

    private func receive(_ snapshot: OperationProgressSnapshot) {
        let schedule = lock.withLock { () -> Bool in
            latest = OperationProgressSnapshot(
                totalItems: base.totalItems + snapshot.totalItems,
                completedItems: base.completedItems + snapshot.completedItems,
                totalBytes: base.totalBytes + snapshot.totalBytes,
                completedBytes: base.completedBytes + snapshot.completedBytes,
                currentName: snapshot.currentName)
            defer { deliveryScheduled = true }
            return !deliveryScheduled
        }
        guard schedule else { return }
        let id = self.id
        DispatchQueue.main.async {
            MainActor.assumeIsolated { FileProgressCenter.shared.deliver(id) }
        }
    }
}

/// 진행률 창에 보이는 파일 작업 하나. 큐에 넣을 때 만들고 작업이 끝나면 finish 한다.
@MainActor
final class ProgressJob {
    enum Kind { case copy, move, trash, duplicate }
    enum Phase { case waiting, preparing, running }

    let kind: Kind
    let ticket = ProgressTicket()
    var itemCount: Int { didSet { changed() } }
    let sourceFolder: String
    let destinationFolder: String?
    fileprivate(set) var phase = Phase.waiting
    fileprivate(set) var snapshot: OperationProgressSnapshot?
    /// 화면에 보이는 진행 비율. 총량이 늘어 실제 비율이 줄어도 뒤로 가지 않는다.
    fileprivate(set) var shownFraction: Double = 0
    /// 실제로 Core 작업을 시작한 시각. 0.5초 넘게 걸리는 작업만 창을 띄운다.
    fileprivate(set) var runningSince: TimeInterval?
    fileprivate var samples: [(time: TimeInterval, bytes: Int64)] = []
    fileprivate var isFinished = false
    fileprivate weak var center: FileProgressCenter?

    var isCancelled: Bool { ticket.isCancelled }

    /// 지금 떠 있는 충돌 질문을 닫는다. 질문을 띄운 쪽이 걸고, 질문이 끝나면 nil 로 되돌린다 (P-M1).
    var cancelHandler: (() -> Void)?

    fileprivate init(kind: Kind, sources: [URL], destination: URL?) {
        self.kind = kind
        itemCount = sources.count
        let parents = Set(sources.map { Location.key($0.deletingLastPathComponent()) })
        if parents.count == 1, let first = sources.first {
            sourceFolder = Self.folderName(first.deletingLastPathComponent())
        } else {
            sourceFolder = "여러 폴더"
        }
        destinationFolder = destination.map(Self.folderName)
    }

    private static func folderName(_ url: URL) -> String {
        url.path == "/" ? "/" : FileManager.default.displayName(atPath: url.path)
    }

    /// 충돌 질문 등 Core 호출 전 준비. 이 시간은 0.5초 기준에 넣지 않는다.
    func prepare() {
        phase = .preparing
        changed()
    }

    /// Core 작업을 시작한다.
    func begin() {
        phase = .running
        runningSince = ProcessInfo.processInfo.systemUptime
        changed()
    }

    /// 열린 충돌 질문도 '취소'로 닫아 큐의 다음 작업이 이어지게 한다.
    func cancel() {
        ticket.cancel()
        changed()
        let handler = cancelHandler
        cancelHandler = nil
        handler?()
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        center?.remove(self)
    }

    fileprivate func apply(_ snapshot: OperationProgressSnapshot) {
        self.snapshot = snapshot
        shownFraction = max(shownFraction, min(1, Self.fraction(snapshot)))
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, snapshot.completedBytes))
        // 최근 3초로 속도를 잰다.
        while let first = samples.first, now - first.time > 3, samples.count > 2 { samples.removeFirst() }
    }

    /// 바이트로 재되, 크기가 0 인 파일만 있으면 항목 수로 잰다.
    private static func fraction(_ snapshot: OperationProgressSnapshot) -> Double {
        if snapshot.totalBytes > 0 { return Double(snapshot.completedBytes) / Double(snapshot.totalBytes) }
        if snapshot.totalItems > 0 { return Double(snapshot.completedItems) / Double(snapshot.totalItems) }
        return 0
    }

    /// 초당 바이트. 1초 넘게 재기 전에는 nil.
    var bytesPerSecond: Double? {
        guard let since = runningSince, ProcessInfo.processInfo.systemUptime - since >= 1,
              let first = samples.first, let last = samples.last, last.time - first.time >= 0.5 else { return nil }
        return Double(last.bytes - first.bytes) / (last.time - first.time)
    }

    private func changed() { center?.jobChanged(self) }
}

/// 앱 전체의 파일 작업 진행률. 창은 탐색기 창과 따로 떠 있어 모든 창을 닫아도 보인다 (R1).
@MainActor
final class FileProgressCenter {
    static let shared = FileProgressCenter()

    /// 이 시간보다 오래 걸린 작업이 있을 때만 창을 띄운다.
    static let showDelay: TimeInterval = 0.5

    private(set) var jobs: [ProgressJob] = []
    /// 작업이 끝나면 앱을 종료하기로 했다 (R1). 창 아래에 알린다.
    var quitsWhenDone = false { didSet { if quitsWhenDone != oldValue { panel?.setQuitNotice(quitsWhenDone) } } }
    private var panel: ProgressPanelController?
    private var timer: Timer?
    /// 사용자가 창을 닫았다. 새 작업이 들어오기 전까지 다시 띄우지 않는다.
    private var dismissed = false

    var isPanelVisible: Bool { panel?.window?.isVisible == true }
    var panelWindow: NSWindow? { panel?.window }

    func track(_ kind: ProgressJob.Kind, sources: [URL], destination: URL? = nil) -> ProgressJob {
        let job = ProgressJob(kind: kind, sources: sources, destination: destination)
        job.center = self
        jobs.append(job)
        dismissed = false
        startTimer()
        // 창이 있으면 줄 하나만 덧붙인다. 다른 줄은 다시 그리지 않는다 (P-M2).
        panel?.insert(job)
        showIfNeeded()
        return job
    }

    fileprivate func remove(_ job: ProgressJob) {
        jobs.removeAll { $0 === job }
        panel?.remove(job)
        if jobs.isEmpty {
            timer?.invalidate()
            timer = nil
            panel?.window?.orderOut(nil)
        }
    }

    fileprivate func deliver(_ id: UUID) {
        guard let job = jobs.first(where: { $0.ticket.id == id }), let snapshot = job.ticket.take() else { return }
        job.apply(snapshot)
        jobChanged(job)
    }

    /// 바뀐 작업의 줄만 고친다.
    fileprivate func jobChanged(_ job: ProgressJob) {
        guard !jobs.isEmpty else { return }
        if isPanelVisible {
            panel?.refresh(job)
        } else {
            showIfNeeded()
        }
    }

    /// 진행 중이거나 기다리는 작업이 있는지. 창 메뉴 항목을 켜고 끈다.
    var hasJobs: Bool { !jobs.isEmpty }

    /// 지금 창을 띄운다. Cmd+Q 경고 뒤처럼 작업 상태를 바로 보여야 할 때 쓴다.
    func showNow() {
        guard !jobs.isEmpty else { return }
        dismissed = false
        present()
    }

    private var shouldShow: Bool {
        if isPanelVisible { return true }
        guard !dismissed else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        return jobs.contains { job in
            job.runningSince.map { now - $0 >= Self.showDelay } ?? false
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        // 0.5초 기준 확인과 남은 시간 갱신을 함께 한다. 진행 값 갱신은 deliver 가 따로 한다.
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { FileProgressCenter.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 남은 시간은 실행 중인 줄에만 있으므로 그 줄만 고친다.
    fileprivate func tick() {
        guard !jobs.isEmpty else { return }
        if isPanelVisible {
            for job in jobs where job.phase == .running && !job.isCancelled { panel?.refresh(job) }
        } else {
            showIfNeeded()
        }
    }

    private func showIfNeeded() {
        if !isPanelVisible, shouldShow { present() }
    }

    private func present() {
        if panel == nil {
            let controller = ProgressPanelController()
            controller.onDismiss = { [weak self] in self?.dismissed = true }
            panel = controller
        }
        // 숨어 있는 동안 고치지 않은 줄을 한 번에 맞춘다.
        panel?.sync(jobs: jobs, quitsWhenDone: quitsWhenDone)
        panel?.present()
    }
}

// MARK: - 창

/// "파일 작업" 창. 작업마다 한 줄씩 쌓는다. 앱을 활성화하거나 키 창을 빼앗지 않는다.
@MainActor
final class ProgressPanelController: NSWindowController, NSWindowDelegate {
    var onDismiss: (() -> Void)?
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let footer = UI.label("", size: Theme.Font.secondary, color: Theme.secondaryText)
    private var rows: [ObjectIdentifier: ProgressRowView] = [:]
    private var placed = false
    /// 종료 예정 문구가 없을 때와 있을 때의 아래쪽 끝. 숨긴 문구가 자리를 차지하지 않게 바꿔 끼운다.
    private var scrollBottom: NSLayoutConstraint!
    private var footerBottom: NSLayoutConstraint!
    /// 줄 목록이 보이는 높이. 줄이 많으면 창 최대 높이에서 멈추고 스크롤한다.
    private var scrollHeight: NSLayoutConstraint!
    /// 한 이벤트 차례에 줄이 여러 번 바뀌어도 창 크기는 한 번만 다시 잰다.
    private var resizeScheduled = false

    static let width: CGFloat = 460
    /// 창 최대 높이. 화면이 낮으면 화면 높이의 3/4 까지만 쓴다 (P-M2).
    static let maxHeight: CGFloat = 520
    /// 제목 표시줄 높이.
    private static let titleInset: CGFloat = 32

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 140),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.title = "파일 작업"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // 충돌 질문이 독립 모달로 떠 있어도 취소 단추를 누를 수 있게 한다 (P-M1).
        panel.worksWhenModal = true
        super.init(window: panel)
        panel.delegate = self

        let background = FillView(Theme.toolbarBackground)
        background.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = background

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        footer.isHidden = true
        footer.stringValue = "모든 작업이 끝나면 Explorer 를 종료합니다."
        background.addSubview(scroll)
        background.addSubview(footer)
        let clip = scroll.contentView
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(equalToConstant: Self.width),
            // 제목 표시줄 높이만큼 비운다.
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.titleInset),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollHeight,
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Theme.Space.xs),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Theme.Space.l + 40),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -Theme.Space.l),
        ])
        scrollBottom = scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Theme.Space.xs)
        footerBottom = footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Theme.Space.l)
        scrollBottom.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        guard let window else { return }
        resizeKeepingTop()
        if !placed {
            placed = true
            place(window)
        }
        // 키 창으로 만들지 않는다. 다른 앱을 쓰는 중이면 그 앱 창 위로 끌어오지 않는다.
        window.orderFront(nil)
    }

    /// 처음 띄울 때 작업을 시작한 탐색기 창 위쪽 가운데, 없으면 화면 위쪽 가운데에 둔다.
    private func place(_ window: NSWindow) {
        let anchor = (NSApp.mainWindow ?? NSApp.keyWindow).flatMap { $0.browserTabs != nil ? $0 : nil }
        let size = window.frame.size
        if let anchor {
            let frame = anchor.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 120))
        } else if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 160))
        }
    }

    /// 창을 처음 만들었거나 숨어 있다 다시 보일 때 줄 전체를 작업 목록에 맞춘다.
    func sync(jobs: [ProgressJob], quitsWhenDone: Bool) {
        let ids = Set(jobs.map(ObjectIdentifier.init))
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for job in jobs {
            if let row = rows[ObjectIdentifier(job)] { row.refresh() } else { insert(job) }
        }
        updateDividers()
        updateTitle()
        setQuitNotice(quitsWhenDone)
    }

    /// 작업 하나를 맨 아래 줄로 덧붙인다. 작업은 큐 순서대로 들어오므로 끝에 붙이면 순서가 맞다.
    func insert(_ job: ProgressJob) {
        let id = ObjectIdentifier(job)
        guard rows[id] == nil else { return }
        let row = ProgressRowView(job: job)
        row.showsDivider = !stack.arrangedSubviews.isEmpty
        rows[id] = row
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        row.refresh()
        updateTitle()
        setNeedsResize()
    }

    func remove(_ job: ProgressJob) {
        guard let row = rows.removeValue(forKey: ObjectIdentifier(job)) else { return }
        row.removeFromSuperview()
        updateDividers()
        updateTitle()
        setNeedsResize()
    }

    /// 한 줄만 다시 채운다. 줄 높이가 바뀌었을 때만 창 크기를 다시 잰다.
    func refresh(_ job: ProgressJob) {
        guard let row = rows[ObjectIdentifier(job)] else { return }
        if row.refresh() { setNeedsResize() }
    }

    func setQuitNotice(_ quitsWhenDone: Bool) {
        guard footer.isHidden == quitsWhenDone else { return }
        footer.isHidden = !quitsWhenDone
        scrollBottom.isActive = !quitsWhenDone
        footerBottom.isActive = quitsWhenDone
        setNeedsResize()
    }

    private func updateDividers() {
        for (index, view) in stack.arrangedSubviews.enumerated() {
            (view as? ProgressRowView)?.showsDivider = index > 0
        }
    }

    private func updateTitle() {
        let title = rows.count > 1 ? "파일 작업 \(rows.count)개" : "파일 작업"
        if window?.title != title { window?.title = title }
    }

    private func setNeedsResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        // 모달 대화상자가 도는 동안에도 크기를 맞추도록 공통 모드에서 부른다.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                guard self.resizeScheduled else { return }
                self.resizeScheduled = false
                self.resizeKeepingTop()
            }
        }
    }

    /// 작업 줄이 늘거나 줄면 위쪽 모서리를 그대로 두고 높이만 바꾼다.
    /// 줄이 최대 높이를 넘으면 창은 그 높이에서 멈추고 줄 목록을 스크롤한다.
    private func resizeKeepingTop() {
        guard let window, let content = window.contentView else { return }
        let rowsHeight = stack.fittingSize.height
        // 줄 목록을 뺀 제목·여백·종료 문구 높이.
        let chrome = content.fittingSize.height - scrollHeight.constant
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? Self.maxHeight
        let limit = min(Self.maxHeight, (screen * 0.75).rounded(.down))
        let listHeight = max(0, min(rowsHeight, limit - chrome))
        if abs(scrollHeight.constant - listHeight) > 0.5 { scrollHeight.constant = listHeight }
        content.layoutSubtreeIfNeeded()
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero,
                                                            size: NSSize(width: Self.width, height: chrome + listHeight)))
        guard abs(frame.height - window.frame.height) > 0.5 else { return }
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 닫아도 작업은 계속한다. 새 작업이 들어오면 다시 보인다.
        sender.orderOut(nil)
        onDismiss?()
        return false
    }
}

/// 작업 한 줄. Windows 복사 창처럼 제목, 퍼센트, 막대, 현재 이름, 남은 양을 보인다.
@MainActor
final class ProgressRowView: NSView {
    private let job: ProgressJob
    private let icon = NSImageView()
    private let title = UI.label("", size: Theme.Font.body)
    private let percent = UI.label("", size: 20)
    private let bar = ProgressBarView()
    private let name = UI.label("", size: Theme.Font.secondary, color: Theme.secondaryText)
    private let remaining = UI.label("", size: Theme.Font.secondary, color: Theme.secondaryText)
    private let rate = UI.label("", size: Theme.Font.secondary, color: Theme.secondaryText)
    private lazy var cancelButton: ThemedButton = {
        let button = ThemedButton(symbol: Theme.symbol("xmark", "취소", size: 11), tip: "취소",
                                  target: self, action: #selector(cancel(_:)))
        button.shape = .circle
        button.fixedSize = NSSize(width: 24, height: 24)
        return button
    }()
    var showsDivider = false { didSet { needsDisplay = true } }
    /// 막대와 남은 양 줄을 숨기면 그 자리를 비우지 않도록 바꿔 끼우는 제약.
    private var nameBelowBar: NSLayoutConstraint!
    private var nameBelowPercent: NSLayoutConstraint!
    private var bottomBelowRemaining: NSLayoutConstraint!
    private var bottomBelowName: NSLayoutConstraint!

    init(job: ProgressJob) {
        self.job = job
        super.init(frame: .zero)
        let symbol: String
        switch job.kind {
        case .copy: symbol = "doc.on.doc"
        case .move: symbol = "arrow.right.doc.on.clipboard"
        case .trash: symbol = "trash"
        case .duplicate: symbol = "plus.square.on.square"
        }
        icon.image = Theme.symbol(symbol, nil, size: 22)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = Theme.accent
        title.font = .systemFont(ofSize: Theme.Font.body, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        percent.font = .systemFont(ofSize: 20, weight: .regular)
        percent.textColor = Theme.primaryText
        bar.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingMiddle
        rate.alignment = .right
        for view in [icon, title, percent, bar, name, remaining, rate, cancelButton] as [NSView] { addSubview(view) }
        rate.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let l = Theme.Space.l
        let textLeading = l + 40
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: l),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.m),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),

            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading),
            title.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.m),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -Theme.Space.s),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            cancelButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            percent.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            percent.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Theme.Space.xs),

            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -l),
            bar.topAnchor.constraint(equalTo: percent.bottomAnchor, constant: Theme.Space.s),
            bar.heightAnchor.constraint(equalToConstant: 6),

            name.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -l),

            remaining.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            remaining.topAnchor.constraint(equalTo: name.bottomAnchor, constant: Theme.Space.xs),
            remaining.trailingAnchor.constraint(lessThanOrEqualTo: rate.leadingAnchor, constant: -Theme.Space.s),
            rate.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rate.firstBaselineAnchor.constraint(equalTo: remaining.firstBaselineAnchor),
        ])
        nameBelowBar = name.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: Theme.Space.s)
        nameBelowPercent = name.topAnchor.constraint(equalTo: percent.bottomAnchor, constant: Theme.Space.xs)
        bottomBelowRemaining = remaining.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.m)
        bottomBelowName = name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.m)
        nameBelowBar.isActive = true
        bottomBelowRemaining.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard showsDivider else { return }
        Theme.divider.setFill()
        NSRect(x: Theme.Space.l, y: 0, width: bounds.width - Theme.Space.l * 2, height: 1).fill()
    }

    @objc private func cancel(_ sender: Any?) {
        job.cancel()
    }

    /// 막대와 남은 양 줄을 보일지 정한다. 숨기면 줄 높이도 그만큼 줄인다. 높이가 바뀌면 true.
    private func setLayout(bar showsBar: Bool, detail showsDetail: Bool) -> Bool {
        if bar.isHidden == showsBar { bar.isHidden = !showsBar }
        if remaining.isHidden == showsDetail { remaining.isHidden = !showsDetail }
        if rate.isHidden == showsDetail { rate.isHidden = !showsDetail }
        guard nameBelowBar.isActive != showsBar || bottomBelowRemaining.isActive != showsDetail else { return false }
        NSLayoutConstraint.deactivate([nameBelowBar, nameBelowPercent, bottomBelowRemaining, bottomBelowName])
        NSLayoutConstraint.activate([showsBar ? nameBelowBar : nameBelowPercent,
                                     showsDetail ? bottomBelowRemaining : bottomBelowName])
        return true
    }

    /// 값이 같으면 글자를 다시 넣지 않는다. 다시 넣으면 그 칸을 다시 재고 그린다.
    private static func set(_ label: NSTextField, _ value: String) {
        if label.stringValue != value { label.stringValue = value }
    }

    /// 작업 상태로 줄을 다시 채운다. 줄 높이가 바뀌면 true.
    @discardableResult
    func refresh() -> Bool {
        let verb: String
        switch job.kind {
        case .copy: verb = "복사"
        case .move, .trash: verb = "이동"
        case .duplicate: verb = "복제"
        }
        let target: String
        switch job.kind {
        case .trash: target = " 휴지통으로"
        case .duplicate: target = ""
        case .copy, .move: target = job.destinationFolder.map { " '\($0)'(으)로" } ?? ""
        }
        let header = "\(job.itemCount)개 항목을 '\(job.sourceFolder)'에서\(target) \(verb)하는 중"
        if title.stringValue != header {
            title.stringValue = header
            title.toolTip = header
        }

        let snapshot = job.snapshot
        let fraction = job.shownFraction
        if cancelButton.isEnabled == job.isCancelled { cancelButton.isEnabled = !job.isCancelled }

        let percentText: String, nameText: String, remainingText: String, rateText: String
        let showsBar: Bool, showsDetail: Bool
        if job.isCancelled {
            let started = job.phase == .running
            percentText = started ? "취소하는 중…" : "취소됨"
            nameText = started ? "지금까지 한 작업을 되돌리고 있습니다." : "시작하지 않고 건너뜁니다."
            (remainingText, rateText) = ("", "")
            bar.fraction = fraction
            bar.isDimmed = true
            (showsBar, showsDetail) = (started, false)
        } else {
            bar.isDimmed = false
            switch job.phase {
            case .waiting, .preparing:
                percentText = job.phase == .waiting ? "대기 중" : "준비 중"
                nameText = job.phase == .waiting ? "앞 작업이 끝나면 시작합니다." : "충돌 항목을 확인하고 있습니다."
                (remainingText, rateText) = ("", "")
                bar.fraction = 0
                (showsBar, showsDetail) = (false, false)
            case .running:
                if let snapshot {
                    percentText = "\(Int((fraction * 100).rounded(.down)))% 완료"
                    bar.fraction = fraction
                    nameText = snapshot.currentName.isEmpty ? " " : "이름: \(snapshot.currentName)"
                    let items = max(0, snapshot.totalItems - snapshot.completedItems)
                    let bytes = max(0, snapshot.totalBytes - snapshot.completedBytes)
                    remainingText = "남은 항목: \(items)개 (\(Self.size(bytes)))"
                    if let speed = job.bytesPerSecond, speed > 0 {
                        rateText = "\(Self.size(Int64(speed)))/초 · \(Self.duration(Double(bytes) / speed))"
                    } else {
                        rateText = "남은 시간 계산 중…"
                    }
                    (showsBar, showsDetail) = (true, true)
                } else {
                    percentText = "0% 완료"
                    nameText = "항목 수를 세는 중…"
                    (remainingText, rateText) = ("", "")
                    bar.fraction = 0
                    (showsBar, showsDetail) = (true, false)
                }
            }
        }
        Self.set(percent, percentText)
        Self.set(name, nameText)
        Self.set(remaining, remainingText)
        Self.set(rate, rateText)
        let label = "\(header), \(percentText)"
        if accessibilityLabel() != label { setAccessibilityLabel(label) }
        return setLayout(bar: showsBar, detail: showsDetail)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func size(_ bytes: Int64) -> String { byteFormatter.string(fromByteCount: bytes) }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "남은 시간 계산 중…" }
        let s = Int(seconds.rounded(.up))
        if s < 2 { return "곧 끝남" }
        if s < 60 { return "약 \(s)초 남음" }
        if s < 3600 { return "약 \((s + 30) / 60)분 남음" }
        return "약 \(s / 3600)시간 \((s % 3600) / 60)분 남음"
    }
}

/// 둥근 진행 막대. 채운 부분은 accent, 바탕은 divider 보다 조금 진한 회색이다.
@MainActor
final class ProgressBarView: NSView {
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsDisplay = true; updateValue() } } }
    var isDimmed = false { didSet { if isDimmed != oldValue { needsDisplay = true } } }

    private static let track = Theme.dynamic(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.14))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
        updateValue()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateValue() { setAccessibilityValue(Int(fraction * 100)) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Self.track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let width = bounds.width * min(1, max(0, fraction))
        guard width > 0 else { return }
        let fill = NSRect(x: 0, y: 0, width: max(width, bounds.height), height: bounds.height)
        (isDimmed ? Theme.secondaryText : Theme.accent).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

#if DEBUG
extension ProgressJob {
    /// 하네스가 Core 없이 진행 값을 넣어 본다.
    func debugApply(_ snapshot: OperationProgressSnapshot) { apply(snapshot) }
}

extension FileProgressCenter {
    /// 백그라운드에서 진행 값 하나가 도착한 것처럼 처리한다.
    func debugDeliver(_ job: ProgressJob, _ snapshot: OperationProgressSnapshot) {
        job.apply(snapshot)
        jobChanged(job)
    }

    /// 0.25초 타이머 한 번.
    func debugTick() { tick() }

    var debugPanel: ProgressPanelController? { panel }
}

extension ProgressRowView {
    /// 줄의 취소 단추를 누른다.
    func debugPressCancel() { cancelButton.performClick(nil) }
}

extension ProgressPanelController {
    /// 작업 줄. 하네스가 개수와 높이를 본다.
    var debugRows: [NSView] { stack.arrangedSubviews }
    var debugScrollView: NSScrollView { scroll }

    /// 미뤄 둔 창 크기 맞춤을 지금 한다. 측정에 그 시간까지 넣으려고 쓴다.
    func debugFlushResize() {
        guard resizeScheduled else { return }
        resizeScheduled = false
        resizeKeepingTop()
    }
}
#endif

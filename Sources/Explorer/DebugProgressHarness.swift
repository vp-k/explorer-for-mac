import AppKit
import ExplorerCore

#if DEBUG

/// 진행률 창 확인용 하네스. 디버그 빌드에만 들어가고 EXPLORER_PROGRESS_HARNESS 가 있을 때만 돈다.
/// 그 폴더 아래 work 폴더에 큰 파일을 만들고 실제 붙여넣기·휴지통 경로로 작업을 돌린다.
/// 결과는 harness.log 에, 진행률 창 캡처는 progress-*.png 로 남긴다. 화면 조작은 하지 않는다.
/// 마지막 장면은 탐색기 창을 모두 닫고 작업이 끝나면 앱이 스스로 종료하는지 본다 (R1).
@MainActor
enum DebugProgressHarness {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["EXPLORER_PROGRESS_HARNESS"] != nil }

    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["EXPLORER_PROGRESS_HARNESS"] else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        Task { @MainActor in await run(in: folder) }
    }

    private static var logURL: URL?
    private static var failures = 0

    private static func log(_ line: String) {
        guard let logURL else { return }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @discardableResult
    private static func wait(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < end {
            if condition() { return true }
            await pause(0.05)
        }
        return condition()
    }

    private static var center: FileProgressCenter { .shared }

    /// 오류 알림이 떴는지. 시트나 모달 창을 본다.
    private static var alertShown: Bool {
        NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
    }

    private static func contents(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private static func makeFiles(in folder: URL, count: Int, megabytes: Int, prefix: String) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var chunk = Data(count: 16 << 20)
        chunk.withUnsafeMutableBytes { buffer in
            for i in stride(from: 0, to: buffer.count, by: 8) { buffer.storeBytes(of: UInt64.random(in: 0...UInt64.max), toByteOffset: i, as: UInt64.self) }
        }
        var urls: [URL] = []
        for index in 1...count {
            let url = folder.appendingPathComponent("\(prefix) \(index).bin")
            fm.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            for _ in 0..<(megabytes / 16) { handle.write(chunk) }
            try handle.close()
            urls.append(url)
        }
        return urls
    }

    private static func run(in folder: URL) async {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        logURL = folder.appendingPathComponent("harness.log")
        try? fm.removeItem(at: logURL!)
        let work = folder.appendingPathComponent("work", isDirectory: true)
        try? fm.removeItem(at: work)
        log("harness start \(Date())")

        await pause(1.2)
        guard let window = NSApp.windows.first(where: { $0.browserTabs != nil }),
              let browser = window.browserTabs?.selectedBrowser else {
            log("FAIL no browser window")
            NSApp.terminate(nil)
            return
        }
        let big: [URL], small: [URL], trashable: [URL]
        do {
            big = try makeFiles(in: work.appendingPathComponent("원본"), count: 6, megabytes: 512, prefix: "큰 파일")
            small = try makeFiles(in: work.appendingPathComponent("작은 원본"), count: 1, megabytes: 16, prefix: "작은 파일")
            trashable = try makeFiles(in: work.appendingPathComponent("휴지통 원본"), count: 3, megabytes: 16, prefix: "버릴 파일")
        } catch {
            log("FAIL setup \(error)")
            NSApp.terminate(nil)
            return
        }
        let target = work.appendingPathComponent("대상", isDirectory: true)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        browser.navigate(to: work)
        await pause(0.5)

        check("작업이 없으면 진행률 메뉴 꺼짐", menuEnabled == false, "\(String(describing: menuEnabled))")
        checkMonotonicPercent()

        // 1. 짧은 작업은 창을 띄우지 않는다.
        var everShown = false
        let shortDone = Flag()
        let shortTask = Task {
            let ok = await browser.performTransfer(small, to: target, move: false)
            shortDone.value = true
            return ok
        }
        while !shortDone.value {
            everShown = everShown || center.isPanelVisible
            await pause(0.02)
        }
        await pause(0.8)
        everShown = everShown || center.isPanelVisible
        let shortOK = await shortTask.value
        check("짧은 작업은 창이 뜨지 않음", shortOK && !everShown && !center.isPanelVisible,
              "result=\(shortOK) shown=\(everShown)")
        try? fm.removeItem(at: target.appendingPathComponent(small[0].lastPathComponent))

        // 2. 큰 파일 복사는 0.5초 뒤 진행률을 보이고 끝나면 닫힌다.
        let copyTask = Task { await browser.performTransfer(big, to: target, move: false) }
        let started = ProcessInfo.processInfo.systemUptime
        let appeared = await wait(10) { center.isPanelVisible }
        let delay = ProcessInfo.processInfo.systemUptime - started
        check("작업 중에는 진행률 메뉴 켜짐", menuEnabled == true)
        await wait(5) { (center.jobs.first?.snapshot?.completedBytes ?? 0) > 0 }
        let snapshot = center.jobs.first?.snapshot
        check("큰 복사 진행 창 표시", appeared && delay >= FileProgressCenter.showDelay,
              String(format: "%.2fs 뒤 표시, %@", delay, snapshot.map { "\($0.completedBytes)/\($0.totalBytes) B, \($0.currentName)" } ?? "값 없음"))
        if let panel = center.panelWindow {
            await pause(0.4)
            capture(panel, folder.appendingPathComponent("progress-light.png"))
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await pause(0.4)
            capture(panel, folder.appendingPathComponent("progress-dark.png"))
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        let copied = await copyTask.value
        await wait(1) { !center.isPanelVisible }
        check("큰 복사 완료 후 창 닫힘", copied && !center.isPanelVisible && contents(target).count == big.count,
              "대상 항목 \(contents(target).count)개")
        for name in contents(target) { try? fm.removeItem(at: target.appendingPathComponent(name)) }

        // 3. 취소하면 롤백하고 알림을 띄우지 않는다. 큐에서 기다리던 휴지통 작업도 취소한다.
        let before = contents(target)
        let cancelTask = Task { await browser.performTransfer(big, to: target, move: false) }
        await wait(10) { center.isPanelVisible && (center.jobs.first?.snapshot?.completedBytes ?? 0) > 0 }
        browser.trash(trashable)
        await wait(2) { center.jobs.count == 2 }
        let progressed = center.jobs.first?.snapshot?.completedBytes ?? 0
        center.jobs.last?.cancel()
        await pause(0.3)
        capture(center.panelWindow, folder.appendingPathComponent("progress-cancel-light.png"))
        center.jobs.first?.cancel()
        let cancelled = await cancelTask.value
        await wait(5) { center.jobs.isEmpty }
        await pause(0.5)
        check("취소 시 롤백", !cancelled && contents(target) == before && contents(big[0].deletingLastPathComponent()).count == big.count,
              "취소 전 \(progressed) B 복사, 대상 \(contents(target))")
        check("기다리던 휴지통 작업 취소", trashable.allSatisfy { fm.fileExists(atPath: $0.path) })
        check("취소는 오류 알림 없음", !alertShown)
        check("취소 후 창 닫힘", !center.isPanelVisible)

        // 4. 여러 작업이 큐에 있으면 한 창에 쌓인다.
        let second = work.appendingPathComponent("대상 2", isDirectory: true)
        try? fm.createDirectory(at: second, withIntermediateDirectories: true)
        let queued = [
            Task { await browser.performTransfer(Array(big.prefix(3)), to: target, move: false) },
            Task { await browser.performTransfer(Array(big.suffix(3)), to: second, move: false) },
        ]
        browser.trash(trashable)
        await wait(10) { center.isPanelVisible }
        await pause(0.3)
        let rows = center.panelWindow?.contentView?.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.count ?? 0
        check("큐 여러 개 표시", center.jobs.count == 3 && rows == 3, "작업 \(center.jobs.count)개, 줄 \(rows)개")
        let stackRows = center.panelWindow?.contentView?.subviews.compactMap { $0 as? NSStackView }.first?
            .arrangedSubviews ?? []
        let heights = stackRows.map { $0.frame.height }
        check("대기 줄은 실행 줄보다 낮음", heights.count == 3 && heights[1] < heights[0] - 20 && heights[2] < heights[0] - 20,
              "높이 \(heights.map { Int($0) })")
        capture(center.panelWindow, folder.appendingPathComponent("progress-queue-light.png"))
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await pause(0.4)
        capture(center.panelWindow, folder.appendingPathComponent("progress-queue-dark.png"))
        NSApp.appearance = NSAppearance(named: .aqua)
        for task in queued { _ = await task.value }
        await wait(10) { center.jobs.isEmpty }
        check("큐 작업 모두 완료", contents(target).count == 3 && contents(second).count == 3
              && !trashable.contains { fm.fileExists(atPath: $0.path) })
        for name in contents(target) { try? fm.removeItem(at: target.appendingPathComponent(name)) }

        // 5. 마지막 탐색기 창을 닫아도 진행 창은 남고, 작업이 끝나면 앱이 종료한다 (R1).
        let lastTask = Task { await browser.performTransfer(big, to: target, move: false) }
        await wait(10) { center.isPanelVisible }
        for window in NSApp.windows where window.browserTabs != nil { window.close() }
        await pause(0.5)
        let browsersLeft = NSApp.windows.filter { $0.isVisible && $0.browserTabs != nil }.count
        check("마지막 창을 닫아도 진행 창 유지", browsersLeft == 0 && center.isPanelVisible && !center.jobs.isEmpty,
              "탐색기 창 \(browsersLeft)개")
        check("진행 창에 종료 예정 표시", center.quitsWhenDone)
        capture(center.panelWindow, folder.appendingPathComponent("progress-quit-light.png"))
        // 닫은 창을 창 메뉴로 다시 띄운다. 탐색기 창이 없어도 된다.
        center.panelWindow?.performClose(nil)
        await pause(0.6)
        let hidden = !center.isPanelVisible
        if let item = menuItem { NSApp.sendAction(item.action!, to: item.target, from: item) }
        let reopened = center.panelWindow?.frame.height ?? 0
        check("닫은 진행 창을 메뉴로 다시 표시", hidden && center.isPanelVisible && reopened > 100,
              "창 높이 \(Int(reopened))")
        log("summary failures=\(failures)")
        log("waiting for app to quit after last job")
        _ = await lastTask.value
        // 앱이 스스로 종료하지 않으면 여기까지 온다.
        await pause(3)
        log("FAIL app did not quit after last job")
        NSApp.terminate(nil)
    }

    private final class Flag { var value = false }

    private static var menuItem: NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.action == #selector(AppDelegate.showFileProgress(_:)) { return item }
                if let found = find(item.submenu) { return found }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    private static var menuEnabled: Bool? {
        menuItem.map { AppDelegate.shared.validateMenuItem($0) }
    }

    /// 복제처럼 배치가 늘어 총량이 커져도 표시 퍼센트가 줄지 않는지 본다. 창은 띄우지 않는다.
    private static func checkMonotonicPercent() {
        let job = center.track(.duplicate, sources: [URL(fileURLWithPath: "/tmp/a")])
        func snap(_ done: Int64, _ total: Int64) -> OperationProgressSnapshot {
            OperationProgressSnapshot(totalItems: 2, completedItems: 1, totalBytes: total, completedBytes: done, currentName: "a")
        }
        job.debugApply(snap(50, 100))
        let first = job.shownFraction
        job.debugApply(snap(100, 400))
        let afterGrow = job.shownFraction
        job.debugApply(snap(300, 400))
        let later = job.shownFraction
        job.finish()
        check("총량이 늘어도 퍼센트 단조 증가", first == 0.5 && afterGrow == 0.5 && later == 0.75,
              "\(first) → \(afterGrow) → \(later)")
    }

    private static func capture(_ window: NSWindow?, _ url: URL) {
        guard let window, let root = window.contentView?.superview ?? window.contentView,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif

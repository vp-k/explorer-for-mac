import AppKit

#if DEBUG

/// 화면 확인용 스냅숏. 디버그 빌드에만 들어간다. 환경 변수 EXPLORER_SNAPSHOT_DIR 이 있을 때만 돈다.
/// 첫 창으로 정해진 장면(자세히·아이콘·내 Mac·빈 폴더)을 라이트/다크로 차례로 띄우고 탭 넘침도 한 장 뜨고
/// NSView.cacheDisplay 로 창 내용을 PNG 로 남긴 뒤 종료한다. 화면 녹화 권한이 없어도 된다.
@MainActor
enum DebugSnapshot {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["EXPLORER_SNAPSHOT_DIR"] else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        Task { @MainActor in
            await run(into: folder)
            NSApp.terminate(nil)
        }
    }

    private static func pause(_ seconds: Double = 0.8) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func run(into folder: URL) async {
        await pause(1.2)
        guard let window = NSApp.windows.first(where: { $0.browserTabs != nil }),
              let tabs = window.browserTabs, let first = tabs.selectedBrowser else { return }
        let start = first.currentURL
        // 두 번째 탭을 열었다가 첫 탭으로 돌아온다. 탭 줄에 탭이 둘 보인다.
        AppDelegate.shared.openTab(in: window, at: start.appendingPathComponent("문서"))
        await pause()
        tabs.select(0)
        await pause()
        if first.fileList.items.count > 1 { first.fileList.select(indexes: [1]) }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            first.setViewMode(.details)
            first.navigate(to: start)
            await pause()
            if first.fileList.items.count > 1 { first.fileList.select(indexes: [1]) }
            await pause(0.4)
            capture(window, folder.appendingPathComponent("\(name)-list.png"))

            first.setViewMode(.largeIcons)
            await pause()
            capture(window, folder.appendingPathComponent("\(name)-icons.png"))
            first.setViewMode(.details)

            first.navigate(to: Location.thisMac)
            await pause()
            capture(window, folder.appendingPathComponent("\(name)-thismac.png"))

            first.navigate(to: start.appendingPathComponent("빈 폴더"))
            await pause()
            capture(window, folder.appendingPathComponent("\(name)-empty.png"))
        }

        // 탭이 넘칠 때의 좌우 화살표.
        NSApp.appearance = NSAppearance(named: .aqua)
        for _ in 0..<14 { AppDelegate.shared.openTab(in: window, at: start) }
        await pause()
        capture(window, folder.appendingPathComponent("light-tabs-overflow.png"))
    }

    private static func capture(_ window: NSWindow, _ url: URL) {
        // 제목 표시줄의 신호등 버튼까지 담도록 테마 프레임을 뜬다.
        guard let root = window.contentView?.superview ?? window.contentView,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        // 테마 프레임에서 뜨면 NSTableView 의 행과 머리글이 빠진다. 보이는 표·머리글·안내 문구는 따로 떠서 제자리에 겹친다.
        if let list = window.activeBrowser?.fileList, !list.tableView.isHiddenOrHasHiddenAncestor,
           let clip = list.tableView.enclosingScrollView?.contentView, let context = NSGraphicsContext(bitmapImageRep: rep) {
            var parts: [(NSView, NSRect, NSView)] = [(list.tableView, clip.documentVisibleRect, clip)]
            if let header = list.tableView.headerView, let headerClip = header.superview {
                parts.append((header, header.visibleRect, headerClip))
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            for (view, source, frameView) in parts {
                guard let part = view.bitmapImageRepForCachingDisplay(in: source) else { continue }
                view.cacheDisplay(in: source, to: part)
                let target = root.convert(frameView.frame, from: frameView.superview)
                let rect = root.isFlipped
                    ? NSRect(x: target.minX, y: root.bounds.height - target.maxY, width: target.width, height: target.height)
                    : target
                part.draw(in: rect)
            }
            // 안내 문구는 바탕 없이 글자만 다시 그린다.
            let label = list.messageLabel
            if !label.isHidden {
                let target = root.convert(label.frame, from: label.superview)
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    label.attributedStringValue.draw(in: NSRect(x: target.minX, y: target.minY, width: target.width + 4,
                                                                height: target.height))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif

import AppKit
import ExplorerCore

/// 파일 작업 (3.3장). 실제 작업은 Core 가 백그라운드에서 하고, 결과로 목록을 다시 읽는다.
extension BrowserViewController {
    var selectedURLs: [URL] { fileList.selectedURLs }

    /// 메뉴 항목이 빈 곳 메뉴에서 왔으면 현재 폴더를 대상으로 한다.
    private func isBackgroundSender(_ sender: Any?) -> Bool {
        ((sender as? NSMenuItem)?.representedObject as? String) == "background"
    }

    private func targetURLs(_ sender: Any?) -> [URL] {
        if isBackgroundSender(sender) || selectedURLs.isEmpty {
            return isThisMac ? [] : [currentURL]
        }
        return selectedURLs
    }

    // MARK: 열기 (F1, F16)

    func open(_ items: [FileItem], inNewTab: Bool = false) {
        guard !items.isEmpty else { return }
        let folders = items.filter(\.isNavigable)
        let files = items.filter { !$0.isNavigable }
        if folders.count == 1, files.isEmpty, !inNewTab {
            navigate(to: folders[0].url)
        } else {
            for folder in folders { openTab(at: folder.url) }
        }
        for file in files { NSWorkspace.shared.open(file.url) }
    }

    @objc func openSelection(_ sender: Any?) {
        open(fileList.selectedItems)
    }

    @objc func openInNewTab(_ sender: Any?) {
        if let url = (sender as? NSMenuItem)?.representedObject as? URL {
            openTab(at: url)
        } else {
            open(fileList.selectedItems.filter(\.isNavigable), inNewTab: true)
        }
    }

    @objc func openWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let urls = fileList.selectedItems.filter { !$0.isNavigable }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func chooseApplication(_ sender: Any?) {
        let urls = fileList.selectedItems.filter { !$0.isNavigable }.map(\.url)
        guard !urls.isEmpty, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "열기"
        panel.message = "이 파일을 열 앱을 선택하세요."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: 잘라내기 / 복사 / 붙여넣기 (F2, F8, F9, F12)

    @objc func cut(_ sender: Any?) {
        ClipboardBridge.write(selectedURLs, mode: .cut)
    }

    @objc func copy(_ sender: Any?) {
        ClipboardBridge.write(selectedURLs, mode: .copy)
    }

    @objc func paste(_ sender: Any?) {
        guard !isThisMac, let content = ClipboardBridge.readForPaste() else { return }
        var destination = currentURL
        // 폴더 하나를 우클릭해 붙여넣으면 그 폴더 안으로.
        if (sender as? NSMenuItem)?.representedObject as? String == "item",
           let folder = fileList.selectedItems.first, fileList.selectedItems.count == 1, folder.isNavigable {
            destination = folder.url
        }
        let move = content.mode == .cut
        Task {
            if await performTransfer(content.urls, to: destination, move: move), move {
                ClipboardBridge.finishCutPaste(changeCount: content.changeCount)
            }
        }
    }

    /// Cmd+⌥+V: 대지의 항목을 여기로 이동한다. Finder 에서 Cmd+C 한 파일도 옮긴다.
    @objc func pasteMove(_ sender: Any?) {
        guard !isThisMac, let content = ClipboardBridge.readForPaste() else { return }
        let destination = currentURL
        Task {
            if await performTransfer(content.urls, to: destination, move: true) {
                ClipboardBridge.finishCutPaste(changeCount: content.changeCount)
            }
        }
    }

    @objc func copyPath(_ sender: Any?) {
        ClipboardBridge.copyPaths(targetURLs(sender))
    }

    /// 드래그 앤 드롭(F10)과 탐색 창 놓기에서 쓴다.
    func transfer(_ urls: [URL], to destination: URL, move: Bool) {
        Task { await performTransfer(urls, to: destination, move: move) }
    }

    /// 충돌이 있으면 원본마다 대화상자(F8)로 정책을 묻고 복사·이동한다. 성공하면 true.
    /// 폴더끼리 부딪치면 병합하고 그 안의 충돌도 하나씩 묻는다. 건너뛴 원본은 작업에 넣지 않는다.
    /// 앞 작업이 끝난 뒤의 파일 상태로 묻도록 질문도 작업 큐 안에서 한다.
    @discardableResult
    func performTransfer(_ urls: [URL], to destination: URL, move: Bool) async -> Bool {
        guard !urls.isEmpty else { return false }
        let state = self.state
        let window = view.window
        // 기다리는 동안에도 진행률 창에 보이도록 큐에 넣을 때 등록한다.
        let job = FileProgressCenter.shared.track(move ? .move : .copy, sources: urls, destination: destination)
        let ticket = job.ticket
        let outcome: Result<OperationResult, Error>? = await state.operations.run {
            defer { job.finish() }
            // 기다리는 중에 취소했으면 충돌을 묻지 않는다.
            if job.isCancelled { return .failure(FileOperationError.cancelled) }
            job.prepare()
            let scanned = await Task.detached(priority: .userInitiated) {
                (ConflictDialog.scan(urls, to: destination), ConflictDialog.isCaseSensitive(destination))
            }.value
            // 질문 중에 진행률 창에서 취소하면 질문이 닫히고 nil 이 온다.
            guard !job.isCancelled,
                  let plan = await ConflictDialog.plan(scanned.0, destination: destination, move: move,
                                                       caseSensitive: scanned.1, window: window, job: job),
                  !plan.sources.isEmpty else { return nil }
            if job.isCancelled { return .failure(FileOperationError.cancelled) }
            let sources = plan.sources
            let resolver = plan.resolver
            job.itemCount = sources.count
            job.begin()
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let progress = ticket.makeProgress()
                    return move
                        ? try FileOperations.move(sources, to: destination, conflict: resolver.policy(for:), progress: progress)
                        : try FileOperations.copy(sources, to: destination, conflict: resolver.policy(for:), progress: progress)
                }
            }.value
            if case .success(let done) = result { state.pushUndo(done.record) }
            return result
        }
        guard let outcome else { return false }
        let folders = [destination] + urls.map { $0.deletingLastPathComponent() }
        return finishOperation(outcome, renameResult: false, folders: folders) != nil
    }

    /// Cmd+D: 선택 항목을 같은 폴더에 "이름 - 복사본" 으로 복제한다. 검색 결과면 항목마다 제 폴더에 만든다.
    @objc func duplicateSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, !isThisMac else { return }
        var groups: [(parent: URL, urls: [URL])] = []
        for url in urls {
            let parent = url.deletingLastPathComponent()
            if let index = groups.firstIndex(where: { Location.same($0.parent, parent) }) {
                groups[index].urls.append(url)
            } else {
                groups.append((parent, [url]))
            }
        }
        let batches = groups
        Task {
            // 큐에 넣는 순서와 진행률 창의 순서가 같도록 같은 차례에 등록한다.
            let job = FileProgressCenter.shared.track(.duplicate, sources: urls)
            let ticket = job.ticket
            await runOperation(job: job) {
                var records: [FileOperationRecord] = []
                var created: [URL] = []
                do {
                    for batch in batches {
                        let result = try FileOperations.copy(batch.urls, to: batch.parent, conflict: { _ in .keepBoth },
                                                             progress: ticket.makeProgress())
                        if let record = result.record { records.append(record) }
                        created += result.resultURLs
                    }
                } catch {
                    // 앞 폴더에서 만든 복사본은 되돌린다.
                    for record in records.reversed() { _ = try? FileOperations.undo(record) }
                    throw error
                }
                let record: FileOperationRecord? = records.count > 1 ? .compound(records: records) : records.first
                return OperationResult(record: record, resultURLs: created, skipped: [])
            }
        }
    }

    // MARK: 삭제 (F4)

    @objc func moveToTrash(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, !isThisMac else { return }
        trash(urls)
    }

    /// 휴지통으로 보낸다. 오래 걸리면 진행률 창에 보이고 취소하면 원래 자리로 되돌린다.
    func trash(_ urls: [URL]) {
        Task {
            // 큐에 넣는 순서와 진행률 창의 순서가 같도록 같은 차례에 등록한다.
            let job = FileProgressCenter.shared.track(.trash, sources: urls)
            let ticket = job.ticket
            await runOperation(job: job) { try FileOperations.trash(urls, progress: ticket.makeProgress()) }
        }
    }

    @objc func deletePermanently(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, !isThisMac, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = urls.count == 1
            ? "'\(urls[0].lastPathComponent)'을(를) 영구적으로 삭제하시겠습니까?"
            : "이 \(urls.count)개 항목을 영구적으로 삭제하시겠습니까?"
        alert.informativeText = "이 작업은 실행 취소할 수 없습니다."
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak self] in
                await self?.runOperation {
                    try FileOperations.deletePermanently(urls)
                    return OperationResult(record: nil, resultURLs: [], skipped: [])
                }
            }
        }
    }

    // MARK: 이름 바꾸기, 새로 만들기 (F3, F5, F6)

    @objc func renameSelection(_ sender: Any?) {
        let items = fileList.selectedItems
        guard items.count == 1, !isThisMac else { return }
        fileList.beginRename(items[0].url)
    }

    func commitRename(_ item: FileItem, to newName: String) {
        guard newName != item.name else { return }
        let url = item.url
        Task { await runOperation { try FileOperations.rename(url, to: newName) } }
    }

    /// 검색 중이면 검색을 끝내고 현재 폴더에 만들어 바로 이름을 편집한다.
    @objc func newFolder(_ sender: Any?) {
        guard !isThisMac else { return }
        if isSearching { endSearch() }
        let directory = currentURL
        Task { await runOperation(renameResult: true) { try FileOperations.createFolder(in: directory) } }
    }

    @objc func newTextFile(_ sender: Any?) {
        guard !isThisMac else { return }
        if isSearching { endSearch() }
        let directory = currentURL
        Task { await runOperation(renameResult: true) { try FileOperations.createFile(in: directory) } }
    }

    // MARK: 실행 취소 (F7)

    @objc func undo(_ sender: Any?) {
        // 주소창·이름 편집 중의 Cmd+Z 는 글자 실행 취소다.
        if let manager = textUndoManager { manager.undo(); return }
        guard !state.undoStack.isEmpty else { NSSound.beep(); return }
        Task { await runHistory(redo: false) }
    }

    @objc func redo(_ sender: Any?) {
        if let manager = textUndoManager { manager.redo(); return }
        guard !state.redoStack.isEmpty else { NSSound.beep(); return }
        Task { await runHistory(redo: true) }
    }

    /// 실행 취소·다시 실행도 작업 큐에서 차례로 한다. 기록은 실행할 차례에 꺼내고, 성공해야 반대 스택으로 옮긴다.
    /// 실패하면 Core 가 바꾼 것을 되돌리므로 기록을 그대로 두어 원인을 치운 뒤 다시 시도할 수 있다.
    private func runHistory(redo: Bool) async {
        let state = self.state
        let outcome: Result<Void, Error>? = await state.operations.run {
            guard let record = redo ? state.redoStack.last : state.undoStack.last else { return nil }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FileOperations.undo(record) }
            }.value
            switch result {
            case .success(let inverse):
                if redo { state.completeRedo(undo: inverse) } else { state.completeUndo(redo: inverse) }
                return .success(())
            case .failure(let error):
                return .failure(error)
            }
        }
        guard let outcome else { NSSound.beep(); return }
        if case .failure(let error) = outcome { presentOperationError(error) }
        state.post(AppState.filesChanged)
        reload()
    }

    /// 글자 입력 중이면 그 입력 칸의 실행 취소 관리자.
    private var textUndoManager: UndoManager? {
        guard GlobalKeyHandler.isEditingText(in: view.window) else { return nil }
        return view.window?.firstResponder?.undoManager
    }

    // MARK: 압축 (F11)

    @objc func compressSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard let first = urls.first else { return }
        let directory = isSearching ? first.deletingLastPathComponent() : currentURL
        Task { await runOperation { try FileOperations.compress(urls, in: directory) } }
    }

    @objc func extractSelection(_ sender: Any?) {
        guard let zip = fileList.selectedItems.first(where: { $0.fileExtension == "zip" })?.url else { return }
        let directory = zip.deletingLastPathComponent()
        Task { await runOperation { try FileOperations.extract(zip, to: directory) } }
    }

    // MARK: 선택 (S3)

    @objc func invertSelection(_ sender: Any?) {
        fileList.invertSelection()
    }

    // MARK: 기타 (N7, F13, F14, F15)

    @objc func togglePin(_ sender: Any?) {
        let url = ((sender as? NSMenuItem)?.representedObject as? URL)
            ?? fileList.selectedItems.first(where: \.isNavigable)?.url
        guard let url else { return }
        state.togglePin(url)
    }

    @objc func openInTerminal(_ sender: Any?) {
        var folder = isThisMac ? Location.home : currentURL
        if !isBackgroundSender(sender), let item = fileList.selectedItems.first {
            folder = item.isNavigable ? item.url : item.url.deletingLastPathComponent()
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = targetURLs(sender)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func showProperties(_ sender: Any?) {
        let urls = targetURLs(sender)
        guard !urls.isEmpty else { return }
        PropertiesWindowController.show(for: urls)
    }

    // MARK: 보기 (V3, V4, V5, V7)

    @objc func setViewModeFromMenu(_ sender: NSMenuItem) {
        if let mode = ViewMode(rawValue: sender.tag) { setViewMode(mode) }
    }

    @objc func setSortKeyFromMenu(_ sender: NSMenuItem) {
        guard SortKey.allCases.indices.contains(sender.tag) else { return }
        var order = sortOrder
        order.key = SortKey.allCases[sender.tag]
        setSortOrder(order)
    }

    @objc func setSortDirectionFromMenu(_ sender: NSMenuItem) {
        var order = sortOrder
        order.ascending = sender.tag == 1
        setSortOrder(order)
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        state.showHidden.toggle()
    }

    @objc func toggleExtensions(_ sender: Any?) {
        state.showExtensions.toggle()
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        setPreviewVisible(!previewVisible)
    }

    @objc func focusAddressBar(_ sender: Any?) {
        addressBar.beginEditing()
    }

    @objc func focusSearch(_ sender: Any?) {
        guard !isThisMac else { return }
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: 공통 실행

    /// Core 작업을 앱 공유 작업 큐에서 백그라운드로 돌리고 실행 취소 기록, 목록 갱신, 오류 표시를 맡는다.
    /// 창이 닫혀도 작업과 실행 취소 기록은 끝까지 처리한다.
    /// job 이 있으면 차례가 왔을 때 진행률 창에 시작을 알리고, 끝나면 창에서 뺀다.
    @discardableResult
    func runOperation(renameResult: Bool = false, job: ProgressJob? = nil,
                      _ work: @escaping @Sendable () throws -> OperationResult) async -> OperationResult? {
        let state = self.state
        let outcome: Result<OperationResult, Error> = await state.operations.run {
            defer { job?.finish() }
            job?.begin()
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            if case .success(let done) = result { state.pushUndo(done.record) }
            return result
        }
        return finishOperation(outcome, renameResult: renameResult, folders: [])
    }

    /// 작업 결과를 화면에 반영한다. folders 와 결과 항목의 폴더는 탐색 창도 다시 읽는다.
    @discardableResult
    private func finishOperation(_ outcome: Result<OperationResult, Error>, renameResult: Bool,
                                 folders: [URL]) -> OperationResult? {
        switch outcome {
        case .success(let result):
            let changed = folders + result.resultURLs.map { $0.deletingLastPathComponent() } + [currentURL]
            state.post(AppState.filesChanged, userInfo: ["folders": changed.filter { !Location.isThisMac($0) }])
            reload(selecting: result.resultURLs, rename: renameResult ? result.resultURLs.first : nil)
            return result
        case .failure(let error):
            // 사용자가 취소했으면 Core 가 이미 되돌렸다. 알리지 않고 목록만 다시 읽는다.
            if error as? FileOperationError != .cancelled { presentOperationError(error) }
            state.post(AppState.filesChanged)
            reload()
            return nil
        }
    }

    func presentOperationError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch error as? FileOperationError {
        case .partialDeletion(let deleted, let failed, let reason)?:
            alert.alertStyle = .critical
            alert.messageText = "일부 항목만 영구 삭제되었습니다."
            let shown = deleted.prefix(10).map { "  \($0.path)" }
            let more = deleted.count > shown.count ? ["  외 \(deleted.count - shown.count)개"] : []
            alert.informativeText = (["'\(failed.lastPathComponent)'을(를) 삭제하지 못해 작업을 멈췄습니다.",
                                      "이유: \(reason)", "", "이미 삭제되어 되돌릴 수 없는 항목 \(deleted.count)개:"]
                                     + shown + more).joined(separator: "\n")
        case .destinationContainsSource(let path)?:
            alert.messageText = "대상의 같은 이름 항목이 옮기려는 원본을 포함하고 있습니다."
            alert.informativeText = "'\(URL(fileURLWithPath: path).lastPathComponent)'을(를) 덮어쓰거나 병합하면 원본도 사라지므로 작업을 멈췄습니다. 아무것도 바뀌지 않았습니다.\n\n대상: \(path)"
        case .destinationInsideSource(let path)?:
            alert.messageText = "폴더를 자기 자신이나 그 하위 폴더로 옮기거나 복사할 수 없습니다."
            alert.informativeText = "아무것도 바뀌지 않았습니다.\n\n대상: \(path)"
        default:
            alert.messageText = "작업을 완료할 수 없습니다."
            alert.informativeText = error.localizedDescription
        }
        if let window = ConflictDialog.hostWindow(preferring: view.window) {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - 메뉴 상태

extension BrowserViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selected = fileList.selectedItems
        let hasSelection = !selected.isEmpty && !isThisMac
        guard let action = menuItem.action else { return true }
        switch action {
        case #selector(goBack(_:)): return history.canGoBack
        case #selector(goForward(_:)): return history.canGoForward
        case #selector(goUp(_:)): return canGoUp
        case #selector(openSelection(_:)): return !selected.isEmpty
        case #selector(openInNewTab(_:)):
            return menuItem.representedObject is URL || selected.contains(where: \.isNavigable)
        case #selector(cut(_:)), #selector(copy(_:)), #selector(moveToTrash(_:)), #selector(duplicateSelection(_:)),
             #selector(deletePermanently(_:)), #selector(compressSelection(_:)):
            return hasSelection
        case #selector(copyPath(_:)), #selector(revealInFinder(_:)), #selector(showProperties(_:)):
            return !isThisMac || hasSelection
        case #selector(renameSelection(_:)): return selected.count == 1 && !isThisMac
        case #selector(paste(_:)), #selector(pasteMove(_:)): return ClipboardBridge.canPaste && !isThisMac
        case #selector(newFolder(_:)), #selector(newTextFile(_:)),
             #selector(invertSelection(_:)), #selector(focusSearch(_:)):
            return !isThisMac
        case #selector(extractSelection(_:)): return selected.contains { $0.fileExtension == "zip" }
        case #selector(undo(_:)): return textUndoManager.map(\.canUndo) ?? !state.undoStack.isEmpty
        case #selector(redo(_:)): return textUndoManager.map(\.canRedo) ?? !state.redoStack.isEmpty
        case #selector(togglePin(_:)):
            return menuItem.representedObject is URL || selected.contains(where: \.isNavigable)
        case #selector(setViewModeFromMenu(_:)):
            menuItem.state = menuItem.tag == viewMode.rawValue ? .on : .off
        case #selector(setSortKeyFromMenu(_:)):
            let index = SortKey.allCases.firstIndex(of: sortOrder.key) ?? 0
            menuItem.state = menuItem.tag == index ? .on : .off
        case #selector(setSortDirectionFromMenu(_:)):
            menuItem.state = (menuItem.tag == 1) == sortOrder.ascending ? .on : .off
        case #selector(toggleHiddenFiles(_:)): menuItem.state = state.showHidden ? .on : .off
        case #selector(toggleExtensions(_:)): menuItem.state = state.showExtensions ? .on : .off
        case #selector(togglePreviewPane(_:)): menuItem.state = previewVisible ? .on : .off
        default: break
        }
        return true
    }
}

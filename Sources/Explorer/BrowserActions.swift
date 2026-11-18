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
                ClipboardBridge.finishCutPaste()
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

    /// 충돌이 있으면 대화상자(F8)로 정책을 묻고 복사·이동한다. 성공하면 true.
    @discardableResult
    func performTransfer(_ urls: [URL], to destination: URL, move: Bool) async -> Bool {
        guard !urls.isEmpty else { return false }
        var policy = ConflictPolicy.keepBoth
        let conflicts = ConflictDialog.conflicts(for: urls, in: destination)
        if !conflicts.isEmpty {
            guard let chosen = await ConflictDialog.ask(conflicts: conflicts, total: urls.count,
                                                        destination: destination, move: move,
                                                        window: view.window) else { return false }
            policy = chosen
        }
        let chosenPolicy = policy
        let result = await runOperation {
            move ? try FileOperations.move(urls, to: destination, conflict: chosenPolicy)
                 : try FileOperations.copy(urls, to: destination, conflict: chosenPolicy)
        }
        return result != nil
    }

    // MARK: 삭제 (F4)

    @objc func moveToTrash(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, !isThisMac else { return }
        Task { await runOperation { try FileOperations.trash(urls) } }
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

    @objc func newFolder(_ sender: Any?) {
        guard !isThisMac else { return }
        let directory = currentURL
        Task { await runOperation(renameResult: true) { try FileOperations.createFolder(in: directory) } }
    }

    @objc func newTextFile(_ sender: Any?) {
        guard !isThisMac else { return }
        let directory = currentURL
        Task { await runOperation(renameResult: true) { try FileOperations.createFile(in: directory) } }
    }

    // MARK: 실행 취소 (F7)

    @objc func undo(_ sender: Any?) {
        guard let record = state.popUndo() else { NSSound.beep(); return }
        Task {
            do {
                let redo = try await Task.detached(priority: .userInitiated) {
                    try FileOperations.undo(record)
                }.value
                state.pushRedo(redo)
            } catch {
                presentOperationError(error)
            }
            reload()
        }
    }

    @objc func redo(_ sender: Any?) {
        guard let record = state.popRedo() else { NSSound.beep(); return }
        Task {
            do {
                let undo = try await Task.detached(priority: .userInitiated) {
                    try FileOperations.undo(record)
                }.value
                state.pushUndoKeepingRedo(undo)
            } catch {
                presentOperationError(error)
            }
            reload()
        }
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

    /// Core 작업을 백그라운드에서 돌리고 실행 취소 기록, 목록 갱신, 오류 표시를 맡는다.
    @discardableResult
    func runOperation(renameResult: Bool = false,
                      _ work: @escaping @Sendable () throws -> OperationResult) async -> OperationResult? {
        do {
            let result = try await Task.detached(priority: .userInitiated) { try work() }.value
            state.pushUndo(result.record)
            reload(selecting: result.resultURLs, rename: renameResult ? result.resultURLs.first : nil)
            return result
        } catch {
            presentOperationError(error)
            reload()
            return nil
        }
    }

    func presentOperationError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "작업을 완료할 수 없습니다."
        alert.informativeText = error.localizedDescription
        if let window = view.window {
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
        case #selector(goUp(_:)): return !isThisMac
        case #selector(openSelection(_:)): return !selected.isEmpty
        case #selector(openInNewTab(_:)):
            return menuItem.representedObject is URL || selected.contains(where: \.isNavigable)
        case #selector(cut(_:)), #selector(copy(_:)), #selector(moveToTrash(_:)),
             #selector(deletePermanently(_:)), #selector(compressSelection(_:)):
            return hasSelection
        case #selector(copyPath(_:)), #selector(revealInFinder(_:)), #selector(showProperties(_:)):
            return !isThisMac || hasSelection
        case #selector(renameSelection(_:)): return selected.count == 1 && !isThisMac
        case #selector(paste(_:)): return ClipboardBridge.canPaste && !isThisMac
        case #selector(newFolder(_:)), #selector(newTextFile(_:)),
             #selector(invertSelection(_:)), #selector(focusSearch(_:)):
            return !isThisMac
        case #selector(extractSelection(_:)): return selected.contains { $0.fileExtension == "zip" }
        case #selector(undo(_:)): return !state.undoStack.isEmpty
        case #selector(redo(_:)): return !state.redoStack.isEmpty
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

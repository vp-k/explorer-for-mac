import AppKit
import ExplorerCore

/// F10 드래그 앤 드롭. 같은 볼륨은 이동, 다른 볼륨은 복사, ⌥ 를 누르면 복사.
@MainActor
enum DragPolicy {
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func operation(for info: NSDraggingInfo, urls: [URL], destination: URL) -> NSDragOperation {
        guard !urls.isEmpty else { return [] }
        let destKey = Location.key(destination)
        // 자기 자신 위에는 놓을 수 없다.
        if urls.contains(where: { Location.key($0) == destKey }) { return [] }
        let mask = info.draggingSourceOperationMask
        let canMove = mask.contains(.move) || mask.contains(.generic)
        let wantsCopy = NSEvent.modifierFlags.contains(.option) || !canMove
        if wantsCopy { return mask.contains(.copy) ? .copy : [] }
        let sameFolder = urls.allSatisfy { Location.key($0.deletingLastPathComponent()) == destKey }
        if sameFolder { return [] }
        if urls.allSatisfy({ FileOperations.isSameVolume($0, destination) }) { return .move }
        return mask.contains(.copy) ? .copy : .move
    }
}

extension FileListController {
    private func dropTarget(index: Int?, on: Bool) -> URL? {
        if on, let index, index >= 0, index < items.count, items[index].isNavigable {
            return items[index].url
        }
        return delegate?.fileListDropDestination()
    }

    // MARK: 자세히 보기

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        row < items.count ? items[row].url as NSURL : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let urls = DragPolicy.fileURLs(from: info.draggingPasteboard)
        let onFolder = dropOperation == .on && row >= 0 && row < items.count && items[row].isNavigable
        if !onFolder { tableView.setDropRow(-1, dropOperation: .on) }
        guard let destination = dropTarget(index: row, on: onFolder) else { return [] }
        return DragPolicy.operation(for: info, urls: urls, destination: destination)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = DragPolicy.fileURLs(from: info.draggingPasteboard)
        guard let destination = dropTarget(index: row, on: dropOperation == .on) else { return false }
        let operation = DragPolicy.operation(for: info, urls: urls, destination: destination)
        guard !operation.isEmpty else { return false }
        return delegate?.fileListDrop(urls, onto: destination, operation: operation) ?? false
    }

    // MARK: 아이콘 보기

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        indexPath.item < items.count ? items[indexPath.item].url as NSURL : nil
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let urls = DragPolicy.fileURLs(from: info.draggingPasteboard)
        let index = proposedIndexPath.pointee.item
        let onFolder = dropOperation.pointee == .on && index < items.count && items[index].isNavigable
        guard let destination = dropTarget(index: index, on: onFolder) else { return [] }
        return DragPolicy.operation(for: info, urls: urls, destination: destination)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let urls = DragPolicy.fileURLs(from: info.draggingPasteboard)
        guard let destination = dropTarget(index: indexPath.item, on: dropOperation == .on) else { return false }
        let operation = DragPolicy.operation(for: info, urls: urls, destination: destination)
        guard !operation.isEmpty else { return false }
        return delegate?.fileListDrop(urls, onto: destination, operation: operation) ?? false
    }
}

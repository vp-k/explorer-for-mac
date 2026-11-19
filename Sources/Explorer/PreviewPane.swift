import AppKit
import ExplorerCore
import Quartz

/// V7 미리 보기 창 (QuickLook).
@MainActor
final class PreviewPane: FillView {
    private let previewView: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
    private let placeholder = UI.label(L("미리 볼 파일을 선택하세요."), color: Theme.secondaryText)
    private var currentURL: URL?

    init() {
        super.init(Theme.contentBackground)
        UI.pin(previewView, to: self)
        previewView.autostarts = true
        placeholder.alignment = .center
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -20),
        ])
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ item: FileItem?) {
        guard let item, !item.isNavigable else {
            currentURL = nil
            previewView.previewItem = nil
            previewView.isHidden = true
            placeholder.isHidden = false
            placeholder.stringValue = item == nil ? L("미리 볼 파일을 선택하세요.") : L("폴더는 미리 볼 수 없습니다.")
            return
        }
        guard currentURL != item.url else { return }
        currentURL = item.url
        previewView.isHidden = false
        placeholder.isHidden = true
        previewView.previewItem = item.url as NSURL
    }
}

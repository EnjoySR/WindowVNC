import AVFoundation
import AppKit
import CoreMedia

/// 用 AVSampleBufferDisplayLayer 直接吃 SCStream 的 CMSampleBuffer，零拷贝上屏。
/// M1 阶段这个预览就是"对方将会看到的画面"的等价物。
final class PreviewLayerView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func enqueue(_ sb: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        // 分辨率切换时这一层可能进入 failed，不 flush 的话预览会永久卡住
        if renderer.status == .failed {
            renderer.flush()
            NSLog("[Preview] 渲染层失败已重置: \(String(describing: renderer.error))")
        }
        guard renderer.isReadyForMoreMediaData else { return }
        renderer.enqueue(sb)
    }
}

final class PreviewWindowController: NSWindowController {
    let previewView = PreviewLayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
    private let statsLabel = NSTextField(labelWithString: "等待第一帧…")
    private let clientLabel = NSTextField(labelWithString: "无观看者")
    var onClose: (() -> Void)?

    init(title: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "共享预览 — \(title)"
        w.isReleasedWhenClosed = false
        super.init(window: w)

        let container = NSView(frame: w.contentRect(forFrameRect: w.frame))
        container.autoresizingMask = [.width, .height]

        previewView.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.lineBreakMode = .byTruncatingTail

        clientLabel.translatesAutoresizingMaskIntoConstraints = false
        clientLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        clientLabel.textColor = .secondaryLabelColor
        clientLabel.lineBreakMode = .byTruncatingTail

        container.addSubview(previewView)
        container.addSubview(statsLabel)
        container.addSubview(clientLabel)
        // 这几个常数必须和 statsRowHeight 精确对上，否则预览视图的宽高比
        // 和视频对不上，resizeAspect 就会在左右留黑边
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: container.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: statsLabel.topAnchor,
                                                constant: -Self.statsGap),
            statsLabel.heightAnchor.constraint(equalToConstant: 16),
            statsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statsLabel.bottomAnchor.constraint(equalTo: clientLabel.topAnchor),
            clientLabel.heightAnchor.constraint(equalToConstant: 16),
            clientLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            clientLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            clientLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                                constant: -Self.statsBottomInset),
        ])
        w.contentView = container
        w.center()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                self?.onClose?()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let statsGap: CGFloat = 6
    private static let statsLabelHeight: CGFloat = 32   // 两行：本地统计 + 观看者统计
    private static let statsBottomInset: CGFloat = 8
    private var statsRowHeight: CGFloat {
        Self.statsGap + Self.statsLabelHeight + Self.statsBottomInset
    }

    /// 让预览窗口贴合被共享窗口的真实宽高比。
    /// 传进来的是像素尺寸，1x 时就按原尺寸显示，2x 时缩一半（否则窗口会大得离谱）。
    func adaptSize(to pixelSize: CGSize) {
        guard let window, pixelSize.width > 1, pixelSize.height > 1 else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
        let maxW = visible.width * 0.8
        let maxH = visible.height * 0.8 - statsRowHeight

        var w = pixelSize.width, h = pixelSize.height
        let shrink = min(1, min(maxW / w, maxH / h))
        w *= shrink; h *= shrink

        // 保持窗口左上角不动，避免每次尺寸变化窗口都往屏幕中间跳
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        let content = NSSize(width: w.rounded(), height: (h + statsRowHeight).rounded())
        // 锁住宽高比，这样你手动拖预览窗口时也不会重新出现黑边
        window.contentAspectRatio = content
        window.setContentSize(content)
        window.setFrameTopLeftPoint(topLeft)
    }

    private var clientLine = ""

    func updateClients(_ clients: [ClientStats]) {
        clientLine = clients.isEmpty ? "" : clients.map {
            String(format: "%@ %@ %.0ffps %.1fMbps 编码%.0fms 发送%.0fms %.0fKB",
                   $0.encoding, $0.pixelFormat, $0.fps, $0.mbps,
                   $0.encodeMs, $0.sendMs, $0.lastFrameKB)
        }.joined(separator: "  |  ")
        clientLabel.stringValue = clientLine.isEmpty ? "无观看者" : clientLine
    }

    func update(stats: FrameStats) {
        statsLabel.stringValue = String(
            format: "%.0f fps   %.0f×%.0f px   脏矩形 %d 块 / 占比 %.1f%%   观看者 %d   状态 %@",
            stats.fps, stats.pixelSize.width, stats.pixelSize.height,
            stats.dirtyRectCount, stats.dirtyRatio * 100,
            stats.clientCount, stats.status as NSString)
    }
}

import AVFoundation
import AppKit
import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit

/// 一帧的统计信息，用来验证脏矩形机制到底省了多少
struct FrameStats {
    var pixelSize: CGSize = .zero
    var dirtyRectCount: Int = 0
    var dirtyRatio: Double = 0      // 脏区面积 / 全窗口面积
    var fps: Double = 0
    var droppedOrIdle: Int = 0
    var status: String = "-"
    var clientCount: Int = 0
}

protocol CaptureEngineDelegate: AnyObject {
    func captureEngine(_ engine: CaptureEngine, didOutput sampleBuffer: CMSampleBuffer,
                       dirtyRects: [CGRect])
    func captureEngine(_ engine: CaptureEngine, didUpdate stats: FrameStats)
    func captureEngine(_ engine: CaptureEngine, didFailWith error: Error)
    /// 目标窗口尺寸变了（用户拖了窗口边框，或者切了画质）
    func captureEngine(_ engine: CaptureEngine, didResizeTo pixelSize: CGSize)
    /// 目标窗口没了（被关掉了）
    func captureEngineWindowDisappeared(_ engine: CaptureEngine)
}

extension CaptureEngineDelegate {
    func captureEngine(_ engine: CaptureEngine, didResizeTo pixelSize: CGSize) {}
    func captureEngineWindowDisappeared(_ engine: CaptureEngine) {}
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var delegate: CaptureEngineDelegate?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture.output", qos: .userInteractive)

    private(set) var targetWindow: SCWindow?
    private(set) var includeChildWindows = true
    private(set) var pixelScale: CGFloat = 1.0
    private(set) var fps: Int = 30
    /// 窗口的**当前**尺寸。SCWindow.frame 是选窗口那一刻的快照，会过期。
    private var currentWindowFrame: CGRect = .zero
    private var watchTimer: DispatchSourceTimer?
    private var pendingFrame: CGRect?
    private var reconfiguring = false

    // 统计
    private var frameTimestamps: [CFTimeInterval] = []
    private var stats = FrameStats()
    private var lastStatsPush: CFTimeInterval = 0
    private var idleCount = 0
    private var framesLogged = 0

    var isRunning: Bool { stream != nil }

    /// pixelScale = 1.0 表示按窗口的"视觉尺寸"传（Retina 上像素量只有原生的 1/4，
    /// 编码耗时和带宽同步降 4 倍，而对方看到的清晰度等同于在普通显示器上看这个窗口）。
    /// 2.0 才是 Retina 原生像素。
    func start(window: SCWindow, includeChildWindows: Bool, fps: Int,
               pixelScale: CGFloat = 1.0) async throws {
        await stop()
        self.targetWindow = window
        self.includeChildWindows = includeChildWindows
        self.pixelScale = pixelScale
        self.fps = fps
        self.currentWindowFrame = window.frame

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = makeConfiguration()

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s

        DebugLog.reset()
        framesLogged = 0
        frameTimestamps.removeAll()
        idleCount = 0
        stats = FrameStats()
        stats.pixelSize = CGSize(width: cfg.width, height: cfg.height)
        startWindowWatcher(windowID: window.windowID)
    }

    // MARK: - 盯着窗口尺寸

    /// SCStream 的输出尺寸是创建时写死的，用户拖动窗口边框它不会自己跟着变——
    /// 只会把新内容缩放留边塞进旧画布。所以得主动轮询窗口实际尺寸并热更新配置。
    private func startWindowWatcher(windowID: CGWindowID) {
        watchTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.2, repeating: 0.15)
        t.setEventHandler { [weak self] in self?.pollWindowFrame(windowID) }
        watchTimer = t
        t.resume()
    }

    private func pollWindowFrame(_ windowID: CGWindowID) {
        guard let frame = Self.windowBounds(windowID) else {
            watchTimer?.cancel()
            watchTimer = nil
            delegate?.captureEngineWindowDisappeared(self)
            return
        }
        guard abs(frame.width - currentWindowFrame.width) >= 1 ||
              abs(frame.height - currentWindowFrame.height) >= 1 else {
            // 尺寸稳定下来了，把上一轮攒的改动提交掉
            if let pending = pendingFrame {
                pendingFrame = nil
                applyFrame(pending)
            }
            return
        }
        // 拖动过程中尺寸每帧都在变，先记下来，等停手了再提交，
        // 否则每次变化都要发一次 DesktopSize + 全帧，观看者那边会疯狂闪烁
        pendingFrame = frame
        currentWindowFrame.size = frame.size
    }

    private func applyFrame(_ frame: CGRect) {
        guard !reconfiguring, stream != nil else { return }
        reconfiguring = true
        currentWindowFrame = frame
        let cfg = makeConfiguration()
        Task { [weak self] in
            guard let self, let stream = self.stream else { return }
            do {
                try await stream.updateConfiguration(cfg)
                self.stats.pixelSize = CGSize(width: cfg.width, height: cfg.height)
                self.delegate?.captureEngine(self,
                    didResizeTo: CGSize(width: cfg.width, height: cfg.height))
                NSLog("[CaptureEngine] 窗口改尺寸 -> \(cfg.width)x\(cfg.height)")
            } catch {
                NSLog("[CaptureEngine] updateConfiguration 失败: \(error)")
            }
            self.reconfiguring = false
        }
    }

    /// 用 CGWindowList 拿窗口当前边框，比重新枚举 SCShareableContent 轻得多
    static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
                as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.width = max(2, Int(currentWindowFrame.width * pixelScale))
        cfg.height = max(2, Int(currentWindowFrame.height * pixelScale))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.queueDepth = 6
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true      // 演示场景：对方需要看到你鼠标指到哪
        cfg.capturesAudio = false
        cfg.backgroundColor = .black
        cfg.shouldBeOpaque = true
        cfg.ignoreShadowsSingleWindow = true
        cfg.ignoreGlobalClipSingleWindow = true
        cfg.includeChildWindows = includeChildWindows
        return cfg
    }

    /// 热更新画质。不重建 SCStream，也不断开已连接的观看者——
    /// 分辨率变化会走和"拖动窗口改大小"完全相同的那条链路：
    /// 帧缓冲发现尺寸变了 -> 发 DesktopSize 伪编码 -> 观看者画面自动重排。
    func updatePixelScale(_ scale: CGFloat) async throws {
        guard let stream else { return }
        pixelScale = scale
        let cfg = makeConfiguration()
        try await stream.updateConfiguration(cfg)
        stats.pixelSize = CGSize(width: cfg.width, height: cfg.height)
        delegate?.captureEngine(self, didResizeTo: CGSize(width: cfg.width, height: cfg.height))
        NSLog("[CaptureEngine] 画质切到 \(scale)x -> \(cfg.width)x\(cfg.height)")
    }

    func stop() async {
        watchTimer?.cancel()
        watchTimer = nil
        pendingFrame = nil
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                 createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = array.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }

        switch status {
        case .complete:
            break
        case .idle, .blank, .suspended, .started, .stopped:
            idleCount += 1
            stats.status = "\(status)"
            stats.droppedOrIdle = idleCount
            pushStatsIfNeeded()
            return
        @unknown default:
            return
        }

        stats.status = "complete"

        // 脏矩形统计
        var dirtyArea: CGFloat = 0
        var rects: [CGRect] = []
        if let dicts = info[.dirtyRects] as? [[String: Any]] {
            for d in dicts {
                if let r = CGRect(dictionaryRepresentation: d as CFDictionary) {
                    rects.append(r)
                    dirtyArea += r.width * r.height
                }
            }
        }
        let dirtyCount = rects.count
        // contentRect 是**点**为单位（日志实测 864x500，contentScale=0.5），
        // 而 dirtyRects 是**像素**为单位（1728x41）。不换算的话占比会差 4 倍，
        // 之前预览里出现过 "占比 351.9%" 这种不可能的数字就是这么来的。
        var contentArea: CGFloat = CGFloat(max(1, stats.pixelSize.width * stats.pixelSize.height))
        if let cd = info[.contentRect] as? [String: Any],
           let cr = CGRect(dictionaryRepresentation: cd as CFDictionary) {
            let cs = (info[.contentScale] as? CGFloat) ?? 1
            contentArea = max(1, cr.width * cr.height / (cs * cs))
        }

        // FPS：一秒滑动窗口
        let now = CACurrentMediaTime()
        frameTimestamps.append(now)
        frameTimestamps.removeAll { now - $0 > 1.0 }

        if framesLogged < 40 {
            framesLogged += 1
            let surface = "\(CVPixelBufferGetWidth(sampleBuffer.imageBuffer!))x\(CVPixelBufferGetHeight(sampleBuffer.imageBuffer!))"
            var cr = "nil"
            if let cd = info[.contentRect] as? [String: Any],
               let r = CGRect(dictionaryRepresentation: cd as CFDictionary) {
                cr = "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
            }
            let scaleInfo = "scaleFactor=\(info[.scaleFactor] ?? "-") contentScale=\(info[.contentScale] ?? "-")"
            let rectDesc = rects.prefix(6).map {
                "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))"
            }.joined(separator: " | ")
            DebugLog.log("CAP surface=\(surface) contentRect=\(cr) \(scaleInfo) "
                       + "dirty=\(rects.count) [\(rectDesc)] area=\(Int(dirtyArea))")
        }
        stats.dirtyRectCount = dirtyCount
        stats.dirtyRatio = Double(dirtyArea / contentArea)
        stats.fps = Double(frameTimestamps.count)

        // 让预览层立刻显示这一帧
        Self.markDisplayImmediately(sampleBuffer)
        delegate?.captureEngine(self, didOutput: sampleBuffer, dirtyRects: rects)
        pushStatsIfNeeded(now: now)
    }

    private func pushStatsIfNeeded(now: CFTimeInterval = CACurrentMediaTime()) {
        guard now - lastStatsPush > 0.25 else { return }
        lastStatsPush = now
        let snapshot = stats
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.captureEngine(self, didUpdate: snapshot)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.captureEngine(self, didFailWith: error)
        }
    }

    // MARK: - helpers

    /// AVSampleBufferDisplayLayer 没有 timebase 时，靠这个标记让帧立即上屏
    static func markDisplayImmediately(_ sb: CMSampleBuffer) {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
              CFArrayGetCount(arr) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }

    /// SCWindow.frame 是 CG 坐标（左上原点，points），找出它所在屏幕的缩放倍率
    static func scaleFactor(for frame: CGRect) -> CGFloat {
        guard let primary = NSScreen.screens.first else { return 2 }
        let h = primary.frame.height
        var best = primary.backingScaleFactor
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let ns = screen.frame
            let cg = CGRect(x: ns.origin.x, y: h - ns.origin.y - ns.height,
                            width: ns.width, height: ns.height)
            let inter = cg.intersection(frame)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea { bestArea = area; best = screen.backingScaleFactor }
        }
        return best
    }
}

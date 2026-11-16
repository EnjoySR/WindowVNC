import CoreMedia
import CoreVideo
import Foundation

/// 脏区累积器。RFB 是客户端拉取模型：一帧来了不一定马上发得出去，
/// 所以每个客户端各自攒着"自上次发送以来变脏的区域"。
struct DirtyRegion {
    private(set) var rects: [CGRect] = []
    private(set) var isFull = false

    /// 攒太多小矩形反而不划算（每个矩形都有 12 字节头 + 独立的编码开销），
    /// 超过阈值就直接合并成一个包围盒。
    private static let maxRects = 24

    mutating func add(_ r: CGRect) {
        guard !isFull, !r.isEmpty else { return }
        // 去重：ScreenCaptureKit 有时会给出互相重叠甚至完全重复的脏矩形，
        // 不去重的话同一块像素会被编码发送多次（实测出现过整窗口发两遍、单帧 13MB）
        for existing in rects where existing.contains(r) { return }
        rects.removeAll { r.contains($0) }
        rects.append(r)
        if rects.count > Self.maxRects { collapse() }
    }

    mutating func addFull(_ size: CGSize) {
        isFull = true
        rects = [CGRect(origin: .zero, size: size)]
    }

    private mutating func collapse() {
        guard let first = rects.first else { return }
        let box = rects.dropFirst().reduce(first) { $0.union($1) }
        rects = [box]
    }

    mutating func clear() {
        rects.removeAll(keepingCapacity: true)
        isFull = false
    }

    var isEmpty: Bool { rects.isEmpty }
}

/// 服务端侧的持久帧缓冲：BGRA，行紧凑（stride = width * 4）。
/// 捕获线程往里写，编码线程从里读，靠一把读写锁隔开。
final class FrameBuffer {
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var data: UnsafeMutablePointer<UInt8>?
    var stride: Int { width * 4 }

    private let lock = NSLock()
    /// 尺寸变化的代数，客户端靠它判断要不要发 DesktopSize
    private(set) var sizeGeneration: UInt64 = 0

    deinit { data?.deallocate() }

    func withReadLock<T>(_ body: (UnsafePointer<UInt8>?, Int, Int, Int) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(data.map { UnsafePointer($0) }, width, height, stride)
    }

    func currentSize() -> (Int, Int, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (width, height, sizeGeneration)
    }

    private func resizeLocked(width w: Int, height h: Int) {
        data?.deallocate()
        width = w
        height = h
        let bytes = w * h * 4
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(bytes, 4))
        p.initialize(repeating: 0, count: max(bytes, 4))
        data = p
        sizeGeneration &+= 1
    }

    /// 把这一帧的脏区拷进来。返回实际变脏的区域（尺寸变了就是全屏）。
    @discardableResult
    func update(from pixelBuffer: CVPixelBuffer, dirtyRects: [CGRect]) -> DirtyRegion {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return DirtyRegion() }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return DirtyRegion() }
        let srcStride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        lock.lock()
        defer { lock.unlock() }

        var region = DirtyRegion()
        let sizeChanged = (srcW != width || srcH != height)
        if sizeChanged {
            resizeLocked(width: srcW, height: srcH)
        }
        guard let dst = data else { return region }

        // 尺寸变了、或者拿不到有效脏矩形，就整帧拷贝
        var rects = dirtyRects.compactMap { r -> CGRect? in
            let clamped = r.intersection(CGRect(x: 0, y: 0, width: srcW, height: srcH))
            return clamped.isNull || clamped.isEmpty ? nil : clamped.integral
        }
        if sizeChanged || rects.isEmpty {
            rects = [CGRect(x: 0, y: 0, width: srcW, height: srcH)]
            region.addFull(CGSize(width: srcW, height: srcH))
        } else {
            for r in rects { region.add(r) }
        }

        let dstStride = srcW * 4
        for r in rects {
            let x = Int(r.minX), y = Int(r.minY)
            let w = min(Int(r.width), srcW - x), h = min(Int(r.height), srcH - y)
            guard w > 0, h > 0 else { continue }
            let rowBytes = w * 4
            for row in 0..<h {
                let s = srcBase.advanced(by: (y + row) * srcStride + x * 4)
                let d = dst.advanced(by: (y + row) * dstStride + x * 4)
                memcpy(d, s, rowBytes)
            }
        }
        return region
    }
}

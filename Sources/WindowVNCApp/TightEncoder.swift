import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Tight 编码（TightVNC 扩展，RealVNC Viewer / TigerVNC 都支持）。
///
/// 核心思路：不同内容用不同压缩方式，这是它比 Zlib/ZRLE 强的原因。
///   纯色区域   -> Fill，3~4 字节搞定
///   UI / 文字  -> 调色板 + zlib，无损，字是锐的
///   照片 / 视频 -> JPEG，有损但压缩比高
///
/// 分类策略：先整体判断，颜色数少就整块走无损；颜色太多说明是混合内容，
/// 再切成 256×256 的瓦片逐块判断——这样一个网页里的正文走无损、配图走 JPEG。
final class TightEncoder {
    private var streams: [ZlibStream] = (0..<4).map { _ in ZlibStream() }
    /// JPEG 质量。0.8 在文字上已经能看，照片上几乎无损感知
    var jpegQuality: CGFloat = 0.8
    /// 颜色数超过这个值就不再尝试调色板
    private let maxPaletteColors = 256
    private let tileSize = 256

    func reset() { streams.forEach { $0.reset() } }

    /// 编码一个脏矩形，可能产出多个 RFB 矩形（瓦片）。
    /// 返回值是完整的 RFB 矩形数据（含 12 字节头），以及矩形个数。
    func encode(rect: CGRect,
                fb: UnsafePointer<UInt8>, fbStride: Int,
                format: PixelFormat,
                into out: inout [UInt8]) -> Int {
        let x = Int(rect.minX), y = Int(rect.minY)
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 0, h > 0 else { return 0 }

        // 小块或者颜色单一，就整块编码，不切瓦片
        let area = w * h
        if area <= 4096 {
            return encodeTile(x: x, y: y, w: w, h: h, fb: fb, fbStride: fbStride,
                              format: format, allowJPEG: true, into: &out)
        }

        let analysis = analyze(x: x, y: y, w: w, h: h, fb: fb, fbStride: fbStride)
        if analysis.colorCount <= maxPaletteColors {
            // 整块颜色就不多（典型：纯文字页面、纯色背景），一个矩形拿下
            return encodeTile(x: x, y: y, w: w, h: h, fb: fb, fbStride: fbStride,
                              format: format, allowJPEG: true,
                              precomputed: analysis, into: &out)
        }

        // 混合内容，切瓦片分别处理
        var count = 0
        var ty = y
        while ty < y + h {
            let th = min(tileSize, y + h - ty)
            var tx = x
            while tx < x + w {
                let tw = min(tileSize, x + w - tx)
                count += encodeTile(x: tx, y: ty, w: tw, h: th, fb: fb, fbStride: fbStride,
                                    format: format, allowJPEG: true, into: &out)
                tx += tw
            }
            ty += th
        }
        return count
    }

    // MARK: - 单块编码

    private func encodeTile(x: Int, y: Int, w: Int, h: Int,
                            fb: UnsafePointer<UInt8>, fbStride: Int,
                            format: PixelFormat,
                            allowJPEG: Bool,
                            precomputed: Analysis? = nil,
                            into out: inout [UInt8]) -> Int {
        let a = precomputed ?? analyze(x: x, y: y, w: w, h: h, fb: fb, fbStride: fbStride)

        appendRectHeader(x: x, y: y, w: w, h: h, encoding: .tight, into: &out)

        if a.colorCount == 1 {
            // Fill：控制字节 0x80 + 一个 TPIXEL
            out.append(0x80)
            appendTPixel(a.palette[0], into: &out)
            return 1
        }

        if a.colorCount == 2 {
            encodeMono(x: x, y: y, w: w, h: h, fb: fb, fbStride: fbStride,
                       palette: a.palette, into: &out)
            return 1
        }

        if a.colorCount <= maxPaletteColors {
            encodePalette(x: x, y: y, w: w, h: h, fb: fb, fbStride: fbStride,
                          palette: a.palette, into: &out)
            return 1
        }

        if allowJPEG,
           let jpeg = Self.jpegData(fb: fb, fbStride: fbStride, x: x, y: y, w: w, h: h,
                                    quality: jpegQuality) {
            out.append(0x90)                    // JpegCompression
            appendCompactLength(jpeg.count, into: &out)
            out.append(contentsOf: jpeg)
            return 1
        }

        // 兜底：CopyFilter + zlib（无损）
        encodeCopy(x: x, y: y, w: w, h: h, fb: fb, fbStride: fbStride, into: &out)
        return 1
    }

    // MARK: - 各种子编码

    /// 2 色：1 bit / 像素，每行按字节对齐
    private func encodeMono(x: Int, y: Int, w: Int, h: Int,
                            fb: UnsafePointer<UInt8>, fbStride: Int,
                            palette: [UInt32], into out: inout [UInt8]) {
        let rowBytes = (w + 7) / 8
        var data = [UInt8](repeating: 0, count: rowBytes * h)
        let bg = palette[0]
        for row in 0..<h {
            let src = fb + (y + row) * fbStride + x * 4
            let base = row * rowBytes
            for col in 0..<w {
                let px = loadPixel(src + col * 4)
                if px != bg {
                    data[base + col / 8] |= UInt8(0x80) >> UInt8(col % 8)
                }
            }
        }
        // 控制字节：basic + readFilter + stream 1
        out.append(0x40 | (1 << 4))
        out.append(1)                 // filter id = Palette
        out.append(1)                 // numColors - 1
        appendTPixel(palette[0], into: &out)
        appendTPixel(palette[1], into: &out)
        appendFiltered(data, stream: 1, into: &out)
    }

    /// 3~256 色：1 字节索引 / 像素
    private func encodePalette(x: Int, y: Int, w: Int, h: Int,
                               fb: UnsafePointer<UInt8>, fbStride: Int,
                               palette: [UInt32], into out: inout [UInt8]) {
        var index = [UInt32: UInt8]()
        index.reserveCapacity(palette.count)
        for (i, c) in palette.enumerated() { index[c] = UInt8(i) }

        var data = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let src = fb + (y + row) * fbStride + x * 4
            let base = row * w
            for col in 0..<w {
                data[base + col] = index[loadPixel(src + col * 4)] ?? 0
            }
        }
        out.append(0x40 | (2 << 4))   // basic + readFilter + stream 2
        out.append(1)                 // filter id = Palette
        out.append(UInt8(palette.count - 1))
        for c in palette { appendTPixel(c, into: &out) }
        appendFiltered(data, stream: 2, into: &out)
    }

    /// 无损兜底：原始 TPIXEL + zlib
    private func encodeCopy(x: Int, y: Int, w: Int, h: Int,
                            fb: UnsafePointer<UInt8>, fbStride: Int,
                            into out: inout [UInt8]) {
        var data = [UInt8](repeating: 0, count: w * h * 3)
        var o = 0
        for row in 0..<h {
            let src = fb + (y + row) * fbStride + x * 4
            for col in 0..<w {
                let p = src + col * 4
                data[o] = p[2]; data[o + 1] = p[1]; data[o + 2] = p[0]  // BGRA -> RGB
                o += 3
            }
        }
        out.append(0x00)              // basic，无 filter（= CopyFilter），stream 0
        appendFiltered(data, stream: 0, into: &out)
    }

    /// Tight 规定：过滤后数据 < 12 字节就不压缩、也不写长度
    private func appendFiltered(_ data: [UInt8], stream: Int, into out: inout [UInt8]) {
        if data.count < 12 {
            out.append(contentsOf: data)
            return
        }
        let compressed = streams[stream].compress(data)
        appendCompactLength(compressed.count, into: &out)
        out.append(contentsOf: compressed)
    }

    // MARK: - 颜色分析

    struct Analysis {
        var colorCount: Int
        var palette: [UInt32]
    }

    /// 数颜色，超过 256 就提前退出。用开放寻址的定长哈希表，比 Swift Set 快很多。
    private func analyze(x: Int, y: Int, w: Int, h: Int,
                         fb: UnsafePointer<UInt8>, fbStride: Int) -> Analysis {
        let capacity = 1024                      // 2 的幂，装 256 个键负载率 25%
        var keys = [UInt32](repeating: 0, count: capacity)
        var used = [Bool](repeating: false, count: capacity)
        var palette: [UInt32] = []
        palette.reserveCapacity(maxPaletteColors)

        for row in 0..<h {
            let src = fb + (y + row) * fbStride + x * 4
            for col in 0..<w {
                let px = loadPixel(src + col * 4)
                var slot = Int(px &* 2654435761 >> 20) & (capacity - 1)
                var found = false
                while used[slot] {
                    if keys[slot] == px { found = true; break }
                    slot = (slot + 1) & (capacity - 1)
                }
                if found { continue }
                used[slot] = true
                keys[slot] = px
                palette.append(px)
                if palette.count > maxPaletteColors {
                    return Analysis(colorCount: palette.count, palette: [])
                }
            }
        }
        return Analysis(colorCount: palette.count, palette: palette)
    }

    @inline(__always)
    private func loadPixel(_ p: UnsafePointer<UInt8>) -> UInt32 {
        // BGRA -> 0x00RRGGBB，A 丢掉（窗口是不透明的）
        UInt32(p[2]) << 16 | UInt32(p[1]) << 8 | UInt32(p[0])
    }

    // MARK: - 序列化辅助

    private func appendTPixel(_ c: UInt32, into out: inout [UInt8]) {
        // 紧凑 TPIXEL：R, G, B 三字节
        out.append(UInt8(truncatingIfNeeded: c >> 16))
        out.append(UInt8(truncatingIfNeeded: c >> 8))
        out.append(UInt8(truncatingIfNeeded: c))
    }

    /// Tight 的变长长度：每字节 7 位有效，最高位表示"还有下一字节"
    private func appendCompactLength(_ len: Int, into out: inout [UInt8]) {
        if len < 128 {
            out.append(UInt8(len))
        } else if len < 16384 {
            out.append(UInt8(len & 0x7F) | 0x80)
            out.append(UInt8((len >> 7) & 0x7F))
        } else {
            out.append(UInt8(len & 0x7F) | 0x80)
            out.append(UInt8((len >> 7) & 0x7F) | 0x80)
            out.append(UInt8((len >> 14) & 0xFF))
        }
    }

    private func appendRectHeader(x: Int, y: Int, w: Int, h: Int,
                                  encoding: RFB.Encoding, into out: inout [UInt8]) {
        out.appendBE(UInt16(x))
        out.appendBE(UInt16(y))
        out.appendBE(UInt16(w))
        out.appendBE(UInt16(h))
        out.appendBE(encoding.rawValue)
    }

    // MARK: - JPEG

    static func jpegData(fb: UnsafePointer<UInt8>, fbStride: Int,
                         x: Int, y: Int, w: Int, h: Int,
                         quality: CGFloat) -> Data? {
        let rowBytes = w * 4
        var buf = [UInt8](repeating: 0, count: rowBytes * h)
        buf.withUnsafeMutableBytes { dst in
            guard let d = dst.baseAddress else { return }
            for row in 0..<h {
                memcpy(d.advanced(by: row * rowBytes),
                       fb + (y + row) * fbStride + x * 4, rowBytes)
            }
        }
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        // BGRA 内存布局在小端上的标准写法
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue |
                      CGBitmapInfo.byteOrder32Little.rawValue)
        guard let img = CGImage(width: w, height: h,
                                bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: rowBytes,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: bitmapInfo,
                                provider: provider, decode: nil,
                                shouldInterpolate: false,
                                intent: .defaultIntent) else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

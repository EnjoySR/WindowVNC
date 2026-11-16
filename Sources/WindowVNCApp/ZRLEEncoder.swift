import CoreGraphics
import Foundation

/// 可增长的字节缓冲，直接操作裸指针。
/// 用 Swift 的 [UInt8].append 每像素要调三次，每次都带唯一性检查和容量检查，
/// 一帧几十万次，实测这是编码的主要开销。
final class ByteBuf {
    private(set) var ptr: UnsafeMutablePointer<UInt8>
    private(set) var count = 0
    private var cap: Int

    init(_ initial: Int = 1 << 20) {
        cap = initial
        ptr = .allocate(capacity: initial)
    }
    deinit { ptr.deallocate() }

    func clear() { count = 0 }

    @inline(__always) func reserve(_ extra: Int) {
        guard count + extra > cap else { return }
        var n = cap * 2
        while n < count + extra { n *= 2 }
        let np = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        np.update(from: ptr, count: count)
        ptr.deallocate()
        ptr = np
        cap = n
    }
    @inline(__always) func u8(_ v: UInt8) {
        ptr[count] = v; count += 1
    }
    /// CPIXEL：小端 32bpp 的低 3 字节，即 B, G, R
    @inline(__always) func bgr(_ px: UInt32) {
        ptr[count]     = UInt8(truncatingIfNeeded: px)
        ptr[count + 1] = UInt8(truncatingIfNeeded: px >> 8)
        ptr[count + 2] = UInt8(truncatingIfNeeded: px >> 16)
        count += 3
    }
    @inline(__always) func runLength(_ run: Int) {
        var r = run - 1
        while r >= 255 { ptr[count] = 255; count += 1; r -= 255 }
        ptr[count] = UInt8(r); count += 1
    }
}

/// ZRLE 编码（RFB 标准，编码号 16）。
///
/// 这是 RealVNC 自己发明并首选的编码，RealVNC Viewer / TigerVNC / macOS 屏幕共享
/// 全都支持。Tight 压缩率更好，但 RealVNC Viewer 不认，所以必须有这一路。
final class ZRLEEncoder {
    private let zlib = ZlibStream()
    private let tile = 64
    private let buf = ByteBuf()

    // 瓦片工作区，一次分配反复用
    private let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: 64 * 64)
    private let indices = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 64)
    private let palette = UnsafeMutablePointer<UInt32>.allocate(capacity: 128)
    // 开放寻址哈希表。用"代数"标记代替每个瓦片清空一次数组
    private let hKey = UnsafeMutablePointer<UInt32>.allocate(capacity: 512)
    private let hVal = UnsafeMutablePointer<Int32>.allocate(capacity: 512)
    private let hGen = UnsafeMutablePointer<UInt32>.allocate(capacity: 512)
    private var gen: UInt32 = 0

    init() { hGen.initialize(repeating: 0, count: 512) }

    deinit {
        pixels.deallocate(); indices.deallocate(); palette.deallocate()
        hKey.deallocate(); hVal.deallocate(); hGen.deallocate()
    }

    func reset() { zlib.reset() }

    static func supports(_ f: PixelFormat) -> Bool { f.isNativeBGRA }

    func encode(rect: CGRect,
                fb: UnsafePointer<UInt8>, fbStride: Int,
                into out: inout [UInt8]) -> Int {
        let x = Int(rect.minX), y = Int(rect.minY)
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 0, h > 0 else { return 0 }

        buf.clear()
        // 最坏情况：每瓦片 1 字节头 + 每像素 3 字节；一次性备够，中途不再扩容
        buf.reserve(w * h * 3 + (w / 64 + 1) * (h / 64 + 1) * 8 + 1024)

        var ty = 0
        while ty < h {
            let th = min(tile, h - ty)
            var tx = 0
            while tx < w {
                let tw = min(tile, w - tx)
                encodeTile(fb: fb, fbStride: fbStride, x: x + tx, y: y + ty, w: tw, h: th)
                tx += tw
            }
            ty += th
        }

        let compressed = zlib.compress(buf.ptr, count: buf.count)

        out.appendBE(UInt16(x)); out.appendBE(UInt16(y))
        out.appendBE(UInt16(w)); out.appendBE(UInt16(h))
        out.appendBE(RFB.Encoding.zrle.rawValue)
        out.appendBE(UInt32(compressed.count))
        out.append(contentsOf: compressed)
        return 1
    }

    private func encodeTile(fb: UnsafePointer<UInt8>, fbStride: Int,
                            x: Int, y: Int, w: Int, h: Int) {
        let n = w * h
        gen &+= 1
        if gen == 0 { hGen.initialize(repeating: 0, count: 512); gen = 1 }

        var paletteCount = 0
        var overflow = false
        var p = 0
        for row in 0..<h {
            var src = fb + (y + row) * fbStride + x * 4
            for _ in 0..<w {
                let px = UInt32(src[0]) | UInt32(src[1]) << 8 | UInt32(src[2]) << 16
                pixels[p] = px
                if !overflow {
                    var slot = Int((px &* 2654435761) >> 21) & 511
                    while hGen[slot] == gen && hKey[slot] != px { slot = (slot + 1) & 511 }
                    if hGen[slot] != gen {
                        if paletteCount >= 127 {
                            overflow = true
                        } else {
                            hGen[slot] = gen
                            hKey[slot] = px
                            hVal[slot] = Int32(paletteCount)
                            palette[paletteCount] = px
                            indices[p] = UInt8(paletteCount)
                            paletteCount += 1
                        }
                    } else {
                        indices[p] = UInt8(hVal[slot])
                    }
                }
                src += 4
                p += 1
            }
        }

        if !overflow && paletteCount == 1 {
            buf.u8(1)                                   // 纯色
            buf.bgr(palette[0])
            return
        }

        if !overflow && paletteCount <= 16 {
            // 打包调色板：2 色 1bit，3-4 色 2bit，5-16 色 4bit，每行按字节对齐
            buf.u8(UInt8(paletteCount))
            for i in 0..<paletteCount { buf.bgr(palette[i]) }
            let bits = paletteCount == 2 ? 1 : (paletteCount <= 4 ? 2 : 4)
            for row in 0..<h {
                var acc: UInt8 = 0
                var filled = 0
                let base = row * w
                for col in 0..<w {
                    acc = (acc << UInt8(bits)) | indices[base + col]
                    filled += bits
                    if filled == 8 { buf.u8(acc); acc = 0; filled = 0 }
                }
                if filled > 0 { buf.u8(acc << UInt8(8 - filled)) }
            }
            return
        }

        if !overflow {
            // 调色板 + RLE
            buf.u8(UInt8(128 + paletteCount))
            for i in 0..<paletteCount { buf.bgr(palette[i]) }
            var i = 0
            while i < n {
                let idx = indices[i]
                var run = 1
                while i + run < n && indices[i + run] == idx { run += 1 }
                if run == 1 {
                    buf.u8(idx)
                } else {
                    buf.u8(idx | 0x80)
                    buf.runLength(run)
                }
                i += run
            }
            return
        }

        // 颜色太多：先看 RLE 划不划算，不划算就原样交给 zlib
        var runs = 0
        var i = 0
        while i < n {
            var run = 1
            while i + run < n && pixels[i + run] == pixels[i] { run += 1 }
            runs += 1
            i += run
        }
        if runs * 4 < n * 3 {
            buf.u8(128)                                 // 纯 RLE
            i = 0
            while i < n {
                var run = 1
                while i + run < n && pixels[i + run] == pixels[i] { run += 1 }
                buf.bgr(pixels[i])
                buf.runLength(run)
                i += run
            }
        } else {
            buf.u8(0)                                   // 原样，靠 zlib 压
            for j in 0..<n { buf.bgr(pixels[j]) }
        }
    }
}

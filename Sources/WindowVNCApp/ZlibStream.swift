import CZlib
import Foundation

/// Tight 编码要求 zlib 流在多个矩形之间**持续存在**（这样重复内容才能跨帧命中字典），
/// 并且每个矩形结束时用 Z_SYNC_FLUSH 刷出去，让客户端能立刻解码这一段。
/// Apple 的 compression 框架没有 sync flush，所以只能直接用 libz。
final class ZlibStream {
    private var stream = z_stream()
    private var initialized = false
    private var outBuf = [UInt8](repeating: 0, count: 1 << 16)

    init(level: Int32 = 6) {
        let r = deflateInit2_(&stream, level, Z_DEFLATED,
                              15,          // windowBits：15 = 带 zlib 头，Tight 要求这个
                              8,           // memLevel
                              Z_DEFAULT_STRATEGY,
                              ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        initialized = (r == Z_OK)
    }

    deinit { if initialized { deflateEnd(&stream) } }

    func reset() {
        guard initialized else { return }
        deflateReset(&stream)
    }

    /// 压一段数据并 sync flush，返回这一段产生的全部输出
    func compress(_ input: UnsafePointer<UInt8>, count: Int) -> [UInt8] {
        guard initialized, count > 0 else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(count / 3 + 64)

        stream.next_in = UnsafeMutablePointer(mutating: input)
        stream.avail_in = uInt(count)

        repeat {
            let produced: Int = outBuf.withUnsafeMutableBufferPointer { buf -> Int in
                stream.next_out = buf.baseAddress
                stream.avail_out = uInt(buf.count)
                _ = deflate(&stream, Z_SYNC_FLUSH)
                return buf.count - Int(stream.avail_out)
            }
            if produced > 0 { out.append(contentsOf: outBuf[0..<produced]) }
            if produced == 0 { break }
        } while stream.avail_in > 0 || stream.avail_out == 0

        return out
    }

    func compress(_ bytes: [UInt8]) -> [UInt8] {
        bytes.withUnsafeBufferPointer { compress($0.baseAddress!, count: $0.count) }
    }
}

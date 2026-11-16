import Foundation

// RFB 协议常量与基础类型。参考 RFC 6143 + TightVNC 的 Tight 编码扩展。

enum RFB {
    static let version38 = "RFB 003.008\n"

    enum SecurityType: UInt8 {
        case invalid = 0
        case none = 1
        case vncAuth = 2
    }

    enum ClientMessage: UInt8 {
        case setPixelFormat = 0
        case setEncodings = 2
        case framebufferUpdateRequest = 3
        case keyEvent = 4
        case pointerEvent = 5
        case clientCutText = 6
    }

    enum ServerMessage: UInt8 {
        case framebufferUpdate = 0
    }

    enum Encoding: Int32 {
        case raw = 0
        case copyRect = 1
        case zrle = 16
        case tight = 7
        // 伪编码
        case desktopSize = -223
        case lastRect = -224
        case tightPNG = -260
    }
}

/// RFB 的 PIXEL_FORMAT（16 字节）
struct PixelFormat: Equatable {
    var bitsPerPixel: UInt8
    var depth: UInt8
    var bigEndian: Bool
    var trueColor: Bool
    var redMax: UInt16
    var greenMax: UInt16
    var blueMax: UInt16
    var redShift: UInt8
    var greenShift: UInt8
    var blueShift: UInt8

    /// 我们内存里就是 BGRA 字节序；按小端读成 u32 就是 B|G<<8|R<<16|A<<24，
    /// 所以 shift 分别是 16/8/0。客户端如果不改格式，Raw 可以直接 memcpy。
    static let bgra888 = PixelFormat(
        bitsPerPixel: 32, depth: 24, bigEndian: false, trueColor: true,
        redMax: 255, greenMax: 255, blueMax: 255,
        redShift: 16, greenShift: 8, blueShift: 0)

    var isNativeBGRA: Bool { self == .bgra888 }

    /// Tight 的 TPIXEL 在 32bpp/depth24/各分量 max=255 时压缩成 3 字节
    var usesCompactTPixel: Bool {
        bitsPerPixel == 32 && depth == 24 &&
        redMax == 255 && greenMax == 255 && blueMax == 255
    }

    func serialize(into out: inout [UInt8]) {
        out.append(bitsPerPixel)
        out.append(depth)
        out.append(bigEndian ? 1 : 0)
        out.append(trueColor ? 1 : 0)
        out.appendBE(redMax)
        out.appendBE(greenMax)
        out.appendBE(blueMax)
        out.append(redShift)
        out.append(greenShift)
        out.append(blueShift)
        out.append(contentsOf: [0, 0, 0]) // padding
    }

    static func parse(_ b: [UInt8]) -> PixelFormat? {
        guard b.count >= 16 else { return nil }
        return PixelFormat(
            bitsPerPixel: b[0],
            depth: b[1],
            bigEndian: b[2] != 0,
            trueColor: b[3] != 0,
            redMax: UInt16(b[4]) << 8 | UInt16(b[5]),
            greenMax: UInt16(b[6]) << 8 | UInt16(b[7]),
            blueMax: UInt16(b[8]) << 8 | UInt16(b[9]),
            redShift: b[10],
            greenShift: b[11],
            blueShift: b[12])
    }
}

// MARK: - 大端写入辅助（RFB 全程网络字节序）

extension Array where Element == UInt8 {
    mutating func appendBE(_ v: UInt16) {
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v))
    }
    mutating func appendBE(_ v: UInt32) {
        append(UInt8(truncatingIfNeeded: v >> 24))
        append(UInt8(truncatingIfNeeded: v >> 16))
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v))
    }
    mutating func appendBE(_ v: Int32) { appendBE(UInt32(bitPattern: v)) }
}

extension Data {
    func be16(_ i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    func be32(_ i: Int) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 |
        UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}

import CommonCrypto
import Foundation

/// 标准 VNC Authentication（RFB security type 2）。
/// 服务端发 16 字节随机挑战，客户端用密码做 DES key 加密后回传。
///
/// 有个经典的历史坑：VNC 的 DES key 要把密码每个字节的**比特顺序反转**。
/// 这是 AT&T 当年实现的 bug，但已经成了事实标准，所有客户端都这么做。
enum VNCAuth {
    static func challenge() -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, c.count, &c)
        return c
    }

    /// 密码取前 8 字节，不足补 0，再逐字节反转比特
    static func desKey(from password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, byte) in Array(password.utf8).prefix(8).enumerated() {
            key[i] = reverseBits(byte)
        }
        return key
    }

    private static func reverseBits(_ b: UInt8) -> UInt8 {
        var v = b
        v = (v & 0xF0) >> 4 | (v & 0x0F) << 4
        v = (v & 0xCC) >> 2 | (v & 0x33) << 2
        v = (v & 0xAA) >> 1 | (v & 0x55) << 1
        return v
    }

    /// 用 DES-ECB 加密 16 字节挑战（两个 8 字节块）
    static func encrypt(challenge: [UInt8], password: String) -> [UInt8]? {
        guard challenge.count == 16 else { return nil }
        let key = desKey(from: password)
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = key.withUnsafeBytes { keyPtr in
            challenge.withUnsafeBytes { inPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCrypt(CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmDES),
                            CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, 8,
                            nil,
                            inPtr.baseAddress, 16,
                            outPtr.baseAddress, 16,
                            &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == 16 else { return nil }
        return out
    }

    static func verify(challenge: [UInt8], response: [UInt8], password: String) -> Bool {
        guard let expected = encrypt(challenge: challenge, password: password),
              expected.count == response.count else { return false }
        // 常数时间比较，避免时序侧信道
        var diff: UInt8 = 0
        for i in 0..<expected.count { diff |= expected[i] ^ response[i] }
        return diff == 0
    }
}

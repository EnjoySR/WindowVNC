import CoreGraphics
import Foundation
import Network
import QuartzCore

/// 单个客户端的实时统计，用来回答"对方那边到底慢在哪"
struct ClientStats {
    var peer = "?"
    var encoding = "协商中"
    var pixelFormat = "-"
    var fps: Double = 0
    var mbps: Double = 0
    var lastFrameKB: Double = 0
    var framesSent = 0
    /// 编码耗时占比高说明是 CPU 瓶颈，发送耗时占比高说明是网络瓶颈
    var encodeMs: Double = 0
    var sendMs: Double = 0
    /// 客户端声明支持的编码号，排错用
    var offered = ""
}

/// 一个已连接的 VNC 客户端。
///
/// RFB 是**客户端拉取**模型：客户端发 FramebufferUpdateRequest，服务端才回一帧。
/// 所以这里两条线并行：
///   读线程（async）——解析客户端消息，记下"它想要更新了"
///   写线程（Thread）——等到「有人要 + 画面确实脏了」才编码发送，编码很吃 CPU，不能占着读线程
final class RFBSession {
    private let connection: NWConnection
    private let fb: FrameBuffer
    private let password: String
    private let desktopName: String
    let id = UUID()
    var onClose: ((RFBSession) -> Void)?

    private var format = PixelFormat.bgra888
    private var useTight = false
    private var useZRLE = false
    private var supportsDesktopSize = false
    private let encoder = TightEncoder()
    private let zrle = ZRLEEncoder()

    // 下面这些由 cond 保护
    private let cond = NSCondition()
    private var pendingRequest = false
    private var dirty = DirtyRegion()
    private var needFullUpdate = true
    private var knownSizeGen: UInt64 = 0
    private var knownW = 0, knownH = 0
    private var closed = false

    private var writerThread: Thread?
    private var frameNo = 0

    // 统计，单独一把锁，别和 cond 搅在一起
    private let statsLock = NSLock()
    private var stats = ClientStats()
    private var sendLog: [(t: CFTimeInterval, bytes: Int)] = []

    func snapshot() -> ClientStats {
        statsLock.lock(); defer { statsLock.unlock() }
        var s = stats
        let now = CACurrentMediaTime()
        let window = sendLog.filter { now - $0.t <= 2.0 }
        if let first = window.first, window.count > 1 {
            let dt = max(now - first.t, 0.001)
            s.fps = Double(window.count) / dt
            s.mbps = Double(window.reduce(0) { $0 + $1.bytes }) * 8 / dt / 1e6
        }
        return s
    }

    @discardableResult
    private func withStats<T>(_ body: () -> T) -> T {
        statsLock.lock(); defer { statsLock.unlock() }
        return body()
    }

    private func recordSend(bytes: Int, encodeMs: Double, sendMs: Double) {
        statsLock.lock()
        let now = CACurrentMediaTime()
        sendLog.append((now, bytes))
        sendLog.removeAll { now - $0.t > 2.0 }
        stats.framesSent += 1
        stats.lastFrameKB = Double(bytes) / 1024
        stats.encodeMs = encodeMs
        stats.sendMs = sendMs
        statsLock.unlock()
    }

    init(connection: NWConnection, fb: FrameBuffer, password: String, desktopName: String) {
        self.connection = connection
        self.fb = fb
        self.password = password
        self.desktopName = desktopName
    }

    // MARK: - 生命周期

    func start() {
        statsLock.lock()
        stats.peer = "\(connection.endpoint)"
        statsLock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        Task.detached { [weak self] in await self?.runProtocol() }
    }

    func close() {
        cond.lock()
        if closed { cond.unlock(); return }
        closed = true
        cond.broadcast()
        cond.unlock()
        connection.cancel()
        onClose?(self)
    }

    /// 捕获线程调用：告诉这个客户端画面哪里脏了
    func markDirty(_ region: DirtyRegion, size: CGSize) {
        cond.lock()
        if region.isFull {
            dirty.addFull(size)
        } else {
            for r in region.rects { dirty.add(r) }
        }
        cond.broadcast()
        cond.unlock()
    }

    // MARK: - 协议流程

    private func runProtocol() async {
        do {
            // 1. 版本协商
            try await send(Data(RFB.version38.utf8))
            let clientVersion = try await recv(12)
            guard String(data: clientVersion, encoding: .ascii)?.hasPrefix("RFB 003.") == true else {
                throw Err("客户端版本号不认识")
            }

            // 2. 安全类型：只提供 VNC Auth
            try await send(Data([1, RFB.SecurityType.vncAuth.rawValue]))
            let chosen = try await recv(1)
            guard chosen[0] == RFB.SecurityType.vncAuth.rawValue else {
                throw Err("客户端选了不支持的安全类型 \(chosen[0])")
            }

            // 3. DES 挑战应答
            let challenge = VNCAuth.challenge()
            try await send(Data(challenge))
            let response = try await recv(16)
            guard VNCAuth.verify(challenge: challenge,
                                 response: [UInt8](response),
                                 password: password) else {
                var fail: [UInt8] = []
                fail.appendBE(UInt32(1))            // SecurityResult = failed
                let reason = "密码错误"
                fail.appendBE(UInt32(reason.utf8.count))
                fail.append(contentsOf: Array(reason.utf8))
                try? await send(Data(fail))
                throw Err("密码错误")
            }
            var ok: [UInt8] = []
            ok.appendBE(UInt32(0))
            try await send(Data(ok))

            // 4. ClientInit（共享标志，我们一律允许多人同时看）
            _ = try await recv(1)

            // 5. ServerInit
            let (w, h, gen) = fb.currentSize()
            withCond { knownW = w; knownH = h; knownSizeGen = gen }
            var initMsg: [UInt8] = []
            initMsg.appendBE(UInt16(w))
            initMsg.appendBE(UInt16(h))
            format.serialize(into: &initMsg)
            let nameBytes = Array(desktopName.utf8)
            initMsg.appendBE(UInt32(nameBytes.count))
            initMsg.append(contentsOf: nameBytes)
            try await send(Data(initMsg))

            startWriter()
            try await readLoop()
        } catch {
            NSLog("[RFBSession] 结束: \(error)")
            close()
        }
    }

    private func readLoop() async throws {
        while !isClosed {
            let head = try await recv(1)
            guard let msg = RFB.ClientMessage(rawValue: head[0]) else {
                throw Err("未知的客户端消息类型 \(head[0])")
            }
            switch msg {
            case .setPixelFormat:
                _ = try await recv(3)                       // padding
                let pf = try await recv(16)
                if let parsed = PixelFormat.parse([UInt8](pf)) {
                    format = parsed
                    // 客户端换了格式，之前压的 zlib 字典就作废了
                    encoder.reset()
                    zrle.reset()
                    requestFull()
                    let desc = "\(parsed.bitsPerPixel)bpp/depth\(parsed.depth)" +
                               (parsed.trueColor ? "" : " 非真彩") +
                               (parsed.usesCompactTPixel ? "" : " ⚠️非标准")
                    withStats { stats.pixelFormat = desc }
                    NSLog("[RFBSession] 客户端像素格式: \(desc)")
                }

            case .setEncodings:
                _ = try await recv(1)                       // padding
                let countData = try await recv(2)
                let n = Int(countData.be16(0))
                var list: [Int32] = []
                if n > 0 {
                    let body = try await recv(n * 4)
                    for i in 0..<n { list.append(Int32(bitPattern: body.be32(i * 4))) }
                }
                useTight = list.contains(RFB.Encoding.tight.rawValue)
                useZRLE = list.contains(RFB.Encoding.zrle.rawValue)
                supportsDesktopSize = list.contains(RFB.Encoding.desktopSize.rawValue)
                // 优先级：Tight 压缩率最好；RealVNC Viewer 不认 Tight，用它自己发明的 ZRLE；
                // 两个都不支持才退到 Raw（裸像素，一帧好几 MB，只有回环能扛）
                let name = useTight ? "Tight" : (useZRLE ? "ZRLE" : "Raw ⚠️(对方只支持裸像素)")
                withStats {
                    stats.encoding = name
                    stats.offered = list.map(String.init).joined(separator: ",")
                }
                NSLog("[RFBSession] 客户端编码 \(list) -> 采用 \(name), desktopSize=\(supportsDesktopSize)")

            case .framebufferUpdateRequest:
                let body = try await recv(9)
                let incremental = body[0] != 0
                withCond {
                    pendingRequest = true
                    if !incremental { needFullUpdate = true }
                    cond.broadcast()
                }

            case .keyEvent:
                _ = try await recv(7)                       // 只读掉，不执行（只看不控）

            case .pointerEvent:
                _ = try await recv(5)

            case .clientCutText:
                _ = try await recv(3)
                let lenData = try await recv(4)
                let len = Int(lenData.be32(0))
                if len > 0 { _ = try await recv(min(len, 1 << 20)) }
            }
        }
    }

    private func requestFull() {
        withCond { needFullUpdate = true; cond.broadcast() }
    }

    private var isClosed: Bool { withCond { closed } }

    /// 包一层同步函数：Swift 6 不允许在 async 上下文里直接持锁，
    /// 但这些临界区都极短，包一下即可，不需要改成 actor。
    @discardableResult
    private func withCond<T>(_ body: () -> T) -> T {
        cond.lock()
        defer { cond.unlock() }
        return body()
    }

    // MARK: - 写线程

    private func startWriter() {
        let t = Thread { [weak self] in self?.writerLoop() }
        t.name = "rfb.writer"
        t.qualityOfService = .userInitiated
        writerThread = t
        t.start()
    }

    private func writerLoop() {
        while true {
            cond.lock()
            // 尺寸必须在**每次判断时**重新读。之前在进入 wait 之前读一次，
            // 唤醒后拿的是旧值，切画质/拖窗口改尺寸时就会错判成"尺寸没变"。
            var curW = 0, curH = 0, curGen: UInt64 = 0
            while !closed {
                (curW, curH, curGen) = fb.currentSize()
                if pendingRequest && (curGen != knownSizeGen || needFullUpdate || !dirty.isEmpty) {
                    break
                }
                cond.wait()
            }
            if closed { cond.unlock(); return }

            let sizeChanged = curGen != knownSizeGen
            let full = needFullUpdate || sizeChanged
            let rects: [CGRect] = full
                ? [CGRect(x: 0, y: 0, width: curW, height: curH)]
                : dirty.rects
            dirty.clear()
            needFullUpdate = false
            pendingRequest = false
            let oldW = knownW, oldH = knownH
            knownSizeGen = curGen
            knownW = curW; knownH = curH
            cond.unlock()

            // 窗口尺寸变了：先用 DesktopSize 伪编码通知客户端重排，再发全帧
            if sizeChanged && (curW != oldW || curH != oldH) {
                guard supportsDesktopSize else {
                    NSLog("[RFBSession] 客户端不支持 DesktopSize，尺寸变化后只能断开")
                    close()
                    return
                }
                var msg: [UInt8] = []
                msg.append(RFB.ServerMessage.framebufferUpdate.rawValue)
                msg.append(0)
                msg.appendBE(UInt16(1))
                msg.appendBE(UInt16(0)); msg.appendBE(UInt16(0))
                msg.appendBE(UInt16(curW)); msg.appendBE(UInt16(curH))
                msg.appendBE(RFB.Encoding.desktopSize.rawValue)
                if !sendSync(Data(msg)) { return }
                // 尺寸一变，zlib 的历史字典就没意义了，而且客户端那边的流也重置了
                encoder.reset()
            }

            let encodeStart = CACurrentMediaTime()
            let encoded = encodeUpdate(rects: rects, w: curW, h: curH)
            let encodeMs = (CACurrentMediaTime() - encodeStart) * 1000
            guard let payload = encoded else {
                // 这一轮没编出东西（多半是编码期间尺寸又变了）。
                // 关键：必须把请求标志还回去，否则客户端在等响应、我们在等请求，双方永久互等。
                withCond {
                    pendingRequest = true
                    needFullUpdate = true
                    cond.broadcast()
                }
                // 退避一下：万一连续失败，这里会变成 100% CPU 空转
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            let sendStart = CACurrentMediaTime()
            if !sendSync(payload) { return }
            let sendMs = (CACurrentMediaTime() - sendStart) * 1000
            recordSend(bytes: payload.count, encodeMs: encodeMs, sendMs: sendMs)
            frameNo += 1
            // 只记录开头一段用于排错，不然长时间共享会把日志文件撑大
            if frameNo <= 200 {
                let area = rects.reduce(0) { $0 + Int($1.width * $1.height) }
                DebugLog.log(String(format:
                    "SEND #%d rects=%d area=%dpx(%.0f%%) out=%.1fKB encode=%.1fms send=%.1fms",
                    frameNo, rects.count, area,
                    Double(area) / Double(max(curW * curH, 1)) * 100,
                    Double(payload.count) / 1024, encodeMs, sendMs))
            }
        }
    }

    private func encodeUpdate(rects: [CGRect], w: Int, h: Int) -> Data? {
        var body: [UInt8] = []
        var rectCount = 0

        encoder.jpegQuality = CGFloat(Settings.jpegQuality)
        fb.withReadLock { ptr, fbW, fbH, stride in
            guard let ptr, fbW == w, fbH == h else { return }
            let bounds = CGRect(x: 0, y: 0, width: fbW, height: fbH)
            for r in rects {
                let clipped = r.intersection(bounds)
                guard !clipped.isNull, !clipped.isEmpty else { continue }
                let tightUsable = useTight && format.usesCompactTPixel && format.trueColor
                let zrleUsable = useZRLE && ZRLEEncoder.supports(format)
                if tightUsable {
                    rectCount += encoder.encode(rect: clipped, fb: ptr, fbStride: stride,
                                                format: format, into: &body)
                } else if zrleUsable {
                    rectCount += zrle.encode(rect: clipped, fb: ptr, fbStride: stride, into: &body)
                } else {
                    if useTight || useZRLE {
                        statsLock.lock()
                        stats.encoding = "Raw ⚠️(像素格式非标准，压缩编码用不了)"
                        statsLock.unlock()
                    }
                    rectCount += encodeRaw(rect: clipped, fb: ptr, fbStride: stride, into: &body)
                }
            }
        }
        guard rectCount > 0 else { return nil }

        var msg: [UInt8] = []
        msg.reserveCapacity(body.count + 4)
        msg.append(RFB.ServerMessage.framebufferUpdate.rawValue)
        msg.append(0)
        msg.appendBE(UInt16(rectCount))
        msg.append(contentsOf: body)
        return Data(msg)
    }

    /// Raw 编码。客户端不支持 Tight、或者用了我们不打算转换的像素格式时的兜底。
    private func encodeRaw(rect: CGRect, fb ptr: UnsafePointer<UInt8>, fbStride: Int,
                           into out: inout [UInt8]) -> Int {
        let x = Int(rect.minX), y = Int(rect.minY)
        let w = Int(rect.width), h = Int(rect.height)
        out.appendBE(UInt16(x)); out.appendBE(UInt16(y))
        out.appendBE(UInt16(w)); out.appendBE(UInt16(h))
        out.appendBE(RFB.Encoding.raw.rawValue)

        if format.isNativeBGRA {
            for row in 0..<h {
                let src = ptr + (y + row) * fbStride + x * 4
                out.append(contentsOf: UnsafeBufferPointer(start: src, count: w * 4))
            }
        } else {
            // 通用慢路径：按客户端要求的位宽和位移重新打包
            let bytes = Int(format.bitsPerPixel) / 8
            for row in 0..<h {
                let src = ptr + (y + row) * fbStride + x * 4
                for col in 0..<w {
                    let p = src + col * 4
                    let r = UInt32(p[2]) * UInt32(format.redMax) / 255
                    let g = UInt32(p[1]) * UInt32(format.greenMax) / 255
                    let b = UInt32(p[0]) * UInt32(format.blueMax) / 255
                    let v = r << format.redShift | g << format.greenShift | b << format.blueShift
                    if format.bigEndian {
                        for i in stride(from: bytes - 1, through: 0, by: -1) {
                            out.append(UInt8(truncatingIfNeeded: v >> (8 * i)))
                        }
                    } else {
                        for i in 0..<bytes {
                            out.append(UInt8(truncatingIfNeeded: v >> (8 * i)))
                        }
                    }
                }
            }
        }
        return 1
    }

    // MARK: - IO

    struct Err: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private func recv(_ n: Int) async throws -> Data {
        guard n > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, error in
                if let error { cont.resume(throwing: error); return }
                guard let data, data.count == n else {
                    cont.resume(throwing: Err("连接已断开")); return
                }
                cont.resume(returning: data)
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// 写线程用的同步发送。等发完再编码下一帧，天然形成背压：
    /// 网络慢下来时自动降帧，而不是把内存撑爆。
    private func sendSync(_ data: Data) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = true
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { ok = false }
            sem.signal()
        })
        sem.wait()
        if !ok { close() }
        return ok
    }
}

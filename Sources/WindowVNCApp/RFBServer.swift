import CoreGraphics
import CoreVideo
import Foundation
import Network

/// VNC 服务端。只在"共享中"才监听端口——不共享时端口是关的，
/// 比 RealVNC 那种开机常驻监听更可控。
final class RFBServer {
    let framebuffer = FrameBuffer()

    private(set) var port: UInt16
    private var password: String
    private var desktopName: String

    private var listener: NWListener?
    private var sessions: [RFBSession] = []
    private let lock = NSLock()

    var onClientCountChanged: ((Int) -> Void)?
    var onError: ((Error) -> Void)?

    init(port: UInt16, password: String, desktopName: String) {
        self.port = port
        self.password = password
        self.desktopName = desktopName
    }

    var clientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    func start() throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 关掉 Nagle：VNC 是小包 + 突发大包混合，攒包只会增加延迟
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "RFBServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "端口号非法: \(port)"])
        }
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state { self?.onError?(e) }
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
        NSLog("[RFBServer] 已监听 :\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let all = sessions
        sessions.removeAll()
        lock.unlock()
        all.forEach { $0.close() }
        onClientCountChanged?(0)
    }

    func updateDesktopName(_ name: String) { desktopName = name }

    private func accept(_ conn: NWConnection) {
        let session = RFBSession(connection: conn, fb: framebuffer,
                                 password: password, desktopName: desktopName)
        session.onClose = { [weak self] s in self?.remove(s) }
        lock.lock()
        sessions.append(session)
        let n = sessions.count
        lock.unlock()
        session.start()
        onClientCountChanged?(n)
        NSLog("[RFBServer] 新客户端接入，当前 \(n) 个")
    }

    private func remove(_ s: RFBSession) {
        lock.lock()
        sessions.removeAll { $0.id == s.id }
        let n = sessions.count
        lock.unlock()
        onClientCountChanged?(n)
    }

    func allClientStats() -> [ClientStats] {
        lock.lock(); let all = sessions; lock.unlock()
        return all.map { $0.snapshot() }
    }

    /// 捕获线程调用：把新一帧灌进来，然后通知所有客户端哪里脏了
    func ingest(pixelBuffer: CVPixelBuffer, dirtyRects: [CGRect]) {
        let region = framebuffer.update(from: pixelBuffer, dirtyRects: dirtyRects)
        guard !region.isEmpty else { return }
        let (w, h, _) = framebuffer.currentSize()
        let size = CGSize(width: w, height: h)
        lock.lock()
        let all = sessions
        lock.unlock()
        for s in all { s.markDirty(region, size: size) }
    }

    /// 本机所有非回环 IPv4 地址，用来告诉用户该连哪个
    static func localIPv4Addresses() -> [String] {
        var results: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }        // 有线/无线网卡
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("127.") { results.append(ip) }
            }
        }
        return results
    }
}

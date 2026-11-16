import Foundation

/// 用 UserDefaults 存，够用。端口默认 5901 —— 让开 5900，
/// 这样你现有的 RealVNC Server 可以继续在 5900 上跑，两者互不影响。
enum Settings {
    private static let d = UserDefaults.standard

    static var port: UInt16 {
        get { UInt16(d.object(forKey: "port") as? Int ?? 5901) }
        set { d.set(Int(newValue), forKey: "port") }
    }
    static var password: String {
        get { d.string(forKey: "password") ?? "123456" }
        set { d.set(newValue, forKey: "password") }
    }
    /// 1.0 = 按窗口视觉尺寸传（推荐），2.0 = Retina 原生像素
    static var pixelScale: Double {
        get { d.object(forKey: "pixelScale") as? Double ?? 1.0 }
        set { d.set(newValue, forKey: "pixelScale") }
    }
    static var fps: Int {
        get { d.object(forKey: "fps") as? Int ?? 30 }
        set { d.set(newValue, forKey: "fps") }
    }
    /// 无人观看多少秒后自动停止共享。0 = 不自动停止。
    /// 防止演示完忘了关，窗口一直在局域网上开着。
    static var autoStopSeconds: Int {
        get { d.object(forKey: "autoStopSeconds") as? Int ?? 0 }
        set { d.set(max(0, newValue), forKey: "autoStopSeconds") }
    }
    static var jpegQuality: Double {
        get { d.object(forKey: "jpegQuality") as? Double ?? 0.8 }
        set { d.set(newValue, forKey: "jpegQuality") }
    }
}

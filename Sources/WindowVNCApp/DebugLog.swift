import Foundation

/// NSLog 在这个 App 里进不了统一日志系统，排错很不方便。
/// 直接写文件：~/Library/Logs/WindowVNC.log
enum DebugLog {
    private static let queue = DispatchQueue(label: "debuglog")
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WindowVNC.log")
    }()
    private static var handle: FileHandle?

    static func reset() {
        queue.async {
            try? handle?.close()
            handle = nil
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func log(_ msg: String) {
        queue.async {
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                try? handle?.seekToEnd()
            }
            let line = String(format: "%.3f  %@\n", Date().timeIntervalSince1970, msg)
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }
}

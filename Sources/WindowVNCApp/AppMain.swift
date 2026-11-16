import AppKit

// 不能用 main.swift：Swift 5 语言模式下顶层代码不是 MainActor 隔离的，
// 而 AppDelegate 是 @MainActor。改用 @main + @MainActor 的静态入口。
@main
@MainActor
struct AppMain {
    static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

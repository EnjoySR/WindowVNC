import AppKit
import SwiftUI

struct AboutView: View {
    var version: String

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .padding(.top, 26)
                .padding(.bottom, 12)

            Text("WindowVNC")
                .font(.system(size: 17, weight: .semibold))
            Text("版本 \(version)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Divider()
                .padding(.horizontal, 40)
                .padding(.vertical, 18)

            Text("奇技教育")
                .font(.system(size: 20, weight: .medium))
                .tracking(4)

            Text("只共享指定窗口的屏幕共享工具")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Spacer(minLength: 24)
        }
        .frame(width: 300, height: 300)
    }
}

final class AboutWindowController: NSWindowController {
    convenience init(version: String) {
        let hosting = NSHostingController(rootView: AboutView(version: version))
        let w = NSWindow(contentViewController: hosting)
        w.title = "关于 WindowVNC"
        w.styleMask = [.titled, .closable]     // 固定大小，不给拖
        w.isReleasedWhenClosed = false
        w.center()
        self.init(window: w)
    }
}

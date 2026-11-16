import AppKit

/// 状态栏图标。空闲时是普通的窗口符号（模板图，跟随系统亮/暗自动变色）；
/// 共享中是一个圆圈（同原来的 record.circle），中间那个点改成红色并闪烁。
///
/// 红点必须用非模板图（模板图会被系统统一染成单色，红色会丢），
/// 所以共享中的两张图都自己画，符号颜色取 labelColor 保证亮/暗都看得清。
enum StatusIcon {
    static let size = NSSize(width: 22, height: 20)

    static func idle() -> NSImage {
        let img = NSImage(systemSymbolName: "macwindow.on.rectangle",
                          accessibilityDescription: "WindowVNC")
        img?.isTemplate = true
        return img ?? NSImage()
    }

    static func sharing(dotVisible: Bool) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            // 保持和原来 record.circle 一样的外圈，只是把中间那个点换成红色
            guard let symbol = NSImage(systemSymbolName: "circle",
                                       accessibilityDescription: nil) else { return false }
            let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            let base = symbol.withSymbolConfiguration(cfg) ?? symbol

            // 先画符号，再用 sourceAtop 整体染成前景色——这样亮色/暗色菜单栏都清晰
            let s = base.size
            let target = NSRect(x: (rect.width - s.width) / 2,
                                y: (rect.height - s.height) / 2,
                                width: s.width, height: s.height)
            base.draw(in: target)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)

            if dotVisible {
                let d: CGFloat = 9
                let dot = NSRect(x: (rect.width - d) / 2, y: (rect.height - d) / 2,
                                 width: d, height: d)
                // systemRed 偏亮，在浅色菜单栏上不够醒目，用更深的正红
                NSColor(srgbRed: 0.80, green: 0.09, blue: 0.08, alpha: 1).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

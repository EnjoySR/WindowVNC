#!/usr/bin/env swift
// 生成 App 图标：一个窗口 + 向外发散的信号弧，表达"把某个窗口播出去"。
// 输出 Resources/AppIcon.icns
import AppKit
import Foundation

func draw(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    let k = size / 1024.0                       // 所有尺寸都按 1024 设计再等比缩放

    // 圆角底板。macOS 图标四周要留白，内容区约占 80%
    let inset = 96 * k
    let plate = NSRect(x: inset, y: inset, width: size - inset*2, height: size - inset*2)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 185*k, yRadius: 185*k)
    ctx.saveGState()
    platePath.addClip()
    let grad = NSGradient(colors: [NSColor(srgbRed: 0.35, green: 0.47, blue: 0.95, alpha: 1),
                                   NSColor(srgbRed: 0.16, green: 0.27, blue: 0.70, alpha: 1)])!
    grad.draw(in: plate, angle: -90)
    ctx.restoreGState()

    // 右上角向外发散的信号弧，表达"共享出去"。
    // 必须裁剪在底板内，否则弧线会被底板圆角切断，看起来像画残了。
    ctx.saveGState()
    platePath.addClip()
    let origin = NSPoint(x: plate.maxX - 118*k, y: plate.maxY - 118*k)
    NSColor(white: 1, alpha: 0.28).setStroke()
    for i in 0..<3 {
        let r = (62 + CGFloat(i) * 60) * k
        let arc = NSBezierPath()
        arc.appendArc(withCenter: origin, radius: r, startAngle: 200, endAngle: 290)
        arc.lineWidth = 20 * k
        arc.lineCapStyle = .round
        arc.stroke()
    }
    // 波心的实心小点
    NSColor(white: 1, alpha: 0.32).setFill()
    NSBezierPath(ovalIn: NSRect(x: origin.x - 16*k, y: origin.y - 16*k,
                                width: 32*k, height: 32*k)).fill()
    ctx.restoreGState()

    // 窗口本体
    let winW = 560 * k, winH = 400 * k
    let win = NSRect(x: (size - winW)/2, y: (size - winH)/2 - 30*k, width: winW, height: winH)
    ctx.setShadow(offset: CGSize(width: 0, height: -10*k), blur: 30*k,
                  color: NSColor(white: 0, alpha: 0.28).cgColor)
    NSColor(white: 1, alpha: 0.97).setFill()
    NSBezierPath(roundedRect: win, xRadius: 44*k, yRadius: 44*k).fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // 标题栏
    let barH = 92 * k
    let bar = NSRect(x: win.minX, y: win.maxY - barH, width: win.width, height: barH)
    ctx.saveGState()
    NSBezierPath(roundedRect: win, xRadius: 44*k, yRadius: 44*k).addClip()
    NSColor(srgbRed: 0.90, green: 0.92, blue: 0.96, alpha: 1).setFill()
    bar.fill()
    ctx.restoreGState()

    // 标题栏左侧三个圆点
    let dotR = 15 * k
    for (i, c) in [NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1),
                   NSColor(srgbRed: 1.0, green: 0.74, blue: 0.19, alpha: 1),
                   NSColor(srgbRed: 0.24, green: 0.79, blue: 0.29, alpha: 1)].enumerated() {
        c.setFill()
        let cx = win.minX + 52*k + CGFloat(i) * 56*k
        NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: bar.midY - dotR,
                                    width: dotR*2, height: dotR*2)).fill()
    }

    // 内容区示意的几根横线
    NSColor(srgbRed: 0.62, green: 0.67, blue: 0.76, alpha: 1).setFill()
    let widths: [CGFloat] = [0.72, 0.52, 0.62, 0.38]
    for (i, wf) in widths.enumerated() {
        let y = bar.minY - 72*k - CGFloat(i) * 62*k
        let r = NSRect(x: win.minX + 54*k, y: y, width: (win.width - 108*k) * wf, height: 26*k)
        NSBezierPath(roundedRect: r, xRadius: 13*k, yRadius: 13*k).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (base, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let px = CGFloat(base * scale)
    let rep = draw(size: px)
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: iconset.appendingPathComponent(name))
}
print("iconset 已生成: \(iconset.path)")

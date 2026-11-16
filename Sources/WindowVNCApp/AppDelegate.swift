import AppKit
import CoreMedia
import ScreenCaptureKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, CaptureEngineDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let engine = CaptureEngine()
    private var server: RFBServer?
    private var pickerWindow: NSWindow?
    private let pickerModel = WindowPickerModel()
    private var preview: PreviewWindowController?
    private var sharingTitle = ""
    private var clientCount = 0
    private var statsTimer: Timer?
    private var blinkTimer: Timer?
    private var blinkOn = false
    private var latestClientStats: [ClientStats] = []
    /// 从什么时候开始没人看。有人连上时置空。
    private var noViewerSince: Date?
    private var about: AboutWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engine.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 菜单内容在展开的瞬间才生成（见 menuNeedsUpdate），保证看到的永远是最新状态。
        // 之前是"人数变化时重建一次"，而那一刻统计数据还没到，于是永远显示"暂无观看者"。
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    // MARK: - 菜单栏

    /// 菜单要展开了，现取一次最新数据再填内容
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func rebuildMenu() {
        updateIcon(sharing: engine.isRunning)
        if let menu = statusItem.menu { populate(menu) }
    }

    private func populate(_ menu: NSMenu) {
        let sharing = engine.isRunning
        menu.removeAllItems()
        if sharing {
            addDisabled(menu, "正在共享：\(sharingTitle)")
            for ip in RFBServer.localIPv4Addresses() {
                addDisabled(menu, "    \(ip):\(Settings.port)")
            }
            addDisabled(menu, "    密码 \(Settings.password)")
            let viewers = server?.clientCount ?? 0
            if viewers > 0 {
                addDisabled(menu, "    \(viewers) 人正在观看")
            } else if let left = autoStopRemaining {
                addDisabled(menu, "    暂无观看者，\(left) 秒后自动停止")
            } else {
                addDisabled(menu, "    暂无观看者")
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "拷贝连接地址", action: #selector(copyAddress), keyEquivalent: "")
            menu.addItem(qualityMenuItem())
            menu.addItem(autoStopMenuItem())
            menu.addItem(withTitle: "显示本地预览", action: #selector(showPreview), keyEquivalent: "")
            menu.addItem(withTitle: "切换窗口…", action: #selector(openPicker), keyEquivalent: "")
            menu.addItem(withTitle: "停止共享", action: #selector(stopSharing), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "选择窗口并共享…", action: #selector(openPicker), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "关于 WindowVNC", action: #selector(openAbout), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "退出 WindowVNC", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil && item.target == nil {
            item.target = self
        }
    }

    /// 画质子菜单。共享过程中切换是实时生效的：靠 SCStream.updateConfiguration
    /// 改捕获分辨率，再用 DesktopSize 伪编码通知观看者重排，不需要重连。
    private func qualityMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        for (title, scale) in [("1x  流畅（推荐）", 1.0), ("2x  Retina 原生", 2.0)] {
            let i = NSMenuItem(title: title, action: #selector(setScale(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = scale
            i.state = abs(Settings.pixelScale - scale) < 0.01 ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        for (title, q) in [("JPEG 高清 0.9", 0.9), ("JPEG 均衡 0.8", 0.8), ("JPEG 省流 0.6", 0.6)] {
            let i = NSMenuItem(title: title, action: #selector(setJPEGQuality(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = q
            i.state = abs(Settings.jpegQuality - q) < 0.01 ? .on : .off
            sub.addItem(i)
        }
        let item = NSMenuItem(title: "画质", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    /// 无人观看自动停止的快捷档位。任意秒数可以在「设置…」里填。
    private func autoStopMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        let presets: [(String, Int)] = [("不自动停止", 0), ("30 秒", 30), ("1 分钟", 60),
                                        ("3 分钟", 180), ("5 分钟", 300), ("10 分钟", 600)]
        let current = Settings.autoStopSeconds
        var matched = false
        for (title, secs) in presets {
            let i = NSMenuItem(title: title, action: #selector(setAutoStop(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = secs
            i.state = current == secs ? .on : .off
            if current == secs { matched = true }
            sub.addItem(i)
        }
        if !matched {
            sub.addItem(.separator())
            let i = NSMenuItem(title: "自定义：\(current) 秒", action: nil, keyEquivalent: "")
            i.state = .on
            i.isEnabled = false
            sub.addItem(i)
        }
        let item = NSMenuItem(title: "无人观看时", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    @objc private func setAutoStop(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Int else { return }
        Settings.autoStopSeconds = secs
        // 改了档位就重新起算，不然可能刚设完就立刻触发停止
        if clientCount == 0 { noViewerSince = Date() }
        rebuildMenu()
    }

    @objc private func setScale(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? Double else { return }
        Settings.pixelScale = scale
        Task { @MainActor in
            if engine.isRunning {
                do { try await engine.updatePixelScale(CGFloat(scale)) }
                catch { presentError(error) }
            }
            rebuildMenu()
        }
    }

    @objc private func setJPEGQuality(_ sender: NSMenuItem) {
        guard let q = sender.representedObject as? Double else { return }
        Settings.jpegQuality = q      // 编码时每帧读一次，立即生效
        rebuildMenu()
    }

    /// 共享中让图标中间的红点闪烁，一眼就能看出正在共享。
    /// 定时器加到 .common 模式，否则菜单展开时 RunLoop 切模式，闪烁会停。
    private func updateIcon(sharing: Bool) {
        guard let button = statusItem.button else { return }
        if sharing {
            if blinkTimer == nil {
                blinkOn = true
                let t = Timer(timeInterval: 0.7, target: self,
                              selector: #selector(blinkTick), userInfo: nil, repeats: true)
                RunLoop.main.add(t, forMode: .common)
                blinkTimer = t
            }
            button.image = StatusIcon.sharing(dotVisible: blinkOn)
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkOn = false
            button.image = StatusIcon.idle()
        }
    }

    @objc private func blinkTick() {
        blinkOn.toggle()
        statusItem.button?.image = StatusIcon.sharing(dotVisible: blinkOn)
    }

    private func addDisabled(_ menu: NSMenu, _ title: String) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        menu.addItem(i)
    }

    // MARK: - 动作

    @objc private func openPicker() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = pickerWindow {
            w.makeKeyAndOrderFront(nil)
            Task { await pickerModel.refresh() }
            return
        }
        let view = WindowPickerView(
            model: pickerModel,
            onPick: { [weak self] window, includeChildren in
                self?.startSharing(window: window, includeChildren: includeChildren)
            },
            onCancel: { [weak self] in self?.closePicker() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "WindowVNC"
        w.setContentSize(NSSize(width: 780, height: 580))
        w.styleMask.insert(.resizable)
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        pickerWindow = w
    }

    private func closePicker() {
        pickerWindow?.close()
        pickerWindow = nil
    }

    private func startSharing(window: SCWindow, includeChildren: Bool) {
        closePicker()
        sharingTitle = (window.title?.isEmpty == false) ? window.title! : "(无标题窗口)"
        Task { @MainActor in
            do {
                try await engine.start(window: window,
                                       includeChildWindows: includeChildren,
                                       fps: Settings.fps,
                                       pixelScale: CGFloat(Settings.pixelScale))
                if server == nil {
                    let s = RFBServer(port: Settings.port,
                                      password: Settings.password,
                                      desktopName: "奇技教育 · \(sharingTitle)")
                    s.onClientCountChanged = { [weak self] n in
                        Task { @MainActor in
                            guard let self else { return }
                            self.clientCount = n
                            self.noViewerSince = (n > 0) ? nil : Date()
                            self.rebuildMenu()
                        }
                    }
                    s.onError = { [weak self] e in
                        Task { @MainActor in self?.presentError(e) }
                    }
                    try s.start()
                    server = s
                    serverRef = s
                } else {
                    server?.updateDesktopName("奇技教育 · \(sharingTitle)")
                }
                noViewerSince = Date()
                startStatsTimer()
                showPreview()
                preview?.adaptSize(to: CGSize(width: window.frame.width * CGFloat(Settings.pixelScale),
                                              height: window.frame.height * CGFloat(Settings.pixelScale)))
                rebuildMenu()
            } catch {
                presentError(error)
            }
        }
    }

    /// 每秒把每个观看者的实时状况刷到预览窗口和菜单里。
    /// 关键是把「编码耗时」和「发送耗时」分开——前者高是 CPU 不够，后者高是网络不够。
    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let server = self.server else { return }
                self.latestClientStats = server.allClientStats()
                self.preview?.updateClients(self.latestClientStats)
                self.checkAutoStop()
            }
        }
    }

    /// 无人观看超时就自动停止共享
    private func checkAutoStop() {
        let limit = Settings.autoStopSeconds
        guard limit > 0, clientCount == 0, let since = noViewerSince else { return }
        let idle = Int(Date().timeIntervalSince(since))
        if idle >= limit {
            DebugLog.log("无人观看 \(idle) 秒，自动停止共享")
            stopSharing()
        }
    }

    /// 剩余多少秒自动停止，不启用或有人在看时返回 nil
    private var autoStopRemaining: Int? {
        let limit = Settings.autoStopSeconds
        guard limit > 0, clientCount == 0, let since = noViewerSince else { return nil }
        return max(0, limit - Int(Date().timeIntervalSince(since)))
    }

    @objc private func showPreview() {
        if preview == nil {
            let pc = PreviewWindowController(title: sharingTitle)
            pc.onClose = { [weak self] in self?.preview = nil }
            preview = pc
        }
        NSApp.activate(ignoringOtherApps: true)
        preview?.showWindow(nil)
        preview?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func copyAddress() {
        let ip = RFBServer.localIPv4Addresses().first ?? "127.0.0.1"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(ip):\(Settings.port)", forType: .string)
    }

    @objc private func stopSharing() {
        Task { @MainActor in
            await engine.stop()
            statsTimer?.invalidate()
            statsTimer = nil
            latestClientStats = []
            noViewerSince = nil
            server?.stop()
            server = nil
            serverRef = nil
            preview?.close()
            preview = nil
            sharingTitle = ""
            clientCount = 0
            rebuildMenu()
        }
    }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        if about == nil {
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "—"
            about = AboutWindowController(version: v)
        }
        about?.showWindow(nil)
        about?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "设置"
        alert.informativeText = "端口和密码在下次开始共享时生效；画质和自动停止立即生效。\n"
                              + "「无人观看自动停止」填 0 表示不自动停止。"
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 340, height: 116))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let portField = NSTextField(string: String(Settings.port))
        let pwField = NSTextField(string: Settings.password)
        let autoStopField = NSTextField(string: String(Settings.autoStopSeconds))
        let scalePopup = NSPopUpButton()
        scalePopup.addItems(withTitles: ["1x（推荐，更流畅）", "2x（Retina 原生，更清晰）"])
        scalePopup.selectItem(at: Settings.pixelScale >= 1.5 ? 1 : 0)

        for (label, view) in [("端口", portField), ("密码", pwField),
                              ("无人观看自动停止(秒)", autoStopField)] as [(String, NSView)] {
            let row = NSStackView(views: [NSTextField(labelWithString: label), view])
            row.orientation = .horizontal
            (view as? NSTextField)?.preferredMaxLayoutWidth = 180
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(row)
        }
        let scaleRow = NSStackView(views: [NSTextField(labelWithString: "画质"), scalePopup])
        scaleRow.orientation = .horizontal
        stack.addArrangedSubview(scaleRow)

        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let p = UInt16(portField.stringValue), p > 0 { Settings.port = p }
        if !pwField.stringValue.isEmpty {
            // VNC Auth 的 DES key 只有 8 字节，超出部分客户端会截断，这里也截断保持一致
            Settings.password = String(pwField.stringValue.prefix(8))
        }
        Settings.pixelScale = scalePopup.indexOfSelectedItem == 1 ? 2.0 : 1.0
        if let secs = Int(autoStopField.stringValue) { Settings.autoStopSeconds = secs }
        rebuildMenu()
    }

    @objc private func quit() {
        Task { @MainActor in
            await engine.stop()
            server?.stop()
            NSApp.terminate(nil)
        }
    }

    private func presentError(_ error: Error) {
        let a = NSAlert()
        a.messageText = "出错了"
        a.informativeText = "\(error)"
        a.alertStyle = .warning
        a.addButton(withTitle: "好")
        a.runModal()
    }

    // MARK: - CaptureEngineDelegate（在捕获队列上被调用）

    nonisolated func captureEngine(_ engine: CaptureEngine, didOutput sampleBuffer: CMSampleBuffer,
                                   dirtyRects: [CGRect]) {
        // 直接在捕获队列上灌进服务端，省一次跨线程往返
        if let pb = sampleBuffer.imageBuffer {
            serverRef?.ingest(pixelBuffer: pb, dirtyRects: dirtyRects)
        }
        DispatchQueue.main.async { [weak self] in
            self?.preview?.previewView.enqueue(sampleBuffer)
        }
    }

    nonisolated func captureEngine(_ engine: CaptureEngine, didUpdate stats: FrameStats) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var s = stats
            s.clientCount = self.clientCount
            self.preview?.update(stats: s)
        }
    }

    nonisolated func captureEngine(_ engine: CaptureEngine, didResizeTo pixelSize: CGSize) {
        DispatchQueue.main.async { [weak self] in
            self?.preview?.adaptSize(to: pixelSize)
        }
    }

    nonisolated func captureEngineWindowDisappeared(_ engine: CaptureEngine) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSLog("[App] 被共享的窗口已关闭，自动停止共享")
            self.stopSharing()
        }
    }

    nonisolated func captureEngine(_ engine: CaptureEngine, didFailWith error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentError(error)
            self.stopSharing()
        }
    }

    /// 捕获队列上要用 server，但 server 属性是 MainActor 隔离的。
    /// 这里存一份非隔离的引用，只在开始/停止共享时写，读写都是原子的指针赋值。
    private nonisolated(unsafe) static var _serverRef: RFBServer?
    private nonisolated var serverRef: RFBServer? {
        get { Self._serverRef }
        set { Self._serverRef = newValue }
    }
}

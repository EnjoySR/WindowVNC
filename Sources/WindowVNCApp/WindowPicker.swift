import AppKit
import ScreenCaptureKit
import SwiftUI

let kChromeBundleID = "com.google.Chrome"

struct CandidateWindow: Identifiable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bundleID: String
    let frame: CGRect
    let isOnScreen: Bool
    var thumbnail: CGImage?

    var scWindow: SCWindow
}

@MainActor
final class WindowPickerModel: ObservableObject {
    @Published var windows: [CandidateWindow] = []
    @Published var chromeOnly = true
    @Published var includeChildWindows = true
    @Published var loading = false
    @Published var errorText: String?

    func refresh() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            // onScreenWindowsOnly: true —— 只要当前真正显示在屏幕上的窗口。
            // 用 false 的话，已经关掉但对象还没销毁的、最小化的、隐藏的窗口都会混进来。
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            var list: [CandidateWindow] = []
            for w in content.windows {
                guard let app = w.owningApplication else { continue }
                if chromeOnly && app.bundleIdentifier != kChromeBundleID { continue }
                // Chrome 会开一堆不可见的辅助窗口，按尺寸、图层、可见性过滤掉
                guard w.isOnScreen else { continue }
                guard w.frame.width >= 200, w.frame.height >= 150 else { continue }
                guard w.windowLayer == 0 else { continue }
                // 没标题的基本都是 Chrome 的内部辅助窗口，不是真正的浏览器窗口
                guard let t = w.title, !t.isEmpty else { continue }
                list.append(CandidateWindow(
                    id: w.windowID,
                    title: w.title ?? "",
                    appName: app.applicationName,
                    bundleID: app.bundleIdentifier,
                    frame: w.frame,
                    isOnScreen: w.isOnScreen,
                    thumbnail: nil,
                    scWindow: w))
            }
            list.sort { ($0.appName, $0.id) < ($1.appName, $1.id) }
            windows = list
            await loadThumbnails()
        } catch {
            errorText = "\(error)"
            windows = []
        }
    }

    private func loadThumbnails() async {
        for (idx, cand) in windows.enumerated() {
            guard let img = await Self.thumbnail(for: cand.scWindow,
                                                 includeChildren: includeChildWindows) else { continue }
            if idx < windows.count, windows[idx].id == cand.id {
                windows[idx].thumbnail = img
            }
        }
    }

    static func thumbnail(for window: SCWindow, includeChildren: Bool) async -> CGImage? {
        let cfg = SCStreamConfiguration()
        let aspect = window.frame.height / max(window.frame.width, 1)
        cfg.width = 480
        cfg.height = max(2, Int(480 * aspect))
        cfg.showsCursor = false
        cfg.backgroundColor = .black
        cfg.shouldBeOpaque = true
        cfg.ignoreShadowsSingleWindow = true
        cfg.ignoreGlobalClipSingleWindow = true
        cfg.includeChildWindows = includeChildren
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

struct WindowPickerView: View {
    @ObservedObject var model: WindowPickerModel
    var onPick: (SCWindow, Bool) -> Void
    var onCancel: () -> Void

    @State private var selected: CGWindowID?

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack {
            Text("选择要共享的窗口")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新窗口列表")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let e = model.errorText {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("无法获取窗口列表").font(.headline)
                Text(e).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text("多半是缺少「屏幕录制」权限：\n系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 WindowVNC")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("打开系统设置") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if model.windows.isEmpty && !model.loading {
            VStack(spacing: 8) {
                Text(model.chromeOnly ? "没有找到 Chrome 窗口" : "没有找到可共享的窗口")
                    .font(.headline)
                Text(model.chromeOnly
                     ? "确认 Chrome 已经打开且窗口没有最小化，或者取消勾选下面的「只显示 Chrome」"
                     : "只会列出当前显示在屏幕上的窗口，最小化的不会出现")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.windows) { w in
                        card(w)
                    }
                }
                .padding(16)
            }
        }
    }

    private func card(_ w: CandidateWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.15))
                if let t = w.thumbnail {
                    Image(decorative: t, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(w.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(w.appName)
                Text("·")
                Text("\(Int(w.frame.width))×\(Int(w.frame.height))")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected == w.id ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected == w.id ? Color.accentColor : Color.gray.opacity(0.25),
                              lineWidth: selected == w.id ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pick(w) }
        .onTapGesture { selected = w.id }
    }

    private var footer: some View {
        HStack {
            Toggle("只显示 Chrome", isOn: $model.chromeOnly)
                .onChange(of: model.chromeOnly) { _, _ in Task { await model.refresh() } }
            Toggle("包含子窗口（菜单 / 弹窗）", isOn: $model.includeChildWindows)
                .onChange(of: model.includeChildWindows) { _, _ in Task { await model.refresh() } }
                .help("Chrome 的右键菜单、地址栏补全、下载气泡是独立的子窗口，关掉这个选项它们不会出现在共享画面里")
            Spacer()
            Button("取消") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("开始共享") {
                if let id = selected, let w = model.windows.first(where: { $0.id == id }) {
                    pick(w)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selected == nil)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func pick(_ w: CandidateWindow) {
        onPick(w.scWindow, model.includeChildWindows)
    }
}

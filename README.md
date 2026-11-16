# WindowVNC

只把**指定的一个窗口**通过标准 VNC 协议共享出去，对方用任意 VNC Viewer 就能看。
观看端体验和普通 VNC 完全一样：输入 `局域网IP:5901` + 密码。

## 为什么不能用现成的 VNC 软件

RFB 协议传的是一整块 framebuffer，协议里没有"窗口"这个概念，
所以 RealVNC / 系统屏幕共享都只能共享整个显示器。

这里用 `SCContentFilter(desktopIndependentWindow:)` 抓单个窗口——它取的是
**窗口自己的图层内容**，不是从屏幕上抠一块。所以目标窗口被别的窗口盖住时，
盖在上面的东西不会出现在画面里；桌面、Dock、菜单栏、其他 App 从来就不在这块
buffer 里。隔离性是结构性保证的，不是靠裁剪。

## 用法

1. 菜单栏图标 →「选择窗口并共享…」→ 挑一个窗口
2. 共享中图标会闪红点，菜单里显示连接地址、密码、观看者实时状态
3. 对方 VNC Viewer 连 `IP:5901`，输密码

默认端口 **5901**，避开 5900，可以和系统自带的屏幕共享或 RealVNC Server 并存。

只看不控——键鼠事件会被解析后丢弃，所以不需要辅助功能权限，只需要屏幕录制权限。

## 编码

按客户端支持情况自动降级，这一步直接决定流畅度：

| 编码 | 用于 | 说明 |
|---|---|---|
| Tight | TigerVNC / TightVNC | 压缩率最好，有 JPEG 通路，适合图片视频 |
| **ZRLE** | **RealVNC Viewer** | RealVNC 首选，无损，文字锐利 |
| Raw | 都不支持时的兜底 | 裸像素，一帧几 MB，只有回环扛得住 |

**RealVNC Viewer 不支持 Tight**，所以 ZRLE 这一路是必需的——只有 Tight 和 Raw
的话会直接掉到 Raw，单帧 13MB，Wi-Fi 上必卡。

## 构建

```bash
./build_app.sh                # 编译 + 签名，产物 build/WindowVNC.app
./scripts/package_dmg.sh      # 打 DMG，产物 dist/WindowVNC-<版本>.dmg
```

**必须用 Release 构建**（脚本默认就是）。Debug 构建不消除数组边界检查也不内联，
ZRLE 的逐像素循环会慢一倍以上，帧率从 28fps 掉到 13fps。

签名用 Apple Development 证书而不是 ad-hoc：TCC 的屏幕录制授权绑定代码签名身份，
ad-hoc 每次编译 cdhash 都变，系统会当成新 App 反复索要权限。

未做公证，别人的 Mac 首次打开需要在「系统设置 → 隐私与安全性」里放行，
DMG 里附了说明。要消除该提示需要 Developer ID 证书 + Apple 公证，
钩子见 `scripts/package_dmg.sh` 顶部注释。

## 排错

`~/Library/Logs/WindowVNC.log` 记录开头 200 帧的详情：
ScreenCaptureKit 给的脏矩形、每帧编码耗时 / 发送耗时 / 输出字节数。

预览窗口底部两行实时状态，其中观看者那行能一眼定位瓶颈：

- 显示 `Raw ⚠️` → 编码协商退化了
- **编码 ms 远大于发送 ms** → CPU 瓶颈
- **发送 ms 远大于编码 ms** → 网络瓶颈

## 已知限制

- **最小化的窗口抓不到新画面**，所以选择器不列它们
- Chrome 的右键菜单、地址栏补全等是独立子窗口，靠 `includeChildWindows` 带上
- **DRM 内容是黑的**（Netflix 等走 Widevine 硬件通路），任何屏幕捕获都一样
- 滚动时整个窗口重绘，需无损重编码约 220KB / 40ms 每帧。
  还没做 CopyRect——滚动时内容大多只是整体平移，用 CopyRect 可以 12 字节
  代替 220KB 重传，这是后续最大的一个优化杠杆

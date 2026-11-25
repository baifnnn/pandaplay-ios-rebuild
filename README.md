# 从 iOS 重做 PandaPlay+ 1.3

原 App 是 iPhone 上的**接收端**（accessory）：车机（controller）把 H.264 画面推过来，iPhone 显示并把触摸回转。这个仓**从零重写**了同一套协议栈，不复制原二进制、不含原资源。

```
pandaplay-ios/
├── PandaPlayCore/                 Swift Package，纯 Swift 协议栈，无 UIKit 依赖
│   ├── Sources/PandaPlayCore/
│   │   ├── Crypto/                ChaCha20-Poly1305、SHA-512、X25519、Ed25519、SRP-6a
│   │   ├── Protocol/              RTSP、媒体分帧、触控、Pairing、H.264
│   │   ├── Transport/             Bonjour、DNS 线格式、通道抽象
│   │   └── Diagnostics/           遥测与帧长直方图
│   └── Tests/PandaPlayCoreTests/  163 项 XCTest，任意平台可跑
├── App/                           iOS 壳（SwiftUI + AVSampleBufferDisplayLayer）
│   ├── PandaPlay.xcodeproj
│   └── PandaPlay/                 Info.plist、entitlements、5 个 Swift 源文件
└── docs/protocol.md               协议逆向记录
```

## 为什么 Core 是独立的 Swift Package

原 App 是单个 arm64 二进制，协议逻辑与 UI 搅在一起，没法单独验证。这里把协议栈抽成不依赖 UIKit / Network.framework 的包，于是：

- 在 **Windows 或 Linux** 上就能跑完整测试（本仓的 163 项就是这样验证的），不需要 iPhone 或 Mac；
- 协议细节可以对着 XCTest 断言逐步校，而不是装到真机上盲试；
- iOS 壳只剩适配层，约 700 行。

## 构建

需要 macOS 14+ 与 Xcode 15+（iOS 17 SDK）。

```bash
cd App
xcodebuild -project PandaPlay.xcodeproj -scheme PandaPlay \
  -destination 'generic/platform=iOS' -configuration Release build
```

签名用你自己的 Team：`DEVELOPMENT_TEAM=你的TeamID`。Bundle ID 沿用 `top.shareway.pandaplayplus.ios`；换成自己的会更好，因为车机侧只按 Bonjour 服务名匹配，不校验 Bundle ID。

打 IPA：

```bash
xcodebuild -project PandaPlay.xcodeproj -scheme PandaPlay \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath build/PandaPlay.xcarchive archive
xcodebuild -exportArchive -archivePath build/PandaPlay.xcarchive \
  -exportPath build/ipa -exportOptionsPlist ExportOptions.plist
```

`ExportOptions.plist` 里 `method` 选 `development`（真机调试）或 `ad-hoc`。

## 只跑测试（不需要 Xcode）

```bash
cd PandaPlayCore
swift test
```

Windows 上需要 MSVC Build Tools 与 Swift 6.x；本仓根目录的 `swift.cmd` 是给 Windows 用的包装（先 `vcvars64.bat` 再设 `SDKROOT`），路径都相对脚本自身解析，换机器可直接用。若工具链装在别处，先设 `SWIFT_ROOT` / `VCVARS64`：

```bat
set SWIFT_ROOT=C:\path\to\Swift
set VCVARS64=C:\path\to\vcvars64.bat
swift.cmd test
```

macOS/Linux 直接用 `swift test`。

## 运行时需要的东西

| 项 | 值 |
|---|---|
| Bonjour 服务类型 | `_panda.wireless-car._tcp` |
| 控制端口 | 7000 |
| 媒体端口 | 7100–7103（UI 暴露 5 个候选，传输层实际 arm 7 个） |
| 配对码 | 3939 |
| 部署目标 | iOS 17.0 |

`Info.plist` 里的 `NSLocalNetworkUsageDescription` 与 `NSBonjourServices` 必须在，否则 iOS 会在收到第一个包之前就拦掉发现流程。

## 实现了什么

- **配对**：SRP-6a（RFC 3526 group 15）→ HKDF-SHA512 → Ed25519 验签 → ChaCha20-Poly1305；`/pair-setup` 与 `/pair-verify` 各三问三答。
- **控制面**：RTSP 六目标（`/pair-setup`、`/pair-verify`、`/auth-setup`、`/info`、`/feedback`、`/command`）、四方法（`SET_PARAMETER`、`SETUP`、`RECORD`、`TEARDOWN`）加 `OPTIONS`；六种状态行。
- **媒体面**：16 字节信令帧（槽 0/1）与 8 字节窗口帧（槽 ≥2）分开，同一 socket 永不混用；19 个命令字的应答规则（奇数命令是对端回复，永不再回）。
- **触控**：int16 大端 action/坐标；手势规则先于几何校验；钳位只在按键按下时生效。
- **H.264**：AVCC 长度前缀分帧、avcC 盒、参数集变更触发解码器重建。
- **发现**：手写 DNS 线格式与 mDNS 应答（PTR/SRV/TXT/A 四条记录）。

## 刻意不做

这些在二进制里能证明原版也没有，所以不做——不是省事，是保持一致：

- **音频流**：能力档写明 `no_audio`，`/info` 的 `modes` 不含音频。
- **H.264 I 帧主动请求**：`supportH264IFrame` 恒为 `false`。
- **账号与授权**：`/auth-setup` 只回 `503`，原版的后端（`pandaplus.shareway.top:8443`）不复刻。
- **iAP2 / MFi / CarPlay 有线握手**：USB 投影走的是七个环回监听器，不是 CarPlay。

## 已知限制

- `SETUP` 只回环回端口表，五把 `*-Encryption-Key` 没有真正参与会话密钥派生——原版在同一处也是只回表，密钥由配对层产出。
- **Windows 上产不出可安装的 IPA**：没有 iPhoneOS SDK，也没有 Apple 签名链。本仓在 Windows 上验证的是 Core 的 163 项测试；出 IPA 必须在 macOS 上做。
- 没有做 App 图标与启动图，用系统默认。

## 协议细节

见 `docs/protocol.md`。那里记了每个常量的来源、逆向时的误判与纠正，以及"为什么这个字段看着该有却没有"。

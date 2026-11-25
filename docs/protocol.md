# PandaPlay+ 1.3 协议记录

这份文档是逆向笔记，记录**每个常量从哪来**、**当初怎么判错的**、以及为什么某些看着该有的东西真的没有。它对应 `PandaPlayCore` 里的类型，改实现前先看这里。

目标二进制：`PandaPlay+_1.3_decrypted.ipa` / `Payload/USBProbe.app/USBProbe`。

---

## 0. 二进制的事实

| 项 | 值 |
|---|---|
| CFBundleIdentifier | `top.shareway.pandaplayplus.ios` |
| CFBundleName / Executable | `USBProbe`（伪装名） |
| 版本 | 1.3 / build 132 |
| 架构 | arm64 thin |
| MinOS | 17.0 |
| Team | `MX42GAQFQ8` |
| entitlements | `com.apple.developer.networking.wifi-info`、`com.apple.developer.networking.HotspotConfiguration` |
| 加密 | `LC_ENCRYPTION_INFO_64 cryptid = 0`，段熵 6.6 → 已完整脱壳 |
| 描述文件 | 无 `embedded.mobileprovision`（TestFlight 原件） |

残留的 `SC_Info/` 只是脱壳没清掉，不代表还有加密。

### 反编译时踩的三个坑

1. **`__cstring` 里的中文是 GBK，不是 UTF-8。** 直接按 UTF-8 读会得到乱码，进而误判"原版没有中文文案"。实际有 332 条。
2. **Swift ≤15 字节的字符串会内联成小端 u64 立即数。** `cstring` 表里搜不到某个字面量，**不等于功能不存在**。找协议字面量必须三路并行：
   - `__cstring` 表；
   - `strrefs`（静态 `String` 对象）；
   - 反编译里的十六进制立即数。
   早期据此得出"只支持 `/command`"的结论是错的，后来在立即数里挖出了完整的 RTSP 目标表。
3. **VA → 文件偏移 = `VA − 0x100000000`。** 换段基址时容易算错。

内嵌的源码路径（原作者机器）：

```
/Users/ergou/Documents/vsProject/panda-project/panda-mini-ios-1.2/...
/Users/ergou/panda-carplay-ios-port/v023-receiver-session-development/...
```

---

## 1. 角色

iPhone 是 **accessory（附件）**，只监听，从不外拨。

- 车机（controller）主动连上来。
- `role 1` = controller→phone 方向；`role 2` = phone→controller。
- USB 投影不走 CarPlay，是**七个固定 IPv4 环回监听器**。

---

## 2. 控制面：RTSP

### 2.1 六个目标、四个方法（不是只有 `/command`）

| target | 枚举值 |
|---|---|
| `/pair-setup` | 0 |
| `/pair-verify` | 1 |
| `/auth-setup` | 2 |
| `/info` | 3 |
| `/feedback` | 4 |
| `/command` | 5 |
| 其它 | 12 |

| method | 枚举值 |
|---|---|
| `SET_PARAMETER` | 6 |
| `SETUP` | 9 |
| `RECORD` | 10 |
| `TEARDOWN` | 11 |
| 其它 | none |

另外应答 `OPTIONS`。

### 2.2 为什么曾经判断错

早期只在 `__cstring` 里看到 `/command`，就写了"只支持 `/command`"。错因是 §0 的第 2 条：另外五个路径字符串都 ≤15 字节，被内联成立即数了，`cstring` 表里根本没有。教训记在这里，免得重犯。

### 2.3 六种状态行

| 码 | 短语 |
|---|---|
| 200 | `OK` |
| 400 | `Bad Request` |
| 403 | `Forbidden` |
| 461 | `Unsupported Transport`（`0x1cd`） |
| 501 | `Not Implemented`（`0x1f5`） |
| 503 | `Service Unavailable`（`0x1f7`） |

461 是 RTSP 特有的"传输参数对不上"，本协议用它表示流配置被拒。

### 2.4 `/command` 的 11 个 `type`

| wire | 内部名 |
|---|---|
| `requestUI` | `request_ui` |
| `takeScreen` | `take_screen` |
| `releaseScreen` | `release_screen` |
| `modesChanged` | `modes_changed` |
| `hidSetInputMode` | `hid_set_input_mode` |
| `disableBluetooth` | `disable_bluetooth` |
| `forceKeyFrame` | `force_key_frame` |
| `updateFeedback` | `update_feedback` |
| `duckAudio` | `duck_audio` |
| `unduckAudio` | `unduck_audio` |
| `hidCopyInputMode` | `hid_copy_input_mode` |

`takeScreen` 的响应体带上 `width` / `height` / `orientation`；`hidSetInputMode` 的 `params` 里带触控样本。

### 2.5 `/info` 的字典

编码是**二进制 plist**（`NSPropertyListBinaryFormat_v1_0`，format 200），但 `Content-Type` 声明 `application/octet-stream`。这个不一致是原版行为，这里故意保留——改对了反而会和车机的解析器冲突。

键：

```
sourceVersion  deviceID  model  features  statusFlags
modes  displays  safeArea  viewArea  initialViewArea
```

约束：

| 项 | 范围 |
|---|---|
| 宽 / 高 | 17 … 4096 |
| fps | 1 … 60 |
| uuid 长度 | ≤ 128 |
| display `type` | 常量 `110` |
| `features` | `physicalWidth != 0 ? 8 : 0` |

`displays` 是数组，每个元素一个字典；`modes` 只有 `screen` / `video`——**没有音频**（见 §5）。

### 2.6 `SETUP` 的流表

`streams` 数组，每个元素：

```
type  dataPort  controlPort  timingPort  streamConnectionID
```

五把密钥名（配对层产出，`SETUP` 只回表）：

```
DataStream-Output-Encryption-Key
Events-Read-Encryption-Key
Events-Write-Encryption-Key
Control-Write-Encryption-Key
Control-Read-Encryption-Key
```

11 条拒绝原因：

```
unsupported_transport     unsupported_plist        unsupported_codec
invalid_connection_id     invalid_codec_type       unsupported_stream_type
unsupported_stream_count  invalid_stream_type      invalid_stream_dictionary
empty_streams             already_configured
```

### 2.7 缓冲与解析诊断

- 缓冲上限 `0x10000`（64 KiB）。
- 诊断词：`buffer_limit`、`message_limit`、`header_encoding`、`start_line`、`version`、`header_syntax`、`cseq_syntax`、`header_limit`、`body_limit`。

头必须以 `\r\n\r\n` 结束；只认 CRLF。

---

## 3. 媒体面

### 3.1 两套分帧，同一 socket 永不混用

poll 槽分流（`0x100004eb0` 第 855 / 871 行）：

| 槽 | 分帧 |
|---|---|
| 0 / 1 | 16 字节信令帧（`FUN_1000049d8`） |
| ≥ 2 | 8 字节窗口帧（`FUN_100007854`，槽号减 2） |

### 3.2 16 字节信令头

收发同构：

```
u32 command        (BE)
u32 totalLength    (BE)
u32 command ^ totalLength  (BE)
u32 auxiliary      (LE)   ← 注意是小端
payload
```

出站 `payload ≤ 0x3f0`（1008）；队列最多 128 帧且累计 ≤ `0x4000`。入站严格上限 `0x2000`，宽松 `0x1000000`；全局帧计数上限 `0x80`。

命令字：

| 值 | 名 |
|---|---|
| `0x10000` / `0x10001` | c2pHello / Reply |
| `0x10010` / `0x10011` | controlRequest / Reply |
| `0x10020` | controlAck |
| `0x10040` | controlStatus |
| `0x10200` | controlMode |
| `0x102b0` | controlAuxiliary |
| `0x103e0` | controlTiming |
| `0x10400` | keepalive |
| `0x10450` / `0x10451` | clockRequest / Reply |
| `0x10470` | controlSession |
| `0x10610` | controlEvent |
| `0x10690` / `0x10691` | timingReset / Reply |
| `0x20000` / `0x20001` | p2cHello / Reply |
| `0x20590` | videoPull |
| `0x30000` / `0x30001` | streamSetup / Reply |
| `0x30020` / `0x30120` / `0x31020` | streamTiming 三个变体 |
| `0x40010` | （保留） |
| `0x70000000` / `0x70000001` | probe / Reply |
| `0x80000010` / `0x80000020` | halt |

### 3.3 回包规则（`FUN_100006574`）

1. hello 的 payload 必须**恰好 16 字节**。
2. 首次 hello 置 role（1 = c2p，2 = p2c），回 `cmd|1` 空 payload。
3. **奇数命令 = 对端回复，永不再回。** 这条是硬规则，漏了会打出无限乒乓。
4. `0x10010` 一次性回 staged 控制体。
5. `0x10450` 回时钟信封：

   ```json
   {"time":N,"currentTime":N,"currentTimeZone":"Z"}
   ```

   `time` 与 `currentTime` **同值**——不是笔误，原版就是这样。
6. 其余偶数已知命令回 `cmd|1` 空 payload。
7. 附件唯一的自发请求：`role == 2` 之后发一次 `0x20590`，payload 13 字节 `{"control":1}`。

### 3.4 8 字节窗口头

全小端：

```
u16 command
u16 payloadLength
u32 reserved
payload
```

| command | 含义 |
|---|---|
| `0x10` | controlRequest |
| `0x70` | ready（control 认领） |
| `0x72` | pull（video 认领） |

上限：`payload ≤ 0x1000`，帧上限 `0x800`，控制请求最短 `0x1b`（27），触控最短 10 字节。

### 3.5 触控

```
int16 action   (BE)
int16 x        (BE)
int16 y        (BE)
……
```

action：1 = down、2 = move、3 = up、4 = cancel。
回调 phase 编码：move = 0、down = 1、up = 2、cancel = 4。

拒绝码：0 / 1 / 2 / 4 / 5 / 6。**0 有两个含义**（accepted 与 payloadTooShort），所以实现里 `TouchOutcome` 用 struct 而不是 enum——Swift 不允许 enum 有重复 rawValue。

**手势规则先于几何**：重复 down、没有 down 的 move，先被手势规则拒掉，不看坐标是否越界。
**钳位只在按键按下时生效**：`action != move && allowed && pressed`。

---

## 4. 配对与加密

四层：

```
SRP-6a（RFC 3526 group 15，3072-bit，g = 5）
  → HKDF-SHA512
    → Ed25519 验签
      → ChaCha20-Poly1305
```

八个 HKDF 标签：

```
Pair-Setup-Encrypt-Salt      Pair-Setup-Encrypt-Info
Pair-Setup-Controller-Sign-Salt   Pair-Setup-Controller-Sign-Info
Pair-Setup-Accessory-Sign-Salt    Pair-Setup-Accessory-Sign-Info
Pair-Verify-Encrypt-Salt     Pair-Verify-Encrypt-Info
```

12 字节 nonce = 4 字节 0 + `PS-Mg05`（setup）/ `PS-Mg06`（verify）。

phase 状态机 0…6：setup 与 verify 各三问三答。

宽高校验：A = 384、M1 = 64、签名 = 64、salt = 32。

---

## 5. 刻意不实现的部分

这些都能在二进制里证明原版也没有，所以不做。不是省事，是保持一致——多做了会让车机侧的能力协商走到原版没走过的分支。

| 项 | 证据 |
|---|---|
| 音频流 | 能力档 `car_h264_full_initial_arbitration_no_audio_v3` 写明 `no_audio`；`/info` 的 `modes` 无音频 |
| H.264 I 帧主动请求 | PXC hello 里 `supportH264IFrame` 恒 `false` |
| 账号与授权 | `/auth-setup` 只回 `503`；后端 `pandaplus.shareway.top:8443` 不复刻 |
| iAP2 / MFi / CarPlay 有线握手 | USB 投影是七个环回监听器，不是 CarPlay 通道 |

---

## 6. 发现

Bonjour 用**自定义服务类型** `panda.wireless-car`，不是 `_airplay._tcp` 也不是 `_raop._tcp`。

TXT 记录：

```
ty=PandaPlay+    ver=1.3    proto=1    srcvers=1.0.2
```

mDNS 端口 5353。DNS 名字在 rdata 里**完整写出，不做压缩**——压缩指针是合法的，但原版不压缩，跟着不压缩最省事。

无线探针端口 **10930**：只发一次 hello，5000 ms 超时，失败提示「等待本地网络权限」。

USB 投影 = 七个固定 IPv4 环回监听器（遥测键 `usb_projection_transport=seven_fixed_ipv4_loopback_listeners`）；UI 只暴露 5 个候选端口。

---

## 7. 其它常量

### PXC hello（15 键严格序）

```
pxcVersion("1.0.2") → phoneUUID → phoneBrand → phoneModel → phoneOs
→ package → phoneOsVersion → versionCode(恒 1) → supportH264IFrame(恒 false)
→ supportFunction(0) → appVersionFingerPrint("") → token("")
→ pubkey → encryptedHUID → currentTimeZone
```

### H.264

- AVCC（长度前缀大端），不是 Annex-B。
- SPS/PPS 走 `CMVideoFormatDescriptionCreateFromH264ParameterSets`。
- 能力档 `car_h264_full_initial_arbitration_no_audio_v3`。

### 帧长度分带（`FUN_100006cf8`）

```
< 0x2001        → 1
> 0x400000      → 8
> 0x100000      → 7
> 0x40000       → 6
> 0x10000       → 5
> 0x8000        → 4
> 0x4000        → 3
否则            → 2
```

### 授权后端（不复刻，仅记录）

```
https://pandaplus.shareway.top:8443
issuer:   pandaplay-backend
audience: top.shareway.pandaplayplus
P-256 trust key: pandaplay-prod-20261112
```

八个错误码：`invalid_credentials`、`device_unavailable`、`device_not_found`、`entitlement_unavailable`、`current_device_requires_proof`、`user_account_required`、`invalid_challenge`、`invalid_response`。

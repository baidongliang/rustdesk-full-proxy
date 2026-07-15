# 被控端（Android 定制设备）设计文档

> 本文是 [`CUSTOM_DEPLOYMENT_DESIGN.md`](./CUSTOM_DEPLOYMENT_DESIGN.md) 的互补篇。
> 前者覆盖整体部署架构、主控端选型、注册上报、统一密码、自建 hbbs/hbbr、deeplink 拉起；
> 本文聚焦**被控端**在 Android 定制设备上的落地形态：**无 UI 纯服务 + 开机自启 + 前台通知保活 + 静默授权 + 预设密码**。
>
> 本文档只描述设计，不包含改动后的完整代码。所有代码引用格式为 `文件:行号`，供后续开发按图施工。

---

## 一、场景与边界

### 1.1 运行环境

- **设备**：Android 定制设备，拥有全部系统权限。
- **预装**：设备出厂已预装你方**业务 app**，业务 app 统一开启开机启动与看门狗。
- **RustDesk 被控端**：作为**独立 APK**、**独立进程**、**独立包名**与业务 app 并行运行，互不感知。

### 1.2 关键决策（已与需求方确认）

| # | 决策项 | 结论 |
|---|--------|------|
| 1 | UI 形态 | 被控端**无业务 UI**，设备屏幕只显示业务 app；被控端只跑前台服务 |
| 2 | 开机自启归属 | **优先用 Android 系统自身的 `BOOT_COMPLETED` 广播拉起**（复用现有 `BootReceiver`），不接入定制系统 SDK 的开机自启能力；若与业务 app 冲突或保活不稳，再回退接入 SDK。理由：怕与业务 app 的拉起机制打架 |
| 3 | 看门狗/保活 | **不引入独立看门狗进程**；靠 Android **前台服务通知 + `START_STICKY`** 让系统自恢复 |
| 4 | 静默授权 | **先按"系统签名 + 预装"路径实现**（见第五章路径 1），不接入 SDK 授权能力；若不可行再评估 SDK 路径 |
| 5 | 认证 | **预设固定密码**（先固定一个，后期有风险再调整）+ `approve-mode=password`，无人值守，控制端带密码直连 |
| 6 | 与业务 app 关系 | **独立 APK、独立进程、独立包名**（`cn.xinzx.rustdesk.android`），各自管各自生命周期，不通过 AIDL/广播互相调用 |
| 7 | 设备 SN 来源 + 安全程序注册 | **SDK `getCpuSerial()` 取 SN** + **`DwSecure.registerSafeProgram("Dewod1234")` 注册安全程序**（见第十一章） |
| 8 | 后端 API | **先留空占位**，控制端设备列表用本地 mock 数据走通流程；后端协议由需求方后续补 |
| 9 | 三端包名/Bundle ID | Android 被控端 `cn.xinzx.rustdesk.android`、macOS `cn.xinzx.rustdesk.desktop`、Windows 本轮不改（exe 名/产品名/公司名保持开源默认，见第十二章） |

> **本轮策略**（2026-07-14 确认）：目的是**先把流程走通、验证方案可行性**，所以保活/授权/自启都**先用 Android 系统原生机制**，不依赖定制 SDK；SDK 仅用于获取设备 SN。三端全打通，后端用 mock。后期 SDK 能力按需渐进接入。

### 1.3 设计原则

1. **Rust 核心零改动**：协议、rendezvous、编解码、会话管理全部复用，所有定制在 Flutter + Kotlin 层。
2. **复用优先**：开机自启、前台通知、投屏、输入注入等 RustDesk 已有现成机制，只做"默认开启 + 移除用户交互卡点"的改造，不重新造轮子。
3. **与业务 app 物理隔离**：独立进程、独立包名，避免双看门狗互 kill、避免资源抢占。

---

## 二、现有代码基线（只读引用，不在本阶段改动）

被控端的能力分散在 Kotlin 原生层与 Flutter 层，核心文件如下。

### 2.1 Kotlin 原生层（`flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/`）

| 文件 | 行数 | 职责 | 关键锚点 |
|------|------|------|----------|
| `MainService.kt` | 729 | 被控核心前台服务。`onCreate` 调 `FFI.startServer()`（`:246`）启动 Rust 被控核心；持有 `MediaProjection` + `VirtualDisplay` 做投屏；通过 `@Keep` JNI 方法接收 Rust 回调（`rustPointerInput`/`rustKeyEventInput`/`rustSetByName` 等）；`createForegroundNotification()`（`:330`）挂起前台通知 | `onStartCommand` 返回 `START_NOT_STICKY`（`:349`） |
| `InputService.kt` | 761 | `AccessibilityService`，把远端鼠标/键盘/触摸注入为 Android 手势/按键 | 静态 `isOpen` 反映是否已启用 |
| `BootReceiver.kt` | ~50 | 监听 `BOOT_COMPLETED`/`QUICKBOOT_POWERON`，拉起 `MainService` 前台服务（`:40-44`） | 当前需 `KEY_START_ON_BOOT_OPT=true` 且电池/overlay 权限齐备（`:25-33`） |
| `FloatingWindowService.kt` | — | 1px `TYPE_APPLICATION_OVERLAY` 浮窗，app 退后台时的保活锚点 + 弹出菜单 | 由 `MainActivity.onStop` 触发 |
| `PermissionRequestTransparentActivity.kt` | — | 透明 Activity，调 `MediaProjectionManager.createScreenCaptureIntent()` 弹投屏授权框，授权后拉 `MainService` | 当前唯一授权入口 |
| `AudioRecordHandle.kt` | — | 经 `MediaProjection` 抓系统音频 | 需 SDK≥29 |
| `MainApplication.kt` | — | `Application` 子类，`onCreate` 调 `FFI.onAppStart()` | 默认配置可在此写入 |
| `ffi.kt`（`kotlin/ffi.kt`） | — | JNI 桥，`System.loadLibrary("rustdesk")` + 声明所有 `external` 方法 | Kotlin↔Rust 唯一入口 |

### 2.2 Flutter 层

| 文件 | 职责 | 关键锚点 |
|------|------|----------|
| `flutter/lib/models/server_model.dart` | 被控端状态机：`startService()`（`:450`）拉起 `init_service`（Kotlin）+ `mainStartService`（Rust）；`stopService()`（`:464`） | 自动启动的接入点 |
| `flutter/lib/mobile/pages/home_page.dart` | 移动端底部导航壳。`initPages()`（`:48-60`）依据 `bind.isIncomingOnly()` / `bind.isOutgoingOnly()` 决定显示哪些 tab | 无 UI 改造点 |
| `flutter/lib/main.dart` | App 入口，`runMobileApp()`（`:205-215`）为移动端启动路径 | 无 UI 入口改造点 |

### 2.3 Rust 侧能力标志（FFI）

`is_incoming_only()` / `is_outgoing_only()` / `is_custom_client()` / `is_disable_*()`（`src/flutter_ffi.rs:2467-2520`）—— 这些是**构建期/运行期能力开关**，UI 层据此决定显示哪些页面。被控端构建需让 `isIncomingOnly()` 返回 `true`，从而隐藏所有控制端 UI。

> **注意**：Rust 核心本身没有"控制器/被控端"的角色标志。角色由"调用哪个入口"隐式决定——Android 上被控端走 `MainService.onCreate` → `FFI.startServer`（`flutter_ffi.rs:3078` 的 `Java_ffi_FFI_startServer`），控制端走 `Session::start`。两端逻辑核心都已存在且完整。

---

## 三、开机自启方案

### 3.1 复用现有 BootReceiver 机制

RustDesk 已实现开机自启：`BootReceiver` 监听 `ACTION_BOOT_COMPLETED`（AndroidManifest 已注册，priority=1000），开机时以 `startForegroundService` 拉起 `MainService`（`BootReceiver.kt:40-44`）。**这套机制对定制设备完全可用，保留。**

### 3.2 与业务 app 独立自启不冲突的论证

- Android 允许**任意数量**的 app 各自注册 `BOOT_COMPLETED` 接收器，系统开机后会**逐一分发**广播，接收器之间互不阻塞、互不感知。
- 业务 app 的开机自启条目与 RustDesk 的 `BootReceiver` 是两个独立接收器，各自拉起各自的 Service/Activity，**不存在抢占关系**。
- 同理，业务 app 的看门狗监控的是**它自己关心的进程**，不会去 kill 一个独立包名、独立进程的 RustDesk 服务（除非看门狗逻辑显式遍历进程名单——需与业务 app 团队确认其看门狗不扫描全量第三方进程）。

> **待确认项**：请与业务 app 团队核实其看门狗的扫描范围。若看门狗只守护自身进程，则无冲突；若它"清理后台"式地扫描所有非白名单进程，需把 RustDesk 被控端包名加入其白名单。

### 3.3 两条注册路径择一（不叠加）

| 路径 | 做法 | 适用 |
|------|------|------|
| **A. 系统广播（现有）** | 保留 `BootReceiver` 监听 `BOOT_COMPLETED` | SDK 不提供开机自启 API，或定制系统允许第三方 app 收该广播 |
| **B. SDK 注册** | 用定制系统 SDK 的 API 把被控端注册进系统开机启动清单 | SDK 提供专门的开机自启注册接口 |

> 两条路径**择一即可**，不要同时启用，避免重复拉起。建议优先评估路径 B（SDK 注册通常更可靠，不受 app 待机桶/后台限制影响）；若 SDK 无此能力，退回路径 A。

### 3.4 改动点（仅文字描述，不在本阶段改代码）

1. **默认开机即启**：移除 `BootReceiver` 中对 `KEY_START_ON_BOOT_OPT` 的判断（`BootReceiver.kt:25-28`），被控端构建下默认开机即拉服务；或在 `MainApplication.onCreate` 首次写入该开关为 `true`。
2. **移除运行时权限校验**：移除 `BootReceiver` 对 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` / `SYSTEM_ALERT_WINDOW` 的运行时检查（`:30-33`），这两个权限在定制设备上由 SDK/系统签名预先授予，无需代码再校验。
3. **SDK 接入（若走路径 B）**：在 `MainApplication.onCreate` 或专门初始化入口调用 SDK 的开机自启注册 API，注册被控端 `MainService`。

---

## 四、前台通知保活方案

### 4.1 复用现有前台通知机制

`MainService.onCreate` → `createForegroundNotification()`（`onStartCommand:330` 调用）已挂起前台通知。**前台服务是 Android 官方推荐的保活手段，系统几乎不会主动杀死**。机制可用，保留。

### 4.2 FloatingWindowService 锚点

`FloatingWindowService`（1px `TYPE_APPLICATION_OVERLAY`）作为额外保活锚点，在 app 退后台时由 `MainActivity.onStop` 触发。被控端构建下**默认开启**，并设为**透明不可见**（不干扰业务 app 显示）。配置项 `disable-floating-window`（`config.rs:3028`）默认置 `N`。

### 4.3 START_STICKY 改造（关键改动）

**现状**：`MainService.onStartCommand` 返回 `START_NOT_STICKY`（`:349`）。源码注释说明原因——重启后的新 service 会丢失崩溃前的 `MediaProjection` token，拿不到 token 就无法投屏。

**改造**：改为 `START_REDELIVER_INTENT` 或 `START_STICKY`。

**可行性论证**：原限制的根因是"MediaProjection token 跨进程无法恢复"。在定制设备静默授权方案（见第五章）下，重启后的新 service 能**随时重新静默拿到 token**，不再依赖崩溃前那一份。因此 sticky 重启后能恢复完整投屏能力。

**重启后流程**：
```
系统重启 MainService（START_STICKY）
  → onStartCommand
  → 无 EXT_MEDIA_PROJECTION_RES_INTENT
  → 走静默授权分支重新拿 token
  → startCapture() 恢复投屏
```

> ⚠️ **依赖**：本改动**必须在静默授权落地后**才能验证通过。若静默授权未落地，重启后拿不到 token，sticky 重启也只是个空壳服务。建议第五章方案确定后再改此处。

### 4.4 保活策略对比表

| 场景 | 机制 | 现状 | 被控端改造 |
|------|------|------|-----------|
| 开机后启动 | `BootReceiver` 监听系统广播 | 有，需手动开开关 | 默认开（或走 SDK 注册） |
| 运行中保活 | 前台服务通知 | 有 | 保留 |
| 退后台保活 | 1px 浮窗锚点 | 有，默认关 | 默认开、透明不可见 |
| 崩溃后自恢复 | `START_STICKY` | 返回 `START_NOT_STICKY` | 改为 `START_STICKY`（依赖静默授权） |
| 看门狗 | 无 | — | **不引入**，与业务 app 隔离，避免双看门狗互 kill |

---

## 五、静默授权方案（本轮先用系统机制，不依赖 SDK）

> **本轮策略**：需求方担心 SDK 的开机自启/保活能力与业务 app 打架，因此**本轮只用 Android 系统原生机制**，不接入 SDK 的授权/保活能力。SDK 仅用于获取 SN（见第十一章）。
>
> 授权方面**先按路径 1（系统签名 + 预装）实现**；若真机验证失败（比如无法获得系统签名），再评估路径 2/3。三条路径仍保留在文档里作为备选。

被控端要免授权拿到两类关键能力：
- **MediaProjection**（投屏）：默认需弹 `createScreenCaptureIntent()` 用户授权框。
- **AccessibilityService**（`InputService` 输入注入）：默认需用户在系统设置里手动启用。

### 路径 1：系统签名 + 预装（推荐主线）

- 被控端 APK 以**系统签名**预装到 `/system/priv-app`，自动获得所有系统权限。
- **MediaProjection 免授权框**：`PermissionRequestTransparentActivity` 检测到自身为系统应用（`ApplicationInfo.FLAG_SYSTEM`）时，跳过 `createScreenCaptureIntent()` 的用户授权框，直接构造投影。
- **无障碍自动启用**：系统侧预置 `Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES` 把 `InputService` 加入已启用列表（系统配置层面，非运行时写入，零代码）。
- **优点**：最彻底，所有权限一次到位。
- **代价**：需要定制设备厂商配合预装到系统分区并提供系统签名。

### 路径 2：SDK 运行时静默授予

- SDK 提供 jar/aar，被控端运行时调 SDK API：
  - 静默授予 MediaProjection（SDK 内部用系统权限拿到 token，回传给 `MainService`）。
  - 写入 `Settings.Secure` 启用无障碍（SDK 持有 `WRITE_SECURE_SETTINGS`）。
  - 静默申请 overlay / battery 权限。
- APK **普通签名即可**，但依赖 SDK 能力到位。
- **代码影响**：需新增 `SilentPermissionHelper.kt` 封装 SDK 调用，在 `MainService.onCreate` / `BootReceiver` 中调用。

### 路径 3：定制系统预置权限白名单

- 定制系统侧在配置文件里把被控端包名加入权限白名单。
- 被控端运行时**正常申请**，系统自动静默通过。
- **代码影响最小**：被控端代码几乎不改，现有申请逻辑照常，系统侧自动放行。

### 三条路径代码影响差异

| 维度 | 路径 1（系统签名） | 路径 2（SDK 授予） | 路径 3（系统白名单） |
|------|------------------|-------------------|--------------------|
| MediaProjection 免框 | 改 `PermissionRequestTransparentActivity` 加系统应用分支 | 新增 `SilentPermissionHelper` 调 SDK | 代码不改，系统放行 |
| 无障碍启用 | 系统配置预置（零代码） | SDK 写 `Settings.Secure` | 系统配置预置（零代码） |
| overlay/battery | 系统签名自带 | SDK 静默授予 | 白名单自动通过 |
| APK 签名要求 | 系统签名 | 普通签名 | 普通/系统签名均可 |
| 代码工作量 | 小 | 中 | 极小 |

### AndroidManifest 需新增的系统级权限清单

（三条路径中至少一条需要，按最终选定路径取舍）

```xml
<!-- 静默写系统设置（启用无障碍等） -->
<uses-permission android:name="android.permission.WRITE_SECURE_SETTINGS" />
<!-- 静默 MediaProjection（系统签名路径） -->
<uses-permission android:name="android.permission.CAPTURE_VIDEO_OUTPUT" />
<!-- 或 -->
<uses-permission android:name="android.permission.MANAGE_MEDIA_PROJECTION" />
```

> 这些是系统级权限，普通签名装不上。定制设备预装/SDK 授予/系统白名单任一路径生效即可。

---

## 六、无 UI 纯服务形态

### 6.1 入口改造思路

**`flutter/lib/main.dart`**：在 `runMobileApp()`（`:205-215`）路径中，当 `bind.isIncomingOnly() && isAndroid` 时：
- **不启动 `HomePage`**（底部导航），改为启动一个**空壳 `MaterialApp`**（透明/纯色背景，无可见业务 UI）。
- 在其 `initState` 中**自动调用 `ServerModel.startService()`**（`server_model.dart:450`），无需任何用户交互。

**`flutter/lib/mobile/pages/home_page.dart`**：`initPages()`（`:48-60`）在 `isIncomingOnly()` 下返回空列表（或仅一个占位页），因为服务已自动启动，不需要任何 tab。

### 6.2 MainActivity 退后台

被控端 `MainActivity` 启动后立即 `moveTaskToBack(true)` 把自己退到后台，前台只留 `MainService` 的常驻通知。设备屏幕始终显示业务 app。

> 需确认：定制系统的保活策略下，`moveTaskToBack` 后的 Activity 进程是否会被系统回收。若会，靠 `START_STICKY` 重启服务兜底。

### 6.3 构建配置

**`flutter/android/app/build.gradle`**：
- `applicationId` 从 `com.carriez.flutter_hbb` 改为 **`cn.xinzx.rustdesk.android`**（已定，见第十二章）。
- 新增 product flavor `hostOnly`，通过 manifest placeholder 或编译期参数让 `isIncomingOnly()` 返回 `true`。
- `minSdkVersion` 保持 22，`targetSdkVersion` 33（与现有一致）。

### 6.4 验收标准

定制设备开机后：
- 屏幕上看不到任何 RustDesk 界面（只有一条可设为低优先级/最小化的常驻通知）。
- 设备屏幕始终显示业务 app，不受 RustDesk 干扰。
- 控制端能直接连上看到投屏并能操控。

---

## 七、预设固定密码与无人值守

> 详细机制见 [`CUSTOM_DEPLOYMENT_DESIGN.md`](./CUSTOM_DEPLOYMENT_DESIGN.md) 改动点 3，本节只做被控端视角补充。

### 7.1 机制（运维配置，被控端零代码）

`custom.txt` 的 `override-settings` 预置：
- `approve-mode=password`（密码对即放行，**不弹同意框**，无人值守）。
- `password` + `salt`（预设密码的 h1 格式，解析逻辑在 `libs/hbb_common/src/config.rs:1415` 的 `get_preset_password_storage_and_salt()`）。

当本地 `Config.password` 为空时回退到预置密码（`config.rs:1394-1408`）。预置密码格式 = `"00" + base64(SHA256(password + salt))`。

### 7.2 控制端配套

控制端设备列表的每条设备自带 `password` 字段，调用 `connect(context, id, password: device.password)`（`common.dart:2580`）直连，无需用户输入密码。

### 7.3 安全建议

- 统一密码泄露 = 全设备沦陷。建议配 `whitelist`（`config.rs:2920`）只允许控制端出口 IP 发起连接。
- 跨公网场景建议 hbbs/hbbr 启用 TLS，`custom.txt` 配 `key`。

---

## 八、改动文件清单（供后续开发参考）

> 本文档阶段不执行任何改动。本表仅供后续开发按图施工。

| 层 | 文件 | 改/新增 | 一句话描述 |
|----|------|---------|-----------|
| SDK | `flutter/android/app/libs/dewodSDK_1.0.03_release.aar` | 新增 | 定制系统 SDK，本轮仅用于获取 SN |
| Gradle | `flutter/android/app/build.gradle` | 改 | `applicationId`→`cn.xinzx.rustdesk.android`；新增 aar 依赖；可选 `hostOnly` flavor |
| Kotlin | `SnHelper.kt` | 新增 | 封装 `DwFirmwareInfo.getCpuSerial()`，try-catch 兜底，暴露给 Flutter |
| Kotlin | `MainService.kt` | 改 | `onStartCommand` 返回值改 `START_STICKY`（`:349`）；投屏授权失败时走静默分支 |
| Kotlin | `BootReceiver.kt` | 改 | 默认开机即启；移除运行时权限校验（`:25-33`） |
| Kotlin | `PermissionRequestTransparentActivity.kt` | 改 | 路径 1：系统应用分支跳过授权框 |
| Kotlin | `MainApplication.kt` | 改 | `onCreate` 写入默认配置（开机自启开关等）；**SDK 初始化：`DwSecure.registerSafeProgram("Dewod1234")`**（见 11.4） |
| Kotlin | `MainActivity.kt` | 改 | 启动后 `moveTaskToBack` |
| Manifest | `AndroidManifest.xml` | 改 | 新增系统级权限；applicationId 调整 |
| Dart | `flutter/lib/main.dart` | 改 | `isIncomingOnly()` 下启动空壳 + 自动 `startService()` |
| Dart | `flutter/lib/mobile/pages/home_page.dart` | 改 | `isIncomingOnly()` 下 `initPages()` 返回空 |
| Dart | `flutter/lib/models/device_register.dart` | 新增 | {sn, id} 上报（本轮后端留空，打日志） |
| Dart | `flutter/lib/models/server_model.dart` | 改 | `startService()` 成功后触发上报 |
| macOS | `flutter/macos/Runner.xcodeproj/project.pbxproj` | 改 | 3 处 `PRODUCT_BUNDLE_IDENTIFIER`→`cn.xinzx.rustdesk.desktop` |
| Windows | `flutter/windows/runner/Runner.rc` | **不改** | 本轮保持开源默认（exe 名/产品名/公司名） |
| Dart | `flutter/lib/desktop/pages/device_list_page.dart` | 改 | 设备列表改 mock 数据驱动 |
| Dart | `flutter/lib/desktop/pages/desktop_tab_page.dart` | 改 | 控制端 UI 精简（设备列表为主入口） |
| Rust | `libs/hbb_common/src/config.rs` | 零改 | 本轮不改核心 |
| 构建脚本 | `flutter/build_android.sh` 等 | 改/新增 | 被控端 / 控制端构建脚本 |

---

## 九、待提供输入清单

> 本轮（2026-07-14）已确认一批输入，下表标注各输入当前状态。

| # | 输入项 | 状态 | 说明 |
|---|--------|------|------|
| 1 | 定制系统 SDK | ✅ 已提供（仅用 SN） | `dewodSDK_1.0.03_release.aar`，本轮**只用于获取 SN**（`getCpuSerial()`）；开机自启/保活/授权**暂不依赖 SDK** |
| 2 | 后端 API 协议 | ⏳ 待补 | 设备列表接口的 URL、鉴权、返回结构；本轮控制端先用本地 mock 走通流程 |
| 3 | 设备 SN 获取方式 | ✅ 已定 | SDK `DwFirmwareInfo.getInstance(ctx).getCpuSerial()`（见第十一章） |
| 4 | 被控端包名 | ✅ 已定 | `cn.xinzx.rustdesk.android` |
| 5 | 预设密码策略 | ✅ 已定 | 先固定一个统一密码，后期有风险再调整 |
| 6 | 业务 app 看门狗扫描范围 | ⏳ 待确认 | 确认不 kill 独立包名进程；本轮先用 Android 原生机制验证，若冲突再回退 |
| 7 | macOS Bundle ID | ✅ 已定 | `cn.xinzx.rustdesk.desktop`（见第十二章） |
| 8 | Windows 标识 | ✅ 已定 | 本轮不改（exe 名/产品名/公司名保持开源默认，见第十二章） |

---

## 十、实施顺序建议（本轮：三端全打通）

> 本轮目标：**先把流程走通、验证方案可行性**。保活/授权/自启都用 Android 原生机制，后端用 mock。以下顺序为本轮开发计划。

| 步骤 | 内容 | 平台 | 依赖 |
|------|------|------|------|
| 1 | SDK 接入：复制 aar + 配置 gradle + SN 获取工具（第十一章） | Android | 无 |
| 2 | 三端包名/Bundle ID 改造（第十二章） | 全平台 | 无 |
| 3 | 被控端无 UI 入口：`isIncomingOnly()` 下启动空壳 + 自动 `startService()`（第六章） | Android | 步骤 2 |
| 4 | 开机自启默认开 + 移除运行时权限校验（第三章 3.4）+ START_STICKY（第四章 4.3）+ 前台通知保活（第四章 4.1/4.2） | Android | 步骤 3 |
| 5 | 预设固定密码 `custom.txt` 配置（第七章）+ SN 上报占位（打日志，后端留空） | Android | 步骤 1 |
| 6 | 控制端设备列表 mock 数据 + UI 精简（隐藏 ID 输入板，设备列表为主入口）+ 会话连接 | Win/Mac | 步骤 2 |
| 7 | 三端构建脚本 + 端到端验证 | 全平台 | 步骤 1-6 |

> **本轮不做的**：静默授权（第五章，先靠系统签名预装，真机验证）、后端 API 真实接入（留 mock）、SDK 的开机自启/保活能力（怕与业务 app 冲突）。这些留到验证通过后的下一轮。

**端到端验证标准**（步骤 7）：
- 定制设备开机后，被控服务自动运行（无 UI，只有常驻通知）。
- Win/Mac 控制端启动后显示 mock 设备列表，点"控制"用预设密码直连被控端，能看到投屏并能操控。
- 三端包名/Bundle ID 均为 `cn.xinzx.*`，与开源 RustDesk 区分。

---

## 十一、定制系统 SDK 接入（SN 获取 + 安全程序注册）

### 11.1 SDK 概况

- **文件**：`dewodSDK_1.0.03_release.aar`（34KB），由需求方提供。
- **原路径**：`/Users/dong/work/project/YbtProject/xxt_read_bookcase/LocalRepo/aarlib/`。
- **包名**：`com.dewod.sdk.*` / `com.dewod.android.*`。
- **Manifest**：仅声明 `minSdkVersion 19 / targetSdkVersion 31`，**无额外权限、无 Application 初始化、无 proguard 规则**，接入干净。
- **本轮用两件事**：
  1. `DwFirmwareInfo.getInstance(ctx).getCpuSerial()` 获取设备 SN（CPU 序列号）。
  2. `DwSecure.getInstance(ctx).registerSafeProgram("Dewod1234")` 把被控端注册为定制系统"安全程序"（见 11.4），获得系统层面的清理豁免。
- **SDK 其他能力**（`DwPower`/`DwWatchDog`/`DwBootAnimation` 等）**本轮不接入**，避免与业务 app 的拉起/保活冲突。

### 11.2 SN 获取 API

```kotlin
// 反编译确认的方法签名（com.dewod.sdk.DwFirmwareInfo）
public static DwFirmwareInfo getInstance(android.content.Context);
public java.lang.String getCpuSerial();        // ← 本轮用这个
public java.lang.String getFactoryInfo();      // 备选：出厂信息（可能含 SN）
public java.lang.String getProductInfo();      // 备选：产品信息
public java.lang.String getSpecialInfo();      // 备选：特殊信息
```

**调用示例（示意，非最终代码）**：
```kotlin
val sn = try {
    DwFirmwareInfo.getInstance(context).getCpuSerial()
} catch (e: Throwable) {
    null  // SDK 仅在定制系统可用，普通设备会抛异常
}
```

> ⚠️ SDK 走定制系统的隐藏服务（`DwFirmwareInfoManager`），**普通 Android 设备或模拟器上调不通**，会抛异常。开发调试时需在定制设备真机上验证，或加 try-catch 兜底返回空串，避免崩溃。

### 11.3 接入步骤（编码阶段执行）

1. **复制 aar**：`dewodSDK_1.0.03_release.aar` → `flutter/android/app/libs/`（目录不存在则新建）。
2. **配置 `flutter/android/app/build.gradle`**：
   - `dependencies` 块新增 `implementation(files("libs/dewodSDK_1.0.03_release.aar"))`（或 `fileTree` 方式）。
3. **新增 SN 获取工具** `SnHelper.kt`（放 `flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/`，包名随主包名调整）：
   - 封装 `getCpuSerial()`，带 try-catch 兜底。
   - **调用前提**：`MainApplication` 已先执行 `registerSafeProgram`（见 11.4），否则系统服务会拒绝。
   - 通过 `MethodChannel("mChannel")` 暴露 `get_sn` 方法给 Flutter，或直接在 Kotlin 侧注册上报时调用。
4. **Flutter 侧**：注册上报模块（`device_register.dart`）通过 MethodChannel 取 SN，拼 `{sn, rustdesk_id}` 上报。本轮后端留空，**只打日志**。

### 11.4 SDK 初始化（安全程序注册）

> **必须做**：定制系统侧要求调用方先注册为"安全程序"，否则 SN 等系统服务调用可能被拒，且 app 会被系统当作普通第三方进程清理。这一步是定制系统能力的"准入认证"。

**调用**（反编译确认签名：`DwSecure.registerSafeProgram(String): Boolean`，内部走 `Context.getSystemService("dewod_secure_manager")`）：

```kotlin
// 放在 MainApplication.onCreate() 的 SDK 初始化处
try {
    com.dewod.sdk.DwSecure.getInstance(context).registerSafeProgram("Dewod1234")
} catch (e: Throwable) {
    // SDK 仅定制系统可用，普通设备/模拟器会抛异常，忽略即可
    android.util.Log.w("RustDesk", "registerSafeProgram failed: ${e.message}")
}
```

**说明**：
- `"Dewod1234"` 为需求方提供的固定安全口令（统一密钥），所有被控端实例用同一个。
- 返回值 `true` 表示注册成功；建议记录日志便于排查。
- **放在哪**：`MainApplication.onCreate()` 的 SDK 初始化区域（与 `FFI.onAppStart()` 同级），保证 app 一启动就注册。`MainService`/`BootReceiver` 在服务进程里再次 `getInstance` 时复用同一单例，无需重复注册。
- **为什么不和业务 app 冲突**：`registerSafeProgram` 注册的是**自己这个包名**为安全程序，与业务 app 各自注册各自的包名，互不影响。业务 app 的"安全程序"身份不因 RustDesk 注册而改变。
- `registerSafeProgram` 的逆操作是 `unregisterSafeProgram()`，被控端常驻不需要调用。
- 配套方法 `checkSafeProgramOfSelf(): Boolean` 可用于自检当前包名是否已注册为安全程序。

> ⚠️ **顺序**：务必在调用任何其他 SDK 能力（如 `getCpuSerial()`）**之前**完成 `registerSafeProgram`，否则系统服务可能因调用方未认证而拒绝。

### 11.5 SN 与 RustDesk ID 的关系

- **SN**：设备硬件序列号（`getCpuSerial()`），稳定不变，作为业务后台的主键。
- **RustDesk ID**：RustDesk 自己生成的连接 ID（`config.rs:gen_id()`，Android 上是 `1_000_000_000..2_000_000_000` 随机数），存本地配置。
- **上报**：`{sn, rustdesk_id}` 一起上报后台，后台以 sn 建索引，控制端用 rustdesk_id 发起连接。
- **本轮**：不强行让 RustDesk ID 等于 SN（那需改 `gen_id()` 核心逻辑）。两者独立，靠上报关联。

---

## 十二、三端包名 / Bundle ID（与开源 RustDesk 区分）

### 12.1 命名方案（已确认）

| 平台 | 旧标识 | 新标识 | 改动位置 |
|------|--------|--------|----------|
| **Android 被控端** | `com.carriez.flutter_hbb` | **`cn.xinzx.rustdesk.android`** | `flutter/android/app/build.gradle:100` 的 `applicationId`；Kotlin 包目录随之调整 |
| **macOS** | `com.carriez.rustdesk` | **`cn.xinzx.rustdesk.desktop`** | `flutter/macos/Runner.xcodeproj/project.pbxproj`（3 处 `PRODUCT_BUNDLE_IDENTIFIER`，行 448/593/630） |
| **Windows** | exe `rustdesk.exe` / 产品名 `RustDesk` / 公司 `Purslane Tech Pte. Ltd.` | **本轮不改** | `flutter/windows/runner/Runner.rc`（行 92-99） |

### 12.2 关于 Windows 端本轮不动

Windows 没有类似 Android `applicationId` 或 macOS `PRODUCT_BUNDLE_IDENTIFIER` 的包名概念，其唯一标识位在 `Runner.rc` 的版本信息块：exe 名（`rustdesk.exe`）、产品名（`RustDesk`）、公司名（`Purslane Tech`）。

需求方确认本轮**"只改标识不动产品名"**。对 Windows 而言：
- Bundle ID/包名概念不适用 → 无对应字段可改。
- exe 名/产品名/公司名按需求保持开源默认 → `Runner.rc` 不动。

因此 **Windows 端本轮实际零改动**。若后续需要彻底去开源化（exe 改名、产品名改品牌），再单独处理 `Runner.rc` + CMake 中的 outputName。

### 12.3 Android 包名改动的连带影响

改 `applicationId` 不只是改一行 gradle，注意连带：
- **Kotlin 源码包目录**：当前 `kotlin/com/carriez/flutter_hbb/`，包名改后建议同步调整目录与 `package` 声明（或保持目录不变只改 applicationId，Android 允许两者不一致，但为整洁建议一致）。本轮为减小风险，**可先只改 `applicationId`，Kotlin package 声明保持 `com.carriez.flutter_hbb`**（applicationId 与 package 解耦，不影响运行）。
- **AndroidManifest.xml**：`package` 属性（如有）需与 applicationId 一致；`MainActivity`/`MainService` 等组件的 `android:name` 若用全限定名需同步。
- **proguard / 签名**：包名变化不影响签名 keystore，但 release 构建产物的包名会变。
- **MethodChannel / Flutter 调用**：`MainActivity.kt` 的 MethodChannel 名 `"mChannel"` 不依赖包名，无需改。

### 12.4 macOS Bundle ID 改动的连带影响

- **3 处 `PRODUCT_BUNDLE_IDENTIFIER`** 都要改（Debug/Release/Profile 配置各一处）。
- **`Runner.xcodeproj/project.pbxproj`** 里可能还有 `PRODUCT_NAME` 等，本轮不动。
- 首次改 Bundle ID 后，已安装的旧版本会被系统视为不同 app，需卸载旧版重装。

---

## 附：与现有文档的关系

- **本文档（CUSTOM_HOST_DESIGN.md）**：被控端设计（无 UI、自启、保活、静默授权、预设密码、SDK 接入、三端包名）。
- **[CUSTOM_DEPLOYMENT_DESIGN.md](./CUSTOM_DEPLOYMENT_DESIGN.md)**：整体部署架构、主控端选型、注册上报、统一密码、自建 hbbs/hbbr、deeplink、安全加固、工作量估算。
- 两文档互补，无重叠。被控端的"预设密码"在两文档都有提及：v1 文档讲机制（h1 格式、`custom.txt`），本文档讲被控端视角（默认 `approve-mode=password`、控制端带密码直连）。

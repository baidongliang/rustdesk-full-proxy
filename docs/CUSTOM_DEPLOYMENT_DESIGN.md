# 定制化批量部署方案设计文档

> 场景:100 台 Android 定制设备(跨公网分布),通过业务后台集中远程管控。
>
> 基础思路:**RustDesk ID 与业务设备标识解耦** —— ID 随机生成(传输门牌号),
> 硬件序列号作为业务唯一标识,App 启动后主动把 `{序列号, RustDesk ID}` 上报给业务后台,
> 后台维护映射表 + 自建心跳,管理员在主控端点「连接」即可远程控制指定设备。
>
> **主控端选型结论(关键)**:复用本仓库的 Flutter 桌面端,业务定制(设备列表/登录/鉴权)
> 全部在 Flutter 业务层实现,连接核心一行代码 `connect(context, id)` 调用现成逻辑。
> 不另开 Rust 程序复用核心(详见附录 A 的选型分析)。

---

## 一、背景与目标

### 1.1 需求

- 100 台 Android 定制硬件设备,每台有**厂商分配的唯一序列号**(字母+数字,如 `A001`)。
- 设备统一安装同一个 APK,**不希望逐台配置**(不打 100 个包、不写 100 份配置)。
- 业务后台(Web)能列出所有设备,管理员点「连接」即可远程控制指定设备。
- 被控端无需人工点「同意」(无人值守)。

### 1.2 设计原则

1. **ID 解耦**:RustDesk ID 只是传输层标识,保持随机生成;业务用硬件序列号识别设备。
2. **统一 APK**:100 台设备装同一个包,通过运行时上报 + 后台映射实现差异化。
3. **复用现有能力**:服务器锁定、无人值守、统一密码等用 RustDesk 原生机制,不重复造轮子。
4. **最小改动**:只新增「设备注册上报」这一模块,其余用配置和运维手段完成。

---

## 二、整体架构

### 2.1 数据流

```
┌────────────────────────────────────────────────────────────┐
│ 100 台 Android 设备(装同一个 APK)                          │
│                                                            │
│  首次启动 / 服务启动成功后:                                  │
│    1. 生成随机 RustDesk ID(原生机制,持久化)                │
│    2. 读取硬件序列号(method channel 调 Native)              │
│    3. POST {sn, rustdesk_id} → 业务后台                     │
└────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌────────────────────────────────────────────────────────────┐
│ 业务后台(自建 Web 服务 + 数据库)                           │
│                                                            │
│  devices 表:                                              │
│   sn(PK) | rustdesk_id | last_seen | online | name         │
│                                                            │
│  POST /api/devices/register  ← App 上报                    │
│  GET  /api/devices           → 后台页面展示                 │
└────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌────────────────────────────────────────────────────────────┐
│ 管理员操作                                                  │
│                                                            │
│  后台设备列表 → 点设备 A001 的「远程连接」                   │
│    → 浏览器跳转 rustdesk://connect?id=<映射出的ID>           │
│    → 拉起 PC / 手机上的 RustDesk 主控端,自动填 ID 连接       │
└────────────────────────────────────────────────────────────┘
```

### 2.2 网络拓扑

```
[主控端 App]                              [被控端 App × 100]
     │                                          │
     │   ① 注册 ID                              │  ① 向 hbbs 注册 ID
     ├──> [hbbs  ID 服务器]  <───────────────────┤  ② 心跳保活
     │   ② 协商 P2P / 中继                       │
     ▼                                          │
[hbbr 中继服务器]  <────────────────────────────┘  ③ P2P 不通时走中继
```

自建服务器组件:

| 组件 | 默认端口 | 作用 |
|------|---------|------|
| hbbs | 21115 / 21116 / 21116(UDP) | ID 分配 + P2P 打洞协商 |
| hbbr | 21117 | 中继转发(P2P 不通时) |
| api-server | 21114 | Web API(可选,用于后台查在线状态) |

> 关键事实:RustDesk 代码里**没有** `custom-id-server`,ID Server 与 Rendezvous Server 是同一个(hbbs),用的配置项是 `custom-rendezvous-server`(`libs/hbb_common/src/config.rs:2935`)。

---

## 三、改动清单

### 改动点 1:锁定服务器配置(运维为主,改 1 行代码)

**目标**:100 台设备连到自建服务器,终端用户改不了。

**机制**:RustDesk 的 `custom.txt` 预置文件,支持 `default-settings`(可改)与 `override-settings`(强制锁定,UI 自动禁用)两档。读取合并顺序见 `libs/hbb_common/src/config.rs:1223`: `DEFAULT → 用户配置 → OVERWRITE`。

**`custom.txt` 示例内容**:
```json
{
  "app-name": "YourCompanyDesk",
  "override-settings": {
    "custom-rendezvous-server": "hbbs.yourcompany.com",
    "relay-server": "hbbr.yourcompany.com",
    "api-server": "https://api.yourcompany.com",
    "key": "<你的服务器公钥 base64>",
    "approve-mode": "password",
    "verification-method": "use-permanent-password",
    "hide-server-settings": "Y",
    "hide-network-settings": "Y",
    "is-disable-change-permanent-password": "Y"
  },
  "default-settings": {
    "enable-keyboard": "Y",
    "enable-clipboard": "Y",
    "enable-file-transfer": "Y",
    "enable-audio": "Y"
  }
}
```

**签名**:`custom.txt` 经 base64 + 签名验证后加载,入口 `src/common.rs:2181` 的 `read_custom_client()`。验证公钥硬编码在 `src/common.rs:2186`(`5Qbwsde3unUc...`),内网自用必须改成自己的公钥:

```rust
// src/common.rs:2186 附近
// 把官方公钥换成你自己 keypair 的公钥
const PUB_KEY: &str = "<你的 base64 公钥>";
```

然后用你自己的私钥签名 `custom.txt`,随 APK 预置。Android 下通过 JNI `Java_ffi_FFI_startServer`(`src/flutter_ffi.rs:3078-3097`)传入 `custom_client_config` 生效。

---

### 改动点 2:设备注册上报模块(核心新增代码)

这是整个方案唯一实质性的代码新增。

#### 2.1 Native 层:读取硬件序列号

**文件**:`flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainActivity.kt`

新增 method channel handler,返回定制硬件的唯一序列号。序列号来源取决于定制硬件,三种常见方案:

```kotlin
// MainActivity.kt 内新增

private fun getDeviceSn(): String {
    // 方案 a:Android 系统序列号(Android 8+ 需 READ_PHONE_STATE 权限)
    // return try { android.os.Build.getSerial() } catch (e: Exception) { "" }

    // 方案 b:ANDROID_ID(零权限,App 签名不变则稳定)
    val androidId = android.provider.Settings.Secure.getString(
        contentResolver,
        android.provider.Settings.Secure.ANDROID_ID
    )
    // return androidId ?: ""

    // 方案 c:定制硬件 SDK(根据厂商文档)
    // return YourHardwareSdk.getSerialNo()

    return androidId ?: ""  // 按你的硬件实际情况选择
}
```

在已有的 `MethodChannel` 注册处加 handler(参考文件中已有的 method 调用模式):
```kotlin
"get_device_sn" -> result.success(getDeviceSn())
```

#### 2.2 Flutter 层:新增注册上报服务

**新建文件**:`flutter/lib/models/device_register.dart`

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_hbb/main.dart';
import '../common.dart';

/// 设备注册上报:把 {硬件序列号, RustDesk ID} 上报给业务后台。
///
/// 设计要点:
/// - App 启动 / 服务启动成功后调用。
/// - fire-and-forget,失败不阻塞主流程。
/// - 失败时存本地,下次启动补报(幂等上报,后台 upsert)。
class DeviceRegister {
  static const _backendUrl = 'https://your-backend.com/api/devices/register';
  static const _platform = MethodChannel('rustdesk_custom');

  /// 在 ServerModel.startService() 成功、ID 生成后调用。
  static Future<void> report() async {
    try {
      final sn = await _getDeviceSn();
      if (sn.isEmpty) {
        debugPrint('[DeviceRegister] device sn empty, skip');
        return;
      }
      final rustdeskId = await bind.mainGetMyId();
      if (rustdeskId.isEmpty) {
        debugPrint('[DeviceRegister] rustdesk id empty, skip');
        return;
      }
      final resp = await http.post(
        Uri.parse(_backendUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'sn': sn,
          'rustdesk_id': rustdeskId,
          'app_version': await _getAppVersion(),
          'timestamp': DateTime.now().toIso8601String(),
        }),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        debugPrint('[DeviceRegister] report ok: $sn -> $rustdeskId');
      } else {
        debugPrint('[DeviceRegister] report failed: ${resp.statusCode}');
        // TODO: 存本地,下次补报
      }
    } catch (e) {
      debugPrint('[DeviceRegister] report error: $e');
      // TODO: 存本地,下次补报
    }
  }

  static Future<String> _getDeviceSn() async {
    try {
      final sn = await _platform.invokeMethod('get_device_sn');
      return sn?.toString() ?? '';
    } on PlatformException catch (e) {
      debugPrint('[DeviceRegister] get sn failed: ${e.message}');
      return '';
    }
  }

  static Future<String> _getAppVersion() async {
    // 按项目现有获取版本号的方式实现,占位
    return '';
  }
}
```

#### 2.3 在服务启动成功处接入

**文件**:`flutter/lib/models/server_model.dart`,方法 `startService()`(当前位于第 449 行)

在 `startService()` 内、`bind.mainStartService()` 之后调用:

```dart
Future<void> startService() async {
  _isStart = true;
  notifyListeners();
  parent.target?.ffiModel.updateEventListener(parent.target!.sessionId, "");
  await parent.target?.invokeMethod("init_service");
  // ugly is here, because for desktop, this is useless
  await bind.mainStartService();
  updateClientState();
  if (isAndroid) {
    androidUpdatekeepScreenOn();
  }
  // === 新增:上报设备注册信息(ID 已在 mainStartService 后生成)===
  if (isAndroid) {
    DeviceRegister.report();  // fire-and-forget
  }
}
```

> 也可在 `fetchID()`(`server_model.dart:474`)ID 变化时上报,作为兜底。

---

### 改动点 3:统一永久密码(运维,零业务代码)

**目标**:100 台设备用同一个永久密码,实现无人值守(`approve-mode = password`,密码对即放行,无需人工点同意)。

**方式 A —— 预置到 `custom.txt`(推荐,开机即生效)**

`custom.txt` 的 `override-settings` 增加:
```json
"password": "<预置密码的 h1 格式>",
"salt": "<base64 盐>"
```
预置密码格式 = `"00" + base64(SHA256(password + salt))`,解析逻辑在 `libs/hbb_common/src/config.rs:1415` 的 `get_preset_password_storage_and_salt()`。当本地 `Config.password` 为空时回退到预置密码(`config.rs:1394-1408`)。

**方式 B —— App 首次启动后由后台动态下发**

后台通过私有指令通道下发密码明文,App 调 `bind.mainSetOption` 写入。这种方式不依赖 `custom.txt` 的签名算 h1,但需要先建好指令通道(见改动点 5)。

---

### 改动点 4:主控端 deeplink 拉起(中改动)

**目标**:后台页面点「连接」按钮 → 拉起控制端 App,自动填 ID 并连接。

#### 4.1 Android 主控端注册 scheme

**文件**:`flutter/android/app/src/main/AndroidManifest.xml`

给 `MainActivity` 增加 intent-filter:
```xml
<activity android:name=".MainActivity" ...>
  <!-- 现有配置 -->
  <intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="rustdesk" android:host="connect" />
  </intent-filter>
</activity>
```

#### 4.2 Flutter 解析 deeplink

**文件**:`flutter/lib/main.dart`(或新建 `flutter/lib/deeplink_handler.dart`)

```dart
// 解析 rustdesk://connect?id=xxx&password=yyy
// 把 id 填入连接输入框并触发 connect,复用现有连接逻辑:
//   flutter/lib/common/widgets/login.dart:562 附近的 mainGetMyId / connect 逻辑
```

#### 4.3 后台「连接」按钮

业务后台前端:
```html
<a href="rustdesk://connect?id={{rustdesk_id}}&password={{统一密码}}">
  远程连接
</a>
```

---

### 改动点 5:(可选)后台→设备的指令通道

如果后续需要后台主动下发指令(改配置、推文件、改密码、强制断开),需要新增一个轮询/WebSocket 通道。**当前方案不依赖它**,可以后续演进。

设计草图:
- 被控端新增 `flutter/lib/models/cmd_channel.dart`,定期 GET 业务后台指令队列。
- 收到指令后在本地执行,复用 RustDesk 现有 API:
  - 改配置:`bind.mainSetOption(key: ..., value: ...)`
  - 改密码:`bind.mainSetOption(key: 'permanent-password', ...)` 或走 IPC
  - 推文件:下载到本地路径
- 安全:指令必须签名,或用设备证书 mTLS。

---

## 四、改动汇总表

| # | 改动点 | 文件 | 性质 | 工作量 |
|---|--------|------|------|--------|
| 1 | 锁定服务器配置 | `custom.txt`(新生成)+ `src/common.rs:2186` 改公钥 | 运维 + 1 行 | 小 |
| 2 | **设备注册上报**(核心) | 新建 `device_register.dart` + 改 `MainActivity.kt` + `server_model.dart:449` | **新代码** | **中** |
| 3 | 统一永久密码 | `custom.txt` 预置 | 运维 | 小 |
| 4 | deeplink 拉起 | `AndroidManifest.xml` + `main.dart` | 新代码 | 小 |
| 5 | (可选)指令通道 | 新建 `cmd_channel.dart` | 新代码 | 中 |

---

## 五、需要自建的服务器组件

| 组件 | 来源 | 用途 |
|------|------|------|
| hbbs + hbbr | `rustdesk-server` 官方开源(Docker 一键) | ID 分配 + 中继 |
| 业务后台 | 自研 | 设备注册接口 + 设备列表页 + deeplink 按钮 |
| (可选)api-server | `rustdesk-api-server` 社区项目 | 后台查设备在线状态 |

---

## 六、安全风险与对策

| 风险 | 说明 | 对策 |
|------|------|------|
| 上报通道被伪造 | 任何人都能 POST 假 SN 注册 | 上报请求带硬件签名 / 设备证书 mTLS;后台校验 SN 白名单 |
| 统一密码泄露 | 泄露 = 100 台全沦陷 | 配 `whitelist`(`config.rs:2920`)只允许后台服务器 IP 发起连接;或改用 per-device 密码 |
| `custom.txt` 篡改 | 终端用户改配置连到别的服务器 | 用 `override-settings` 锁定 + 改公钥自签名 |
| ID 变化 | App 重装 / 清数据后 ID 变 | App 上报时后台做 upsert,以 SN 为主键,RustDesk ID 只是最新值 |

---

## 七、关键代码索引(供实现时参考)

| 关注点 | 位置 |
|--------|------|
| RustDesk ID 生成(Android 分支) | `libs/hbb_common/src/config.rs:1023-1026` |
| `mainGetMyId()`(Flutter 取 ID API) | `flutter/lib/generated_bridge.dart:4673` |
| 服务启动入口 | `flutter/lib/models/server_model.dart:449`(`startService`) |
| ID 变化回调 | `flutter/lib/models/server_model.dart:474`(`fetchID`) |
| 自定义服务器配置项 | `libs/hbb_common/src/config.rs:2935-2937` |
| `custom.txt` 加载与签名验证 | `src/common.rs:2181-2252` |
| 配置合并优先级 | `libs/hbb_common/src/config.rs:1223-1228` |
| 可锁定 UI 开关(`hide-*`) | `libs/hbb_common/src/config.rs:2983-2984` |
| 预置密码(h1 格式) | `libs/hbb_common/src/config.rs:1415` |
| 无人值守(`approve-mode`) | `libs/hbb_common/src/config.rs:2932` |
| 权限开关(`enable-*`) | `libs/hbb_common/src/config.rs:2899-2910` |
| Android JNI 启动入口 | `src/flutter_ffi.rs:3078-3097` |

---

## 八、实施顺序建议

1. **先跑通自建服务器**:Docker 起 hbbs/hbbr,改 `custom.txt` + 公钥,装到一台测试设备,确认能连到自建服务器。
2. **做改动点 2(注册上报)**:写 `device_register.dart` + Native handler,跑通「设备 → 后台」的注册上报。
3. **做改动点 3(统一密码)**:预置密码,确认能无人值守连接。
4. **做改动点 4(deeplink)**:主控端支持 `rustdesk://connect`,后台点按钮拉起。
5. **按需做改动点 5(指令通道)**:后续演进。

---

## 九、关于悬浮窗开关(本仓库已有能力)

需求「最小化后显示悬浮窗」的开关**已存在**,无需二次开发:

- 配置项:`disable-floating-window`(`libs/hbb_common/src/config.rs:3028`)
- UI:移动端 Settings → Enhancements → "Floating window"(`flutter/lib/mobile/pages/settings_page.dart:645-654`)
- 触发:`MainActivity.kt:403-409`,`onStop()`(最小化)时若未禁用则启动 `FloatingWindowService`
- 可通过 `custom.txt` 的 `override-settings` 预置该值,实现批量统一控制。

---

## 附录 A:主控端选型分析(为什么不另开 Rust 程序)

> 曾考虑「另开一个 Rust 程序,依赖 `librustdesk`,复用连接核心,业务层自己实现」。
> 调研后结论:**不可取,改本仓库 Flutter 桌面端**。下面是依据。

### A.1 连接核心的分层(本仓库已泛型化)

```
┌─────────────────────────────────────────────────┐
│ UI 层 (可替换)                                    │
│  Flutter: flutter/lib/  ←─FFI─→                  │
│  Sciter:  src/ui/       (deprecated)            │
└──────────────────┬──────────────────────────────┘
                   │ 通过 trait 注入(回调)
                   ▼
┌─────────────────────────────────────────────────┐
│ 会话层  Session<T: InvokeUiSession>              │
│  src/ui_session_interface.rs:57                  │
│  自动 impl Interface                             │
│  (ui_session_interface.rs:1768)                  │
└──────────────────┬──────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────┐
│ 连接核心 (纯逻辑,UI 无关)                         │
│  Client::start(peer,key,token,conn_type,Interface)│
│  src/client.rs:193                               │
│  Remote<T>::io_loop  src/client/io_loop.rs:138    │
└─────────────────────────────────────────────────┘
```

`Cargo.toml:11` 已把核心暴露为 `librustdesk`(`cdylib/staticlib/rlib`),`Client::start`
只依赖抽象 `Interface`(`client.rs:198`)。**架构上确实支持外部复用。**

### A.2 但另开程序有 4 个真实代价

| # | 代价 | 说明 | 出处 |
|---|------|------|------|
| 1 | **默认 feature 强依赖 sciter UI** | `Cargo.toml:91` 默认引入 `sciter-rs`;没有现成的「纯核心」feature 组合 | `Cargo.toml:91` |
| 2 | **`InvokeUiSession` 有 40+ 回调方法** | 即使只想要视频也必须实现全部(或大量空实现) | `ui_session_interface.rs:1683-1749` |
| 3 | **`Config` 全局状态副作用** | 复用核心就继承它的 toml 配置、ID、密钥管理,两程序共用易冲突 | `libs/hbb_common/src/config.rs` |
| 4 | **视频帧是 raw RGBA** | `on_rgba`/`get_rgba`/`next_rgba` 回调裸像素,你的 UI 框架要自己接管渲染 | `ui_session_interface.rs:1725,1736,1737` |

### A.3 选型对比

| 维度 | 另开 Rust 程序 | 改本仓库 Flutter 桌面端 ✅ |
|------|--------------|-------------------------|
| 连接功能 | 零开发(`Client::start`) | 零开发(`connect()`) |
| UI 自由度 | 任意框架 | 受 Flutter 约束 |
| `InvokeUiSession` 实现 | 40+ 方法要写 | 已实现 |
| 视频渲染 | 自己处理 RGBA | 现成 |
| 工作量 | 2-3 周+ | 2-3 天 |
| RustDesk 升级跟进 | 每次重新对接 | 直接 merge |

**前提**:核心诉求是「业务定制」(设备列表/登录/鉴权来自业务后台),而非「UI 必须
自绘」。在此前提下,另开程序的全部代价换不来任何收益。

### A.4 结论

改本仓库的 Flutter 桌面端,业务定制全部在 Flutter 业务层实现,**完全不碰 Rust 核心**。
连接窗口、视频解码、键鼠、剪贴板、文件传输全是 RustDesk 现成的。

### A.5 补充:RustDesk 主控端不支持 headless

调研确认:**RustDesk 主控端必须有 GUI**。`--connect` 等命令行参数只是把请求转发给
正在运行的 GUI 进程(`src/core_main.rs:807 core_main_invoke_new_connection`),主进程
没跑就不会建立连接。不存在「后台 API 一调就让某台机器无界面发起连接」的能力。

所以业务侧的「控制」形态只有一种:**管理员在有 GUI 的设备上点连接**。

---

## 附录 B:业务侧方案(主控端改造)

### B.1 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│ 业务后台(自建后端服务)                                       │
│  POST /api/devices/register    ← 被控端注册上报              │
│  POST /api/devices/{sn}/heartbeat ← 被控端心跳               │
│  GET  /api/devices             → 主控端拉列表                │
│  POST /api/auth/login          → 主控端登录                  │
│  DB: sn | rustdesk_id | last_seen | online | name           │
└─────────────────────────────────────────────────────────────┘
        ▲                           ▲
        │ ① 注册+心跳               │ ② 拉设备列表 + 登录
        │                           │
┌───────┴───────────┐      ┌────────┴──────────────────────┐
│ 100 台被控端       │      │ 桌面主控端(改本仓库 Flutter)   │
│ 同一个 APK         │      │  - 启动登录业务后台            │
│ 启动→上报→心跳     │      │  - 设备列表(在线状态)         │
└───────────────────┘      │  - 点设备→connect(id)         │
                           │  - 走 hbbs/hbbr(跨公网中转)   │
                           └───────────────────────────────┘
```

### B.2 主控端改动(纯 Flutter,不碰 Rust)

| 改动点 | 文件 | 说明 |
|--------|------|------|
| 设备列表数据源 | 替换 `flutter/lib/desktop/pages/connection_page.dart` | 从 `GET /api/devices` 拉设备,替代默认通讯录 |
| 登录业务后台 | 新建 `flutter/lib/models/backend_auth_model.dart` | 参考 `user_model.dart` 的 token 存储模式 |
| 登录页 | 新建 `flutter/lib/desktop/pages/backend_login_page.dart` | 用户名+密码 |
| 设备卡片 | 新建 `flutter/lib/common/widgets/device_card.dart` | 显示 SN/名称/在线状态,点击 `connect(context, id)` |
| 发起连接 | 复用 `flutter/lib/common.dart:2580 connect()` | **一行代码**,不碰核心 |

### B.3 跨公网安全加固(必须做)

| 风险 | 对策 | 实现 |
|------|------|------|
| 设备伪造 | 上报接口鉴权 | 被控端预置 token / 硬件签名;后台 SN 白名单 |
| 通信窃听 | 全链路加密 | hbbs/hbbr 配 TLS;后台 HTTPS;`custom.txt` 配 `key` |
| 统一密码泄露 | 限制连接来源 | `whitelist`(`config.rs:2920`)只允许主控端出口 IP |
| 主控端冒充 | 登录鉴权 | 主控端登录后台拿 token,每次请求带 token |

### B.4 工作量

| 模块 | 性质 | 估时 |
|------|------|------|
| 业务后台后端(4 接口+DB) | 自研 | 2-3 天 |
| 桌面主控端改造 | 改本仓库 | 2-3 天 |
| 被控端注册+心跳 | 改本仓库 | 1 天 |
| 自建 hbbs/hbbr(Docker) | 运维 | 半天 |
| 跨公网安全加固 | 配置+少量代码 | 1 天 |
| **合计** | | **约 1.5-2 周** |

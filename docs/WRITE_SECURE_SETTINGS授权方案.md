# WRITE_SECURE_SETTINGS 授权方案（免 adb 授权路径分析）

- 日期：2026-10-29
- 适用：被控端 `cn.xinzx.rustdesk.android`（rk3568 定制盒子，自研 ROM）
- 状态：方案分析，待选型实施

---

## 一、背景：这个授权是干什么的、为什么会丢

`WRITE_SECURE_SETTINGS` 在被控端上**只服务一件事**：静默启用/自愈无障碍输入服务
（`InputService`）——app 借此读写 `secure` 表的 `enabled_accessibility_services` /
`accessibility_enabled`，实现无 UI 的输入能力自愈（含运行中崩溃的退避清理）。

当前获取方式：`adb shell pm grant`（`flutter/deploy_apk.sh` 内置）。失效场景：

| 场景 | 授权是否保留 |
|------|-------------|
| 重启、`install -r` 覆盖安装 | ✅ 保留 |
| `pm clear` 清数据 | ❌ 收回（部署脚本需重新 grant） |
| 卸载重装 | ❌ 收回 |

不依赖此授权的功能：投屏免框（定制 SystemUI `DwSecure.registerSafeProgram`）、
永久密码（SN 派生）、服务器注册/视频/普通指令传输。

## 二、权限模型：为什么业务 app 授不了

`WRITE_SECURE_SETTINGS` 属 `signature|development` 级：
- 普通第三方 app **无法**通过运行时弹窗或互相授权获得；
- 授予身份只有四种：**adb（shell）**、**root**、**系统（platform）签名**、**Device Owner**；
- "业务 app 拉起被控端"只解决启动，不产生任何授权。

## 三、可行路径对比

| 方案 | 做法 | adb 需求 | 优点 | 代价/风险 |
|------|------|---------|------|----------|
| **A. priv-app 预置（推荐）** | APK 烧进 ROM `/system/priv-app/cn.xinzx.rustdesk/` + `/system/etc/permissions/privapp-permissions-cn.xinzx.rustdesk.xml` 声明权限 | **零**，出厂即带 | 权限与系统同寿（恢复出厂/重装/清数据均保留）；量产标准做法 | 需要改镜像打包流程；升级需版本号高于系统应用 |
| **B. Device Owner** | 首次配置 `adb shell dpm set-device-owner cn.xinzx.rustdesk.android/com.carriez.flutter_hbb.x`（每台一次；需无账户、近出厂状态） | 一次性 | 不动镜像；重装/升级 APK 自动继承授权（development 权限对 DO 自动授予） | 拆卸 DO 才能彻底卸载；DO 绑定包名组件 |
| **C. 平台签名** | 被控端 APK 改用 ROM platform key 签名 | 零 | `signature` 级权限自动获得 | 签名体系全项目统一，影响面大，不推荐单独为此做 |
| **D. root 常驻** | 盒子 root + su 放行一次，启动时自执行 `pm grant` | 一次性（root 时） | 灵活 | 引入 root 攻击面，量产慎用 |
| **E. 现状** | 每次部署 `deploy_apk.sh`（含 grant） | 每次部署 | 量小够用、零改动 | 设备多时繁琐；`pm clear` 后必须重授 |

## 四、方案 A 实施要点（选型后的落地清单）

1. 镜像内放置：
   ```
   /system/priv-app/RustDeskHost/RustDeskHost.apk
   /system/etc/permissions/privapp-permissions-cn.xinzx.rustdesk.xml
   ```
2. 白名单内容（几行即可）：
   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <permissions>
       <privapp-permissions package="cn.xinzx.rustdesk.android">
           <permission name="android.permission.WRITE_SECURE_SETTINGS"/>
       </privapp-permissions>
   </permissions>
   ```
3. 预置后验证：`dumpsys package cn.xinzx.rustdesk.android | grep WRITE_SECURE` 应显示 granted=true（factory 状态、未跑任何 adb）；
4. 升级通道：`/data` 区安装同包名更高 versionCode 的 APK 可覆盖升级，privapp 授权保留；
   **注意**：覆盖升级走普通 `install -r` 即可，**不要 pm clear**（会触发服务器防劫持死锁，见
   《控制端画面冻结问题分析与修复方案》与 10-29 hbbs 死锁排查记录）。

## 五、与被控端待办改进的联动

无障碍运行时自愈（待办）：`rustPointerInput` 检测到 `InputService is not bound` 时，
app 自身调用 `SilentPermsHelper` 逻辑重写 secure settings 完成自愈（退避 + 次数上限 + 日志）。

- 方案 A/B 落地后，该自愈**不再依赖任何外部授权**，运行中崩溃可全自动秒级恢复；
- 方案 E（现状）下，运行时自愈在授权存续期内同样可用，只是重装/清数据后需人工补一次 adb 授权。

三个盒子侧待办（互相正交，可一次出包）：
1. 无障碍运行时自愈（见上）；
2. rendezvous 循环对 UUID_MISMATCH 等认证拒绝做指数退避（消除 30ms 重连洪水）；
3. 控制端方案 A 诊断日志（`src/flutter.rs`，见《控制端画面冻结问题分析与修复方案》）。

## 六、结论

- 量产盒子（镜像可控）：**方案 A priv-app 预置**，出厂免 adb、权限永久；
- 少量测试机 / 暂不改镜像：维持方案 E，`deploy_apk.sh` 一次带过；
- 不管选哪条，运行时自愈改进都值得做——它解决的是"运行中崩溃无人发现"，
  与授权方式正交。

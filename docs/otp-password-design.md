# SN 动态密码（OTP）完整方案 v1

> **状态：备选方案（二期）。** 当前主方案为静态派生密码，见
> `docs/sn-password-design.md`。本文保留为时钟可信度成熟后的升级路径：
> 两者的 SN 归一化、字符集、密钥管理完全一致，且本文的 STATIC 模式报文格式
> 即主方案的密码派生格式，升级到时间轮换无需任何迁移。

被控端连接密码从"长期固定"改为"设备序列号 + 主密钥 + 时间窗口"派生的动态密码，
每 5 分钟轮换，两端独立计算，无需服务器交互。方案一（TOTP）为主体，方案二（静态派生）
作为时钟不可信设备的自动回退，两者共用同一算法，仅 MAC 输入域分隔。

---

## 0. 总览

```
┌─────────────┐   LoginRequest{password: 8位码}   ┌──────────────────┐
│ 控制端 SDK   │ ───────────────────────────────▶ │ 被控端 Android 盒 │
│ SN ← 资产系统 │    （现有 E2EE 通道，协议零改动）   │ SN ← 系统属性      │
│ 算出候选码    │                                  │ 算出候选码比对     │
└─────────────┘                                  └──────────────────┘
      两端共享: K_master(编译期固化) + 算法 v1 + SN 归一化规则
```

- **密码形态**：8 位大写字母数字（去混淆 32 字符集，40 bit 熵），形如 `23UTN36C`
- **轮换周期**：300 秒，容差 ±1 窗口（两端时钟偏差 ≤ ±5 分钟即可互通）
- **回退模式**：时钟不可信的设备自动落入静态派生码（同 40 bit，SN 域分隔）
- **改动面**：`hbb_common` 新增 1 个纯算法模块 + `connection.rs` 1 个校验分支 +
  2 个诊断 FFI + 审计枚举扩展。协议报文、握手、加密流程全部不动。

## 1. 威胁模型与安全边界

| 威胁 | 防护 | 说明 |
|---|---|---|
| 密码被旁观/记录（工单、截图、日志） | 5 分钟窗口轮换 | 相比静态密码的核心收益 |
| 无密钥在线爆破 | 40 bit + IP 白名单 + 现有失败锁定 | 30 次累计 / 每分钟 6 次封顶（`LOGIN_FAILURES`） |
| 被动抓包重放 | 密码本就走 E2EE 通道，且窗口过期即失效 | |
| **主密钥被逆向提取** | **不在防护范围内** | SN 通常可枚举，密钥即全部秘密。对策见 §10 |
| 攻击者知晓 SN | 不构成独立威胁 | 密码 = f(K, SN, T)，SN 非保密因子 |

## 2. 算法规格（v1，双端必须逐字节一致）

### 2.1 设备标识归一化

```
raw → trim → 仅保留 ASCII 字母数字 → 转大写
```

- 结果非空且 ≠ `UNKNOWN` → 用作设备标识（`ro.serialno` 返回 "unknown" 很常见，必须拦）
- 否则用 ANDROID_ID 归一化结果兜底
- 两者皆空 → 该设备 OTP 禁用（绝不允许空标识派生出全局统一密码）

### 2.2 MAC 输入编码

```
msg = "RD-OTP-v1"            // 9 字节 ASCII，同时锁定算法布局与密钥代次
    || mode                  // 1 字节: 0x01 = TOTP, 0x02 = STATIC
    || device_id             // 归一化后的 ASCII
    || 0x00                  // 1 字节分隔符
    || counter               // 8 字节大端 u64
digest = HMAC-SHA256(K_master, msg)
```

counter 取值：

| 模式 | counter |
|---|---|
| TOTP | `floor(unix秒 / 300)` |
| STATIC | 恒为 `0` |

换钥时升级为 `RD-OTP-v2` 并换 `K_master`，被控端过渡期同时接受 v1/v2。

### 2.3 截断与编码（RFC 4226 动态截断）

```
offset = digest[31] & 0x0F
v      = (digest[offset..offset+4] 按大端取 u32) & 0x7FFF_FFFF   // 31 bit
code   = 从高位取 8 组 × 5 bit，各查一次字符表
字符表 = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"   // 32 字符，已去 0/O/1/I/L 混淆
```

> 注意：字符表里保留 L 是刻意的——去除的是易与数字混淆的 I/O 和 0/1；
> 32 字符正好使 5 bit 编码无偏。**双端字符表必须逐字符一致**。

### 2.4 参数表

| 参数 | 值 | 说明 |
|---|---|---|
| 步长 | 300 s | v1 固定，不做配置（减少两端不一致面） |
| 容差窗口 | T-1, T, T+1 | 时钟偏差 ±5 分钟内互通 |
| 码长 / 熵 | 8 字符 / 40 bit | 配合白名单与失败锁定足够 |
| HMAC | SHA-256 | `sodiumoxide::crypto::auth::hmacsha256`，不加新依赖 |
| 主密钥 | 32 字节 | 编译期注入，XOR 混淆存储 |

### 2.5 共享测试向量（测试密钥，双端 CI 必须断言）

测试密钥（仅用于测试，正式包必须替换）：

```
"RD-OTP-TEST-KEY-0123456789ABCDEF"   // 32 字节 ASCII
```

| 模式 | 原始 SN | counter | 期望输出 |
|---|---|---|---|
| TOTP | `ABC-1234` | 5785632 (2025-01-01T00:00:00Z) | `23UTN36C` |
| TOTP | `ABC-1234` | 5785633 | `23XEZGKA` |
| TOTP | `XYZ999` | 5785632 | `23UE34M9` |
| TOTP | `  sn-88@x ` | 5785632 | `22R6ZQBE` |
| STATIC | `ABC-1234` | 0 | `2364JRJV` |
| STATIC | `XYZ999` | 0 | `227BDS3R` |

## 3. 运行模式与时钟可信度

### 3.1 被控端时钟判定（满足任一即"不可信"→ 仅接受 STATIC）

1. `now < 2025-01-01T00:00:00Z`（无 RTC 重置到纪元的典型态）
2. `now + 48h < last_seen`（本次开机时间相对上次运行大幅回跳；
   `last_seen` 每次启动及每小时经 `set_option("otp-last-seen-unix", …)` 持久化）

> 局限：设备若开机即错、长期不回跳（如固件纪元 + uptime），自检无法发现。
> 该状态由 3.3 的服务端静态回退候选兜住，并在审计里现形（见 §7）。

### 3.2 候选码顺序（即校验顺序）

| 端 | 候选序列 | 说明 |
|---|---|---|
| 被控端（时钟可信） | `[TOTP(T), TOTP(T-1), TOTP(T+1), STATIC]` | STATIC 恒在末位兜底 |
| 被控端（时钟不可信） | `[STATIC]` | 本地 T 窗口是垃圾值，不参与比对 |
| 控制端 SDK | `[TOTP(T), TOTP(T-1), TOTP(T+1), STATIC]` | 逐个尝试，成功即停 |

### 3.3 STATIC 常驻兜底的取舍（需要明确接受的代价）

无网无 RTC 设备自检可能"误判自己时钟正常"，若服务端只在自检失败时才收 STATIC，
这类设备将永久失联。因此 **STATIC 作为常驻末位候选**，代价是它成为一个不轮换的
第二密码（即方案二）。缓解：

- 它是 40 bit 的**逐设备**密码，仍有白名单 + 失败锁定保护；
- 走 STATIC 登录打独立审计标记（§7），运维监控其占比；
- 提供开关 `otp-static-fallback`（默认 Y），时间同步问题全量修复后可关闭。

### 3.4 SDK 尝试成本核算

最坏情况（设备时钟错）SDK 4 次尝试内必中；现有锁定阈值是"每分钟 >6 次拦截 /
累计 >30 次拦截"（`src/server/connection.rs:4113`），4 次 ≤ 6 次/分钟，合法
SDK 不会误触；攻击者的失败尝试照常累计。

## 4. 被控端改造清单（文件级）

### 4.1 新增 `libs/hbb_common/src/otp_password.rs`（纯算法，无 IO，完整参考实现）

```rust
//! SN-based one-time password shared by controlled side (verify) and
//! controlling SDK (generate). Spec: docs/otp-password-design.md §2.

use sodiumoxide::crypto::auth::hmacsha256::{authenticate, Key};

pub const OTP_STEP_SECS: u64 = 300;
pub const OTP_LENGTH: usize = 8;
pub const MODE_TOTP: u8 = 0x01;
pub const MODE_STATIC: u8 = 0x02;

// 2025-01-01T00:00:00Z: earlier clocks are treated as unsynced (typical
// post-reset state of RTC-less devices).
const CLOCK_FLOOR_UNIX: u64 = 1_735_689_600;
const CLOCK_BACKWARD_JUMP_TOLERANCE_SECS: u64 = 48 * 3600;

const ALPHABET: &[u8; 32] = b"23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
// Pins both the message layout and the master-key generation. Bump to
// RD-OTP-v2 together with a new key; accept both tags during transition.
const KEY_VERSION: &[u8] = b"RD-OTP-v1";

// The release pipeline replaces both constants as a pair (real key XORed
// with the pad). In-repo default decodes to the public test key so
// `cargo test` runs the shared vectors without a deployment key.
const OTP_KEY_PAD: [u8; 32] = *b"rd-otp-pad-0123456789abcdef-xyz!";
const OTP_KEY_XORED: [u8; 32] = [
    0x20, 0x20, 0x00, 0x20, 0x20, 0x20, 0x00, 0x24, 0x24, 0x37, 0x79, 0x1d, 0x7a, 0x77, 0x6a,
    0x19, 0x05, 0x07, 0x05, 0x0b, 0x0d, 0x54, 0x54, 0x54, 0x5c, 0x5c, 0x27, 0x6f, 0x3b, 0x3d,
    0x3f, 0x67,
];

pub fn master_key() -> [u8; 32] {
    let mut key = OTP_KEY_XORED;
    for (b, p) in key.iter_mut().zip(OTP_KEY_PAD.iter()) {
        *b ^= p;
    }
    key
}

pub fn normalize_sn(raw: &str) -> String {
    raw.trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect()
}

/// SN with fallback to ANDROID_ID; None means OTP must be disabled so that
/// missing identifiers can never derive a fleet-wide password.
pub fn effective_device_id(serial: &str, android_id: &str) -> Option<String> {
    let sn = normalize_sn(serial);
    if !sn.is_empty() && sn != "UNKNOWN" {
        return Some(sn);
    }
    let aid = normalize_sn(android_id);
    (!aid.is_empty()).then_some(aid)
}

pub fn generate(key: &[u8; 32], mode: u8, device_id: &str, counter: u64) -> String {
    let mut msg = Vec::with_capacity(KEY_VERSION.len() + 2 + device_id.len() + 8);
    msg.extend_from_slice(KEY_VERSION);
    msg.push(mode);
    msg.extend_from_slice(device_id.as_bytes());
    msg.push(0u8);
    msg.extend_from_slice(&counter.to_be_bytes());
    let Some(k) = Key::from_slice(key) else {
        return String::new(); // unreachable for 32-byte keys; empty never matches
    };
    let digest: &[u8] = authenticate(&msg, k).as_ref();
    let offset = (digest[31] & 0x0f) as usize;
    let v = u32::from_be_bytes([
        digest[offset],
        digest[offset + 1],
        digest[offset + 2],
        digest[offset + 3],
    ]) & 0x7fff_ffff;
    (0..OTP_LENGTH)
        .map(|i| ALPHABET[((v >> (5 * (OTP_LENGTH - 1 - i))) & 31) as usize] as char)
        .collect()
}

pub fn clock_is_plausible(now_unix: u64, last_seen_unix: u64) -> bool {
    now_unix >= CLOCK_FLOOR_UNIX
        && last_seen_unix.saturating_sub(now_unix) <= CLOCK_BACKWARD_JUMP_TOLERANCE_SECS
}

/// Candidates in verification order. STATIC is always the last resort on a
/// trusted clock (see design doc §3.3); it is the only candidate when the
/// local clock is untrustworthy.
pub fn server_candidates(
    key: &[u8; 32],
    device_id: &str,
    now_unix: u64,
    last_seen_unix: u64,
) -> Vec<(String, bool)> {
    if !clock_is_plausible(now_unix, last_seen_unix) {
        return vec![(generate(key, MODE_STATIC, device_id, 0), true)];
    }
    let t = now_unix / OTP_STEP_SECS;
    let mut out = vec![(generate(key, MODE_TOTP, device_id, t), false)];
    for dt in [-1i64, 1] {
        // guard against u64 underflow far in the past
        let Some(c) = t.checked_add_signed(dt) else { continue };
        out.push((generate(key, MODE_TOTP, device_id, c), false));
    }
    out.push((generate(key, MODE_STATIC, device_id, 0), true));
    out
}

/// Candidates in attempt order for the controlling SDK.
pub fn client_candidates(key: &[u8; 32], device_id: &str, now_unix: u64) -> Vec<String> {
    let t = now_unix / OTP_STEP_SECS;
    let mut out = vec![generate(key, MODE_TOTP, device_id, t)];
    for dt in [-1, 1] {
        if let Some(c) = t.checked_add_signed(dt) {
            out.push(generate(key, MODE_TOTP, device_id, c));
        }
    }
    out.push(generate(key, MODE_STATIC, device_id, 0));
    out
}

#[cfg(test)]
mod tests {
    const TEST_KEY: [u8; 32] = *b"RD-OTP-TEST-KEY-0123456789ABCDEF";

    #[test]
    fn shared_vectors() {
        let k = &super::master_key();
        assert_eq!(k, &super::TEST_KEY, "in-repo key must decode to the test key");
        let sn = super::normalize_sn("ABC-1234");
        assert_eq!(super::generate(&TEST_KEY, super::MODE_TOTP, &sn, 5_785_632), "23UTN36C");
        assert_eq!(super::generate(&TEST_KEY, super::MODE_TOTP, &sn, 5_785_633), "23XEZGKA");
        assert_eq!(
            super::generate(&TEST_KEY, super::MODE_TOTP, &super::normalize_sn("XYZ999"), 5_785_632),
            "23UE34M9"
        );
        assert_eq!(
            super::generate(&TEST_KEY, super::MODE_TOTP, &super::normalize_sn("  sn-88@x "), 5_785_632),
            "22R6ZQBE"
        );
        assert_eq!(super::generate(&TEST_KEY, super::MODE_STATIC, &sn, 0), "2364JRJV");
        assert_eq!(
            super::generate(&TEST_KEY, super::MODE_STATIC, &super::normalize_sn("XYZ999"), 0),
            "227BDS3R"
        );
    }

    #[test]
    fn normalization() {
        assert_eq!(super::normalize_sn(" abc-1234 "), "ABC1234");
        assert_eq!(super::normalize_sn("unknown"), "UNKNOWN");
        assert_eq!(super::effective_device_id("unknown", "a1b2c3d4e5f6").as_deref(), Some("A1B2C3D4E5F6"));
        assert_eq!(super::effective_device_id("", ""), None);
    }

    #[test]
    fn clock_plausibility() {
        let last = 1_800_000_000u64;
        assert!(super::clock_is_plausible(last, last));
        assert!(!super::clock_is_plausible(0, last)); // reset to epoch
        assert!(!super::clock_is_plausible(last - 48 * 3600 - 1, last)); // big backward jump
        assert!(super::clock_is_plausible(last - 47 * 3600, last));
    }
}
```

挂载：`libs/hbb_common/src/lib.rs` 加 `pub mod otp_password;`

### 4.2 `src/server/connection.rs` 校验分支

`validate_password`（现 `src/server/connection.rs:2296`）**最前**插入 OTP 分支：

```rust
if otp::enabled() {
    if let Some(id) = otp::device_id() {
        let now = otp::now_unix();
        let last_seen = otp::last_seen_unix();
        for (code, is_static) in
            otp_password::server_candidates(&otp_password::master_key(), &id, now, last_seen)
        {
            if code.is_empty() {
                continue;
            }
            if self.validate_password_plain(&code) {
                self.set_conn_audit_primary_auth(if is_static {
                    ConnAuditPrimaryAuth::OtpStaticFallback
                } else {
                    ConnAuditPrimaryAuth::OtpPassword
                });
                // 与 temporary 密码路径同法，自动获得断线快连（is_recent_session）
                raii::AuthedConnID::update_or_insert_session(
                    self.session_key(),
                    Some(code),
                    Some(false),
                );
                return true;
            }
        }
    }
}
```

要点：

- **传输零改动**：`validate_password_plain` 对候选码做与服务端对任何密码相同的
  salt/challenge 哈希（`SHA256(pw||salt)` → `SHA256(h1||challenge)`），客户端把 OTP
  当普通密码填入即可，E2EE、Hash 挑战流程全部复用。
- **防爆破零新增**：OTP 失败走现有 `check_failure` / `update_failure_with_scope`
  簿记（IP + IPv6 前缀双粒度，30 次 / 每分钟 6 次拦截 + 告警审计）。
- `ConnAuditPrimaryAuth`（`src/server/connection.rs:257`）增加两个变体：
  `OtpPassword = 5`、`OtpStaticFallback = 6`，上报链路自动携带。
- `otp::enabled()` / `otp::device_id()` / `otp::last_seen_unix()`：薄封装，读选项键
  （§4.4）；`last_seen` 更新点放在连接服务器启动与每小时定时器。

### 4.3 SN 获取（Android）

优先级：

1. Kotlin 系统层（应用为 priv-app，可 `Build.getSerial()` / `getprop`）启动时写入
   选项 `otp-device-serial`、`otp-device-android-id`（复用现有 option FFI 通道）；
2. 兜底：Rust 侧 `__system_property_get("ro.serialno")` extern 声明直读（bionic
   符号，无新依赖）；
3. 两者皆空 → `effective_device_id` 返回 None → OTP 禁用，记 WARN。

### 4.4 配置项（`libs/hbb_common/src/config.rs` keys 增补）

| 键 | 值 | 烤入方式 |
|---|---|---|
| `otp-password` | `Y` 启用 | `DEFAULT_SETTINGS` 烤入 `Y`（与白名单同法，设备可覆盖） |
| `otp-static-fallback` | 默认 `Y` | 运维后期可关 |
| `otp-device-serial` / `otp-device-android-id` | 运行时写入 | 不烤入 |
| `otp-last-seen-unix` | 内部持久化 | 不暴露 |
| `approve-mode` | `password` | **部署必需**：OTP 属密码认证，ApproveMode::Password 门控才放行无 UI 登录 |

### 4.5 密钥注入流程（防逆向）

- 真实 `K_master` 由发布流水线生成（**按客户/批次独立**），与 `OTP_KEY_PAD` 异或后
  替换 `OTP_KEY_XORED` 常量——被控端本体是 Rust `.so`，密钥天然在 native 层；
- 仓库内默认常量解码为公开测试密钥，仅保证 CI 向量可跑；
- 严禁：运行时把密钥写盘、进日志、随配置下发。

## 5. 控制端

### 5.1 控制端也是本 fork 时

直接链接 `hbb_common::otp_password`，FFI（`src/flutter_ffi.rs`）新增：

```rust
// 控制端：给定资产系统中的 SN，返回按序候选码供自动填充
pub fn main_calc_otp_candidates(sn: String) -> String {
    // json: { codes: [...], step_secs: 300, seconds_left: n }
}

// 被控端：诊断页显示当前应呈现的码 / 模式 / 时钟判定结果
pub fn main_get_otp_password() -> String {
    // json: { code, mode: "totp"|"static", seconds_left, device_id_set, clock_plausible }
}
```

### 5.2 独立 Kotlin SDK 参考实现

```kotlin
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object SnOtp {
    private const val STEP_SECS = 300L
    private const val ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    private const val MODE_TOTP = 1
    private const val MODE_STATIC = 2

    // 由 native (NDK) 层注入，勿以明文常量出现在 Kotlin 源码
    @JvmStatic external fun masterKey(): ByteArray

    fun normalizeSn(raw: String): String = raw.trim()
        .uppercase(Locale.US)
        .filter { (it in 'A'..'Z') || (it in '0'..'9') }

    fun generate(mode: Int, deviceId: String, counter: Long): String {
        val msg = ByteArrayOutputStream().apply {
            write("RD-OTP-v1".toByteArray(Charsets.US_ASCII))
            write(mode)
            write(deviceId.toByteArray(Charsets.US_ASCII))
            write(0)
            write(ByteBuffer.allocate(8).putLong(counter).array())
        }.toByteArray()
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(masterKey, "HmacSHA256"))
        val d = mac.doFinal(msg)
        val off = d[31].toInt() and 0x0F
        var v = 0
        for (i in 0..3) v = (v shl 8) or (d[off + i].toInt() and 0xFF)
        v = v and 0x7FFFFFFF
        return (0 until 8).joinToString("") { i ->
            ALPHABET[(v ushr (5 * (7 - i))) and 31].toString()
        }
    }

    /** 按尝试顺序返回候选：T, T-1, T+1, STATIC。逐个填入密码框，成功即停。 */
    fun candidates(serial: String, nowMs: Long = System.currentTimeMillis()): List<String> {
        val id = normalizeSn(serial)
        val t = nowMs / 1000 / STEP_SECS
        return listOf(
            generate(MODE_TOTP, id, t),
            generate(MODE_TOTP, id, t - 1),
            generate(MODE_TOTP, id, t + 1),
            generate(MODE_STATIC, id, 0),
        )
    }
}
```

SDK 侧重试策略：失败后取下一候选重发（复用 SDK 现有的"密码错误重试"路径）；
连续 4 个候选全错才向用户报错。设备侧 `seconds_left < 15s` 时 SDK 应直接改用
下一窗口码，避免提交瞬间跨窗。

## 6. 认证流程

```
SDK                                        被控端
 │ SN ← 资产管理系统                          │ SN/ANDROID_ID ← 系统属性
 │ candidates = [T, T±1, STATIC]             │ 启动: last_seen 持久化, 模式自检
 │ code = candidates[0]                      │
 │──── LoginRequest{password: code} ────────▶│  现有 E2EE 通道（可带 Hash salt 挑战）
 │                                           │  for c in server_candidates():
 │                                           │      constant-time 比对(c)
 │◀─── OK ───────────────────────────────────│  命中 → 审计标记 + 会话快连登记
 │◀─── Wrong Password ───────────────────────│  未命中 → 失败簿记(IP/前缀计数)
 │ 换下一候选重试（≤4 次）                      │
```

## 7. 审计与运维

- 审计标记：`OtpPassword`（正常）/ `OtpStaticFallback`（时钟异常信号），
  现有 `post_alarm_audit` 链路自动携带，无需新通道。
- **运维监控项**：STATIC 占比 —— 出现即把该设备列入 NTP/RTC 修复清单；
  占比应随部署成熟度收敛到 0。
- 日志红线：密码值、主密钥、`otp-last-seen-unix` 之外的原始 SN 不入日志；
  诊断 FFI 输出的码仅显示在设置/诊断页。

## 8. 灰度发布

| 阶段 | 内容 | 退出条件 |
|---|---|---|
| P0 | 算法模块 + 双端向量 CI | 单测全绿 |
| P1 | 被控端构建烤入（密钥、`otp-password=Y`、`approve-mode=password`、白名单），保留 preset 密码作后门；上线诊断 FFI | 抽检盒子可连、preset 仍可用作回退 |
| P2 | SDK 接入候选生成，先对少量设备切换 | 现场连接成功率与改造前持平 |
| P3 | 全量切换；观察 STATIC 占比 | 占比收敛 |
| P4（可选） | 时间问题清零后关 `otp-static-fallback` | — |
| 回滚 | 设备选项 `otp-password=N`（或构建层摘除），回到现有临时/永久密码体系 | — |

## 9. 测试计划

1. **单元**（`otp_password.rs` tests）：§2.5 向量、归一化、空标识禁用、时钟判定边界、
   窗口边界（T=0 时 T-1 不产生 u64 下溢）。
2. **双端一致性**：Kotlin 实现跑同一向量表（作为 SDK 仓库的固定测试资源）。
3. **集成**：本 fork 控制端 ↔ 被控端；错密码 7 次触发"Please try 1 minute later"；
   断线 10 分钟内重连走会话快连；跨窗口重连。
4. **现场验收**：正常盒、无 RTC 盒（应走 STATIC 并打审计）、改本机时间 ±4 分钟
   （±1 窗口容差验证）、诊断页码与 SDK 码逐窗口比对。

## 10. 剩余风险与对策

| 风险 | 对策 |
|---|---|
| 主密钥被逆向（根因性风险） | 每客户独立密钥构建；密钥只在 native 层；版本字节预留双钥过渡；必要时对 `.so` 加壳 |
| 魔改盒子整批复用同一 SN → 同批密码相同 | 资产侧盘点；确认批次改为 SN+ANDROID_ID 复合标识（`effective_device_id` 输入拼接即可，规格不变） |
| 设备时钟错但不回跳，自检失灵 | STATIC 常驻兜底 + STATIC 审计占比监控（§3.3、§7） |
| 长期离线设备时钟漂移超 ±5 分钟 | 漂移速率通常 << 窗口；无法同步的设备本质上只能走 STATIC，纳入修复清单 |
| STATIC 沦为永久后门 | 40 bit 逐设备 + 白名单 + 锁定三重保护；成熟后用 `otp-static-fallback=N` 关闭 |

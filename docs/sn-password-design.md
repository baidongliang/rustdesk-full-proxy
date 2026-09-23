# SN 派生静态密码 — 主方案 v1

连接密码 = 以设备序列号为输入、主密钥为键的 HMAC 截断值。逐设备不同、永不过期、
无时间依赖，被控端与控制端 SDK 各自独立计算，协议与传输层零改动。
时间轮换版（OTP）作为二期备选：`docs/otp-password-design.md`。

**改动量**：新增 1 个纯算法模块（约 80 行）+ `connection.rs` 1 个校验分支（约 15 行）
+ 1 个审计枚举变体 + 1 个配置键。没有时钟判定、没有候选重试、没有窗口容差。

## 1. 定位与安全边界（先说清楚它防什么）

| 对比 | 现状（共享 preset 密码） | 本方案（SN 派生） |
|---|---|---|
| 一台设备的密码被旁观/记录 | **全车队沦陷** | 仅该台沦陷 |
| 一台设备被逆向出密钥 | 全车队沦陷 | 全车队沦陷（相同，见下） |
| 在线爆破 | 白名单 + 失败锁定 | 相同 |
| 密码轮换 | 换构建 | 换构建（版本标签已预留） |

- 密钥保密是根因性前提：SN 通常可枚举，`K_master` 即全部秘密（native 层注入，§5）。
- 静态意味着"泄漏即永久"，本方案买的不是轮换，而是**逐设备隔离**——这是相对
  现状的净提升，代价几乎为零。
- 真正的在线防线是已就位的两件东西：IP 白名单（`DEFAULT_SETTINGS` 烤入）与
  失败锁定（每分钟 >6 次或累计 >30 次拦截，`src/server/connection.rs:4113`）。

## 2. 算法规格（v1，双端逐字节一致）

即 OTP 方案的 STATIC 模式，**报文格式刻意保持一致**，二期升级零迁移：

```
msg    = "RD-OTP-v1"        // 9 字节 ASCII，锁定算法布局与密钥代次
       || 0x02              // mode = STATIC
       || device_id         // 归一化后 ASCII
       || 0x00              // 1 字节分隔符
       || counter(8 字节大端) // 恒为 0
code   = RFC4226 动态截断(HMAC-SHA256(K_master, msg)) → 8 字符
字符表 = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"   // 32 字符，去 0/O/1 混淆
```

### 2.1 设备标识归一化（与 OTP 方案一致）

```
raw → trim → 仅保留 ASCII 字母数字 → 转大写
```

- 非空且 ≠ `UNKNOWN` → 用作标识（`ro.serialno` 返回 "unknown" 很常见，必须拦）
- 否则用 ANDROID_ID 归一化结果兜底
- 两者皆空 → 该设备本方案禁用（绝不允许空标识派生出全车队相同密码）

### 2.2 共享测试向量（测试密钥，双端 CI 断言）

测试密钥：`"RD-OTP-TEST-KEY-0123456789ABCDEF"`（32 字节 ASCII，仅测试用）

| 原始 SN | 期望输出 |
|---|---|
| `ABC-1234` | `2364JRJV` |
| `XYZ999` | `227BDS3R` |

## 3. 被控端改造清单

### 3.1 新增 `libs/hbb_common/src/sn_password.rs`（纯算法，无 IO）

```rust
//! Connection password derived from the device serial number.
//! Spec: docs/sn-password-design.md. The message layout is byte-compatible
//! with the STATIC mode of docs/otp-password-design.md, so upgrading the
//! fleet to time-rotated OTP later needs no migration.

use sodiumoxide::crypto::auth::hmacsha256::{authenticate, Key};

const PASSWORD_LENGTH: usize = 8;
const ALPHABET: &[u8; 32] = b"23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
// Same layout and key-generation tag as the OTP design's STATIC mode.
const KEY_VERSION: &[u8] = b"RD-OTP-v1";
const MODE_STATIC: u8 = 0x02;

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

/// SN with fallback to ANDROID_ID; None means derived passwords must stay
/// disabled so missing identifiers can never yield a fleet-wide password.
pub fn effective_device_id(serial: &str, android_id: &str) -> Option<String> {
    let sn = normalize_sn(serial);
    if !sn.is_empty() && sn != "UNKNOWN" {
        return Some(sn);
    }
    let aid = normalize_sn(android_id);
    (!aid.is_empty()).then_some(aid)
}

pub fn generate(key: &[u8; 32], device_id: &str) -> String {
    let mut msg = Vec::with_capacity(KEY_VERSION.len() + 2 + device_id.len() + 8);
    msg.extend_from_slice(KEY_VERSION);
    msg.push(MODE_STATIC);
    msg.extend_from_slice(device_id.as_bytes());
    msg.push(0u8);
    msg.extend_from_slice(&0u64.to_be_bytes());
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
    (0..PASSWORD_LENGTH)
        .map(|i| ALPHABET[((v >> (5 * (PASSWORD_LENGTH - 1 - i))) & 31) as usize] as char)
        .collect()
}

#[cfg(test)]
mod tests {
    const TEST_KEY: [u8; 32] = *b"RD-OTP-TEST-KEY-0123456789ABCDEF";

    #[test]
    fn shared_vectors() {
        let k = super::master_key();
        assert_eq!(k, TEST_KEY, "in-repo key must decode to the test key");
        assert_eq!(
            super::generate(&TEST_KEY, &super::normalize_sn("ABC-1234")),
            "2364JRJV"
        );
        assert_eq!(
            super::generate(&TEST_KEY, &super::normalize_sn("XYZ999")),
            "227BDS3R"
        );
    }

    #[test]
    fn normalization() {
        assert_eq!(super::normalize_sn(" abc-1234 "), "ABC1234");
        assert_eq!(super::normalize_sn("unknown"), "UNKNOWN");
        assert_eq!(
            super::effective_device_id("unknown", "a1b2c3d4e5f6").as_deref(),
            Some("A1B2C3D4E5F6")
        );
        assert_eq!(super::effective_device_id("", ""), None);
    }
}
```

挂载：`libs/hbb_common/src/lib.rs` 加 `pub mod sn_password;`

### 3.2 `src/server/connection.rs` 校验分支

`validate_password`（现 `src/server/connection.rs:2296`）最前插入：

```rust
if sn_password_enabled() {
    if let Some(id) = sn_device_id() {
        let code = hbb_common::sn_password::generate(
            &hbb_common::sn_password::master_key(),
            &id,
        );
        if self.validate_password_plain(&code) {
            self.set_conn_audit_primary_auth(ConnAuditPrimaryAuth::DerivedPassword);
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
```

要点：

- **传输零改动**：`validate_password_plain` 对派生码做与任何密码相同的
  salt/challenge 哈希比对；客户端把它当普通密码填入即可。
- **防爆破零新增**：失败走现有 `check_failure` / `update_failure_with_scope`
  簿记（30 次 / 每分钟 6 次拦截 + 告警审计）。
- `ConnAuditPrimaryAuth`（`src/server/connection.rs:257`）增加 `DerivedPassword = 5`。
- `sn_password_enabled()` 读选项键 `sn-password`（"Y" 启用）；`sn_device_id()` 读
  `sn-device-serial` / `sn-device-android-id` 两个选项键。

### 3.3 SN 获取（Android）

1. Kotlin 系统层（priv-app 可读）启动时写入选项 `sn-device-serial`、
   `sn-device-android-id`（复用现有 option FFI 通道）；
2. 兜底：Rust 侧 `__system_property_get("ro.serialno")` extern 直读（无新依赖）；
3. 皆空 → `effective_device_id` 返回 None → 本方案禁用，记 WARN。

### 3.4 部署配置

| 键 | 值 | 说明 |
|---|---|---|
| `sn-password` | `Y` | Android 构建 `DEFAULT_SETTINGS` 烤入（与白名单同法） |
| `approve-mode` | `password` | **必需**：派生码属密码认证，ApproveMode::Password 才放行无 UI 登录 |
| preset 密码 | 保留 | 现有 `HARD_SETTINGS` 机制不动，作为发布初期 break-glass |

## 4. 控制端 SDK（Kotlin，约 25 行）

```kotlin
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object SnPassword {
    private const val ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

    // 由 native (NDK) 层注入，勿以明文常量出现在 Kotlin 源码
    @JvmStatic external fun masterKey(): ByteArray

    fun normalizeSn(raw: String): String = raw.trim()
        .uppercase(Locale.US)
        .filter { (it in 'A'..'Z') || (it in '0'..'9') }

    /** 设备连接密码；SN 来自资产管理系统。 */
    fun generate(serial: String): String {
        val msg = ByteArrayOutputStream().apply {
            write("RD-OTP-v1".toByteArray(Charsets.US_ASCII))
            write(0x02)                                    // MODE_STATIC
            write(normalizeSn(serial).toByteArray(Charsets.US_ASCII))
            write(0)
            write(ByteBuffer.allocate(8).putLong(0L).array())
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
}
```

控制端只有一次尝试、一个候选码——没有窗口、没有重试逻辑。

## 5. 密钥注入（防逆向）

- 真实 `K_master` 由发布流水线按客户/批次生成，与 `OTP_KEY_PAD` 异或后替换
  `OTP_KEY_XORED` 常量；被控端本体是 Rust `.so`，密钥天然在 native 层。
- 仓库内默认常量解码为公开测试密钥，仅保证 CI 向量可跑。
- 严禁：运行时把密钥写盘、进日志、随配置下发。
- 轮换 = 换钥发新构建；`RD-OTP-v1` 标签预留版本化，需要双钥过渡时再升 `v2`。

## 6. 测试与上线

1. 单测：§2.2 向量、归一化、空标识禁用（`sn_password.rs` tests）。
2. 双端一致性：Kotlin 实现跑同一向量表。
3. 集成：本 fork 控制端 ↔ 被控端连接；错密码触发既有锁定文案；断线重连走会话快连。
4. 上线：构建烤入（密钥 + `sn-password=Y` + `approve-mode=password` + 白名单）
   一个批次即完成；回滚 = 设备选项 `sn-password=N`，回到现有临时/永久密码体系。

## 7. 二期升级到 OTP 的路径（为何零迁移）

本方案的密码派生报文 = OTP 方案 STATIC 模式（mode 0x02, counter 0）。升级时：

- 设备端校验分支改为接受 `[TOTP(T), TOTP(T±1)]` 候选（ STATIC 是否保留为末位兜底
  见 OTP 文档 §3.3）；
- SDK 从 `generate(sn)` 换成 `candidates(sn)`；
- 密钥、归一化、字符集、全部已发向量均不变，只新增向量。

# WebSocket 模式注册循环被重置问题分析与修复方案

- 日期：2026-11-27
- 基线代码：`54829ae`
- 影响范围：目前仅本机 mac 控制端（配置了 `allow-websocket = 'Y'`）；车队被控端未受影响
- 状态：**未做任何代码/配置改动**，本文档记录分析结论、修复方案与不修复的影响，待决策

---

## 一、症状（2026-11-27 实测）

客户端（mac 控制端，ID `987654321`）日志每 **17 秒**重复下面一组（每轮 8 行，全是 ERROR/WS 相关）：

```
INFO   start rendezvous mediator of 47.95.148.47
INFO   start tcp: ws://47.95.148.47:21118
DEBUG  Client handshake done.
INFO   register_pk -> host=47.95.148.47:21116 id=987654321 uuid=[...] serial=3 ... pk_len=32
INFO   RegisterPkResponse from 47.95.148.47:21116 result=NOT_SUPPORT keep_alive=0
ERROR  unknown RegisterPkResponse
ERROR  WebSocket protocol error: Connection reset without closing handshake
ERROR  rendezvous mediator error: WebSocket protocol error: ...
```

服务器侧（hbbs 1.1.15 抓包）与之一一对应：WebSocket 握手成功（101）→ 客户端发注册 → hbbs 回
`RegisterPkResponse{result=6}`（`NOT_SUPPORT`）→ **hbbs 立即断开连接**。

| 量化项 | 实测值 |
|---|---|
| 重连周期 | 14.2 分钟内 50 轮，平均 17.1 秒/轮 |
| 由此产生的日志 | 约 6.4 MB/天 |
| 功能影响 | 作为控制端正常；作为被控端不可达（见第三节） |

## 二、原因：客户端开了 WebSocket 模式，连的却是 OSS 版 hbbs

这不是代码缺陷，而是**设计上不被支持的配置组合**。设置页该开关的提示原文就是结论
（`src/lang/cn.rs:690`、`:731`）：

> 使用 WebSocket 时，仅支持中继连接。
> 注意：RustDesk 开源服务器 (OSS server) 不包含此功能。

因果链（均已对照代码与抓包证实）：

| # | 环节 | 位置 | 事实 |
|---|---|---|---|
| 1 | 开关默认关闭 | `libs/hbb_common/src/config.rs:2956` `option2bool` | `allow-*` 类选项仅当值为 `"Y"` 时为真，未设置即关闭。本机是被**手动**打开的 |
| 2 | 注册通道二选一 | `src/rendezvous_mediator.rs:528` `start()` | `is_proxy() \|\| use_ws() \|\| is_udp_disabled()` 为真时只跑 `start_tcp`，否则只跑 `start_udp`。**开启 WS 后客户端完全不发 UDP 注册** |
| 3 | 端口改写 | `libs/hbb_common/src/websocket.rs:340` `check_ws()` | WS 开启时把 rendezvous `:21116` 改写为 `ws://…:21118` |
| 4 | 客户端在 WS 上发注册 | `src/rendezvous_mediator.rs:470` `start_tcp()` | 连接建立时先把 `host_key_confirmed` 置假，随后在定时分支里经 WS 发 `register_pk` |
| 5 | 服务器拒绝 | hbbs `src/rendezvous_server.rs` `handle_tcp()` | TCP/WS 通道收到 `RegisterPk` 固定回 `NOT_SUPPORT` 并返回 `false`，外层循环随即断开连接。**OSS 版只在 UDP 通道（`handle_udp`）处理公钥注册**；TCP/WS 通道也不处理 `RegisterPeer` |
| 6 | 客户端当作未知应答 | `src/rendezvous_mediator.rs:365` / `:425` `handle_resp()` | `NOT_SUPPORT` 落入兜底分支，只打一行 `unknown RegisterPkResponse`，`key_confirmed` 永远不会置真 |
| 7 | 18 秒后重来 | `src/rendezvous_mediator.rs:126` `start_all()` | mediator 退出后，外层循环把本轮补足到 `CONNECT_TIMEOUT`（18s）再启动，于是形成稳定循环 |

补充说明：hbbs 的每条 TCP/WS 连接**只处理一条消息**（仅 `PunchHoleRequest` / `RequestRelay` 例外），
所以“回一条就断”是服务器的既定行为，不是异常。

## 三、影响面核实（均为只读操作）

| 核实项 | 方法 | 结果 |
|---|---|---|
| 本机在 hbbs 上是否算已注册 | 只读查询 hbbs 注册库 `/opt/rustdesk/db_v2.sqlite3` 的 `peer` 表 | 共 10 个已注册端点，**没有** `987654321`；对照 `DWDEV202604260020` 正常（有公钥） |
| 还有哪些客户端处于 WS 模式 | 服务器抓包 40 秒，统计 21118 上的握手来源 | 仅 1 个 IP（本机）共 2 次握手；**没有其它客户端或设备** |
| 本机所在网络 UDP 是否可达 | 从本机向 `47.95.148.47:21116` 发 4 次 `RegisterPeer`（一次性 ID，不写库） | 4/4 应答，约 25 ms |

注意：第二项是抓包那一刻的快照，不能保证以后没人打开这个开关。

## 四、不修复带来的问题

按严重程度排序：

1. **本机不能被远程控制。** 本机不在 hbbs 注册表里，任何控制端连它都会得到 `ID_NOT_EXIST`。
   仅当控制端使用时没有功能损失。
2. **被控端上如果有人打开这个开关，设备会直接失联。** 这是本问题最需要防的情况：
   设备会既不可控、又显示离线。目前没有发生（见第三节），但没有任何机制阻止。
3. **每 17 秒一次无效重连，日志约 6.4 MB/天。** 全部是 ERROR，真正的故障容易被淹没。
4. 不涉及安全或数据风险。“RustDesk 状态”显示不受它影响（见第六节）。

## 五、修复方案

| 方案 | 做法 | 效果 | 代价 |
|---|---|---|---|
| **A. 关掉开关**（推荐，立即） | 客户端 设置 → 网络 → “Use WebSocket” 关闭后重启；或把配置里的 `allow-websocket` 设为 `N` | 客户端回到 UDP 注册，循环消失，本机可被控 | 需要所在网络放行 UDP 21116（本机实测可达）。零代码改动 |
| **B. 代码加固**（建议跟进） | 客户端收到 `NOT_SUPPORT` 时打明确告警，并在本次运行内自动回退到 UDP 注册 | 即使有人误开也能自愈 | 约 15 行，改在注册主流程；需发版并验证 |
| C. 换 Pro 服务器 | 仅当确实需要 WebSocket（例如某些网络封了 UDP） | WebSocket 注册可用 | 许可证与运维变更；目前没有这个需求 |

### 5.1 方案 A 细则

- 单机：按上表操作后重启客户端。若要车队层面杜绝，可在定制客户端配置里把该选项下发并锁定，
  用户将无法再打开。
- **前提**：所在网络放行 UDP 21116。可用下面的探针确认（对 `ZZUDPPROBE*` 这类一次性 ID，
  hbbs 只回 `RegisterPeerResponse`，不写库）：

```python
import socket
def vint(n):
    out = b''
    while True:
        b = n & 0x7f; n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n: return out
def ld(f, d):
    d = d.encode(); return vint((f << 3) | 2) + vint(len(d)) + d
# RendezvousMessage{ register_peer(6): RegisterPeer{ id(1), serial(2)=0 } }，UDP 上是裸 protobuf
msg = ld(6, ld(1, 'ZZUDPPROBE001') + vint(2 << 3) + vint(0))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
s.sendto(msg, ('47.95.148.47', 21116))
print(s.recvfrom(1024)[0].hex())   # 正常应答形如 3a021001
```

- **验证清单**（改完后逐项确认）：
  1. 客户端日志不再出现 `start tcp: ws://` 与 `Connection reset without closing handshake`；
  2. hbbs 侧可见本机注册：`journalctl -u rustdesk-hbbs | grep "update_pk <ID>"`，且注册库中出现该 ID；
  3. 控制功能正常，“RustDesk 状态”显示正常。

### 5.2 方案 B 实现要点（供实施时参考）

- 触发点：`src/rendezvous_mediator.rs` `handle_resp()` 的 `RegisterPkResponse` 分支，为 `NOT_SUPPORT`
  增加显式处理（当前落在 :425 的兜底分支）：打 WARN，说明“服务器不支持经 TCP/WebSocket 注册，
  请关闭 Use WebSocket”，并置一个进程级标志。
- 生效点：`start()`（:528）的判断改为 `use_ws() && !标志` 才走 `start_tcp`；置标志后调用 `restart()`
  （:120）让 mediator 立即以 UDP 模式重启。
- 不持久化、不改动用户配置：下次启动若开关仍开着会再探测一次，失败一次后即回退。
- 对 Pro 服务器无影响：Pro 上 WS 注册成功，不会触发回退。
- 风险：属于注册主流程的行为改动，需在 mac 控制端与 Android 被控端上各验证“注册成功、可被控、
  可控制、状态显示”四项，且开关开/关各测一遍。

## 六、与“RustDesk 状态显示离线”的关系（同源，已修复）

两个问题出自同一个开关，但互相独立：

- 状态显示问题：`allow-websocket` 开启时，在线状态查询也被改走 WS 21118，而 hbbs 只在裸 TCP 21115
  上处理 `OnlineRequest`，导致查询全部超时。已修复（提交 `54829ae`）：`src/client.rs:4128`
  `create_online_stream()` 改用 `connect_tcp_local()` 直连 21115。
- 因此**本问题不影响状态显示**；方案 A/B 也不会改变状态显示的行为。

## 七、结论摘要

- 根因：`allow-websocket = 'Y'` + OSS 版 hbbs，是设置页已明确标注“不包含此功能”的组合。
- 当前影响仅限本机：不可被控 + 每 17 秒一轮无效重连；车队被控端不受影响。
- 建议：先执行方案 A（本机关掉开关，UDP 已确认可达）；方案 B 作为车队加固另行排期；
  方案 C 仅在确有 WebSocket 需求时考虑。
- 附带观察（与本题无关）：本机日志的大头是每秒一次的 `get_id` 调试日志，约 25 MB/天，可另行处理。

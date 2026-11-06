import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/thingsboard_model.dart';

typedef DeviceConnectHandler = void Function(
  BuildContext context,
  String id, {
  String? password,
});

class DeviceListPage extends StatefulWidget {
  final DeviceConnectHandler? connectHandler;
  final ThingsBoardDeviceRepository? repository;
  final List<ThingsBoardRemoteDevice>? initialDevices;

  const DeviceListPage({
    Key? key,
    this.connectHandler,
    this.repository,
    this.initialDevices,
  }) : super(key: key);

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage> {
  late final ThingsBoardDeviceRepository _repository;
  late final TextEditingController _serverController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;

  ThingsBoardSession? _session;
  List<ThingsBoardRemoteDevice> _devices = const [];
  bool _loggingIn = false;
  bool _loadingDevices = false;
  String? _error;
  DateTime? _lastUpdatedAt;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? ThingsBoardClient();
    _serverController =
        TextEditingController(text: kThingsBoardDefaultServerUrl);
    _usernameController =
        TextEditingController(text: kThingsBoardDefaultUsername);
    _passwordController =
        TextEditingController(text: kThingsBoardDefaultPassword);
    _devices = widget.initialDevices ?? const [];
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                Text(
                  '设备列表',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                if (_session != null) ...[
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _loadingDevices ? null : _refreshDevices,
                    icon: const Icon(Icons.refresh),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _logout,
                    child: const Text('退出登录'),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                _buildLoginOrStatus(context),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  _buildError(context, _error!),
                ],
                const SizedBox(height: 12),
                _buildDevicesArea(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginOrStatus(BuildContext context) {
    final session = _session;
    if (session != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.account_circle, size: 20, color: MyTheme.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${session.username} · ${session.role} · ${session.serverUrl}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            if (_lastUpdatedAt != null) ...[
              const SizedBox(width: 12),
              Text(
                '更新 ${_formatTime(_lastUpdatedAt!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _buildTextField(
                  controller: _serverController,
                  label: 'ThingsBoard 地址',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildTextField(
                  controller: _usernameController,
                  label: '账号',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildTextField(
                  controller: _passwordController,
                  label: '密码',
                  obscureText: true,
                  onSubmitted: (_) => _login(),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _loggingIn ? null : _login,
                  child: _loggingIn
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('登录'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    bool obscureText = false,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _buildDevicesArea(BuildContext context) {
    if (_loadingDevices) {
      return const SizedBox(
        height: 180,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_devices.isEmpty) {
      return SizedBox(
        height: 180,
        child: Center(
          child: Text(
            _session == null ? '登录后读取设备' : '暂无设备',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < _devices.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _buildDeviceCard(context, _devices[i]),
        ],
      ],
    );
  }

  Widget _buildDeviceCard(
      BuildContext context, ThingsBoardRemoteDevice device) {
    final canControl = device.connectionId.trim().isNotEmpty;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: Theme.of(context).dividerColor,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: MyTheme.accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                Icons.tablet_mac,
                size: 20,
                color: MyTheme.accent,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          device.name,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.w500,
                                  ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildStatusChip(
                        context,
                        device.online,
                        device.online ? '在线' : '离线',
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (device.sn.isNotEmpty)
                    Text(
                      'SN: ${device.sn}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  Text(
                    '远控ID: ${device.connectionId}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    'ThingsBoard ID: ${device.thingsBoardId}',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              onPressed: canControl ? () => _onControl(device) : null,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text('控制'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(BuildContext context, bool active, String text) {
    final color = active ? const Color(0xFF1B8F4D) : const Color(0xFF9A4D2D);
    return Tooltip(
      message: text,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFC63D32).withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFFC63D32),
            ),
      ),
    );
  }

  Future<void> _login() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final serverUrl = _serverController.text.trim();
    if (serverUrl.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写 ThingsBoard 地址、账号和密码');
      return;
    }

    setState(() {
      _loggingIn = true;
      _error = null;
    });
    try {
      final session = await _repository.login(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );
      if (!mounted) {
        return;
      }
      setState(() => _session = session);
      await _refreshDevices();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loggingIn = false);
      }
    }
  }

  Future<void> _refreshDevices() async {
    final session = _session;
    if (session == null) {
      return;
    }
    setState(() {
      _loadingDevices = true;
      _error = null;
    });
    try {
      final devices = await _repository.fetchDevices(session);
      if (mounted) {
        setState(() {
          _devices = devices;
          _lastUpdatedAt = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loadingDevices = false);
      }
    }
  }

  void _logout() {
    setState(() {
      _session = null;
      _devices = const [];
      _error = null;
      _lastUpdatedAt = null;
    });
  }

  void _onControl(ThingsBoardRemoteDevice device) {
    // 密码只走 ID 派生规则 v2（与被控端 Rust sn_password 一致），不读
    // ThingsBoard 属性——被控端启动即按自身 ID 派生写入永久密码，属性密码会
    // 造成必然的"密码不正确"。
    final password = snDerivedPassword(device.connectionId);
    final connectHandler = widget.connectHandler;
    if (connectHandler != null) {
      connectHandler(context, device.connectionId, password: password);
      return;
    }
    connect(context, device.connectionId, password: password);
  }
}

/// 统一密码规则 v2（与被控端 Rust sn_password 一致）：
/// HMAC-SHA256(K, "RD-OTP-v1"|0x02|normalize(ID)|0x00|counter=0) 前 40bit，
/// 按 32 字符去混淆表编码为 8 位。派生源为 ID 本身（normalize 后），任意厂家
/// 序列号格式通用；ID 变化时两端密码同步变化。
/// ID 不合规（normalize 为空）时返回 null，走手动输密码。
String? snDerivedPassword(String connectionId) {
  const keyVersion = 'RD-OTP-v1';
  const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  // 与 Rust 侧 sn_password.rs 的 OTP_KEY_XORED/OTP_KEY_PAD 成对，改动需同步。
  const keyXored = [
    0xe6, 0x1c, 0xf9, 0xcd, 0xcb, 0xad, 0x36, 0x7a, 0x90, 0xa7, 0x51, 0x4e,
    0x3b, 0x10, 0x5c, 0x02, 0xf9, 0x22, 0xc5, 0xfd, 0x6f, 0xe7, 0xb0, 0x76,
    0xad, 0x88, 0x10, 0x75, 0xd6, 0x86, 0xd9, 0x33,
  ];
  final keyPad = ascii.encode('rd-otp-pad-0123456789abcdef-xyz!');
  final masterKey = Uint8List.fromList(
      List.generate(keyXored.length, (i) => keyXored[i] ^ keyPad[i]));
  final id = _normalizeSnId(connectionId);
  if (id.isEmpty) {
    return null;
  }
  final msg = <int>[
    ...ascii.encode(keyVersion),
    0x02,
    ...ascii.encode(id),
    0x00,
    0, 0, 0, 0, 0, 0, 0, 0, // counter，STATIC 模式恒为 0
  ];
  final digest = Hmac(sha256, masterKey).convert(msg).bytes;
  var v = 0;
  for (var i = 0; i < 5; i++) {
    v = (v << 8) | digest[i];
  }
  return List.generate(8, (i) => alphabet[(v >> (5 * (7 - i))) & 31]).join();
}

/// 与 Rust normalize_sn 一致：去 @server 后缀、大写、仅保留字母数字。
String _normalizeSnId(String raw) {
  final id = raw.split('@').first.trim().toUpperCase();
  final sb = StringBuffer();
  for (final c in id.codeUnits) {
    if ((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A)) {
      sb.writeCharCode(c);
    }
  }
  return sb.toString();
}

String _formatTime(DateTime time) {
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${pad(time.hour)}:${pad(time.minute)}:${pad(time.second)}';
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/rustdesk_online_model.dart';
import '../../models/school_device_model.dart';

typedef DeviceConnectHandler = void Function(
  BuildContext context,
  String id, {
  String? password,
});

enum RustDeskOnlineStatus { checking, online, offline, failed }

class DeviceListPage extends StatefulWidget {
  final DeviceConnectHandler? connectHandler;
  final SchoolDeviceRepository? repository;
  final RustDeskOnlineRepository? onlineRepository;
  final School? initialSchool;
  final List<SchoolDevice>? initialDevices;

  const DeviceListPage({
    Key? key,
    this.connectHandler,
    this.repository,
    this.onlineRepository,
    this.initialSchool,
    this.initialDevices,
  }) : super(key: key);

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage> {
  late final SchoolDeviceRepository _repository;
  late final RustDeskOnlineRepository _onlineRepository;
  late final TextEditingController _schoolController;
  late final TextEditingController _deviceController;
  final FocusNode _schoolFocusNode = FocusNode();
  final LayerLink _schoolLayerLink = LayerLink();
  final GlobalKey _schoolFieldKey = GlobalKey();
  final Object _schoolTapGroup = Object();
  final ScrollController _tableHorizontalController = ScrollController();
  OverlayEntry? _schoolOverlay;
  Timer? _schoolSearchTimer;
  Timer? _statusRefreshTimer;
  Timer? _statusTimeout;
  School? _selectedSchool;
  List<School> _schoolOptions = const [];
  List<SchoolDevice> _devices = const [];
  bool _loadingSchools = false;
  bool _loadingDevices = false;
  bool _schoolSearchDone = false;
  bool _hasSearched = false;
  String? _error;
  Map<String, RustDeskOnlineStatus> _onlineStatuses = {};
  Set<String> _pendingStatusIds = {};
  int _schoolSearchVersion = 0;
  int _deviceSearchVersion = 0;
  int _statusQueryVersion = 0;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? SchoolDeviceClient();
    _onlineRepository = widget.onlineRepository ?? RustDeskOnlineClient();
    _onlineRepository.subscribe(_handleOnlineStatus);
    _selectedSchool = widget.initialSchool;
    _schoolController =
        TextEditingController(text: widget.initialSchool?.schoolName ?? '');
    _deviceController = TextEditingController();
    _devices = widget.initialDevices ?? const [];
    _hasSearched = widget.initialDevices != null;
    if (_devices.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startOnlineStatusUpdates();
      });
    }
  }

  @override
  void dispose() {
    _schoolSearchTimer?.cancel();
    _stopOnlineStatusUpdates();
    _onlineRepository.unsubscribe();
    _hideSchoolOptions();
    _schoolFocusNode.dispose();
    _tableHorizontalController.dispose();
    _schoolController.dispose();
    _deviceController.dispose();
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
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
            child: Row(
              children: [
                Text('设备列表', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildFilter(context),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Text('查询结果',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(width: 10),
                      Text('共 ${_devices.length} 台设备',
                          style: Theme.of(context).textTheme.bodySmall),
                      if (_error != null) ...[
                        const SizedBox(width: 16),
                        Expanded(child: _buildError(context, _error!)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(child: _buildDevicesArea(context)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilter(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: theme.shadowColor.withOpacity(0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final schoolField = _buildSchoolField(context);
        final deviceField = _buildDeviceField(context);
        final buttons = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: _loadingDevices ? null : _queryDevices,
              child: const Text('查询'),
            ),
            const SizedBox(width: 10),
            OutlinedButton(onPressed: _reset, child: const Text('重置')),
          ],
        );
        if (constraints.maxWidth < 680) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              schoolField,
              const SizedBox(height: 14),
              deviceField,
              const SizedBox(height: 14),
              buttons,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: schoolField),
            const SizedBox(width: 14),
            Expanded(flex: 2, child: deviceField),
            const SizedBox(width: 14),
            Padding(padding: const EdgeInsets.only(top: 25), child: buttons),
          ],
        );
      }),
    );
  }

  Widget _buildSchoolField(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('学校'),
        const SizedBox(height: 7),
        TapRegion(
          groupId: _schoolTapGroup,
          onTapOutside: (_) {
            _schoolFocusNode.unfocus();
            _hideSchoolOptions();
          },
          child: CompositedTransformTarget(
            link: _schoolLayerLink,
            child: TextField(
              key: _schoolFieldKey,
              controller: _schoolController,
              focusNode: _schoolFocusNode,
              onChanged: _onSchoolChanged,
              onTap: _onSchoolTap,
              decoration: const InputDecoration(
                hintText: '输入学校名称搜索并选择',
                prefixIcon: Icon(Icons.search, size: 20),
                suffixIcon: Icon(Icons.keyboard_arrow_down),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceField(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('设备编号'),
        const SizedBox(height: 7),
        TextField(
          controller: _deviceController,
          onChanged: (_) {
            ++_deviceSearchVersion;
            _stopOnlineStatusUpdates();
            setState(() {
              _devices = const [];
              _hasSearched = false;
              _loadingDevices = false;
              _error = null;
            });
          },
          onSubmitted: (_) => _queryDevices(),
          decoration: const InputDecoration(
            hintText: '可选，输入设备编号',
            prefixIcon: Icon(Icons.numbers, size: 20),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }

  Widget _buildDevicesArea(BuildContext context) {
    if (_loadingDevices) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_devices.isEmpty) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(_hasSearched ? '没有找到符合条件的设备' : '请先搜索并选择学校'),
      );
    }
    final theme = Theme.of(context);
    return Container(
      key: const Key('device-table-viewport'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final tableWidth =
            constraints.maxWidth < 1120 ? 1120.0 : constraints.maxWidth;
        const weights = [1.45, 1.55, 1.6, 1.65, 1.05, 1.1, 1.4, 0.95];
        const totalWeight = 10.75;
        final widths = [
          for (final weight in weights) tableWidth * weight / totalWeight,
        ];
        return Scrollbar(
          controller: _tableHorizontalController,
          thumbVisibility: true,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: SingleChildScrollView(
            controller: _tableHorizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableWidth,
              child: Column(
                children: [
                  Container(
                    key: const Key('device-table-header'),
                    height: 48,
                    color: theme.colorScheme.primary.withOpacity(0.05),
                    child: Row(children: [
                      _tableCell(const Text('设备编号'), widths[0]),
                      _tableCell(const Text('学校'), widths[1]),
                      _tableCell(const Text('位置'), widths[2]),
                      _tableCell(const Text('设备类型 / 型号'), widths[3]),
                      _tableCell(const Text('设备状态'), widths[4]),
                      _tableCell(const Text('软件版本'), widths[5]),
                      _tableCell(const Text('RustDesk 状态'), widths[6]),
                      _tableCell(const Text('操作'), widths[7]),
                    ]),
                  ),
                  Divider(height: 1, color: theme.dividerColor),
                  Expanded(
                    child: ListView.builder(
                      key: const Key('device-rows-scroll'),
                      itemCount: _devices.length,
                      itemBuilder: (context, index) => _buildDeviceRow(
                        context,
                        _devices[index],
                        widths,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _tableCell(Widget child, double width) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(alignment: Alignment.centerLeft, child: child),
      ),
    );
  }

  Widget _buildDeviceRow(
      BuildContext context, SchoolDevice device, List<double> widths) {
    final school = _selectedSchool;
    return Container(
      height: 68,
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(children: [
        _tableCell(
          SelectableText(device.deviceNo, maxLines: 1),
          widths[0],
        ),
        _tableCell(
          _twoLines(
            school?.schoolName ?? '',
            school == null ? '' : '${school.cityName} / ${school.countyName}',
            context,
          ),
          widths[1],
        ),
        _tableCell(
          Text(device.location, maxLines: 2, overflow: TextOverflow.ellipsis),
          widths[2],
        ),
        _tableCell(
          _twoLines(device.deviceTypeDesc, device.deviceModelName, context),
          widths[3],
        ),
        _tableCell(_buildDeviceStatus(device.status), widths[4]),
        _tableCell(
          Text(device.versionCode,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          widths[5],
        ),
        _tableCell(_buildOnlineStatus(device.deviceNo), widths[6]),
        _tableCell(
          OutlinedButton(
            onPressed: device.deviceNo.trim().isEmpty
                ? null
                : () => _onControl(device),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('控制'),
          ),
          widths[7],
        ),
      ]),
    );
  }

  Widget _twoLines(String first, String second, BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(first, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (second.isNotEmpty)
          Text(second,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildDeviceStatus(int? status) {
    final label = status == 0
        ? '在线'
        : status == 1
            ? '离线'
            : '未知';
    final color = status == 0
        ? const Color(0xFF1B8F4D)
        : Theme.of(context).textTheme.bodySmall?.color;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, size: 7, color: color),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: color)),
    ]);
  }

  Widget _buildOnlineStatus(String deviceNo) {
    final status = _onlineStatuses[deviceNo] ?? RustDeskOnlineStatus.checking;
    final label = switch (status) {
      RustDeskOnlineStatus.online => '在线',
      RustDeskOnlineStatus.offline => '离线',
      RustDeskOnlineStatus.failed => '查询失败',
      RustDeskOnlineStatus.checking => '查询中',
    };
    final color = switch (status) {
      RustDeskOnlineStatus.online => const Color(0xFF1B8F4D),
      RustDeskOnlineStatus.failed => const Color(0xFFB0582F),
      _ => Theme.of(context).textTheme.bodySmall?.color,
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, size: 7, color: color),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: color)),
    ]);
  }

  Widget _buildError(BuildContext context, String text) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context)
          .textTheme
          .bodyMedium
          ?.copyWith(color: const Color(0xFFC63D32)),
    );
  }

  void _onSchoolChanged(String value) {
    _schoolSearchTimer?.cancel();
    final version = ++_schoolSearchVersion;
    ++_deviceSearchVersion;
    _stopOnlineStatusUpdates();
    final name = value.trim();
    setState(() {
      _selectedSchool = null;
      _schoolOptions = const [];
      _schoolSearchDone = false;
      _loadingSchools = false;
      _loadingDevices = false;
      _devices = const [];
      _hasSearched = false;
      _error = null;
    });
    if (name.isNotEmpty) {
      _showSchoolOptions();
      _schoolSearchTimer = Timer(const Duration(milliseconds: 300),
          () => _searchSchools(name, version));
    } else {
      _hideSchoolOptions();
    }
    _schoolOverlay?.markNeedsBuild();
  }

  void _showSchoolOptions() {
    if (_schoolController.text.trim().isEmpty || _schoolOverlay != null) return;
    final field = _schoolFieldKey.currentContext?.findRenderObject();
    if (field is! RenderBox) return;
    _schoolOverlay = OverlayEntry(builder: (context) {
      return CompositedTransformFollower(
        link: _schoolLayerLink,
        showWhenUnlinked: false,
        offset: Offset(0, field.size.height + 4),
        child: TapRegion(
          groupId: _schoolTapGroup,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: field.size.width,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: _buildSchoolOptions(),
              ),
            ),
          ),
        ),
      );
    });
    Overlay.of(context).insert(_schoolOverlay!);
  }

  void _onSchoolTap() {
    final name = _schoolController.text.trim();
    if (name.isEmpty) return;
    _showSchoolOptions();
    if (_selectedSchool != null && !_loadingSchools) {
      _searchSchools(name, ++_schoolSearchVersion);
    }
  }

  Widget _buildSchoolOptions() {
    if (_loadingSchools || !_schoolSearchDone) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('正在搜索学校…'),
      );
    }
    if (_schoolOptions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('没有找到学校'),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      itemCount: _schoolOptions.length,
      itemBuilder: (context, index) {
        final school = _schoolOptions[index];
        return ListTile(
          dense: true,
          title: Text(school.schoolName),
          subtitle: Text('${school.cityName} / ${school.countyName}'),
          onTap: () => _selectSchool(school),
        );
      },
    );
  }

  void _hideSchoolOptions() {
    _schoolOverlay?.remove();
    _schoolOverlay?.dispose();
    _schoolOverlay = null;
  }

  Future<void> _searchSchools(String name, int version) async {
    if (!mounted || version != _schoolSearchVersion) return;
    setState(() => _loadingSchools = true);
    try {
      final schools = await _repository.searchSchools(name);
      if (!mounted || version != _schoolSearchVersion) return;
      setState(() {
        _schoolOptions = schools;
        _schoolSearchDone = true;
        _loadingSchools = false;
      });
      _schoolOverlay?.markNeedsBuild();
    } catch (error) {
      if (!mounted || version != _schoolSearchVersion) return;
      setState(() {
        _error = '学校查询失败：$error';
        _schoolSearchDone = true;
        _loadingSchools = false;
      });
      _schoolOverlay?.markNeedsBuild();
    }
  }

  void _selectSchool(School school) {
    _schoolSearchTimer?.cancel();
    ++_schoolSearchVersion;
    _hideSchoolOptions();
    _schoolFocusNode.unfocus();
    setState(() {
      _selectedSchool = school;
      _schoolController.text = school.schoolName;
      _schoolOptions = const [];
      _schoolSearchDone = false;
      _error = null;
    });
  }

  Future<void> _queryDevices() async {
    final school = _selectedSchool;
    if (school == null || _schoolController.text.trim() != school.schoolName) {
      setState(() => _error = '请先从搜索结果中选择学校');
      return;
    }
    final version = ++_deviceSearchVersion;
    _hideSchoolOptions();
    _stopOnlineStatusUpdates();
    setState(() {
      _loadingDevices = true;
      _hasSearched = true;
      _devices = const [];
      _error = null;
    });
    try {
      final devices = await _repository.fetchDevices(
        schoolId: school.schoolId,
        deviceNo: _deviceController.text.trim(),
      );
      if (!mounted || version != _deviceSearchVersion) return;
      setState(() {
        _devices = devices;
        _loadingDevices = false;
      });
      _startOnlineStatusUpdates();
    } catch (error) {
      if (!mounted || version != _deviceSearchVersion) return;
      setState(() {
        _error = '设备查询失败：$error';
        _loadingDevices = false;
      });
    }
  }

  void _reset() {
    _schoolSearchTimer?.cancel();
    ++_schoolSearchVersion;
    ++_deviceSearchVersion;
    _hideSchoolOptions();
    _stopOnlineStatusUpdates();
    _schoolController.clear();
    _deviceController.clear();
    setState(() {
      _selectedSchool = null;
      _schoolOptions = const [];
      _devices = const [];
      _schoolSearchDone = false;
      _loadingSchools = false;
      _loadingDevices = false;
      _hasSearched = false;
      _error = null;
    });
  }

  void _startOnlineStatusUpdates() {
    _stopOnlineStatusUpdates();
    final ids = _devices
        .map((device) => device.deviceNo.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return;
    setState(() {
      _onlineStatuses = {
        for (final id in ids) id: RustDeskOnlineStatus.checking,
      };
    });
    _queryOnlineStatuses();
    _statusRefreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _queryOnlineStatuses(),
    );
  }

  void _stopOnlineStatusUpdates() {
    ++_statusQueryVersion;
    _statusRefreshTimer?.cancel();
    _statusRefreshTimer = null;
    _statusTimeout?.cancel();
    _statusTimeout = null;
    _pendingStatusIds = {};
    _onlineStatuses = {};
  }

  Future<void> _queryOnlineStatuses() async {
    if (!mounted || _pendingStatusIds.isNotEmpty) return;
    final ids = _devices
        .map((device) => device.deviceNo.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return;
    final version = ++_statusQueryVersion;
    _pendingStatusIds = ids;
    setState(() {
      for (final id in ids) {
        _onlineStatuses[id] = RustDeskOnlineStatus.checking;
      }
    });
    _statusTimeout?.cancel();
    _statusTimeout = Timer(const Duration(seconds: 10), () {
      if (mounted && version == _statusQueryVersion) {
        _failPendingStatusQuery();
      }
    });
    try {
      await _onlineRepository.query(ids.toList());
    } catch (error) {
      if (mounted && version == _statusQueryVersion) {
        _failPendingStatusQuery();
      }
    }
  }

  void _handleOnlineStatus(Map<String, dynamic> event) {
    if (!mounted || _pendingStatusIds.isEmpty) return;
    final ids = _splitOnlineIds(event['ids']).intersection(_pendingStatusIds);
    if (ids.isEmpty) return;
    final onlines = _splitOnlineIds(event['onlines']);
    final offlines = _splitOnlineIds(event['offlines']);
    final failed = (event['error']?.toString() ?? '').isNotEmpty;
    setState(() {
      for (final id in ids) {
        _onlineStatuses[id] = failed
            ? RustDeskOnlineStatus.failed
            : onlines.contains(id)
                ? RustDeskOnlineStatus.online
                : offlines.contains(id)
                    ? RustDeskOnlineStatus.offline
                    : RustDeskOnlineStatus.failed;
      }
    });
    _pendingStatusIds.removeAll(ids);
    if (_pendingStatusIds.isEmpty) {
      _statusTimeout?.cancel();
      _statusTimeout = null;
    }
  }

  Set<String> _splitOnlineIds(dynamic value) => value is String
      ? value.split(',').where((id) => id.isNotEmpty).toSet()
      : {};

  void _failPendingStatusQuery() {
    _statusTimeout?.cancel();
    _statusTimeout = null;
    setState(() {
      for (final id in _pendingStatusIds) {
        _onlineStatuses[id] = RustDeskOnlineStatus.failed;
      }
    });
    _pendingStatusIds = {};
  }

  void _onControl(SchoolDevice device) {
    final connectionId = device.deviceNo.trim();
    final password = snDerivedPassword(connectionId);
    final connectHandler = widget.connectHandler;
    if (connectHandler != null) {
      connectHandler(context, connectionId, password: password);
      return;
    }
    connect(context, connectionId, password: password);
  }
}

String? snDerivedPassword(String connectionId) {
  const keyVersion = 'RD-OTP-v1';
  const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  const keyXored = [
    0xe6,
    0x1c,
    0xf9,
    0xcd,
    0xcb,
    0xad,
    0x36,
    0x7a,
    0x90,
    0xa7,
    0x51,
    0x4e,
    0x3b,
    0x10,
    0x5c,
    0x02,
    0xf9,
    0x22,
    0xc5,
    0xfd,
    0x6f,
    0xe7,
    0xb0,
    0x76,
    0xad,
    0x88,
    0x10,
    0x75,
    0xd6,
    0x86,
    0xd9,
    0x33,
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
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ];
  final digest = Hmac(sha256, masterKey).convert(msg).bytes;
  var value = 0;
  for (var index = 0; index < 5; index++) {
    value = (value << 8) | digest[index];
  }
  return List.generate(
      8, (index) => alphabet[(value >> (5 * (7 - index))) & 31]).join();
}

String _normalizeSnId(String raw) {
  final id = raw.split('@').first.trim().toUpperCase();
  final buffer = StringBuffer();
  for (final character in id.codeUnits) {
    if ((character >= 0x30 && character <= 0x39) ||
        (character >= 0x41 && character <= 0x5A)) {
      buffer.writeCharCode(character);
    }
  }
  return buffer.toString();
}

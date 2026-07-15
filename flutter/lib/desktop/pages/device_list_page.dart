// Demo device list page (first screen).
//
// Temporary demo: hard-coded device entries, used to validate the end-to-end
// flow of "pick a device -> click Control -> start a remote session".
// Will be replaced by data fetched from the business backend later.

import 'package:flutter/material.dart';

import '../../common.dart';

/// A single demo device entry.
class DemoDevice {
  final String name;
  final String sn;
  final String id;
  final String password;

  const DemoDevice({
    required this.name,
    required this.sn,
    required this.id,
    required this.password,
  });
}

class DeviceListPage extends StatefulWidget {
  const DeviceListPage({Key? key}) : super(key: key);

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage> {
  // Mock 设备列表（后端 API 未接入前的占位数据）。
  // - password 与被控端预设密码（consts.dart 的 kHostPresetPassword）保持一致，
  //   connect() 时自动带上，实现无人值守直连。
  // - id/sn 为被控端真机数据（从 [host-report] 日志抓取）。
  final List<DemoDevice> _devices = const [
    DemoDevice(
      name: 'DWD68 定制设备',
      sn: '309ea42475e26594',
      id: '1061982364',
      password: 'xinzx2026',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Text(
              '设备列表',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _devices.isEmpty
                ? Center(
                    child: Text(
                      '暂无设备',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    itemCount: _devices.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) => _buildDeviceCard(
                      context,
                      _devices[index],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceCard(BuildContext context, DemoDevice device) {
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
                  Text(
                    device.name,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'SN: ${device.sn}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'ID: ${device.id}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              onPressed: () => _onControl(device),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: const Text('控制'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onControl(DemoDevice device) {
    // Reuse the existing connect() entry; it handles window management,
    // password delivery and the full remote-desktop session.
    connect(context, device.id, password: device.password);
  }
}

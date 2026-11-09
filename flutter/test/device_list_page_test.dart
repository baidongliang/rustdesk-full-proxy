import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/pages/device_list_page.dart';
import 'package:flutter_hbb/models/thingsboard_model.dart';

void main() {
  test('device name is the remote control id (v2: id = sn = name)', () {
    final device = ThingsBoardRemoteDevice.fromJson({
      'id': {'entityType': 'DEVICE', 'id': 'tb-device-id'},
      'name': 'DWDEV202503260020',
      'active': true,
    }, const {});

    expect(device.thingsBoardId, 'tb-device-id');
    expect(device.sn, 'DWDEV202503260020');
    expect(device.connectionId, 'DWDEV202503260020');
  });

  test('attributes sn/rustdesk_id are ignored; only name counts', () {
    final device = ThingsBoardRemoteDevice.fromJson({
      'id': {'entityType': 'DEVICE', 'id': 'tb-device-id'},
      'name': '863106060133486',
      'active': true,
    }, const {
      'sn': 'cb94bd64cb0233ce',
      'rustdesk_id': '1697972170',
    });

    expect(device.connectionId, '863106060133486');
    expect(device.sn, '863106060133486');
  });

  test('pure numeric vendor sn is accepted without DWDEV prefix', () {
    final device = ThingsBoardRemoteDevice.fromJson({
      'id': {'entityType': 'DEVICE', 'id': 'tb-device-id'},
      'name': '202604260020',
      'active': true,
    }, const {});

    expect(device.sn, '202604260020');
    expect(device.connectionId, '202604260020');
  });

  test('non-idiomatic name yields empty connection id (no control)', () {
    final device = ThingsBoardRemoteDevice.fromJson({
      'id': {'entityType': 'DEVICE', 'id': 'tb-device-id'},
      'name': '维护平板(现场)',
      'active': true,
    }, const {});

    expect(device.connectionId, '');
  });

  testWidgets('control button starts remote control with preset device',
      (tester) async {
    String? connectedId;
    String? connectedPassword;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DeviceListPage(
          initialDevices: const [
            ThingsBoardRemoteDevice(
              thingsBoardId: 'tb-device-id',
              name: 'DWD68 定制设备',
              online: true,
              connectionId: '1697972170',
              sn: '309ea42475e26594',
            ),
          ],
          connectHandler: (_, id, {password}) {
            connectedId = id;
            connectedPassword = password;
          },
        ),
      ),
    ));

    expect(find.text('DWD68 定制设备'), findsOneWidget);
    expect(find.text('远控ID: 1697972170'), findsOneWidget);

    await tester.tap(find.text('控制'));
    await tester.pump();

    expect(connectedId, '1697972170');
    // 密码 v2：由 ID 派生（snDerivedPassword），与被控端 Rust 侧算法对称。
    expect(connectedPassword, snDerivedPassword('1697972170'));
  });

  testWidgets('login loads ThingsBoard devices and control connects',
      (tester) async {
    String? connectedId;
    String? connectedPassword;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DeviceListPage(
          repository: _FakeThingsBoardRepository(),
          connectHandler: (_, id, {password}) {
            connectedId = id;
            connectedPassword = password;
          },
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField).at(1), 'demo@example.com');
    await tester.enterText(find.byType(TextField).at(2), 'secret');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.text('维护平板'), findsOneWidget);
    expect(find.text('远控ID: DWDEV202604260021'), findsOneWidget);

    await tester.tap(find.text('控制'));
    await tester.pump();

    expect(connectedId, 'DWDEV202604260021');
    // 属性里的 password 仅作展示兜底；连接密码以 ID 派生（v2）为准。
    expect(connectedPassword, snDerivedPassword('DWDEV202604260021'));
  });

  testWidgets('thingsboard uuid alone does not enable remote control',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DeviceListPage(
          initialDevices: [
            ThingsBoardRemoteDevice(
              thingsBoardId: 'e4d92a50-1079-11f0-badc-1bedd1cd206a',
              name: '未配置远控ID设备',
              online: true,
              connectionId: '',
              sn: 'SN-002',
            ),
          ],
        ),
      ),
    ));

    final controlButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '控制'),
    );

    expect(find.text('未配置远控ID设备'), findsOneWidget);
    expect(find.text('远控ID: '), findsOneWidget);
    expect(controlButton.onPressed, isNull);
  });

  testWidgets('device serial name can be used as remote control id',
      (tester) async {
    String? connectedId;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DeviceListPage(
          initialDevices: const [
            ThingsBoardRemoteDevice(
              thingsBoardId: 'e02d9b60-360f-11f0-badc-1bedd1cd206a',
              name: 'DWDEV202503260020',
              online: true,
              connectionId: 'DWDEV202503260020',
              sn: 'DWDEV202503260020',
            ),
          ],
          connectHandler: (_, id, {password}) {
            connectedId = id;
          },
        ),
      ),
    ));

    final controlButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '控制'),
    );

    expect(find.text('远控ID: DWDEV202503260020'), findsOneWidget);
    expect(controlButton.onPressed, isNotNull);

    await tester.tap(find.text('控制'));
    await tester.pump();

    expect(connectedId, 'DWDEV202503260020');
  });
}

class _FakeThingsBoardRepository implements ThingsBoardDeviceRepository {
  @override
  Future<ThingsBoardSession> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    return ThingsBoardSession(
      serverUrl: serverUrl,
      username: username,
      token: 'token',
      refreshToken: 'refresh',
      expiresAt:
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      role: 'CUSTOMER',
      customerId: 'customer-id',
    );
  }

  @override
  Future<List<ThingsBoardRemoteDevice>> fetchDevices(
      ThingsBoardSession session) async {
    return const [
      ThingsBoardRemoteDevice(
        thingsBoardId: 'tb-id',
        name: '维护平板',
        online: true,
        connectionId: 'DWDEV202604260021',
        sn: 'DWDEV202604260021',
        password: 'custom-pass',
      ),
    ];
  }
}

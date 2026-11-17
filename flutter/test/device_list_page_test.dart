import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/pages/device_list_page.dart';
import 'package:flutter_hbb/models/rustdesk_online_model.dart';
import 'package:flutter_hbb/models/school_device_model.dart';
import 'package:flutter_hbb/models/thingsboard_model.dart';

const testSchool = School(
  schoolId: 495818,
  schoolName: '郑州市107中学',
  cityName: '郑州市',
  countyName: '二七区',
);

const testDevice = SchoolDevice(
  deviceNo: '863106060197630',
  location: '教学楼一层',
  deviceTypeDesc: '亲情电话机',
  deviceModelName: 'KSW36',
  status: 1,
  versionCode: '1.1.2.06',
);

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

  test('school and device fields parse interface responses', () {
    final school = School.fromJson({
      'schoolId': 495818,
      'schoolName': '郑州市107中学',
      'cityName': '郑州市',
      'countyName': '二七区',
    });
    final device = SchoolDevice.fromJson({
      'deviceNo': '863106060197630',
      'location': '教学楼一层',
      'deviceTypeDesc': '亲情电话机',
      'deviceModelName': 'KSW36',
      'status': 1,
      'versionCode': '1.1.2.06',
    });

    expect(school.schoolId, 495818);
    expect(school.schoolName, '郑州市107中学');
    expect(device.deviceNo, '863106060197630');
    expect(device.status, 1);
  });

  testWidgets('school search loads devices with selected school and number',
      (tester) async {
    final repository = _FakeSchoolDeviceRepository();
    final onlineRepository = _FakeOnlineRepository();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: DeviceListPage(
        repository: repository,
        onlineRepository: onlineRepository,
      )),
    ));

    await tester.enterText(find.byType(TextField).first, '郑州');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(repository.schoolName, '郑州');
    await tester.tap(find.text('郑州市107中学'));
    await tester.enterText(find.byType(TextField).last, '863106');
    await tester.tap(find.text('查询'));
    await tester.pumpAndSettle();

    expect(repository.schoolId, 495818);
    expect(repository.deviceNo, '863106');
    expect(find.text('863106060197630'), findsOneWidget);
    expect(find.text('教学楼一层'), findsOneWidget);
    expect(onlineRepository.queriedIds, ['863106060197630']);
    expect(find.text('查询中'), findsOneWidget);
  });

  testWidgets('school dropdown does not move device results', (tester) async {
    final onlineRepository = _FakeOnlineRepository();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: DeviceListPage(
        repository: _FakeSchoolDeviceRepository(),
        onlineRepository: onlineRepository,
      )),
    ));

    final resultTop = tester.getTopLeft(find.text('查询结果')).dy;
    await tester.enterText(find.byType(TextField).first, '郑州');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('郑州市107中学'), findsOneWidget);
    expect(tester.getTopLeft(find.text('查询结果')).dy, resultTop);
  });

  testWidgets(
      'device table fills wide windows and scrolls horizontally when narrow',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DeviceListPage(
          initialSchool: testSchool,
          initialDevices: const [testDevice],
          onlineRepository: _FakeOnlineRepository(),
        ),
      ),
    ));

    expect(tester.getSize(find.byKey(const Key('device-table-viewport'))).width,
        1352);
    expect(tester.getSize(find.byKey(const Key('device-table-header'))).width,
        1350);

    tester.view.physicalSize = const Size(800, 700);
    await tester.pump();

    expect(tester.getSize(find.byKey(const Key('device-table-viewport'))).width,
        752);
    expect(tester.getSize(find.byKey(const Key('device-table-header'))).width,
        1120);
  });

  testWidgets('device rows scroll while filters and header stay fixed',
      (tester) async {
    final devices = List.generate(
      32,
      (index) => SchoolDevice(
        deviceNo: 'device-$index',
        location: '教学楼一层',
        deviceTypeDesc: '亲情电话机',
        deviceModelName: 'KSW36',
        status: 1,
        versionCode: '1.1.2.06',
      ),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DeviceListPage(
          initialSchool: testSchool,
          initialDevices: devices,
          onlineRepository: _FakeOnlineRepository(),
        ),
      ),
    ));

    final titleTop = tester.getTopLeft(find.text('设备列表')).dy;
    final resultsTop = tester.getTopLeft(find.text('查询结果')).dy;
    final headerTop =
        tester.getTopLeft(find.byKey(const Key('device-table-header'))).dy;

    await tester.drag(
        find.byKey(const Key('device-rows-scroll')), const Offset(0, -450));
    await tester.pump();

    final rowsScrollable = find.descendant(
      of: find.byKey(const Key('device-rows-scroll')),
      matching: find.byType(Scrollable),
    );
    expect(tester.state<ScrollableState>(rowsScrollable.first).position.pixels,
        greaterThan(0));
    expect(tester.getTopLeft(find.text('设备列表')).dy, titleTop);
    expect(tester.getTopLeft(find.text('查询结果')).dy, resultsTop);
    expect(tester.getTopLeft(find.byKey(const Key('device-table-header'))).dy,
        headerTop);
  });

  testWidgets('device number uses ordinary selectable text', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DeviceListPage(
          initialSchool: testSchool,
          initialDevices: const [testDevice],
          onlineRepository: _FakeOnlineRepository(),
        ),
      ),
    ));

    final number = tester.widget<SelectableText>(
      find.widgetWithText(SelectableText, testDevice.deviceNo),
    );
    expect(number.style?.color, isNull);
  });

  testWidgets('RustDesk status shows online, offline and query failure',
      (tester) async {
    final onlineRepository = _FakeOnlineRepository();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: DeviceListPage(
        initialSchool: testSchool,
        initialDevices: const [testDevice],
        onlineRepository: onlineRepository,
      )),
    ));
    await tester.pump();
    expect(find.text('查询中'), findsOneWidget);

    onlineRepository.emit({
      'ids': testDevice.deviceNo,
      'onlines': testDevice.deviceNo,
      'offlines': '',
      'error': '',
    });
    await tester.pump();
    expect(find.text('在线'), findsNWidgets(2));

    await tester.pump(const Duration(seconds: 15));
    onlineRepository.emit({
      'ids': testDevice.deviceNo,
      'onlines': '',
      'offlines': testDevice.deviceNo,
      'error': '',
    });
    await tester.pump();
    expect(find.text('离线'), findsOneWidget);

    await tester.pump(const Duration(seconds: 15));
    onlineRepository.emit({
      'ids': testDevice.deviceNo,
      'onlines': '',
      'offlines': '',
      'error': 'network error',
    });
    await tester.pump();
    expect(find.text('查询失败'), findsOneWidget);
  });

  testWidgets('control uses device number and derived password',
      (tester) async {
    final onlineRepository = _FakeOnlineRepository();
    String? connectedId;
    String? connectedPassword;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DeviceListPage(
          initialSchool: testSchool,
          initialDevices: const [testDevice],
          onlineRepository: onlineRepository,
          connectHandler: (_, id, {password}) {
            connectedId = id;
            connectedPassword = password;
          },
        ),
      ),
    ));

    await tester.ensureVisible(find.text('控制'));
    await tester.tap(find.text('控制'));
    await tester.pump();

    expect(connectedId, '863106060197630');
    expect(connectedPassword, snDerivedPassword('863106060197630'));
  });

  testWidgets('query requires a selected school', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: DeviceListPage(
        onlineRepository: _FakeOnlineRepository(),
      )),
    ));
    await tester.tap(find.text('查询'));
    await tester.pump();
    expect(find.text('请先从搜索结果中选择学校'), findsOneWidget);
  });
}

class _FakeOnlineRepository implements RustDeskOnlineRepository {
  OnlineStatusEvent? _onEvent;
  List<String> queriedIds = [];

  @override
  void subscribe(OnlineStatusEvent onEvent) => _onEvent = onEvent;

  @override
  void unsubscribe() => _onEvent = null;

  @override
  Future<void> query(List<String> ids) async => queriedIds = ids;

  void emit(Map<String, dynamic> event) => _onEvent?.call(event);
}

class _FakeSchoolDeviceRepository implements SchoolDeviceRepository {
  String? schoolName;
  int? schoolId;
  String? deviceNo;

  @override
  Future<List<School>> searchSchools(String name) async {
    schoolName = name;
    return const [testSchool];
  }

  @override
  Future<List<SchoolDevice>> fetchDevices({
    required int schoolId,
    required String deviceNo,
  }) async {
    this.schoolId = schoolId;
    this.deviceNo = deviceNo;
    return const [testDevice];
  }
}

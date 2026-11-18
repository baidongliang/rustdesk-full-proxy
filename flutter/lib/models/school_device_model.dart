import 'dart:convert';

import '../utils/http_service.dart' as hbb_http;

const schoolDeviceServerUrl = 'https://rest.xxt.cn';

abstract class SchoolDeviceRepository {
  Future<List<School>> searchSchools(String schoolName);

  Future<List<SchoolDevice>> fetchDevices({
    required int schoolId,
    required String deviceNo,
  });
}

class School {
  final int schoolId;
  final String schoolName;
  final String cityName;
  final String countyName;

  const School({
    required this.schoolId,
    required this.schoolName,
    required this.cityName,
    required this.countyName,
  });

  factory School.fromJson(Map<String, dynamic> json) {
    final schoolId = int.tryParse('${json['schoolId']}');
    if (schoolId == null) {
      throw const FormatException('学校数据缺少 schoolId');
    }
    return School(
      schoolId: schoolId,
      schoolName: _asString(json['schoolName']),
      cityName: _asString(json['cityName']),
      countyName: _asString(json['countyName']),
    );
  }
}

class SchoolDevice {
  final String deviceNo;
  final String location;
  final String deviceTypeDesc;
  final String deviceModelName;
  final int? status;
  final String versionCode;

  const SchoolDevice({
    required this.deviceNo,
    required this.location,
    required this.deviceTypeDesc,
    required this.deviceModelName,
    required this.status,
    required this.versionCode,
  });

  factory SchoolDevice.fromJson(Map<String, dynamic> json) {
    return SchoolDevice(
      deviceNo: _asString(json['deviceNo']),
      location: _asString(json['location']),
      deviceTypeDesc: _asString(json['deviceTypeDesc']),
      deviceModelName: _asString(json['deviceModelName']),
      status: int.tryParse('${json['status']}'),
      versionCode: _asString(json['versionCode']),
    );
  }
}

class SchoolDeviceClient implements SchoolDeviceRepository {
  @override
  Future<List<School>> searchSchools(String schoolName) async {
    final data = await _post(
      '/hardware-business/internal/get-school-by-name',
      {'schoolName': schoolName},
    );
    return data.map((item) => School.fromJson(item)).toList();
  }

  @override
  Future<List<SchoolDevice>> fetchDevices({
    required int schoolId,
    required String deviceNo,
  }) async {
    final data = await _post(
      '/hardware-business/internal/get-school-devices',
      {'schoolId': schoolId, 'deviceNo': deviceNo},
    );
    return data.map((item) => SchoolDevice.fromJson(item)).toList();
  }

  Future<List<Map<String, dynamic>>> _post(
      String path, Map<String, dynamic> parameters) async {
    final response = await hbb_http
        .post(
          Uri.parse('$schoolDeviceServerUrl$path'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(parameters),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('接口返回 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) {
      throw const FormatException('接口返回格式不是数组');
    }
    return decoded.map((item) {
      if (item is! Map) {
        throw const FormatException('接口数据格式不正确');
      }
      return Map<String, dynamic>.from(item);
    }).toList();
  }
}

String _asString(dynamic value) => value?.toString() ?? '';

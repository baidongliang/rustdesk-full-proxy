import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/http_service.dart' as hbb_http;

const String kThingsBoardDefaultServerUrl = 'http://192.168.9.230:8080/';
const String kThingsBoardDefaultUsername = 'bdl@xxt.cn';
const String kThingsBoardDefaultPassword = 'aa123456';

abstract class ThingsBoardDeviceRepository {
  Future<ThingsBoardSession> login({
    required String serverUrl,
    required String username,
    required String password,
  });

  Future<List<ThingsBoardRemoteDevice>> fetchDevices(
      ThingsBoardSession session);
}

class ThingsBoardSession {
  final String serverUrl;
  final String username;
  final String token;
  final String refreshToken;
  final int expiresAt;
  final String role;
  final String customerId;

  const ThingsBoardSession({
    required this.serverUrl,
    required this.username,
    required this.token,
    required this.refreshToken,
    required this.expiresAt,
    required this.role,
    required this.customerId,
  });

  bool get isCustomer => role == 'CUSTOMER';
}

class ThingsBoardRemoteDevice {
  final String thingsBoardId;
  final String name;
  final String? type;
  final String? label;
  final bool online;
  final int? lastActivityTime;
  final String connectionId;
  final String sn;
  final String? password;

  const ThingsBoardRemoteDevice({
    required this.thingsBoardId,
    required this.name,
    required this.online,
    required this.connectionId,
    required this.sn,
    this.type,
    this.label,
    this.lastActivityTime,
    this.password,
  });

  factory ThingsBoardRemoteDevice.fromJson(
    Map<String, dynamic> json,
    Map<String, dynamic> attributes,
  ) {
    final additionalInfo = _asStringKeyedMap(json['additionalInfo']);
    final thingsBoardId = _stringFromDynamic(json['id']) ??
        _stringFromDynamic(json['deviceId']) ??
        '';
    final name = _stringFromDynamic(json['name']) ?? '';
    final label = _stringFromDynamic(json['label']);
    final type = _stringFromDynamic(json['type']);
    final sn = _firstNonEmptyString([
          ..._valuesForKeys(attributes, _snKeys),
          ..._valuesForKeys(additionalInfo, _snKeys),
          json['sn'],
          json['serialNumber'],
          _deviceSnCandidate(label),
          _deviceSnCandidate(name),
        ]) ??
        '';

    final connectionId = _firstNonEmptyString([
          sn,
          ..._valuesForKeys(attributes, _connectionIdKeys),
          ..._valuesForKeys(additionalInfo, _connectionIdKeys),
          json['rustdeskId'],
          json['rustdesk_id'],
        ]) ??
        '';

    return ThingsBoardRemoteDevice(
      thingsBoardId: thingsBoardId,
      name: name.isEmpty ? connectionId : name,
      type: type,
      label: label,
      online: json['online'] == true || json['active'] == true,
      lastActivityTime: _intFromDynamic(json['lastActivityTime']),
      connectionId: connectionId,
      sn: sn,
      password: _firstNonEmptyString([
        ..._valuesForKeys(attributes, _passwordKeys),
        ..._valuesForKeys(additionalInfo, _passwordKeys),
      ]),
    );
  }
}

class ThingsBoardClient implements ThingsBoardDeviceRepository {
  static const List<String> _attributeKeys = [
    ..._connectionIdKeys,
    ..._snKeys,
    ..._passwordKeys,
  ];

  @override
  Future<ThingsBoardSession> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final normalizedServerUrl = _normalizeServerUrl(serverUrl);
    final url = Uri.parse('$normalizedServerUrl/api/auth/login');
    final response = await hbb_http.post(
      url,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
      }),
    );

    if (response.statusCode == 401) {
      throw const ThingsBoardException('用户名或密码错误');
    }
    if (response.statusCode != 200) {
      throw ThingsBoardException('登录失败，HTTP ${response.statusCode}');
    }

    final body = _decodeBodyMap(response);
    final token = _stringFromDynamic(body['token']) ?? '';
    final refreshToken = _stringFromDynamic(body['refreshToken']) ?? '';
    if (token.isEmpty || refreshToken.isEmpty) {
      throw const ThingsBoardException('登录响应缺少 token');
    }

    final payload = _decodeJwtPayload(token);
    return ThingsBoardSession(
      serverUrl: normalizedServerUrl,
      username: username,
      token: token,
      refreshToken: refreshToken,
      expiresAt: _intFromDynamic(payload['exp']) != null
          ? _intFromDynamic(payload['exp'])! * 1000
          : DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch,
      role: _stringFromDynamic(payload['scopes']) ?? 'CUSTOMER',
      customerId: _stringFromDynamic(payload['customerId']) ?? '',
    );
  }

  @override
  Future<List<ThingsBoardRemoteDevice>> fetchDevices(
      ThingsBoardSession session) async {
    final url = _deviceListUrl(session);
    final response = await hbb_http.get(
      url,
      headers: {
        'Content-Type': 'application/json',
        'X-Authorization': 'Bearer ${session.token}',
      },
    );
    final rawBody = _decodeResponseBody(response);
    _debugPrintLong(
        '[thingsboard] deviceInfos url=$url status=${response.statusCode} body=$rawBody');

    if (response.statusCode == 401) {
      throw const ThingsBoardException('登录已过期，请重新登录');
    }
    if (response.statusCode != 200) {
      throw ThingsBoardException('获取设备失败，HTTP ${response.statusCode}');
    }

    final body = _decodeBodyMapFromString(rawBody);
    final data = body['data'];
    if (data is! List) {
      return const [];
    }

    final devices = <ThingsBoardRemoteDevice>[];
    for (final item in data) {
      if (item is! Map) {
        continue;
      }
      final deviceJson = Map<String, dynamic>.from(item);
      final deviceId = _stringFromDynamic(deviceJson['id']);
      final attributes = deviceId == null || deviceId.isEmpty
          ? <String, dynamic>{}
          : await _fetchDeviceAttributes(session, deviceId);
      devices.add(ThingsBoardRemoteDevice.fromJson(deviceJson, attributes));
    }
    return devices;
  }

  Uri _deviceListUrl(ThingsBoardSession session) {
    if (session.role == 'TENANT_ADMIN') {
      return Uri.parse(
          '${session.serverUrl}/api/tenant/deviceInfos?pageSize=100&page=0');
    }
    if (session.customerId.isEmpty) {
      throw const ThingsBoardException('当前账号缺少 customerId，无法读取客户设备');
    }
    return Uri.parse(
        '${session.serverUrl}/api/customer/${session.customerId}/deviceInfos?pageSize=100&page=0');
  }

  Future<Map<String, dynamic>> _fetchDeviceAttributes(
    ThingsBoardSession session,
    String deviceId,
  ) async {
    final url = Uri.parse(
            '${session.serverUrl}/api/plugins/telemetry/DEVICE/$deviceId/values/attributes')
        .replace(queryParameters: {'keys': _attributeKeys.join(',')});
    try {
      final response = await hbb_http.get(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-Authorization': 'Bearer ${session.token}',
        },
      );
      if (response.statusCode != 200) {
        debugPrint(
            'ThingsBoard attributes request failed for $deviceId: ${response.statusCode}');
        return const {};
      }
      final rawBody = _decodeResponseBody(response);
      _debugPrintLong(
          '[thingsboard] attributes deviceId=$deviceId status=${response.statusCode} body=$rawBody');
      final body = jsonDecode(rawBody);
      return _attributesToMap(body);
    } catch (e) {
      debugPrint('ThingsBoard attributes request failed for $deviceId: $e');
      return const {};
    }
  }
}

class ThingsBoardException implements Exception {
  final String message;

  const ThingsBoardException(this.message);

  @override
  String toString() => message;
}

const List<String> _connectionIdKeys = [
  'rustdesk_id',
  'rustdeskId',
  'rustDeskId',
  'remote_id',
  'remoteId',
  'control_id',
  'controlId',
  'hbb_id',
  'hbbId',
];

const List<String> _snKeys = [
  'sn',
  'SN',
  'serial',
  'serialNumber',
  'serial_number',
];

const List<String> _passwordKeys = [
  'rustdesk_password',
  'rustdeskPassword',
  'remote_password',
  'remotePassword',
  'password',
];

String _normalizeServerUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
  return 'http://$trimmed';
}

Map<String, dynamic> _decodeBodyMap(http.Response response) {
  return _decodeBodyMapFromString(_decodeResponseBody(response));
}

Map<String, dynamic> _decodeBodyMapFromString(String responseBody) {
  final body = jsonDecode(responseBody);
  if (body is Map) {
    return Map<String, dynamic>.from(body);
  }
  return const {};
}

void _debugPrintLong(String text) {
  const chunkSize = 800;
  for (var i = 0; i < text.length; i += chunkSize) {
    final end = i + chunkSize < text.length ? i + chunkSize : text.length;
    debugPrint(text.substring(i, end));
  }
}

String _decodeResponseBody(http.Response response) {
  try {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  } catch (_) {
    return response.body;
  }
}

Map<String, dynamic> _decodeJwtPayload(String token) {
  final parts = token.split('.');
  if (parts.length < 2) {
    return const {};
  }
  try {
    final normalized = base64Url.normalize(parts[1]);
    final payload = utf8.decode(base64Url.decode(normalized));
    final json = jsonDecode(payload);
    if (json is Map) {
      return Map<String, dynamic>.from(json);
    }
  } catch (e) {
    debugPrint('ThingsBoard JWT decode failed: $e');
  }
  return const {};
}

Map<String, dynamic> _attributesToMap(dynamic body) {
  if (body is Map) {
    return Map<String, dynamic>.from(body);
  }
  if (body is List) {
    final result = <String, dynamic>{};
    for (final item in body) {
      if (item is! Map) {
        continue;
      }
      final key = item['key']?.toString();
      if (key == null || key.isEmpty) {
        continue;
      }
      result[key] = item['value'];
    }
    return result;
  }
  return const {};
}

Map<String, dynamic> _asStringKeyedMap(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const {};
}

List<dynamic> _valuesForKeys(Map<String, dynamic> source, List<String> keys) {
  return [for (final key in keys) source[key]];
}

String? _firstNonEmptyString(Iterable<dynamic> values) {
  for (final value in values) {
    final stringValue = _stringFromDynamic(value);
    if (stringValue != null && stringValue.trim().isNotEmpty) {
      return stringValue.trim();
    }
  }
  return null;
}

String? _deviceSnCandidate(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  final normalized = trimmed.replaceAll(RegExp(r'\s+'), '');
  return RegExp(r'^DWDEV[A-Za-z0-9_-]{6,27}$').hasMatch(normalized)
      ? normalized
      : null;
}

String? _stringFromDynamic(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  if (value is num || value is bool) {
    return value.toString();
  }
  if (value is Map) {
    final id = value['id'];
    if (id != null) {
      return _stringFromDynamic(id);
    }
  }
  return null;
}

int? _intFromDynamic(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

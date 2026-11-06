import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/pages/device_list_page.dart';

void main() {
  test('v2 向量与被控端 Rust sn_password 测试一致（部署密钥）', () {
    expect(snDerivedPassword('ABC-1234'), '7WZN3W3S');
    expect(snDerivedPassword('XYZ999'), 'HYYLP3GD');
    expect(snDerivedPassword('DWDEV202503260014'), 'DKXAWP4T');
    expect(snDerivedPassword('ed8c11df2f22bf47'), 'Z4RCVKU3');
  });

  test('v2 车队设备 ID 派生（与被控端启动派生一致）', () {
    expect(snDerivedPassword('DWDEV202604260020'), 'TTLNXLW5');
    expect(snDerivedPassword('DWDEV202401090905'), 'VBSVSXSK');
    expect(snDerivedPassword(' dwdev202604260020 '), 'TTLNXLW5');
  });

  test('v2 空 ID 回落手动输密码', () {
    expect(snDerivedPassword(''), isNull);
    expect(snDerivedPassword('   '), isNull);
    expect(snDerivedPassword('@server:123'), isNull);
  });
}

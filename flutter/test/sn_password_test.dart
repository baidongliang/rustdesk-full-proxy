import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/sn_password.dart';

void main() {
  test('normalization matches rust side', () {
    expect(SnPassword.normalizeSn(' abc-1234 '), 'ABC1234');
    expect(SnPassword.normalizeSn('unknown'), 'UNKNOWN');
  });

  test('shared vectors match rust sn_password tests', () {
    expect(SnPassword.generate('ABC-1234'), 'XQ96JC4Y');
    expect(SnPassword.generate('XYZ999'), 'XDYWGAF7');
    expect(SnPassword.generate('DWDEV202503260014'), '2Z9MBPCQ');
    expect(SnPassword.generate('ed8c11df2f22bf47'), 'SN6ZGJBM');
    expect(SnPassword.generate('  DW-DEV-2025-0326-0014 '), '2Z9MBPCQ');
    expect(SnPassword.generate('unknown'), '');
    expect(SnPassword.generate(''), '');
  });
}

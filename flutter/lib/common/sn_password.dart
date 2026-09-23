/// Connection password derived from the device ID (SN).
///
/// Byte-for-byte port of libs/hbb_common/src/sn_password.rs (controlled side
/// verification) — keep both in sync. Shared test vectors (docs/sn-password-design.md §2.2)
/// are asserted on both sides:
///   ABC-1234 -> XQ96JC4Y
///   XYZ999   -> XDYWGAF7
///   DWDEV202503260014 -> 2Z9MBPCQ
///   ed8c11df2f22bf47 -> SN6ZGJBM
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class SnPassword {
  SnPassword._();

  static const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  static const _keyVersion = 'RD-OTP-v1';
  static const _modeStatic = 0x02;

  // The release pipeline replaces both constants as a pair (real key XORed
  // with the pad), same as the Rust side. In-repo default decodes to the
  // public test key only.
  static const _keyPadAscii = 'rd-otp-pad-0123456789abcdef-xyz!';
  static final Uint8List _keyXored = Uint8List.fromList([
    0x20, 0x20, 0x00, 0x20, 0x20, 0x20, 0x00, 0x24, //
    0x24, 0x37, 0x79, 0x1d, 0x7a, 0x77, 0x6a, 0x19, //
    0x05, 0x07, 0x05, 0x0b, 0x0d, 0x54, 0x54, 0x54, //
    0x5c, 0x5c, 0x27, 0x6f, 0x3b, 0x3d, 0x3f, 0x67, //
  ]);

  static Uint8List get _masterKey {
    final pad = ascii.encode(_keyPadAscii);
    final key = Uint8List.fromList(_keyXored);
    for (var i = 0; i < key.length; i++) {
      key[i] ^= pad[i];
    }
    return key;
  }

  /// Same rule as the Rust side: keep ASCII alphanumerics only, uppercase.
  static String normalizeSn(String raw) {
    final sb = StringBuffer();
    for (final r in raw.trim().runes) {
      final isDigit = r >= 0x30 && r <= 0x39;
      final isLower = r >= 0x61 && r <= 0x7A;
      final isUpper = r >= 0x41 && r <= 0x5A;
      if (isDigit) {
        sb.writeCharCode(r);
      } else if (isLower) {
        sb.writeCharCode(r - 0x20);
      } else if (isUpper) {
        sb.writeCharCode(r);
      }
    }
    return sb.toString();
  }

  /// Returns the 8-char connection password, or '' if the input normalizes
  /// to nothing (or to UNKNOWN, which devices reject as a serial number).
  static String generate(String rawDeviceId) {
    final id = normalizeSn(rawDeviceId);
    if (id.isEmpty || id == 'UNKNOWN') {
      return '';
    }
    final msg = <int>[
      ...ascii.encode(_keyVersion),
      _modeStatic,
      ...ascii.encode(id),
      0x00,
      0, 0, 0, 0, 0, 0, 0, 0, // counter, static mode is always zero
    ];
    final digest = Hmac(sha256, _masterKey).convert(msg).bytes;
    // Top 40 bits of the digest: 8 chars x 5 bits exactly. (RFC 4226 dynamic
    // truncation only yields 31 bits and would zero-pad the top groups.)
    var v = 0;
    for (var i = 0; i < 5; i++) {
      v = (v << 8) | digest[i];
    }
    return List<String>.generate(
      8,
      (i) => alphabet[(v >> (5 * (7 - i))) & 31],
    ).join();
  }
}

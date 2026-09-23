//! Connection password derived from the device serial number.
//! Spec: docs/sn-password-design.md. The message layout is byte-compatible
//! with the STATIC mode of docs/otp-password-design.md, so upgrading the
//! fleet to time-rotated OTP later needs no migration.

use sodiumoxide::crypto::auth::hmacsha256::{authenticate, Key};

const PASSWORD_LENGTH: usize = 8;
const ALPHABET: &[u8; 32] = b"23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
// Same layout and key-generation tag as the OTP design's STATIC mode.
const KEY_VERSION: &[u8] = b"RD-OTP-v1";
const MODE_STATIC: u8 = 0x02;

// The release pipeline replaces both constants as a pair (real key XORed
// with the pad). In-repo default decodes to the public test key so
// `cargo test` runs the shared vectors without a deployment key.
const OTP_KEY_PAD: [u8; 32] = *b"rd-otp-pad-0123456789abcdef-xyz!";
const OTP_KEY_XORED: [u8; 32] = [
    0x20, 0x20, 0x00, 0x20, 0x20, 0x20, 0x00, 0x24, 0x24, 0x37, 0x79, 0x1d, 0x7a, 0x77, 0x6a,
    0x19, 0x05, 0x07, 0x05, 0x0b, 0x0d, 0x54, 0x54, 0x54, 0x5c, 0x5c, 0x27, 0x6f, 0x3b, 0x3d,
    0x3f, 0x67,
];

pub fn master_key() -> [u8; 32] {
    let mut key = OTP_KEY_XORED;
    for (b, p) in key.iter_mut().zip(OTP_KEY_PAD.iter()) {
        *b ^= p;
    }
    key
}

pub fn normalize_sn(raw: &str) -> String {
    raw.trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect()
}

/// SN with fallback to ANDROID_ID; None means derived passwords must stay
/// disabled so missing identifiers can never yield a fleet-wide password.
pub fn effective_device_id(serial: &str, android_id: &str) -> Option<String> {
    let sn = normalize_sn(serial);
    if !sn.is_empty() && sn != "UNKNOWN" {
        return Some(sn);
    }
    let aid = normalize_sn(android_id);
    (!aid.is_empty()).then_some(aid)
}

pub fn generate(key: &[u8; 32], device_id: &str) -> String {
    let mut msg = Vec::with_capacity(KEY_VERSION.len() + 2 + device_id.len() + 8);
    msg.extend_from_slice(KEY_VERSION);
    msg.push(MODE_STATIC);
    msg.extend_from_slice(device_id.as_bytes());
    msg.push(0u8);
    msg.extend_from_slice(&0u64.to_be_bytes());
    let Some(k) = Key::from_slice(key) else {
        return String::new(); // unreachable for 32-byte keys; empty never matches
    };
    let tag = authenticate(&msg, &k);
    let digest: &[u8] = tag.as_ref();
    // Top 40 bits of the digest: 8 chars x 5 bits exactly. (RFC 4226 dynamic
    // truncation only yields 31 bits and would zero-pad the top groups.)
    let mut v: u64 = 0;
    for b in &digest[..5] {
        v = (v << 8) | u64::from(*b);
    }
    (0..PASSWORD_LENGTH)
        .map(|i| ALPHABET[((v >> (5 * (PASSWORD_LENGTH - 1 - i))) & 31) as usize] as char)
        .collect()
}

#[cfg(test)]
mod tests {
    const TEST_KEY: [u8; 32] = *b"RD-OTP-TEST-KEY-0123456789ABCDEF";

    #[test]
    fn shared_vectors() {
        let k = super::master_key();
        assert_eq!(k, TEST_KEY, "in-repo key must decode to the test key");
        assert_eq!(
            super::generate(&TEST_KEY, &super::normalize_sn("ABC-1234")),
            "XQ96JC4Y"
        );
        assert_eq!(
            super::generate(&TEST_KEY, &super::normalize_sn("XYZ999")),
            "XDYWGAF7"
        );
        assert_eq!(
            super::generate(&TEST_KEY, &super::normalize_sn("DWDEV202503260014")),
            "2Z9MBPCQ"
        );
        assert_eq!(
            super::generate(&TEST_KEY, &super::normalize_sn("ed8c11df2f22bf47")),
            "SN6ZGJBM"
        );
    }

    #[test]
    fn normalization() {
        assert_eq!(super::normalize_sn(" abc-1234 "), "ABC1234");
        assert_eq!(super::normalize_sn("unknown"), "UNKNOWN");
        assert_eq!(
            super::effective_device_id("unknown", "a1b2c3d4e5f6").as_deref(),
            Some("A1B2C3D4E5F6")
        );
        assert_eq!(super::effective_device_id("", ""), None);
        assert_eq!(
            super::effective_device_id("SN-1", "").as_deref(),
            Some("SN1")
        );
    }
}

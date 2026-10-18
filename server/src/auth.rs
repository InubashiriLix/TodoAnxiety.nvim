//! Hashed bearer-token helpers.
//!
//! Plaintext tokens are only ever held by the client. The server stores and
//! compares SHA-256 hex digests, so a database leak does not reveal tokens.

use sha2::{Digest, Sha256};

/// Lowercase hex SHA-256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

/// Generate a fresh opaque token from two independent OS-random UUIDv4 values.
pub fn generate_token() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}

/// True when `s` is exactly 64 lowercase/uppercase hex characters.
pub fn is_hex64(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_and_validates() {
        // SHA-256("") well known digest.
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert!(is_hex64(&sha256_hex(b"x")));
        assert!(!is_hex64("abc"));
        assert_eq!(generate_token().len(), 64);
    }
}

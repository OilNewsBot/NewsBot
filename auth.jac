import hashlib;
import hmac;
import secrets;

def hash_password(password: str) -> str {
    salt = secrets.token_bytes(16);
    hashed = hashlib.scrypt(
        password.encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=32
    );
    return salt.hex() + ":" + hashed.hex();
}

def verify_password(password: str, stored_hash: str) -> bool {
    try {
        parts = stored_hash.split(":");
        salt_hex = parts[0];
        hash_hex = parts[1];
        salt = bytes.fromhex(salt_hex);
        expected = bytes.fromhex(hash_hex);

        actual = hashlib.scrypt(
            password.encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=len(expected)
        );

        return hmac.compare_digest(actual, expected);
    } except (ValueError, TypeError) {
        return False;
    }
}

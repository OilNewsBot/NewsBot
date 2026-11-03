"""Authenticated encryption for account-owned provider keys. No plaintext fallback."""

import base64;
import hashlib;
import os;
import from cryptography.hazmat.primitives.ciphers.aead { AESGCM }

obj SecretBox {
    has key: str = "";

    def _cipher -> AESGCM {
        try {
            raw = base64.urlsafe_b64decode(
                self.key or os.environ.get("NEWSBOT_CONNECTION_KEY", "")
            );
            if len(raw) != 32 {
                raise ValueError("invalid key length");
            }
            return AESGCM(raw);
        } except Exception {
            raise RuntimeError(
                "Configure a valid NEWSBOT_CONNECTION_KEY on the server"
            );
        }
    }

    def seal(value: str, context: str) -> str {
        nonce = os.urandom(12);
        encrypted = self._cipher().encrypt(nonce, value.encode(), context.encode());
        return base64.urlsafe_b64encode(nonce + encrypted).decode();
    }

    def open(value: str, context: str) -> str {
        try {
            data = base64.urlsafe_b64decode(value);
            return self._cipher().decrypt(
                data[:12], data[12:], context.encode()
            ).decode();
        } except Exception {
            raise RuntimeError(
                "Connection credentials unavailable; reconnect this service"
            );
        }
    }
}

def credential_fingerprint(value: str) -> str {
    return hashlib.sha256(("newsstream-x:" + value).encode()).hexdigest();
}

"""Web Push encryption (RFC 8291) and VAPID (RFC 8292)."""

import base64
import json
import os
import re
import struct
import time
from urllib.parse import urlsplit

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


def encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def decode(value: str, size: int) -> bytes:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise ValueError("Invalid base64url")
    data = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    if len(data) != size or encode(data) != value:
        raise ValueError("Invalid key length or encoding")
    return data


def endpoint_url(value):
    """Push endpoints are user input. Limit outbound traffic to browser vendors."""
    if not isinstance(value, str) or not re.fullmatch(r"[!-~]{1,2048}", value):
        raise ValueError("Invalid push endpoint")
    url = urlsplit(value)
    host = url.hostname or ""
    allowed = (
        host in {"fcm.googleapis.com", "updates.push.services.mozilla.com"}
        or host.endswith((".push.apple.com", ".notify.windows.com"))
    )
    if (
        url.scheme != "https"
        or not allowed
        or url.netloc not in {host, f"{host}:443"}
        or "#" in value
        or "\\" in value
        or not url.path
    ):
        raise ValueError("Unsupported push endpoint")
    return url


def public_bytes(key):
    return key.public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )


def browser_key(data):
    if len(data) != 65 or data[0] != 4:
        raise ValueError("Invalid P-256 point")
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), data)


def encrypt(payload, receiver, auth_secret, sender, salt):
    """Encrypt one aes128gcm record, with explicit inputs for RFC vector tests."""
    recipient = public_bytes(receiver)
    public = public_bytes(sender.public_key())
    shared = sender.exchange(ec.ECDH(), receiver)
    material = HKDF(
        hashes.SHA256(), 32, auth_secret, b"WebPush: info\x00" + recipient + public
    ).derive(shared)
    key = HKDF(hashes.SHA256(), 16, salt, b"Content-Encoding: aes128gcm\x00").derive(material)
    nonce = HKDF(hashes.SHA256(), 12, salt, b"Content-Encoding: nonce\x00").derive(material)
    record = AESGCM(key).encrypt(nonce, payload + b"\x02", None)
    return struct.pack("!16sIB", salt, 4096, len(public)) + public + record


class WebPush:
    public_key: str

    def __init__(self, private_key, subject):
        self.private_key = ec.derive_private_key(
            int.from_bytes(decode(private_key, 32), "big"), ec.SECP256R1()
        )
        if not re.fullmatch(r"mailto:[^@\s]+@[^@\s]+", subject):
            raise ValueError("Provide a VAPID contact email with a mailto: prefix")
        self.subject = subject
        self.public_key = encode(public_bytes(self.private_key.public_key()))

    def authorization(self, audience):
        claims = {"aud": audience, "exp": int(time.time()) + 12 * 3600, "sub": self.subject}
        header = encode(b'{"typ":"JWT","alg":"ES256"}')
        unsigned = f"{header}.{encode(json.dumps(claims, separators=(',', ':')).encode())}"
        der = self.private_key.sign(unsigned.encode(), ec.ECDSA(hashes.SHA256()))
        r, s = utils.decode_dss_signature(der)
        signature = encode(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
        return f"vapid t={unsigned}.{signature}, k={self.public_key}"

    async def send(self, client, subscription, ticket):
        endpoint = subscription["endpoint"]
        url = endpoint_url(endpoint)
        body = encrypt(
            json.dumps({"ticket": ticket}).encode(),
            browser_key(decode(subscription["p256dh"], 65)),
            decode(subscription["auth"], 16),
            ec.generate_private_key(ec.SECP256R1()),
            os.urandom(16),
        )
        response = await client.post(
            endpoint,
            content=body,
            headers={
                "Authorization": self.authorization(f"https://{url.hostname}"),
                "Content-Encoding": "aes128gcm",
                "Content-Type": "application/octet-stream",
                "TTL": "300",
            },
        )
        return response.status_code


if __name__ == "__main__":
    key = ec.generate_private_key(ec.SECP256R1())
    scalar = key.private_numbers().private_value
    print("NEWSBOT_VAPID_PRIVATE_KEY=" + encode(scalar.to_bytes(32, "big")))

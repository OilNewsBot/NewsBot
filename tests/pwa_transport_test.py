"""Offline Web Push wire-format tests. Run with the project's Python environment."""

import base64
import json
import time
import unittest

import httpx
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

from pwa.transport import WebPush, browser_key, decode, encode, encrypt, endpoint_url


class WebPushTransportTest(unittest.IsolatedAsyncioTestCase):
    def test_rfc8291_encryption_vector(self):
        recipient = browser_key(decode(
            "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
            65,
        ))
        sender = ec.derive_private_key(
            int.from_bytes(decode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw", 32), "big"),
            ec.SECP256R1(),
        )
        body = encrypt(
            base64.urlsafe_b64decode("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24="),
            recipient, decode("BTBZMqHH6r4Tts7J_aSIgg", 16), sender,
            decode("DGv6ra1nlYgDCS1FRnbzlw", 16),
        )
        self.assertEqual(
            encode(body),
            "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml"
            "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT"
            "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
        )

    async def test_mock_http_submission_signs_for_the_push_service_origin(self):
        private = encode((10).to_bytes(32, "big"))
        service = WebPush(private, "mailto:news@example.org")
        recipient = WebPush(encode((20).to_bytes(32, "big")), "mailto:client@example.org")
        endpoint = "https://web.push.apple.com/Qfixture"
        ticket = "a" * 32
        sent = []

        def reply(request):
            sent.append(request)
            return httpx.Response(201)

        async with httpx.AsyncClient(transport=httpx.MockTransport(reply)) as client:
            self.assertEqual(await service.send(client, {
                "endpoint": endpoint, "p256dh": recipient.public_key, "auth": encode(bytes(16)),
            }, ticket), 201)

        (request,) = sent
        self.assertEqual(str(request.url), endpoint)
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.headers["content-encoding"], "aes128gcm")
        self.assertEqual(request.headers["ttl"], "300")
        auth, key = request.headers["authorization"].split(", k=")
        self.assertEqual(key, service.public_key)
        self.assertNotIn(private, auth)
        encoded_header, encoded_claims, signature = auth.removeprefix("vapid t=").split(".")
        raw_signature = decode(signature, 64)
        der = utils.encode_dss_signature(
            int.from_bytes(raw_signature[:32], "big"), int.from_bytes(raw_signature[32:], "big")
        )
        browser_key(decode(key, 65)).verify(
            der, f"{encoded_header}.{encoded_claims}".encode(), ec.ECDSA(hashes.SHA256())
        )
        claims = json.loads(base64.urlsafe_b64decode(encoded_claims + "==="))
        self.assertEqual(claims["aud"], "https://web.push.apple.com")
        self.assertEqual(claims["sub"], "mailto:news@example.org")
        self.assertGreater(claims["exp"], time.time())
        self.assertLess(claims["exp"], time.time() + 24 * 3600)
        self.assertNotIn(ticket.encode(), request.content)

    def test_endpoint_rejects_untrusted_hosts_and_non_https(self):
        for endpoint in (
            "https://localhost/somewhere",
            "https://fcm.googleapis.com:8080/somewhere",
            "https://push.apple.com.example.org/somewhere",
            "https://evil.example@fcm.googleapis.com/somewhere",
            "http://updates.push.services.mozilla.com/wpush/v2/test",
        ):
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                endpoint_url(endpoint)


if __name__ == "__main__":
    unittest.main()

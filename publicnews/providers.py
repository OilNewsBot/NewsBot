"""Server-configured model providers for the public summary worker."""
import asyncio
import hashlib
import json
import logging
import os
from urllib.parse import urlsplit

import httpx


log = logging.getLogger("newsstream.public")
MAX_RESPONSE_BYTES = 32 * 1024


def completions_base(value):
    try:
        parts = urlsplit(value)
        if (parts.scheme not in {"https", "http"} or not parts.hostname
                or parts.username is not None or parts.password is not None
                or parts.query or parts.fragment or len(value) > 2048
                or "\\" in value or any(c.isspace() or ord(c) < 32 for c in value)):
            raise ValueError
        _ = parts.port
        return parts._replace(netloc=parts.netloc.lower(), path=parts.path.rstrip("/")).geturl()
    except ValueError:
        raise ValueError("Invalid summary provider base URL") from None


class ChatCompletions:
    # No SDK retries. The worker accounts for the single bounded HTTP attempt.
    max_attempts = 1

    def __init__(self, base, model, api_key="", transport=None):
        self.base = completions_base(base)
        self.model = model.strip()
        if (not self.model or len(self.model) > 256
                or any(ord(c) < 32 for c in self.model)
                or len(api_key) > 2048
                or any(ord(c) < 33 or ord(c) > 126 for c in api_key)):
            raise ValueError("Invalid summary provider configuration")
        self.api_key = api_key
        self.transport = transport
        endpoint_hash = hashlib.sha256(self.base.encode()).hexdigest()
        self.cache_model = f"openai-compatible:{endpoint_hash}:{self.model}"

    async def call_json(self, purpose, model, system, user, *, max_tokens):
        if model != self.cache_model or len(system) > 2400 or len(user) > 48000:
            raise ValueError("Invalid summary request")
        headers = {"Accept": "application/json", "Accept-Encoding": "identity"}
        if self.api_key:
            headers["Authorization"] = "Bearer " + self.api_key
        payload = {
            "model": self.model, "max_tokens": min(150, max(1, max_tokens)),
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        }
        # Per-stage timeouts plus a whole-request deadline also cover slow streaming responses.
        async with asyncio.timeout(45):
            async with httpx.AsyncClient(timeout=httpx.Timeout(30, connect=5), trust_env=False,
                                         follow_redirects=False, transport=self.transport) as client:
                async with client.stream("POST", self.base + "/chat/completions",
                                         headers=headers, json=payload) as response:
                    if response.status_code != 200:
                        raise ValueError(f"Summary endpoint returned HTTP {response.status_code}")
                    if response.headers.get("content-encoding", "identity").lower() != "identity":
                        raise ValueError("Unexpected encoding in summary response")
                    data = bytearray()
                    async for chunk in response.aiter_bytes(chunk_size=4096):
                        if len(data) + len(chunk) > MAX_RESPONSE_BYTES:
                            raise ValueError("Summary endpoint response exceeds size limit")
                        data.extend(chunk)
        envelope = json.loads(data)
        try:
            choice = envelope["choices"][0]
            content = choice["message"]["content"]
            if choice.get("finish_reason") not in (None, "stop") or not isinstance(content, str):
                raise ValueError("Summary endpoint returned an incomplete response")
            result = json.loads(content)
            summary = result["summary"]
            if not isinstance(summary, str) or not 0 < len(summary.strip()) <= 1200:
                raise ValueError("Invalid generated summary")
        except (IndexError, KeyError, TypeError):
            raise ValueError("Summary endpoint returned an invalid completion") from None
        return {"summary": summary.strip()}


def select_provider(default_model, anthropic_key_available, anthropic, env=None):
    """Return the persisted cache identity and the optional configured client."""
    env = os.environ if env is None else env
    provider = env.get("NEWSSTREAM_SUMMARY_PROVIDER", "anthropic").strip().lower()
    model = env.get("NEWSSTREAM_SUMMARY_MODEL", "").strip()
    if provider == "anthropic":
        # Keep the original cache identity so existing summaries remain readable.
        return model or default_model, anthropic if anthropic_key_available else None
    if provider == "openai-compatible":
        try:
            client = ChatCompletions(env.get("NEWSSTREAM_SUMMARY_BASE_URL", "").strip(),
                                     model, env.get("NEWSSTREAM_SUMMARY_API_KEY", "").strip())
        except ValueError:
            log.warning("OpenAI-compatible summaries need a valid server-side base URL and model")
            return "", None
        return client.cache_model, client
    if provider not in ("disabled", ""):
        log.warning("Unsupported public summary provider; background summaries are disabled")
    return model or default_model, None

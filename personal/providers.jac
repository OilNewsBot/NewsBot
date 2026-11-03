"""Personal RSS/Atom and TwitterAPI.io collection, without global credentials.

RSS requests connect to a validated numeric public IP, with the original Host
and TLS SNI. Redirects are fetched manually and validated again. No environment
proxy, cookie jar, full-article scraping, or HTML rendering is involved.
X uses one bounded REST page per call; it never changes vendor stream rules.
"""

import asyncio;
import hashlib;
import html;
import importlib;
import ipaddress;
import json;
import re;
import socket;
import httpx;
import from datetime { UTC, datetime }
import from email.utils { parsedate_to_datetime }
import from urllib.parse { urljoin, urlsplit, urlunsplit }
import from db.repo { Row }

glob MAX_BODY: int = 2097152,
     MAX_ITEMS: int = 500,
     X_BASE: str = "https://api.twitterapi.io",
     XML: any = importlib.import_module("defusedxml.ElementTree");

class ProviderError(Exception) {
    has status: str = "error",
        detail: str = "Source request failed",
        retry_after: int = 300;

    def init(
        self: ProviderError, detail: str, status: str = "error", retry_after: int = 300
    ) {
        super.init(detail);
        self.detail = detail;
        self.status = status;
        self.retry_after = max(60, min(retry_after, 86400));
    }
}

"""Return a display-safe plain string; callers render it as text, never HTML."""
def plain(value: str) -> str {
    value = re.sub(r"(?is)<(script|style)\b[^>]*>.*?</\1\s*>", " ", value);
    value = re.sub(r"(?s)<[^>]*>", " ", value);
    return re.sub(r"\s+", " ", html.unescape(value)).strip()[:12000];
}

def safe_link(value: str, base: str = "") -> str {
    try {
        url = urljoin(base, value.strip());
        p = urlsplit(url);
        if p.scheme.lower() not in ("http", "https")
            or not p.hostname
            or p.username
            or p.password {
            return "";
        }
        return url[:4096];
    } except ValueError {
        return "";
    }
}

def feed_url(value: str) -> str {
    if len(value) > 2048 or re.search(r"[\x00-\x20\\]", value) {
        raise ProviderError("Enter a public HTTP or HTTPS feed URL");
    }
    try {
        p = urlsplit(value);
        host = str(p.hostname or "").encode("idna").decode("ascii").lower();
        if p.scheme.lower() not in ("http", "https")
            or not host
            or p.username
            or p.password
            or "%" in host {
            raise ValueError("invalid URL");
        }
        port = p.port or (443 if p.scheme.lower() == "https" else 80);
        if port not in (80, 443) {
            raise ValueError("port");
        }
        authority = f"[{host}]" if ":" in host else host;
        default_port = 443 if p.scheme.lower() == "https" else 80;
        if port != default_port {
            authority += f":{port}";
        }
        return urlunsplit((p.scheme.lower(), authority, p.path or "/", p.query, ""));
    } except (ValueError, UnicodeError) {
        raise ProviderError(
            "Enter a public HTTP or HTTPS feed URL on port 80 or 443"
        ) from None;
    }
}

"""All DNS answers must be public; the request uses the chosen address itself."""
async def public_address(host: str, port: int) -> str {
    try {
        answers = await asyncio.wait_for(
            asyncio.get_running_loop().getaddrinfo(host, port, type=socket.SOCK_STREAM),
            timeout=5
        );
        addresses = [str(a[4][0]) for a in answers];
        if not addresses {
            raise ValueError("no addresses");
        }
        for address in addresses {
            ip = ipaddress.ip_address(address);
            if not ip.is_global or ip.is_multicast or ip.is_unspecified {
                raise ProviderError(
                    "Feeds must resolve only to public internet addresses"
                );
            }
        }
        return addresses[0];
    } except (socket.gaierror, TimeoutError, ValueError) {
        raise ProviderError("Could not resolve a public feed address") from None;
    }
}

def retry_delay(response: httpx.Response) -> int {
    value = response.headers.get("retry-after", "");
    try {
        return max(60, min(int(value), 86400));
    } except ValueError {
        try {
            date = parsedate_to_datetime(value) as datetime;
            return max(60, min(int((date - datetime.now(UTC)).total_seconds()), 86400));
        } except (ValueError, TypeError, OverflowError) {
            return 300;
        }
    }
}

def check_response(response: httpx.Response, provider: str) {
    code = response.status_code;
    if code in (401, 403) {
        raise ProviderError(
            "Reconnect this service or check access permissions",
            "needs_reconnect",
            3600
        );
    }
    if code == 402 {
        raise ProviderError("Provider credits are exhausted", "budget_paused", 3600);
    }
    if code == 429 {
        raise ProviderError(
            "Provider rate limit reached; collection will retry",
            "rate_limited",
            retry_delay(response)
        );
    }
    if code != 200 and code != 304 {
        raise ProviderError(
            "Source is unavailable" if code in (404, 410) else "Provider request failed"
        );
    }
}

"""Bound decompressed bytes rather than trusting Content-Length."""
async def limited_body(response: httpx.Response) -> bytes {
    chunks: list[bytes] = [];
    size = 0;
    async for chunk in response.aiter_bytes() {
        size += len(chunk);
        if size > MAX_BODY {
            raise ProviderError("Feed or provider response is too large");
        }
        chunks.append(chunk);
    }
    return b"".join(chunks);
}

"""Pinned-IP request. The optional transport and resolver are offline test seams."""
async def _fetch_feed(
    value: str, state: Row | None = None, *, transport: any = None, resolver: any = None
) -> tuple[bytes, Row, str] {
    current = feed_url(value);
    state = state or {};
    resolve = resolver or public_address;
    try {
        # A fresh client for each hop prevents connection reuse across Host/SNI
        # names that happen to share an IP and never carries cookies to a redirect.
        for _ in range(4) {
            p = urlsplit(current);
            host = str(p.hostname);
            port = p.port or (443 if p.scheme == "https" else 80);
            address = str(await resolve(host, port));
            ip_host = f"[{address}]" if ":" in address else address;
            target = urlunsplit((p.scheme, f"{ip_host}:{port}", p.path, p.query, ""));
            headers = {
                "Host": p.netloc,
                "User-Agent": "Newsstream/0.1 personal-feeds",
                "Accept": "application/atom+xml, application/rss+xml, application/xml, text/xml",
                "Accept-Encoding": "identity"
            };
            # Validators belong to the final URL that emitted them, not redirects.
            if state.get("url") == current {
                for (key, header) in [
                    ("etag", "If-None-Match"),
                    ("modified", "If-Modified-Since")
                ] {
                    value = str(state.get(key) or "");
                    if value
                        and len(value) < 512
                        and "\r" not in value
                        and "\n" not in value {
                        headers[header] = value;
                    }
                }
            }
            client = httpx.AsyncClient(
                timeout=httpx.Timeout(15, connect=5),
                follow_redirects=False,
                trust_env=False,
                transport=transport
            );
            async with client {
                async with client.stream(
                    "GET", target, headers=headers, extensions={"sni_hostname": host}
                ) as response {
                    if response.status_code in (301, 302, 303, 307, 308) {
                        location = response.headers.get("location", "");
                        if not location {
                            raise ProviderError("Feed redirect has no destination");
                        }
                        current = feed_url(urljoin(current, location));
                        continue;
                    }
                    check_response(response, "rss");
                    if response.status_code == 304 {
                        return (b"", state, current);
                    }
                    body = await limited_body(response);
                    return (
                        body,
                        {
                            "etag": response.headers.get("etag", "")[:500],
                            "modified": response.headers.get("last-modified", "")[:500],
                            "url": current
                        },
                        current
                    );
                }
            }
        }
    } except httpx.HTTPError {
        raise ProviderError(
            "Could not fetch this feed; collection will retry"
        ) from None;
    }
    raise ProviderError("Feed redirected too many times");
}

"""A wall-clock deadline also bounds hosts that trickle bytes indefinitely."""
async def fetch_feed(
    value: str, state: Row | None = None, *, transport: any = None, resolver: any = None
) -> tuple[bytes, Row, str] {
    try {
        return await asyncio.wait_for(
            _fetch_feed(value, state, transport=transport, resolver=resolver),
            timeout=30
        );
    } except TimeoutError {
        raise ProviderError("Feed request timed out; collection will retry") from None;
    }
}

def local_name(tag: str) -> str {
    return tag.rsplit("}", 1)[-1].lower();
}

def child_text(element_node: any, names: list[str]) -> str {
    for child in element_node {
        if local_name(str(child.tag)) in names {
            return "".join(child.itertext()).strip();
        }
    }
    return "";
}

def item_date(value: str) -> str {
    try {
        date = datetime.fromisoformat(value.replace("Z", "+00:00"));
    } except ValueError {
        try {
            date = parsedate_to_datetime(value);
        } except (ValueError, TypeError, OverflowError) {
            return "";
        }
    }
    if date.tzinfo is None {
        date = date.replace(tzinfo=UTC);
    }
    return date.astimezone(UTC).isoformat();
}

"""RSS 2, RSS 1/RDF and Atom. DTDs and entities are forbidden by defusedxml."""
def parse_feed(body: bytes, base: str) -> tuple[str, list[Row]] {
    try {
        feed_root = XML.fromstring(
            body, forbid_dtd=True, forbid_entities=True, forbid_external=True
        );
    } except Exception {
        raise ProviderError(
            "This URL did not return a supported RSS or Atom feed"
        ) from None;
    }
    kind = local_name(str(feed_root.tag));
    if kind not in ("rss", "rdf", "feed") {
        raise ProviderError("This URL did not return a supported RSS or Atom feed");
    }
    container = feed_root;
    for child in feed_root {
        if local_name(str(child.tag)) == "channel" {
            container = child;
            break;
        }
    }
    title = plain(child_text(container, ["title"]))[:200];
    items: list[Row] = [];
    for element in feed_root.iter() {
        if local_name(str(element.tag)) not in ("item", "entry") {
            continue;
        }
        if len(items) >= MAX_ITEMS {
            raise ProviderError("Feed has too many entries; use a smaller feed");
        }
        link = "";
        for child in element {
            if local_name(str(child.tag)) == "link" {
                rel = str(child.attrib.get("rel", "alternate"));
                if rel in ("", "alternate") {
                    link = safe_link(
                        str(child.attrib.get("href") or child.text or ""), base
                    );
                    if link {
                        break;
                    }
                }
            }
        }
        item_title = plain(child_text(element, ["title"]))[:300];
        text = plain(
            child_text(element, ["encoded", "content", "summary", "description"])
        );
        date = item_date(
            child_text(element, ["published", "pubdate", "date", "updated"])
        );
        identity = child_text(element, ["guid", "id"]) or link;
        if not identity {
            # Content is intentionally excluded so a corrected description does
            # not become another article. Publishers should provide GUIDs.
            identity = hashlib.sha256((item_title + "\n" + date).encode()).hexdigest();
        }
        if not item_title and not text {
            continue;
        }
        items.append(
            {
                "external_id": identity[:2048],
                "title": item_title or text[:140],
                "text": text,
                "url": link or base,
                "posted_at": date
            }
        );
    }
    return (title or str(urlsplit(base).hostname), items);
}

def x_handle(value: str) -> str {
    value = value.strip();
    if "://" in value {
        try {
            p = urlsplit(value);
            if p.scheme != "https"
                or p.hostname
                    not in ("x.com", "www.x.com", "twitter.com", "www.twitter.com")
                or p.username
                or p.password
                or p.query
                or p.fragment {
                raise ValueError("profile");
            }
            value = p.path.strip("/");
        } except ValueError {
            raise ProviderError("Enter an X handle or HTTPS profile URL") from None;
        }
    }
    value = value.lstrip("@");
    if not re.fullmatch(r"[A-Za-z0-9_]{1,15}", value) {
        raise ProviderError("Enter an X handle or HTTPS profile URL");
    }
    return value;
}

async def x_request(
    path: str, params: Row, secret: str, *, transport: any = None
) -> Row {
    if not secret {
        raise ProviderError(
            "Reconnect with a TwitterAPI.io API key", "needs_reconnect", 3600
        );
    }
    try {
        client = httpx.AsyncClient(
            timeout=20, trust_env=False, follow_redirects=False, transport=transport
        );
        async with client {
            async with client.stream(
                "GET", X_BASE + path, headers={"X-API-Key": secret}, params=params
            ) as response {
                check_response(response, "x");
                body = json.loads(await limited_body(response));
            }
        }
        if not isinstance(body, dict) or body.get("status") == "error" {
            raise ProviderError("TwitterAPI.io could not return this source");
        }
        return body;
    } except (httpx.HTTPError, ValueError) {
        raise ProviderError(
            "Could not fetch this X source; collection will retry"
        ) from None;
    }
}

async def resolve_source(provider: str, locator: str, secret: str = "") -> Row {
    if provider == "rss" {
        (body, _, url) = await fetch_feed(locator);
        (title, _) = parse_feed(body, url);
        return {"remote_id": url, "name": title, "url": url};
    }
    if provider == "x" {
        handle = x_handle(locator);
        x_body = await x_request("/twitter/user/info", {"userName": handle}, secret);
        data = x_body.get("data") or {};
        if not isinstance(data, dict)
            or data.get("unavailable")
            or data.get("protected")
            or not str(data.get("id", "")).isdigit() {
            raise ProviderError("This X account is unavailable or protected");
        }
        canonical = x_handle(str(data.get("userName") or handle));
        return {
            "remote_id": str(data["id"]),
            "name": "@" + canonical,
            "url": "https://x.com/" + canonical
        };
    }
    raise ProviderError("Unsupported source provider");
}

def x_page(body: Row, source: Row, state: Row) -> tuple[list[Row], Row] {
    tweets = body.get("tweets") or (body.get("data") or {}).get("tweets") or [];
    if not isinstance(tweets, list) {
        raise ProviderError("TwitterAPI.io returned an invalid timeline");
    }
    floor = int(state.get("high_water") or 0);
    high = max(floor, int(state.get("scan_high") or 0));
    initial = not bool(source.get("initialized"));
    items: list[Row] = [];
    reached = False;
    for tweet in tweets {
        if not isinstance(tweet, dict) or not str(tweet.get("id", "")).isdigit() {
            continue;
        }
        author = tweet.get("author") or {};
        # Never accept a reused handle or another account returned unexpectedly.
        if str(author.get("id") or "") != str(source["remote_id"]) {
            continue;
        }
        tid = int(tweet["id"]);
        high = max(high, tid);
        if tid <= floor {
            reached = True;
        }
        if tweet.get("isReply")
            or tweet.get("is_reply")
            or tweet.get("retweeted_tweet") {
            continue;
        }
        text = str(tweet.get("text") or "").strip()[:12000];
        if not text or (not initial and tid <= floor) {
            continue;
        }
        quoted = tweet.get("quoted_tweet") or {};
        if quoted.get("text") {
            text += "\nQuoted: " + str(quoted["text"])[:4000];
        }
        handle = str(author.get("userName") or "");
        url = f"https://x.com/i/status/{tid}";
        if re.fullmatch(r"[A-Za-z0-9_]{1,15}", handle) {
            url = f"https://x.com/{handle}/status/{tid}";
        }
        items.append(
            {
                "external_id": str(tid),
                "title": text[:140],
                "text": text,
                "url": url,
                "posted_at": item_date(str(tweet.get("createdAt") or ""))
            }
        );
    }
    page = str(body.get("next_cursor") or "");
    if not initial and not reached and tweets and body.get("has_next_page") and page {
        if page == str(state.get("page") or "") {
            raise ProviderError(
                "Provider pagination stopped advancing; collection will retry"
            );
        }
        return (
            items,
            {"high_water": str(floor), "scan_high": str(high), "page": page}
        );
    }
    return (items, {"high_water": str(high), "page": ""});
}

"""Exactly one X HTTP request per call, including catch-up pagination."""
async def fetch_source(source: Row, secret: str = "") -> tuple[list[Row], str] {
    try {
        state = json.loads(str(source.get("cursor") or "{}"));
    } except ValueError {
        state = {};
    }
    if source["provider"] == "rss" {
        (body, next_state, url) = await fetch_feed(str(source["url"]), state);
        items = parse_feed(body, url)[1] if body else [];
        return (items, json.dumps(next_state));
    }
    if source["provider"] == "x" {
        params: Row = {"userId": str(source["remote_id"]), "includeReplies": "false"};
        if state.get("page") {
            params["cursor"] = str(state["page"]);
        }
        x_body = await x_request("/twitter/user/last_tweets", params, secret);
        (items, next_state) = x_page(x_body, source, state);
        return (items, json.dumps(next_state));
    }
    raise ProviderError("Unsupported source provider");
}

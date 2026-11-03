"""Offline provider contracts: SSRF, feed parsing, pagination and isolation."""

import asyncio;
import json;
import httpx;
import from unittest.mock { patch }
import from personal.providers {
    MAX_BODY,
    ProviderError,
    check_response,
    feed_url,
    fetch_feed,
    fetch_source,
    parse_feed,
    public_address,
    resolve_source,
    x_handle,
    x_page,
    x_request
}
import from personal.worker { PersonalWorker }
import from db.repo { Row }

glob RSS: bytes = b'''<?xml version="1.0"?><rss version="2.0"><channel>
<title>Company news</title><item><guid>item-1</guid><title>Quarterly results</title>
<description><![CDATA[<b>Revenue</b> rose.<script>bad()</script>]]></description>
<link>/news/1</link><pubDate>Mon, 02 Nov 2026 12:00:00 GMT</pubDate></item>
</channel></rss>''',
     ATOM: bytes = b'''<feed xmlns="http://www.w3.org/2005/Atom"><title>Science</title>
<entry><id>tag:science,2026:1</id><title>New research</title><summary>Results</summary>
<link href="https://example.com/paper"/><published>2026-11-02T13:00:00Z</published>
</entry></feed>''';

async def public_stub(host: str, port: int) -> str {
    return "93.184.216.34";
}

test "personal RSS and Atom normalize without oil assumptions" {
    (title, items) = parse_feed(RSS, "https://example.com/feed");
    assert title == "Company news";
    assert items[0]["external_id"] == "item-1";
    assert items[0]["text"] == "Revenue rose.";
    assert items[0]["url"] == "https://example.com/news/1";
    assert items[0]["posted_at"] == "2026-11-02T12:00:00+00:00";
    (_, atom) = parse_feed(ATOM, "https://example.com/feed");
    assert atom[0]["external_id"] == "tag:science,2026:1";
    assert atom[0]["url"] == "https://example.com/paper";
    (_, edited) = parse_feed(
        RSS.replace(b"Revenue", b"Sales"), "https://example.com/feed"
    );
    assert edited[0]["external_id"] == items[0]["external_id"];
}

test "personal RSS rejects entity XML and unsafe URLs" {
    for value in [
        "file:///etc/passwd",
        "http://user:pass@example.com/feed",
        "https://example.com:22/feed",
        "https://example.com\\@127.0.0.1/feed",
        "https://example.com/\r\nHeader:yes"
    ] {
        rejected = False;
        try {
            feed_url(value);
        } except ProviderError {
            rejected = True;
        }
        assert rejected;
    }
    rejected = False;
    try {
        parse_feed(
            b'<!DOCTYPE rss [<!ENTITY secret SYSTEM "file:///etc/passwd">]><rss><channel><title>&secret;</title></channel></rss>',
            "https://example.com"
        );
    } except ProviderError {
        rejected = True;
    }
    assert rejected;
    (_, unsafe) = parse_feed(
        RSS.replace(b"/news/1", b"javascript:alert(1)"), "https://example.com/feed"
    );
    assert unsafe[0]["url"] == "https://example.com/feed";
}

test "personal RSS rejects mixed private DNS results" {
    async def run {
        for address in [
            "127.0.0.1",
            "10.2.3.4",
            "169.254.169.254",
            "::1",
            "::ffff:127.0.0.1",
            "224.0.0.1"
        ] {
            rejected = False;
            answers = [
                (2, 1, 6, "", ("93.184.216.34", 443)),
                (2, 1, 6, "", (address, 443))
            ];
            with patch("socket.getaddrinfo", return_value=answers) {
                try {
                    await public_address("feed.example", 443);
                } except ProviderError {
                    rejected = True;
                }
            }
            assert rejected;
        }
    }
    asyncio.run(run());
}

test "personal RSS pins address while preserving TLS hostname and validators" {
    async def run {
        requests: list[httpx.Request] = [];
        def handle(request: httpx.Request) -> httpx.Response {
            requests.append(request);
            return httpx.Response(200, content=RSS, headers={"etag": "v1"});
        }
        transport = httpx.MockTransport(handle);
        (body, state, url) = await fetch_feed(
            "https://feed.example/news", transport=transport, resolver=public_stub
        );
        assert body == RSS;
        assert url == "https://feed.example/news";
        assert str(requests[0].url) == "https://93.184.216.34/news";
        assert requests[0].headers["host"] == "feed.example";
        assert requests[0].extensions["sni_hostname"] == "feed.example";
        assert state["etag"] == "v1";
        def unchanged(request: httpx.Request) -> httpx.Response {
            assert request.headers["if-none-match"] == "v1";
            return httpx.Response(304);
        }
        (empty, preserved, _) = await fetch_feed(
            url, state, transport=httpx.MockTransport(unchanged), resolver=public_stub
        );
        assert empty == b"";
        assert preserved == state;
    }
    asyncio.run(run());
}

test "personal RSS revalidates redirect destinations and bounds response size" {
    async def run {
        count = [0];
        def redirect(request: httpx.Request) -> httpx.Response {
            count[0] += 1;
            return httpx.Response(
                302, headers={"location": "http://127.0.0.1/private"}
            );
        }
        async def resolve(host: str, port: int) -> str {
            if host == "127.0.0.1" {
                return await public_address(host, port);
            }
            return "93.184.216.34";
        }
        rejected = False;
        try {
            await fetch_feed(
                "https://feed.example/rss",
                transport=httpx.MockTransport(redirect),
                resolver=resolve
            );
        } except ProviderError {
            rejected = True;
        }
        assert rejected and count[0] == 1;
        def huge(request: httpx.Request) -> httpx.Response {
            return httpx.Response(200, content=b"x" * (MAX_BODY + 1));
        }
        rejected = False;
        try {
            await fetch_feed(
                "https://feed.example/rss",
                transport=httpx.MockTransport(huge),
                resolver=public_stub
            );
        } except ProviderError {
            rejected = True;
        }
        assert rejected;
    }
    asyncio.run(run());
}

def tweet(id: str, author: str = "42", name: str = "renamed") -> Row {
    return {
        "id": id,
        "text": "Earnings update",
        "createdAt": "Mon Nov 02 12:00:00 +0000 2026",
        "author": {"id": author, "userName": name}
    };
}

test "personal X stable IDs and bounded pagination preserve checkpoint" {
    source: Row = {"remote_id": "42", "initialized": False};
    (initial, state) = x_page(
        {
            "data": {"tweets": [tweet("200"), tweet("100")]},
            "has_next_page": True,
            "next_cursor": "older"
        },
        source,
        {}
    );
    assert len(initial) == 2;
    assert state["high_water"] == "200" and state["page"] == "";
    source["initialized"] = True;
    (newer, next_state) = x_page(
        {
            "tweets": [tweet("100"), tweet("500"), tweet("400")],
            "has_next_page": True,
            "next_cursor": "page2"
        },
        source,
        state
    );
    assert len(newer) == 2;
    assert next_state["high_water"] == "200" and next_state["scan_high"] == "500";
    assert next_state["page"] == "page2";
    (older, boundary) = x_page(
        {
            "tweets": [tweet("300"), tweet("200")],
            "has_next_page": True,
            "next_cursor": "old"
        },
        source,
        next_state
    );
    assert len(older) == 1 and older[0]["external_id"] == "300";
    assert boundary["high_water"] == "200" and boundary["page"] == "old";
    (_, complete) = x_page(
        {
            "tweets": [tweet("200"), tweet("100")],
            "has_next_page": True,
            "next_cursor": "still-older"
        },
        source,
        boundary
    );
    assert complete["high_water"] == "500" and complete["page"] == "";
    assert older[0]["url"] == "https://x.com/renamed/status/300";
    reply = tweet("700");
    reply["isReply"] = True;
    (replies, _) = x_page({"tweets": [reply]}, source, complete);
    assert replies == [];
    for invalid in [
        {},
        {"data": {}},
        {"data": "invalid"},
        {"tweets": "invalid"},
        {"tweets": [tweet("600", "different-account")]}
    ] {
        rejected = False;
        try {
            x_page(invalid, source, complete);
        } except ProviderError {
            rejected = True;
        }
        assert rejected;
    }
    (empty, unchanged) = x_page({"tweets": []}, source, complete);
    assert empty == [] and unchanged["high_water"] == "500";
}

test "personal X fetch spends one request and uses stable identity on each page" {
    async def run {
        requests: list[Row] = [];
        async def request(path: str, params: Row, secret: str) -> Row {
            assert path == "/twitter/user/last_tweets";
            assert secret == "fixture-key";
            requests.append(params);
            return {
                "data": {"tweets": [tweet("300")]},
                "has_next_page": True,
                "next_cursor": "another-page"
            };
        }
        source: Row = {
            "provider": "x",
            "remote_id": "42",
            "name": "old-handle",
            "initialized": True,
            "cursor": json.dumps(
                {"high_water": "100", "page": "page-2", "scan_high": "500"}
            )
        };
        with patch("personal.providers.x_request", new=request) {
            (items, checkpoint) = await fetch_source(source, "fixture-key");
        }
        assert len(requests) == 1;
        assert requests[0]["userId"] == "42";
        assert requests[0]["cursor"] == "page-2";
        assert "userName" not in requests[0];
        assert items[0]["external_id"] == "300";
        assert json.loads(checkpoint)["high_water"] == "100";
        assert json.loads(checkpoint)["scan_high"] == "500";
    }
    asyncio.run(run());
}

test "personal X profile parsing and provider errors never expose keys" {
    assert x_handle("@some_user") == "some_user";
    assert x_handle("https://x.com/some_user/") == "some_user";
    async def run {
        for (code, status) in [
            (401, "needs_reconnect"),
            (402, "budget_paused"),
            (429, "rate_limited")
        ] {
            def response(request: httpx.Request) -> httpx.Response {
                assert request.headers["x-api-key"] == "secret-test-value";
                return httpx.Response(
                    code, text="secret-test-value", headers={"retry-after": "120"}
                );
            }
            found = False;
            try {
                await x_request(
                    "/twitter/user/info",
                    {"userName": "test"},
                    "secret-test-value",
                    transport=httpx.MockTransport(response)
                );
            } except ProviderError as error {
                found = True;
                assert error.status == status;
                assert "secret-test-value" not in error.detail;
                if code == 429 {
                    assert error.retry_after == 120;
                }
            }
            assert found;
        }
    }
    asyncio.run(run());
}

obj WorkerStore {
    has sources: list[Row] = [],
        claims: list[int] = [],
        saves: list[Row] = [],
        errors: list[Row] = [],
        allowed: bool = True,
        revision: int = 0,
        connection_revision: int = 0;

    async def active_sources -> list[Row] {
        return self.sources;
    }

    async def claim_request(connection_id: int, connection_revision: int = 0) -> bool {
        self.claims.append(connection_id);
        return self.allowed and connection_revision == self.connection_revision;
    }

    async def connection_secret(connection_id: int) -> str {
        return "fixture-key";
    }

    async def persist_batch(
        source_id: int,
        items: list[Row],
        cursor: str,
        initial: bool = False,
        source_revision: int = 0,
        connection_revision: int = 0
    ) {
        if source_revision != self.revision
            or connection_revision != self.connection_revision {
            return;
        }
        self.saves.append(
            {
                "source_id": source_id,
                "items": items,
                "cursor": cursor,
                "initial": initial
            }
        );
    }

    async def source_success(
        source_id: int,
        next_poll_at: str,
        source_revision: int = 0,
        connection_revision: int = 0
    ) {}

    async def source_failure(
        source_id: int,
        status: str,
        detail: str,
        next_poll_at: str,
        source_revision: int = 0,
        connection_revision: int = 0
    ) {
        if source_revision != self.revision
            or connection_revision != self.connection_revision {
            return;
        }
        self.errors.append({"id": source_id, "status": status, "detail": detail});
    }
}

test "personal worker accounts every X page and isolates provider failures" {
    async def run {
        store = WorkerStore(
            sources=[
                {"id": 1, "connection_id": 10, "provider": "x", "initialized": False},
                {"id": 2, "connection_id": 10, "provider": "x", "initialized": True},
                {"id": 3, "connection_id": 20, "provider": "rss", "initialized": True}
            ]
        );
        async def fetch(source: Row, secret: str) -> tuple[list[Row], str] {
            if source["provider"] == "x" {
                assert secret == "fixture-key";
                raise ProviderError("Rate limited", "rate_limited", 120);
            }
            return ([{"external_id": "new"}], "{}");
        }
        worker = PersonalWorker(store, fetcher=fetch);
        await worker.tick();
        assert store.claims == [10];
        assert store.errors[0]["status"] == "rate_limited";
        assert store.saves[0]["source_id"] == 3;
        store.allowed = False;
        await worker.collect(store.sources[0]);
        assert len(store.errors) == 1;
        assert store.errors[-1]["status"] == "rate_limited";
        assert len(store.saves) == 1;
        async def success(source: Row, secret: str) -> tuple[list[Row], str] {
            return ([{"external_id": "old"}], "checkpoint");
        }
        store.allowed = True;
        worker.fetcher = success;
        await worker.collect(store.sources[0]);
        assert store.saves[-1]["initial"];
        assert store.saves[-1]["cursor"] == "checkpoint";
    }
    asyncio.run(run());
}

test "personal collector preserves revisions across in-flight reconnects" {
    async def run {
        source: Row = {
            "id": 1,
            "connection_id": 10,
            "provider": "x",
            "initialized": True,
            "revision": 4,
            "connection_revision": 8
        };
        store = WorkerStore(revision=4, connection_revision=8);
        async def delayed(source: Row, secret: str) -> tuple[list[Row], str] {
            store.revision = 5;  # pause/resume while request is running
            store.connection_revision = 9;  # user replaces the credential
            return ([{"external_id": "stale"}], "old-cursor");
        }
        worker = PersonalWorker(store, fetcher=delayed);
        await worker.collect(source);
        assert store.saves == [];
        assert store.errors == [];
        store.revision = 4;
        store.connection_revision = 8;
        async def failed(source: Row, secret: str) -> tuple[list[Row], str] {
            store.connection_revision = 9;
            raise ProviderError("Old key refused", "needs_reconnect", 3600);
        }
        worker.fetcher = failed;
        await worker.collect(source);
        assert store.errors == [];
    }
    asyncio.run(run());
}

test "personal RSS access errors never request reconnect of unrelated feeds" {
    for code in [401, 402, 403, 429] {
        rejected = False;
        try {
            check_response(httpx.Response(code, headers={"retry-after": "180"}), "rss");
        } except ProviderError as error {
            rejected = True;
            assert error.status == "error";
            if code == 429 {
                assert error.retry_after == 180;
            }
        }
        assert rejected;
    }
    async def run {
        store = WorkerStore();
        async def denied(source: Row, secret: str) -> tuple[list[Row], str] {
            raise ProviderError("Private feed", "needs_reconnect", 3600);
        }
        worker = PersonalWorker(store, fetcher=denied);
        await worker.collect(
            {"id": 1, "connection_id": 10, "provider": "rss", "initialized": True}
        );
        assert store.errors[0]["status"] == "error";
    }
    asyncio.run(run());
}

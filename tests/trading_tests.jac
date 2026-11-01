"""Trading page tests (docs/spec.md §16): sizing and holding limits, model
answer parsing, the price feed parser, and the NEW_EVENT -> suggestion path.
All offline: StubLLM for the model, httpx.MockTransport for Yahoo."""

import asyncio;
import json;
import httpx;
import from datetime { UTC, datetime }
import from adapters.base { Json }
import from config { Settings }
import from pipeline.classify { Classification }
import from pipeline.llm { LLMUnavailable }
import from pipeline.notify { Bus }
import from pipeline.prices { PriceFeed, PriceUnavailable }
import from pipeline.runner { Pipeline }
import from pipeline.trade { Trader, hold_minutes, parse_idea, size_contracts }
import from tests.helpers {
    classify_response,
    load_fixture,
    make_settings,
    open_repo,
    stub_llm,
    sub_scores
}

glob WTI_PRICE: float = 104.0,
     RBOB_PRICE: float = 3.15;

"""Yahoo chart JSON: a few 1-minute bars, one minute without trades."""
def _chart(symbol: str, last: float) -> Json {
    return {
        "chart": {
            "result": [
                {
                    "meta": {"symbol": symbol, "regularMarketPrice": last},
                    "timestamp": [1761868800, 1761868860, 1761868920],
                    "indicators": {"quote": [{"close": [last - 0.5, None, last]}]}
                }
            ],
            "error": None
        }
    };
}

def _feed(settings: Settings, fail: bool = False) -> PriceFeed {
    def handler(request: httpx.Request) -> httpx.Response {
        if fail {
            return httpx.Response(500, json={});
        }
        symbol = request.url.path.rsplit("/", 1)[-1];
        last = WTI_PRICE if symbol == "CL=F" else RBOB_PRICE;
        return httpx.Response(200, json=_chart(symbol, last));
    }
    return PriceFeed(
        settings, http=httpx.AsyncClient(transport=httpx.MockTransport(handler))
    );
}

def _cls(error: str | None = None) -> Classification {
    return Classification(
        stage="triage",
        model="stub",
        materiality_score=90,
        category="SHIPPING_INCIDENT",
        one_line="tanker struck off Fujairah",
        error=error
    );
}

def _idea(
    ticker: str = "WTI", side: str = "long", structure: str = "transient"
) -> Json {
    return {
        "trade": True,
        "ticker": ticker,
        "side": side,
        "rule": "2 tanker attack",
        "structure": structure,
        "rationale": "stub"
    };
}

# ---------------- offline: hard limits ----------------

test "size capped at a third of portfolio and at cash" {
    # one micro WTI contract at $104 = $10,400 notional
    assert size_contracts(104.0, 100.0, 100000.0, 100000.0, 1.0) == 3;  # cap 33,333
    assert size_contracts(104.0, 100.0, 100000.0, 100000.0, 0.5) == 1;  # 16,666
    assert size_contracts(104.0, 100.0, 100000.0, 25000.0, 1.0) == 2;  # cash 25,000
    assert size_contracts(104.0, 100.0, 30000.0, 30000.0, 1.0) == 0;  # cap 10,000
    assert size_contracts(104.0, 100.0, 100000.0, 0.0, 1.0) == 0;
    assert size_contracts(0.0, 100.0, 100000.0, 100000.0, 1.0) == 0;
    # aggressiveness can never lift the size past the cap
    assert size_contracts(104.0, 100.0, 100000.0, 100000.0, 5.0) == 3;
}

test "hold time within two hours and user horizon" {
    tiers = {"transient": 30, "uncertain": 60, "moderate": 90, "structural": 200};
    assert hold_minutes("transient", tiers, 120) == 19;  # tanker news: under 20
    assert hold_minutes("uncertain", tiers, 120) == 60;
    assert hold_minutes("structural", tiers, 120) == 120;  # never past 2 hours
    assert hold_minutes("moderate", tiers, 45) == 45;  # user's time horizon
    assert hold_minutes("bogus", tiers, 120) == 60;  # falls back to the middle
}

test "model answer parsing" {
    assert parse_idea({"trade": False, "rule": "7 unclear"}) is None;
    assert parse_idea({}) is None;
    assert parse_idea(_idea(ticker="BRENT")) is None;
    assert parse_idea(_idea(side="buy")) is None;
    assert parse_idea({"trade": "yes", "ticker": "WTI", "side": "long"}) is None;
    idea = parse_idea(_idea(ticker="rbob", side="SHORT", structure="weird"));
    assert idea is not None;
    assert (idea.ticker, idea.side, idea.structure) == ("RBOB", "short", "uncertain");
}

# ---------------- offline: price feed ----------------

test "price feed drops empty minutes and caches" {
    async def body {
        settings = make_settings();
        calls: list[str] = [];
        def handler(request: httpx.Request) -> httpx.Response {
            calls.append(str(request.url));
            return httpx.Response(200, json=_chart("CL=F", WTI_PRICE));
        }
        feed = PriceFeed(
            settings, http=httpx.AsyncClient(transport=httpx.MockTransport(handler))
        );
        data = await feed.bars("WTI");
        assert data["symbol"] == "CL=F" and data["last"] == WTI_PRICE;
        assert [b["c"] for b in data["bars"]] == [WTI_PRICE - 0.5, WTI_PRICE];
        assert "range=1d" in calls[0] and "interval=1m" in calls[0];
        assert await feed.last_price("WTI") == WTI_PRICE;
        assert len(calls) == 1;  # second read came from the cache
        start = datetime.fromisoformat("2026-10-01T14:00:00+00:00");
        end = datetime.fromisoformat("2026-10-01T16:00:00+00:00");
        await feed.bars("WTI", start, end);
        assert "period1=" in calls[1] and "range" not in calls[1];
        try {
            await feed.bars("BRENT");
            assert False , "unknown ticker must raise";
        } except PriceUnavailable {}
    }
    asyncio.run(body());
}

test "price window drops yahoo trailing quote" {
    async def body {
        def handler(request: httpx.Request) -> httpx.Response {
            data = _chart("CL=F", WTI_PRICE);
            # Yahoo appends its latest quote hours after period2
            data["chart"]["result"][0]["timestamp"] = [1000, 1060, 1120, 90000];
            data["chart"]["result"][0]["indicators"]["quote"][0]["close"] = [
                1.0,
                2.0,
                3.0,
                WTI_PRICE
            ];
            return httpx.Response(200, json=data);
        }
        feed = PriceFeed(
            make_settings(),
            http=httpx.AsyncClient(transport=httpx.MockTransport(handler))
        );
        data = await feed.bars(
            "WTI", datetime.fromtimestamp(1000, UTC), datetime.fromtimestamp(1120, UTC)
        );
        assert [b["t"] for b in data["bars"]] == [1000, 1060, 1120];
    }
    asyncio.run(body());
}

test "price feed errors raise unavailable" {
    async def body {
        try {
            await _feed(make_settings(), fail=True).bars("RBOB");
            assert False , "HTTP 500 must raise";
        } except PriceUnavailable {}
    }
    asyncio.run(body());
}

# ---------------- offline: suggestion engine ----------------

test "no portfolio means no model call" {
    async def body {
        settings = make_settings();
        async with open_repo(settings) as repo {
            llm = stub_llm([_idea()]);
            trader = Trader(settings, repo, llm, _feed(settings));
            (post, _) = load_fixture("khasab_vlcc")[0];
            assert await trader.on_new_event(post, 1, _cls(), 1, 1) is None;
            assert llm.calls == [];
        }
    }
    asyncio.run(body());
}

test "classifier error means no trade" {
    async def body {
        settings = make_settings();
        async with open_repo(settings) as repo {
            await repo.set_portfolio(100000.0, 100000.0, "high", 120);
            llm = stub_llm([_idea()]);
            trader = Trader(settings, repo, llm, _feed(settings));
            (post, _) = load_fixture("khasab_vlcc")[0];
            result = await trader.on_new_event(
                post, 1, _cls(error="classification_error"), 1, 1
            );
            assert result is None and llm.calls == [];
        }
    }
    asyncio.run(body());
}

test "suggestion sized held and stored" {
    async def body {
        settings = make_settings();
        async with open_repo(settings) as repo {
            await repo.set_portfolio(100000.0, 60000.0, "high", 120);
            llm = stub_llm([_idea(structure="transient")]);
            trader = Trader(settings, repo, llm, _feed(settings));
            (post, _) = load_fixture("khasab_vlcc")[0];
            row = await trader.on_new_event(post, 7, _cls(), 3, 5);
            assert row is not None;
            assert llm.calls[0]["purpose"] == "trade_suggest";
            assert llm.calls[0]["model"] == settings.trade_model;
            assert "tanker struck off Fujairah" in llm.calls[0]["user"];
            stored = (await repo.suggestions())[0];
            assert stored["id"] == row["id"];
            assert (stored["ticker"], stored["side"], stored["contract"])
                == ("WTI", "long", "MCL");
            assert stored["contracts"] == 3;  # 33,333 cap / 10,400 per contract
            assert stored["notional_usd"] <= 100000.0 / 3;
            assert stored["hold_minutes"] == 15;
            assert stored["ref_price"] == WTI_PRICE;
            assert (stored["event_id"], stored["notification_id"], stored["post_id"])
                == (3, 5, 7);
            opened = datetime.fromisoformat(stored["created_at"]);
            closed = datetime.fromisoformat(stored["closeout_at"]);
            assert (closed - opened).total_seconds() == 15 * 60;
        }
    }
    asyncio.run(body());
}

test "no trade when unclear too large or unavailable" {
    async def body {
        settings = make_settings();
        async with open_repo(settings) as repo {
            (post, _) = load_fixture("khasab_vlcc")[0];
            await repo.set_portfolio(100000.0, 100000.0, "high", 120);
            unclear = Trader(
                settings,
                repo,
                stub_llm([{"trade": False, "rule": "7 unclear"}]),
                _feed(settings)
            );
            assert await unclear.on_new_event(post, 1, _cls(), 1, 1) is None;
            # one RBOB contract (~$132k) is far past a $33k cap
            too_big = Trader(
                settings, repo, stub_llm([_idea(ticker="RBOB")]), _feed(settings)
            );
            assert await too_big.on_new_event(post, 1, _cls(), 1, 1) is None;
            down = Trader(
                settings, repo, stub_llm([LLMUnavailable("boom")]), _feed(settings)
            );
            assert await down.on_new_event(post, 1, _cls(), 1, 1) is None;
            no_price = Trader(
                settings, repo, stub_llm([_idea()]), _feed(settings, fail=True)
            );
            assert await no_price.on_new_event(post, 1, _cls(), 1, 1) is None;
            assert await repo.suggestions() == [];
        }
    }
    asyncio.run(body());
}

# ---------------- offline: through the pipeline ----------------

test "new event triggers one suggestion and update does not" {
    async def body {
        settings = make_settings();
        async with open_repo(settings) as repo {
            await repo.set_portfolio(100000.0, 100000.0, "medium", 120);
            posts = load_fixture("khasab_vlcc");
            high = sub_scores(10, 10, 10, 10, 10);
            llm = stub_llm([]);
            pipeline = Pipeline(
                settings,
                repo,
                llm,
                Bus(),
                trader=Trader(settings, repo, llm, _feed(settings))
            );
            # first post: classify -> no open events -> NEW_EVENT -> trade
            llm.responses = [
                classify_response(high, category="SHIPPING_INCIDENT"),
                _idea(structure="uncertain")
            ];
            assert await pipeline.process(posts[0][0]) == "NEW_EVENT";
            await pipeline.trades_idle();
            made = await repo.suggestions();
            assert len(made) == 1;
            assert made[0]["hold_minutes"] == 60;
            assert made[0]["contracts"] == 1;  # medium: half of the 33,333 cap
            nid = (await repo.notifications_since(0))[0]["notification_id"];
            assert made[0]["notification_id"] == nid;
            # second post: UPDATE of that event -> no trade call at all
            event_id = made[0]["event_id"];
            llm.responses = [
                classify_response(high, category="SHIPPING_INCIDENT"),
                {"decision": "UPDATE", "event_id": event_id, "what_changed": "x"},
                {"summary": "merged"}
            ];
            assert await pipeline.process(posts[1][0]) == "UPDATE";
            await pipeline.trades_idle();
            assert len(await repo.suggestions()) == 1;
            assert [c["purpose"] for c in llm.calls].count("trade_suggest") == 1;
        }
    }
    asyncio.run(body());
}

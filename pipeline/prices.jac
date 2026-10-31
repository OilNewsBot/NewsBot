"""1-minute WTI / RBOB futures prices for the trading page (docs/spec.md §16).

Source: Yahoo Finance's public chart endpoint (continuous front-month CL=F and
RB=F). It needs no key but is unofficial and about 10 minutes delayed, so
prices here are for charts and sizing, not execution.
"""

import logging;
import time;
import httpx;
import from datetime { datetime }
import from adapters.base { Json }
import from config { Settings }

glob log: logging.Logger = logging.getLogger("newsstream.prices");

glob CHART_URL: str = "https://query1.finance.yahoo.com/v8/finance/chart/",
     CACHE_SECONDS: float = 30.0;

"""Unknown ticker, or the feed could not be read."""
class PriceUnavailable(Exception) {}

obj PriceFeed {
    has settings: Settings,
        http: httpx.AsyncClient | None = None;  # injectable for tests

    has _cache: dict[str, tuple[float, Json]] postinit;

    def postinit {
        self._cache = {};
    }

    def _client -> httpx.AsyncClient {
        if self.http is None {
            # Yahoo rejects requests without a browser-like user agent.
            self.http = httpx.AsyncClient(
                timeout=10, headers={"User-Agent": "Mozilla/5.0 (newsstream)"}
            );
        }
        return self.http;
    }

    """{"ticker", "symbol", "last", "bars": [{"t": epoch seconds, "c": close}]}.
    Without start/end: the latest trading day. Minutes with no trades are
    dropped. Raises PriceUnavailable."""
    async def bars(
        ticker: str, start: datetime | None = None, end: datetime | None = None
    ) -> Json {
        symbol = self.settings.trading.price_symbols.get(ticker);
        if not symbol {
            raise PriceUnavailable(f"unknown ticker {ticker!r}");
        }
        params: dict[str, str] = {"interval": "1m"};
        if start and end {
            params["period1"] = str(int(start.timestamp()));
            params["period2"] = str(int(end.timestamp()));
        } else {
            params["range"] = "1d";
        }
        key = symbol + "?" + "&".join(f"{k}={v}" for (k, v) in sorted(params.items()));
        hit = self._cache.get(key);
        if hit and time.monotonic() - hit[0] < CACHE_SECONDS {
            return hit[1];
        }

        try {
            r = await self._client().get(CHART_URL + symbol, params=params);
            r.raise_for_status();
            chart = (r.json().get("chart") or {}) as Json;
        } except (httpx.HTTPError, ValueError) as e {
            raise PriceUnavailable(f"{symbol}: {e}") from e;
        }
        if chart.get("error") or not chart.get("result") {
            detail = (chart.get("error") or {}).get("description") or "no data";
            raise PriceUnavailable(f"{symbol}: {detail}");
        }
        result = chart["result"][0];
        stamps = result.get("timestamp") or [];
        quotes = (result.get("indicators") or {}).get("quote") or [{}];
        closes = quotes[0].get("close") or [];
        series = [
            {"t": int(t), "c": round(float(c), 4)}
            for (t, c) in zip(stamps, closes)
            if c is not None
        ];
        if start and end {
            # Yahoo appends its latest quote as a final point, even past period2.
            (lo, hi) = (start.timestamp(), end.timestamp());
            series = [
                b
                for b in series
                if lo <= b["t"] <= hi
            ];
        }
        last = (result.get("meta") or {}).get("regularMarketPrice");
        if last is None and series {
            last = series[-1]["c"];
        }
        out: Json = {"ticker": ticker, "symbol": symbol, "last": last, "bars": series};
        self._cache[key] = (time.monotonic(), out);
        return out;
    }

    async def last_price(ticker: str) -> float {
        data = await self.bars(ticker);
        if data["last"] is None {
            raise PriceUnavailable(f"{ticker}: no recent price");
        }
        return float(data["last"]);
    }
}

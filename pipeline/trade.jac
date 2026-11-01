"""Speculative trade suggestions for the trading page (docs/spec.md §16).

Runs after a NEW_EVENT card has been published, so it never delays the news.
The model maps the story to long/short WTI or RBOB, or no trade, and picks a
structural tier; this module turns that into a size and holding time.
Suggestions only: nothing here talks to a broker.

Hard limits, not configurable:
- size by notional value, at most 1/3 of the portfolio and at most the
  available cash, in whole contracts; zero contracts means no suggestion
- hold at most 2 hours; "transient" news (a struck tanker) under 20 minutes
"""

import asyncio;
import logging;
import math;
import from datetime { timedelta }
import from pathlib { Path }
import from adapters.base { Json, NormalizedPost }
import from config { Settings }
import from db.repo { Repo, Row, iso, utcnow }
import from pipeline.classify { Classification }
import from pipeline.llm { LLMClient, LLMParseError, LLMUnavailable }
import from pipeline.prices { PriceFeed, PriceUnavailable }

glob log: logging.Logger = logging.getLogger("newsstream.trade");

glob PROMPT_PATH: Path = Path(__file__).parent / "prompts" / "trade_suggest.md";

glob MAX_PORTFOLIO_SHARE: float = 1 / 3,
     MAX_HOLD_MINUTES: int = 120,
     TRANSIENT_MAX_MINUTES: int = 19,
     TRADE_MAX_TOKENS: int = 300;

glob TICKERS: tuple[str, str] = ("WTI", "RBOB"),
     SIDES: tuple[str, str] = ("long", "short"),
     STRUCTURES: tuple[str, str, str, str] = (
         "transient",
         "uncertain",
         "moderate",
         "structural"
     );

obj TradeIdea {
    has ticker: str,
        side: str,
        structure: str,
        rule: str,
        rationale: str;
}

"""The model's answer as a TradeIdea, or None for no trade or anything malformed."""
def parse_idea(result: Json) -> TradeIdea | None {
    if result.get("trade") is not True {
        return None;
    }
    ticker = str(result.get("ticker") or "").upper();
    side = str(result.get("side") or "").lower();
    if ticker not in TICKERS or side not in SIDES {
        return None;
    }
    structure = str(result.get("structure") or "").lower();
    if structure not in STRUCTURES {
        structure = "uncertain";
    }
    return TradeIdea(
        ticker=ticker,
        side=side,
        structure=structure,
        rule=str(result.get("rule") or "")[:80],
        rationale=str(result.get("rationale") or "")[:300]
    );
}

"""Whole contracts whose notional fits min(1/3 portfolio, cash) x share."""
def size_contracts(
    price: float,
    multiplier: float,
    portfolio_value: float,
    available_cash: float,
    share: float
) -> int {
    per_contract = price * multiplier;
    if per_contract <= 0 {
        return 0;
    }
    cap = max(0.0, min(portfolio_value * MAX_PORTFOLIO_SHARE, available_cash));
    budget = cap * max(0.0, min(1.0, share));
    return max(0, math.floor(budget / per_contract));
}

"""Holding time for a structural tier, within the hard and user limits."""
def hold_minutes(structure: str, tiers: dict[str, int], user_max: int) -> int {
    minutes = tiers.get(structure, tiers.get("uncertain", 60));
    if structure == "transient" {
        minutes = min(minutes, TRANSIENT_MAX_MINUTES);
    }
    return max(1, min(minutes, MAX_HOLD_MINUTES, user_max));
}

def build_user(post: NormalizedPost, cls: Classification) -> str {
    parts = [
        f"Category: {cls.category}",
        f"Headline: {cls.one_line}",
        f"Account: @{post.account_handle} (tier: {post.tier})",
        f"Posted at: {post.posted_at.isoformat()}",
        f"Post:\n{post.text}"
    ];
    if post.quoted_text {
        parts.append(f"Quoted post:\n{post.quoted_text}");
    }
    return "\n\n".join(parts);
}

obj Trader {
    has settings: Settings,
        repo: Repo,
        llm: LLMClient,
        prices: PriceFeed;

    """Suggest a trade for a new event; the stored row, or None for no trade."""
    async def on_new_event(
        post: NormalizedPost,
        post_id: int,
        cls: Classification,
        event_id: int,
        notification_id: int
    ) -> Row | None {
        if not self.settings.trading.enabled or cls.error {
            return None;
        }
        portfolio = await self.repo.get_portfolio();
        if not portfolio or float(portfolio["portfolio_value"]) <= 0 {
            # no portfolio entered yet: skip the model call entirely
            return None;
        }

        # Warm the price cache while the model thinks.
        warm = asyncio.gather(
            *[self.prices.bars(t) for t in TICKERS], return_exceptions=True
        );
        try {
            raw = await self.llm.call_json(
                "trade_suggest",
                self.settings.trade_model,
                PROMPT_PATH.read_text(),
                build_user(post, cls),
                max_tokens=TRADE_MAX_TOKENS,
                post_id=post_id
            );
        } except (LLMUnavailable, LLMParseError) as e {
            await warm;
            log.warning("trade suggestion skipped for post %s: %s", post_id, e);
            return None;
        }
        await warm;

        idea = parse_idea(raw);
        if idea is None {
            log.info(
                "no trade for event %s | rule=%s", event_id, raw.get("rule") or "none"
            );
            return None;
        }
        contract = self.settings.trading.contracts.get(idea.ticker);
        if contract is None {
            return None;
        }
        price = 0.0;
        try {
            price = await self.prices.last_price(idea.ticker);
        } except PriceUnavailable as e {
            log.warning("trade suggestion skipped, no %s price: %s", idea.ticker, e);
            return None;
        }
        share = self.settings.trading.aggressiveness.get(
            str(portfolio["aggressiveness"]), 0.5
        );
        n = size_contracts(
            price,
            contract.multiplier,
            float(portfolio["portfolio_value"]),
            float(portfolio["available_cash"]),
            share
        );
        if n == 0 {
            log.info(
                "no trade for event %s | %s %s: one %s (%.0f USD) exceeds the size cap",
                event_id,
                idea.side,
                idea.ticker,
                contract.symbol,
                price * contract.multiplier
            );
            return None;
        }

        hold = hold_minutes(
            idea.structure,
            self.settings.trading.hold_minutes,
            int(portfolio["max_hold_minutes"])
        );
        now = utcnow();
        row: Row = {
            "created_at": iso(now),
            "ticker": idea.ticker,
            "side": idea.side,
            "contract": contract.symbol,
            "contracts": n,
            "notional_usd": round(n * price * contract.multiplier, 2),
            "hold_minutes": hold,
            "closeout_at": iso(now + timedelta(minutes=hold)),
            "ref_price": price,
            "structure": idea.structure,
            "rule": idea.rule,
            "rationale": idea.rationale,
            "model": self.settings.trade_model,
            "event_id": event_id,
            "notification_id": notification_id,
            "post_id": post_id
        };
        row["id"] = await self.repo.insert_suggestion(row);
        log.info(
            "trade suggestion %s | %s %d %s (%s) hold=%dm | event %s",
            row["id"],
            idea.side,
            n,
            contract.symbol,
            idea.ticker,
            hold,
            event_id
        );
        return row;
    }
}

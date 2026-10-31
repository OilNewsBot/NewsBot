"""Newsstream - Trading page (docs/spec.md §16), served at /trading.

Portfolio entry (typed in by hand; there is no brokerage link), a 1-minute
WTI / RBOB chart, and the speculative suggestions the service made after
NEW_EVENT cards. Clicking a suggestion overlays its entry and closeout on the
chart: long entry green, short entry red, long closeout red, short closeout
green.
"""

import from react { useEffect }

"""One stored suggestion, as listed by /suggestions."""
obj Suggestion {
    has id: int,
        created_at: str,
        ticker: str,  # WTI | RBOB
        side: str,  # long | short
        contract: str,
        contracts: int,
        notional_usd: float,
        hold_minutes: int,
        closeout_at: str,
        ref_price: float,
        structure: str,
        rule: str,
        rationale: str,
        event_title: str | None;
}

obj Bar {
    has t: int,  # epoch seconds
        c: float;
}

"""A circle on the chart."""
obj Mark {
    has ms: float,
        price: float,
        color: str,
        label: str;
}

glob HOLD_CHOICES: list[int] = [15, 30, 60, 90, 120];

glob W: int = 760,
     H: int = 280,
     PAD_L: int = 58,
     PAD_R: int = 14,
     PAD_T: int = 12,
     PAD_B: int = 26;

# ---------- helpers ----------

"""GET a JSON endpoint; None when the service cannot be reached."""
async def fetch_json(path: str) -> any {
    try {
        resp = await fetch(path);
        if not resp.ok {
            return None;
        }
        return await resp.json();
    } except Exception {
        return None;
    }
}

def money(v: float) -> str {
    # number formatting is a JS method the checker's float type lacks
    n: any = Math.round(v);
    return "$" + str(n.toLocaleString());
}

def when(ts_iso: str) -> str {
    return new(Date, ts_iso).toLocaleString(
        [], {"month": "short", "day": "numeric", "hour": "2-digit", "minute": "2-digit"}
    );
}

def clock(ms: float) -> str {
    return new(Date, ms).toLocaleTimeString(
        [], {"hour": "2-digit", "minute": "2-digit"}
    );
}

def price_str(ticker: str, p: float) -> str {
    n: any = p;
    return str(n.toFixed(4 if ticker == "RBOB" else 2));
}

"""Past = closed out before today (local time); the rest belong to today."""
def is_past(s: Suggestion) -> bool {
    midnight = new(Date);
    midnight.setHours(0, 0, 0, 0);
    return new(Date, s.closeout_at).getTime() < midnight.getTime();
}

"""Last close at or before ms, or None outside the series."""
def price_at(bars: list[Bar], ms: float) -> float | None {
    found: float | None = None;
    for b in bars {
        if b.t * 1000 > ms {
            break;
        }
        found = b.c;
    }
    return found;
}

"""Entry and closeout circles for one suggestion."""
def marks_for(s: Suggestion, bars: list[Bar]) -> list[Mark] {
    t_in = new(Date, s.created_at).getTime();
    t_out = new(Date, s.closeout_at).getTime();
    long = s.side == "long";
    p_in = price_at(bars, t_in);
    out: list[Mark] = [
        Mark(
            ms=t_in,
            price=p_in if p_in is not None else s.ref_price,
            color="var(--green)" if long else "var(--red)",
            label=("Open long " if long else "Open short ") + when(s.created_at)
        )
    ];
    p_out = price_at(bars, t_out);
    if p_out is not None and t_out <= Date.now() {
        out = out
            + [
                Mark(
                    ms=t_out,
                    price=p_out,
                    color="var(--red)" if long else "var(--green)",
                    label=("Close long " if long else "Close short ")
                        + when(s.closeout_at)
                )
            ];
    }
    return out;
}

# ---------- pieces ----------

def PriceChart(
    ticker: str, bars: list[Bar], marks: list[Mark], note: str
) -> JsxElement {
    if len(bars) < 2 {
        return <div className="chart-empty dim">{note or "Loading prices…"}</div>;
    }
    t0 = bars[0].t * 1000;
    t1 = bars[len(bars) - 1].t * 1000;
    lo = bars[0].c;
    hi = bars[0].c;
    for b in bars {
        lo = Math.min(lo, b.c);
        hi = Math.max(hi, b.c);
    }
    for m in marks {
        lo = Math.min(lo, m.price);
        hi = Math.max(hi, m.price);
    }
    if hi == lo {
        hi = hi + 0.01;
        lo = lo - 0.01;
    }
    span_t = Math.max(1, t1 - t0);

    def x(ms: float) -> float {
        return PAD_L + (ms - t0) / span_t * (W - PAD_L - PAD_R);
    }
    def y(p: float) -> float {
        return PAD_T + (hi - p) / (hi - lo) * (H - PAD_T - PAD_B);
    }

    pts = " ".join(
        [
            str(Math.round(x(b.t * 1000) * 10) / 10)
                + ","
                + str(Math.round(y(b.c) * 10) / 10) for b in bars
        ]
    );
    ticks = [hi, (hi + lo) / 2, lo];
    times = [t0, (t0 + t1) / 2, t1];
    visible = [
        m
        for m in marks
        if m.ms >= t0 and m.ms <= t1
    ];

    <svg className="chart" viewBox={"0 0 " + str(W) + " " + str(H)} role="img">
        <title>{ticker + " 1-minute closes"}</title>
        {for p in ticks {
            <g key={"y" + str(p)}>
                <line x1={PAD_L} x2={W - PAD_R} y1={y(p)} y2={y(p)} className="grid"/>
                <text x={PAD_L - 6} y={y(p) + 4} textAnchor="end" className="axis">
                    {price_str(ticker, p)}
                </text>
            </g>
        }}
        {for (i, t) in enumerate(times) {
            <text
                key={"x" + str(i)}
                x={x(t)}
                y={H - 6}
                textAnchor={["start", "middle", "end"][i]}
                className="axis"
            >
                {clock(t)}
            </text>
        }}
        <polyline points={pts} className="line"/>
        {for m in visible {
            <circle
                key={m.label}
                cx={x(m.ms)}
                cy={y(m.price)}
                r="6"
                fill={m.color}
                className="mark"
            >
                <title>{m.label + " @ " + price_str(ticker, m.price)}</title>
            </circle>
        }}
    </svg>
}

def SuggestionRow(
    s: Suggestion, selected: bool, onPick: Callable[[Suggestion], None]
) -> JsxElement {
    open_now = new(Date, s.closeout_at).getTime() > Date.now();
    left = Math.max(
        0, Math.round((new(Date, s.closeout_at).getTime() - Date.now()) / 60000)
    );
    <div
        className={"sugg" + (" picked" if selected else "")}
        onClick={lambda { onPick(s); }}
        title={s.rationale}
    >
        <span className="dim">{"#" + str(s.id)}</span>
        <span>{when(s.created_at)}</span>
        <span className="tick">{s.ticker}</span>
        <span className={"side " + s.side}>{s.side.upper()}</span>
        <span>
            {str(s.contracts) + " × " + s.contract}
            <span className="dim">{" (" + money(s.notional_usd) + ")"}</span>
        </span>
        <span>{str(s.hold_minutes) + " min"}</span>
        <span className="dim">
            {("closes in " + str(left) + "m") if open_now else "closed"}
        </span>
        {if s.event_title {
            <div className="sugg-event dim">{s.event_title}</div>
        }}
    </div>
}

# ---------- the page ----------

def:pub TradingPage -> JsxElement {
    has ticker: str = "WTI",
        bars: list[Bar] = [],
        chartNote: str = "",
        picked: Suggestion | None = None,
        suggestions: list[Suggestion] = [],
        hasPortfolio: bool = False,
        value: str = "",
        cash: str = "",
        level: str = "medium",
        maxHold: str = "120",
        levels: list[str] = ["low", "medium", "high"],
        sizing: str = "",
        formMsg: str = "",
        tick: int = 0;  # bumped every 30 s so countdowns refresh

    async def load_live(t: str) {
        chartNote = "";
        data = await fetch_json("/prices?ticker=" + t);
        if data is None {
            bars = [];
            chartNote = "Prices unavailable right now (Yahoo Finance).";
            return;
        }
        bars = data.bars as list[Bar];
        if len(bars) < 2 {
            chartNote = "No recent trades.";
        }
    }

    """Chart the window around one suggestion, padded by 30 minutes."""
    async def load_window(s: Suggestion) {
        pad = 30 * 60000;
        start = new(Date, new(Date, s.created_at).getTime() - pad).toISOString();
        end = new(Date, new(Date, s.closeout_at).getTime() + pad).toISOString();
        bars = [];
        chartNote = "";
        data = await fetch_json(
            "/prices?ticker="
                + s.ticker
                + "&start="
                + encodeURIComponent(start)
                + "&end="
                + encodeURIComponent(end)
        );
        if data is None {
            chartNote = "No 1-minute prices for this time (Yahoo keeps about 30 days).";
            return;
        }
        bars = data.bars as list[Bar];
        if len(bars) < 2 {
            chartNote = "No trades in this window.";
        }
    }

    async def load_suggestions {
        data = await fetch_json("/suggestions");
        if data {
            suggestions = data.suggestions as list[Suggestion];
        }
    }

    async def load_portfolio {
        data = await fetch_json("/portfolio");
        if not data {
            return;
        }
        levels = data.aggressiveness as list[str];
        parts: list[str] = [];
        for t in ["WTI", "RBOB"] {
            c = data.contracts[t];
            if c {
                parts = parts
                    + [
                        t
                            + ": 1 "
                            + c.symbol
                            + " = "
                            + c.multiplier.toLocaleString()
                            + " "
                            + c.unit
                    ];
            }
        }
        sizing = " · ".join(parts);
        p = data.portfolio;
        if p {
            hasPortfolio = True;
            value = str(p.portfolio_value);
            cash = str(p.available_cash);
            level = p.aggressiveness;
            maxHold = str(p.max_hold_minutes);
        }
    }

    async def save_portfolio(e: FormEvent) {
        e.preventDefault();
        formMsg = "";
        try {
            resp = await fetch(
                "/portfolio",
                {
                    "method": "PUT",
                    "headers": {"Content-Type": "application/json"},
                    "body": JSON.stringify(
                        {
                            "portfolio_value": parseFloat(value),
                            "available_cash": parseFloat(cash),
                            "aggressiveness": level,
                            "max_hold_minutes": parseInt(maxHold)
                        }
                    )
                }
            );
            body: any = await resp.json();
            if resp.ok {
                hasPortfolio = True;
                formMsg = "Saved.";
            } else {
                formMsg = str(body.detail or "Could not save.");
            }
        } except Exception {
            formMsg = "Could not reach the service.";
        }
    }

    def pick(s: Suggestion) {
        if picked and picked.id == s.id {
            picked = None;  # the live-chart effect reloads
            return;
        }
        picked = s;
        ticker = s.ticker;
        load_window(s);
    }

    def show_ticker(t: str) {
        picked = None;
        ticker = t;
        bars = [];
        load_live(t);
    }

    useEffect(
        lambda {
            load_portfolio();
            load_suggestions();
            sugg_timer = setInterval(lambda { load_suggestions(); }, 10000);
            tick_timer = setInterval(lambda { tick = tick + 1; }, 30000);
            return lambda {
                clearInterval(sugg_timer);
                clearInterval(tick_timer);
            };
        },
        []
    );

    # Live chart: reload every minute unless a suggestion's window is shown.
    useEffect(
        lambda {
            if picked {
                return lambda {};
            }
            load_live(ticker);
            timer = setInterval(lambda { load_live(ticker); }, 60000);
            return lambda { clearInterval(timer); };
        },
        [ticker, picked]
    );

    today = [
        s
        for s in suggestions
        if not is_past(s)
    ];
    past = [
        s
        for s in suggestions
        if is_past(s)
    ];
    marks = marks_for(picked, bars) if picked else [];
    last = bars[len(bars) - 1].c if len(bars) > 0 else None;

    <main className="trading" data-tick={tick}>
        <div className="titlebar">
            <h1>Newsstream - Trading</h1>
            <a href="/">{"← News"}</a>
        </div>
        <p className="dim disclaimer">
            Speculative suggestions only, made by a model from breaking news. Nothing is traded for you. Each one is meant to be closed within 2 hours.
        </p>
        <section className="panel">
            <h2>Portfolio</h2>
            <form className="portfolio" onSubmit={save_portfolio}>
                <label>
                    {"Portfolio size ($)"}
                    <input
                        type="number"
                        min="0"
                        step="any"
                        required
                        value={value}
                        onChange={lambda (e: ChangeEvent) { value = e.target.value; }}
                    />
                </label>
                <label>
                    {"Available cash ($)"}
                    <input
                        type="number"
                        min="0"
                        step="any"
                        required
                        value={cash}
                        onChange={lambda (e: ChangeEvent) { cash = e.target.value; }}
                    />
                </label>
                <label>
                    {"Aggressiveness"}
                    <select
                        value={level}
                        onChange={lambda (e: ChangeEvent) { level = e.target.value; }}
                    >
                        {for l in levels {
                            <option key={l} value={l}>{l}</option>
                        }}
                    </select>
                </label>
                <label>
                    {"Time horizon"}
                    <select
                        value={maxHold}
                        onChange={lambda (e: ChangeEvent) { maxHold = e.target.value; }}
                    >
                        {for m in HOLD_CHOICES {
                            <option key={m} value={str(m)}>
                                {"up to " + str(m) + " min"}
                            </option>
                        }}
                    </select>
                </label>
                <button type="submit">Save</button>
                {if formMsg {
                    <span className="dim">{formMsg}</span>
                }}
            </form>
            <p className="dim small">
                {"Typed in by hand from your Robinhood app; not linked to your account. "
                    + "Size: whole contracts worth at most ⅓ of the portfolio and no more than "
                    + "available cash, scaled by aggressiveness. "
                    + sizing}
            </p>
            {if not hasPortfolio {
                <p className="warn-text">
                    Enter your portfolio to start getting suggestions.
                </p>
            }}
        </section>
        <section className="panel">
            <div className="chart-head">
                <div className="toggle">
                    {for t in ["WTI", "RBOB"] {
                        <button
                            key={t}
                            className={"on" if ticker == t else ""}
                            onClick={lambda { show_ticker(t); }}
                        >
                            {t}
                        </button>
                    }}
                </div>
                <span>
                    {if last is not None and not picked {
                        <strong>{price_str(ticker, last)}</strong>
                    }}
                    <span className="dim">
                        {(" " + ticker + " 1-minute, ~10 min delayed (Yahoo Finance)")}
                    </span>
                </span>
                {if picked {
                    <button onClick={lambda { picked = None; }}>
                        {"Back to live"}
                    </button>
                }}
            </div>
            <PriceChart ticker={ticker} bars={bars} marks={marks} note={chartNote}/>
            {if picked {
                <p className="dim small">
                    {"#"
                        + str(picked.id)
                        + " "
                        + picked.side
                        + " "
                        + picked.ticker
                        + ": "
                        + picked.rationale}
                </p>
            }}
        </section>
        <section className="panel">
            <h2>Today</h2>
            {for s in today {
                <SuggestionRow
                    key={s.id}
                    s={s}
                    selected={picked is not None and picked.id == s.id}
                    onPick={pick}
                />
            }}
            {if len(today) == 0 {
                <div className="dim">No suggestions today.</div>
            }}
        </section>
        <section className="panel">
            <h2>Past suggestions</h2>
            {for s in past {
                <SuggestionRow
                    key={s.id}
                    s={s}
                    selected={picked is not None and picked.id == s.id}
                    onPick={pick}
                />
            }}
            {if len(past) == 0 {
                <div className="dim">None yet.</div>
            }}
        </section>
    </main>
}

"""Newsstream - Trading page (docs/spec.md §16), served at /trading.

Portfolio entry (typed in by hand; there is no brokerage link), a 1-minute
WTI / RBOB chart, and the speculative suggestions the service made after
NEW_EVENT cards. The chart shows one local day: today (live) or any of the
six before it. Clicking a suggestion switches to its ticker and day and
overlays its entry and closeout: long entry green, short entry red, long
closeout red, short closeout green.
"""

import from react { useEffect, useRef }
import from .navigation { Navigation }

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
        model: str,
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

glob DAYS_SHOWN: int = 7,
     PRICE_ERROR: str = "Price data could not be loaded. Try again.";

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

"""Local midnight `back` days before today."""
def day_start(back: int) -> any {
    d = new(Date);
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() - back);
    return d;
}

"""Local midnight on the calendar date of an ISO timestamp."""
def entry_day(ts_iso: str) -> float {
    d = new(Date, ts_iso);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
}

def day_label(start_ms: float) -> str {
    if start_ms == day_start(0).getTime() {
        return "Today";
    }
    return new(Date, start_ms).toLocaleDateString(
        [], {"weekday": "short", "month": "short", "day": "numeric"}
    );
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
    out: list[Mark] = [
        Mark(
            ms=t_in,
            price=s.ref_price,
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

"""1-minute closes; `hold` is [entry ms, closeout ms] of a picked suggestion,
shaded so short holds stay readable on a whole-day chart."""
def PriceChart(
    ticker: str,
    bars: list[Bar],
    marks: list[Mark],
    hold: list[float],
    note: str,
    width: float
) -> JsxElement {
    if len(bars) == 0 {
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
        if t0 == t1 {
            return (PAD_L + width - PAD_R) / 2;
        }
        return PAD_L + (ms - t0) / span_t * (width - PAD_L - PAD_R);
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
    times = [t0] if t0 == t1 else [t0, (t0 + t1) / 2, t1];
    visible = [
        m
        for m in marks
        if m.ms >= t0 and m.ms <= t1
    ];
    band: list[float] = [];
    if len(hold) == 2 and hold[1] >= t0 and hold[0] <= t1 {
        band = [x(Math.max(hold[0], t0)), x(Math.min(hold[1], t1, Date.now()))];
    }

    <svg className="chart" viewBox={"0 0 " + str(width) + " " + str(H)} role="img">
        <title>{ticker + " 1-minute closes"}</title>
        {if len(band) == 2 {
            <rect
                x={band[0]}
                y={PAD_T}
                width={Math.max(2, band[1] - band[0])}
                height={H - PAD_T - PAD_B}
                className="hold"
            />
        }}
        {for p in ticks {
            <g key={"y" + str(p)}>
                <line
                    x1={PAD_L}
                    x2={width - PAD_R}
                    y1={y(p)}
                    y2={y(p)}
                    className="grid"
                />
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
                textAnchor={"middle"
                    if len(times) == 1
                    else ["start", "middle", "end"][i]}
                className="axis"
            >
                {clock(t)}
            </text>
        }}
        {if len(bars) == 1 {
            <circle cx={x(t0)} cy={y(bars[0].c)} r="3" fill="var(--accent)"/>
        } else {
            <polyline points={pts} className="line"/>
        } }
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
    <button
        type="button"
        aria-pressed={selected}
        className={"sugg" + (" picked" if selected else "")}
        onClick={lambda { onPick(s); }}
        title={s.rationale}
    >
        <span className="dim">{"#" + str(s.id)}</span>
        {if s.model == "manual demo entry" {
            <strong>Manual demo</strong>
        }}
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
            <span className="sugg-event dim">{s.event_title}</span>
        } elif s.rationale {
            # hand-entered (demo) suggestions have no event; show why instead
            <span className="sugg-event dim">{s.rationale}</span>
        } }
    </button>
}

# ---------- the page ----------

def:pub TradingPage -> JsxElement {
    chartBox: any = useRef(None);
    chartSeq: any = useRef(0);
    loadingSuggestions: any = useRef(False);
    has ticker: str = "WTI",
        day: float = 0,  # local midnight, or zero to follow today
        chartWidth: float = W,
        bars: list[Bar] = [],
        chartNote: str = "",
        picked: Suggestion | None = None,
        suggestions: list[Suggestion] = [],
        hasPortfolio: bool = False,
        portfolioState: str = "loading",
        suggestionsState: str = "loading",
        tradingEnabled: bool = True,
        saving: bool = False,
        value: str = "",
        cash: str = "",
        level: str = "medium",
        maxHold: str = "120",
        levels: list[str] = ["low", "medium", "high"],
        sizing: str = "",
        formMsg: str = "",
        tick: float = 0;  # updated every 30 s so countdowns and day labels refresh

    """Request one explicit calendar date, even when the local day rolls over."""
    async def load_day(t: str, start_ms: float) {
        chartSeq.current += 1;
        seq = chartSeq.current;
        start = new(Date, start_ms).toISOString();
        tomorrow = new(Date, start_ms);
        tomorrow.setDate(tomorrow.getDate() + 1);
        end = tomorrow.toISOString();
        data = await fetch_json(
            "/prices?ticker="
                + t
                + "&start="
                + encodeURIComponent(start)
                + "&end="
                + encodeURIComponent(end)
        );
        if seq != chartSeq.current {
            return;  # the ticker or day changed while this was loading
        }
        chartNote = "";
        if data is None {
            bars = [];
            chartNote = PRICE_ERROR;
            return;
        }
        bars = data.bars as list[Bar];
        if len(bars) == 0 {
            chartNote = "No one-minute quotes for the selected day.";
        }
    }

    async def load_suggestions {
        if loadingSuggestions.current {
            return;
        }
        loadingSuggestions.current = True;
        data = await fetch_json("/suggestions");
        loadingSuggestions.current = False;
        if data {
            suggestions = data.suggestions as list[Suggestion];
            suggestionsState = "ready";
        } else {
            suggestionsState = "error";
        }
    }

    async def load_portfolio {
        portfolioState = "loading";
        data = await fetch_json("/portfolio");
        if not data {
            portfolioState = "error";
            return;
        }
        tradingEnabled = data.enabled;
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
        portfolioState = "ready";
    }

    async def save_portfolio(e: FormEvent) {
        e.preventDefault();
        if portfolioState != "ready" or saving {
            return;
        }
        saving = True;
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
        } finally {
            saving = False;
        }
    }

    """Show a chart view; the chart effect loads it when it changed."""
    def show(t: str, date_ms: float) {
        if t != ticker or date_ms != day {
            bars = [];
            chartNote = "";
        }
        ticker = t;
        day = date_ms;
    }

    """Overlay a suggestion on its own ticker and day; again to remove it."""
    def pick(s: Suggestion) {
        if picked and picked.id == s.id {
            picked = None;
            return;
        }
        picked = s;
        date_ms = entry_day(s.created_at);
        show(s.ticker, 0 if date_ms == day_start(0).getTime() else date_ms);
    }

    def show_ticker(t: str) {
        picked = None;
        show(t, day);
    }

    def show_day(date_ms: float) {
        if picked
            and not (
                entry_day(picked.created_at) <= date_ms
                and date_ms <= entry_day(picked.closeout_at)
            ) {
            picked = None;
        }
        show(ticker, 0 if date_ms == day_start(0).getTime() else date_ms);
    }

    useEffect(
        lambda {
            load_portfolio();
            load_suggestions();
            win: any = window;
            measure = lambda { chartWidth = Math.max(
                1, chartBox.current.clientWidth
            ); };
            measure();
            observer = new(win.ResizeObserver, measure);
            observer.observe(chartBox.current);
            sugg_timer = setInterval(lambda { load_suggestions(); }, 10000);
            tick_timer = setInterval(lambda { tick = Date.now(); }, 30000);
            return lambda {
                clearInterval(sugg_timer);
                clearInterval(tick_timer);
                observer.disconnect();
            };
        },
        []
    );

    selectedStart = day or day_start(0).getTime();
    useEffect(
        lambda {
            bars = [];
            chartNote = "";
            load_day(ticker, selectedStart);
            if day != 0 {
                return lambda {};
            }
            timer = setInterval(
                lambda { load_day(ticker, day_start(0).getTime()); }, 60000
            );
            return lambda { clearInterval(timer); };
        },
        [ticker, day, selectedStart]
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
    marks = [
        m
        for m in marks_for(picked, bars)
        if entry_day(new(Date, m.ms).toISOString()) == selectedStart
    ]
        if picked
        else [];
    hold: list[float] = [
        new(Date, picked.created_at).getTime(),
        new(Date, picked.closeout_at).getTime()
    ]
        if picked
        else [];
    last = bars[len(bars) - 1].c if len(bars) > 0 else None;
    day_choices = [day_start(i).getTime() for i in range(DAYS_SHOWN)];
    if selectedStart not in day_choices {
        day_choices = day_choices + [selectedStart];
    }
    if picked {
        for stamp in [picked.created_at, picked.closeout_at] {
            date_ms = entry_day(stamp);
            if date_ms not in day_choices {
                day_choices = day_choices + [date_ms];
            }
        }
    }

    <main className="trading" data-tick={tick}>
        <div className="titlebar">
            <div>
                <h1>Trading Insights</h1>
                <p className="dim">
                    {"Explore oil-market charts and review trade suggestions."}
                </p>
            </div>
        </div>
        <p className="dim disclaimer">
            Suggestions are speculative, with a maximum hold of two hours. Newsstream does not place orders.
        </p>
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
                <div className="market-price">
                    {if last is not None and day == 0 {
                        <strong>{price_str(ticker, last)}</strong>
                    }}
                    <span className="dim">
                        {ticker + " · 1-minute chart · ~10 min delayed"}
                    </span>
                </div>
                {if picked or day != 0 {
                    <button
                        onClick={lambda {
                            picked = None;
                            show(ticker, 0);
                        }}
                    >
                        {"Back to live"}
                    </button>
                }}
            </div>
            <div className="days" role="group" aria-label="Day">
                {for d in day_choices {
                    <button
                        key={d}
                        className={"on" if selectedStart == d else ""}
                        onClick={lambda { show_day(d); }}
                    >
                        {day_label(d)}
                    </button>
                }}
            </div>
            <div ref={chartBox}>
                <PriceChart
                    ticker={ticker}
                    bars={bars}
                    marks={marks}
                    hold={hold}
                    note={chartNote}
                    width={chartWidth}
                />
            </div>
            {if chartNote == PRICE_ERROR {
                <button
                    type="button"
                    onClick={lambda { load_day(ticker, selectedStart); }}
                >
                    Retry prices
                </button>
            }}
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
            <h2>Shared simulated portfolio</h2>
            <p id="portfolio-sharing">
                Everyone using this Newsstream server can view and change these figures. Use simulated balances.
            </p>
            {if portfolioState == "loading" {
                <p role="status">Loading portfolio…</p>
            } elif portfolioState == "error" {
                <p role="status">
                    Could not load the shared portfolio.{" "}
                    <button type="button" onClick={lambda { load_portfolio(); }}>
                        Retry portfolio
                    </button>
                </p>
            } }
            <form
                className="portfolio"
                onChange={lambda { formMsg = ""; }}
                onSubmit={save_portfolio}
                aria-describedby="portfolio-sharing"
            >
                <label>
                    {"Portfolio size ($)"}
                    <input
                        type="number"
                        min="0"
                        step="any"
                        required
                        disabled={portfolioState != "ready" or saving}
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
                        disabled={portfolioState != "ready" or saving}
                        value={cash}
                        onChange={lambda (e: ChangeEvent) { cash = e.target.value; }}
                    />
                </label>
                <label>
                    {"Aggressiveness"}
                    <select
                        disabled={portfolioState != "ready" or saving}
                        value={level}
                        onChange={lambda (e: ChangeEvent) { level = e.target.value; }}
                    >
                        {for l in levels {
                            <option key={l} value={l}>{l}</option>
                        }}
                    </select>
                </label>
                <label>
                    {"Time horizon (minutes)"}
                    <input
                        type="number"
                        min="1"
                        max="120"
                        step="1"
                        required
                        disabled={portfolioState != "ready" or saving}
                        value={maxHold}
                        onChange={lambda (e: ChangeEvent) { maxHold = e.target.value; }}
                    />
                </label>
                <button type="submit" disabled={portfolioState != "ready" or saving}>
                    Save
                </button>
                {if formMsg {
                    <span className="dim">{formMsg}</span>
                }}
            </form>
            <p className="dim small">
                {"Whole contracts worth at most ⅓ of the portfolio and no more than "
                    + "available cash, scaled by aggressiveness. "
                    + sizing}
            </p>
            {if portfolioState == "ready" and not tradingEnabled {
                <p className="warn-text">
                    New trading suggestions are disabled on this server.
                </p>
            } elif portfolioState == "ready" and not hasPortfolio {
                <p className="warn-text">
                    Enter simulated balances to start getting suggestions.
                </p>
            } }
        </section>
        <section className="panel">
            <h2>Today</h2>
            {if suggestionsState == "loading" {
                <p role="status">Loading suggestions…</p>
            } elif suggestionsState == "error" {
                <p role="status">
                    Could not refresh trading suggestions.{" "}
                    <button type="button" onClick={lambda { load_suggestions(); }}>
                        Retry suggestions
                    </button>
                </p>
            } }
            {for s in today {
                <SuggestionRow
                    key={s.id}
                    s={s}
                    selected={picked is not None and picked.id == s.id}
                    onPick={pick}
                />
            }}
            {if suggestionsState == "ready" and len(today) == 0 {
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
            {if suggestionsState == "ready" and len(past) == 0 {
                <div className="dim">None yet.</div>
            }}
        </section>
    </main>
}

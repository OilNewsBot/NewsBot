"""Account-owned source settings, feed, and live notifications at /sources."""

import "./sources.css";
import from react { useEffect }
import from .auth { AuthPanel }

# These values belong to this mounted page, never to persistent browser storage.
# Epoch checks discard responses begun by a previous account or unmounted page.
glob _ps_epoch: int = 0,
     _ps_user_id: int = 0,
     _ps_stream: any = None,
     _ps_cursor: int = 0,
     _ps_ready: bool = False,
     _ps_booting: bool = False,
     _ps_seen: any = new(Set),
     _ps_alerts: list[any] = [],
     _ps_screen: bool = False,
     _ps_open_notices: list[any] = [];

def safe_link(value: any) -> str {
    url = str(value or "").strip();
    return url if url.startswith("https://") or url.startswith("http://") else "";
}

def keywords(value: str) -> list[str] {
    return [
        part.strip()
        for part in value.split(",")
        if part.strip()
    ];
}

def source_time(value: any) -> str {
    if not value {
        return "Waiting for first check";
    }
    return new(Date, str(value)).toLocaleString(
        [], {"month": "short", "day": "numeric", "hour": "2-digit", "minute": "2-digit"}
    );
}

def provider_name(value: str) -> str {
    return "X · TwitterAPI.io" if value == "x" else "RSS / Atom";
}

def status_name(value: any) -> str {
    s = str(value or "pending");
    labels: dict[str, str] = {
        "connected": "Connected",
        "live": "Live",
        "active": "Active",
        "pending": "Waiting for first check",
        "starting": "Starting",
        "rate_limited": "Rate limited",
        "budget_paused": "Daily limit reached",
        "budget-paused": "Daily limit reached",
        "needs_reconnect": "Reconnect needed",
        "disconnected": "Disconnected",
        "paused": "Paused",
        "error": "Needs attention"
    };
    return labels.get(s, s.replace("_", " "));
}

async def personal_request(path: str, method: str = "GET", body: any = None) -> any {
    options: any = {
        "method": method,
        "credentials": "same-origin",
        "cache": "no-store"
    };
    if body is not None {
        options.headers = {"Content-Type": "application/json"};
        options.body = JSON.stringify(body);
    }
    try {
        response = await fetch(path, options);
        data: any = {};
        try {
            data = await response.json();
        } except Exception {}
        detail = data.detail;
        return {
            "ok": response.ok,
            "status": response.status,
            "data": data,
            "error": str(detail)
                if isinstance(detail, str)
                else "The request could not be completed."
        };
    } except Exception {
        return {
            "ok": False,
            "status": 0,
            "data": {},
            "error": "Cannot reach Newsstream. Try again shortly."
        };
    }
}

def SourceCard(source: any, busy: bool, onUpdate: any, onRemove: any) -> JsxElement {
    has includeText: str = ", ".join(source.include_keywords or []),
        excludeText: str = ", ".join(source.exclude_keywords or []),
        confirmRemove: bool = False;

    def save(e: any) {
        e.preventDefault();
        onUpdate(
            source.id,
            {
                "include_keywords": keywords(includeText),
                "exclude_keywords": keywords(excludeText)
            }
        );
    }

    <article className="ps-source">
        <div className="ps-row ps-spread">
            <div className="ps-source-name">
                <span className={"ps-provider ps-provider-" + str(source.provider)}>
                    {"X" if source.provider == "x" else "RSS"}
                </span>
                <div>
                    <strong>{source.name}</strong>
                    <div className="ps-muted ps-small">
                        {status_name(source.status) if source.enabled else "Paused"}{" · "
                            + source_time(source.last_success)
                            if source.last_success
                            else ""}
                    </div>
                </div>
            </div>
            {if safe_link(source.url) {
                <a
                    className="ps-text-link"
                    href={safe_link(source.url)}
                    target="_blank"
                    rel="noopener noreferrer"
                >
                    Open ↗
                </a>
            }}
        </div>
        {if source.last_error {
            <p className="ps-inline-error">{source.last_error}</p>
        }}
        <div className="ps-source-actions">
            <label className="ps-toggle">
                <input
                    type="checkbox"
                    checked={bool(source.alerts_enabled)}
                    disabled={busy}
                    onChange={lambda (e: any) { onUpdate(
                        source.id, {"alerts_enabled": e.target.checked}
                    ); }}
                />
                Alerts
            </label>
            <button
                type="button"
                className="ps-quiet"
                disabled={busy}
                onClick={lambda { onUpdate(
                    source.id, {"enabled": not source.enabled}
                ); }}
            >
                {"Pause" if source.enabled else "Resume"}
            </button>
            <button
                type="button"
                className="ps-quiet ps-danger"
                disabled={busy}
                onClick={lambda { confirmRemove = not confirmRemove; }}
            >
                Remove
            </button>
        </div>
        {if confirmRemove {
            <div className="ps-confirm">
                <span>Remove this source from your account?</span>
                <button
                    type="button"
                    disabled={busy}
                    onClick={lambda { onRemove(source.id); }}
                >
                    Remove source
                </button>
                <button
                    type="button"
                    className="ps-quiet"
                    onClick={lambda { confirmRemove = False; }}
                >
                    Cancel
                </button>
            </div>
        }}
        <details className="ps-filters">
            <summary>Alert keyword filters</summary>
            <form onSubmit={save}>
                <label>
                    Include any of these keywords
                    <input
                        value={includeText}
                        maxLength={1000}
                        placeholder="earnings, semiconductor, inflation"
                        onChange={lambda (e: any) { includeText = e.target.value; }}
                    />
                </label>
                <label>
                    Exclude these keywords
                    <input
                        value={excludeText}
                        maxLength={1000}
                        placeholder="Giveaway, promotion"
                        onChange={lambda (e: any) { excludeText = e.target.value; }}
                    />
                </label>
                <p className="ps-help">
                    Separate keywords with commas. Leave both empty to alert on every new post. Your feed keeps all collected posts.
                </p>
                <button type="submit" disabled={busy}>Save filters</button>
            </form>
        </details>
    </article>
}

def ConnectionCard(
    connection: any, busy: bool, onRemove: any, onReconnect: any
) -> JsxElement {
    has confirmRemove: bool = False,
        replacing: bool = False,
        replacementKey: str = "";

    def reconnect(e: any) {
        e.preventDefault();
        secret = replacementKey;
        replacementKey = "";
        replacing = False;
        onReconnect(connection.id, secret);
    }

    <article className="ps-connection">
        <div className="ps-row ps-spread">
            <div>
                <strong>{connection.label}</strong>
                <div className="ps-muted ps-small">
                    {provider_name(connection.provider)}
                </div>
            </div>
            <span className={"ps-status ps-status-" + str(connection.status)}>
                {status_name(connection.status)}
            </span>
        </div>
        {if connection.last_error {
            <p className="ps-inline-error">{connection.last_error}</p>
        }}
        <div className="ps-source-actions">
            {if connection.provider == "x" {
                <span className="ps-muted ps-small">
                    {str(connection.daily_limit) + " requests / day"}
                </span>
                <button
                    className="ps-quiet"
                    type="button"
                    disabled={busy}
                    onClick={lambda {
                        replacing = not replacing;
                        replacementKey = "";
                    }}
                >
                    Replace key
                </button>
            }}
            <button
                className="ps-quiet ps-danger"
                type="button"
                disabled={busy}
                onClick={lambda { confirmRemove = not confirmRemove; }}
            >
                Disconnect
            </button>
        </div>
        {if replacing {
            <form className="ps-key-form" onSubmit={reconnect}>
                <label>
                    New TwitterAPI.io API key
                    <input
                        type="password"
                        autoComplete="off"
                        value={replacementKey}
                        required
                        maxLength={1024}
                        onChange={lambda (e: any) { replacementKey = e.target.value; }}
                    />
                </label>
                <button type="submit" disabled={busy}>Replace key</button>
            </form>
        }}
        {if confirmRemove {
            <div className="ps-confirm">
                <span>Disconnect this service and remove its sources?</span>
                <button
                    type="button"
                    disabled={busy}
                    onClick={lambda { onRemove(connection.id); }}
                >
                    Disconnect
                </button>
                <button
                    type="button"
                    className="ps-quiet"
                    onClick={lambda { confirmRemove = False; }}
                >
                    Cancel
                </button>
            </div>
        }}
    </article>
}

def FeedItem(item: any) -> JsxElement {
    <article className="ps-feed-item">
        <div className="ps-feed-meta">
            <span className={"ps-provider ps-provider-" + str(item.provider)}>
                {"X" if item.provider == "x" else "RSS"}
            </span>
            <strong>{item.source_name}</strong>
            <time dateTime={item.posted_at}>{source_time(item.posted_at)}</time>
        </div>
        {if item.title {
            <h3>{item.title}</h3>
        }}
        {if item.text {
            <p>{str(item.text)[:1400]}</p>
        }}
        {if safe_link(item.url) {
            <a href={safe_link(item.url)} target="_blank" rel="noopener noreferrer">
                Read original ↗
            </a>
        }}
    </article>
}

def:pub SourcesPage -> JsxElement {
    has user: any = None,
        connections: list[any] = [],
        sources: list[any] = [],
        feed: list[any] = [],
        alerts: list[any] = [],
        loaded: bool = False,
        busy: bool = False,
        error: str = "",
        notice: str = "",
        connectionForm: bool = False,
        provider: str = "rss",
        label: str = "",
        apiKey: str = "",
        dailyLimit: str = "200",
        selectedConnection: str = "",
        locator: str = "",
        newAlerts: bool = True,
        newInclude: str = "",
        newExclude: str = "",
        streamStatus: str = "Connecting",
        screenEnabled: bool = False,
        screenHint: str = "";

    def clear_session {
        _ps_epoch += 1;
        _ps_user_id = 0;
        if _ps_stream {
            _ps_stream.close();
            _ps_stream = None;
        }
        for popup in _ps_open_notices {
            popup.close();
        }
        _ps_open_notices = [];
        _ps_cursor = 0;
        _ps_ready = False;
        _ps_booting = False;
        _ps_seen = new(Set);
        _ps_alerts = [];
        _ps_screen = False;
        user = None;
        connections = [];
        sources = [];
        feed = [];
        alerts = [];
        loaded = False;
        busy = False;
        apiKey = "";
        label = "";
        provider = "rss";
        dailyLimit = "200";
        locator = "";
        selectedConnection = "";
        newInclude = "";
        newExclude = "";
        newAlerts = True;
        screenEnabled = False;
        screenHint = "";
        error = "";
        notice = "";
        connectionForm = False;
    }

    def expire {
        clear_session();
        error = "Your session ended. Sign in to see your sources.";
    }

    async def refresh(epoch: int) {
        for endpoint in ["connections", "sources", "feed"] {
            response = await personal_request("/api/me/" + endpoint);
            if epoch != _ps_epoch {
                return;
            }
            if response.status == 401 {
                expire();
                return;
            }
            if not response.ok {
                error = response.error;
                return;
            }
            if endpoint == "connections" {
                connections = response.data.connections or [];
            } elif endpoint == "sources" {
                sources = response.data.sources or [];
                allowed = [
                    int(s.id)
                    for s in sources
                    if s.enabled and s.alerts_enabled
                ];
                _ps_alerts = [
                    item
                    for item in _ps_alerts
                    if int(item.source_id) in allowed
                ];
                alerts = _ps_alerts;
            } else {
                feed = response.data.items or [];
            }
        }
        loaded = True;
    }

    def receive(item: any, epoch: int) {
        if epoch != _ps_epoch or not _ps_user_id {
            return;
        }
        nid = int(item.notification_id);
        if nid <= _ps_cursor or _ps_seen.has(nid) {
            return;
        }
        _ps_cursor = nid;
        _ps_seen.add(nid);
        if _ps_seen.size > 1000 {
            _ps_seen.clear();
        }
        _ps_alerts = ([item] + _ps_alerts)[:5];
        alerts = _ps_alerts;
        refresh(epoch);
        api: any = globalThis.Notification;  # jac:ignore[E1053]
        doc: any = document;
        win: any = window;
        if _ps_screen and api and api.permission == "granted" and doc.hidden {
            popup = new(
                api,
                str(item.source_name or "Newsstream"),
                {
                    "body": str(item.title or item.text or "New post")[:180],
                    "tag": "newsstream-personal-" + str(_ps_user_id) + "-" + str(nid)
                }
            );
            popup.onclick = lambda {
                win.focus();
                popup.close();
            };
            if len(_ps_open_notices) >= 20 {
                _ps_open_notices[0].close();
            }
            _ps_open_notices = (_ps_open_notices + [popup])[-20:];
        }
    }

    def connect(epoch: int) {
        if epoch != _ps_epoch {
            return;
        }
        if _ps_stream {
            _ps_stream.close();
        }
        streamStatus = "Connecting";
        _ps_stream = new(EventSource, "/api/me/stream?since=" + str(_ps_cursor));  # jac:ignore[E1053]
        _ps_stream.addEventListener(
            "notification",
            lambda (event: any) { if epoch == _ps_epoch {
                try {
                    receive(JSON.parse(event.data), epoch);
                } except Exception {}
            }}
        );
        _ps_stream.addEventListener(
            "session_expired", lambda { if epoch == _ps_epoch { expire(); }}
        );
        _ps_stream.onopen = lambda { if epoch == _ps_epoch {
            streamStatus = "Live alerts";
        }};
        _ps_stream.onerror = lambda { if epoch == _ps_epoch {
            streamStatus = "Reconnecting";
            check_session();
        }};
    }

    async def initialize(epoch: int) {
        if _ps_booting or _ps_ready or epoch != _ps_epoch {
            return;
        }
        _ps_booting = True;
        # Head is captured before starting SSE. Its persisted replay covers posts
        # arriving between this response and subscription without old alert spam.
        response = await personal_request("/api/me/notifications/head");
        if epoch != _ps_epoch {
            return;
        }
        _ps_booting = False;
        if response.status == 401 {
            expire();
            return;
        }
        if not response.ok {
            error = response.error;
            return;
        }
        _ps_cursor = int(response.data.notification_id or 0);
        _ps_ready = True;
        connect(epoch);
        await refresh(epoch);
    }

    def session_changed(nextUser: any) {
        nextId = int(nextUser.user_id) if nextUser else 0;
        if nextId == _ps_user_id {
            return;
        }
        clear_session();
        if nextId {
            _ps_user_id = nextId;
            user = nextUser;
            initialize(_ps_epoch);
        }
    }

    async def check_session {
        epoch = _ps_epoch;
        response = await personal_request("/me");
        if epoch != _ps_epoch {
            return;
        }
        if response.ok {
            session_changed(response.data);
        } elif response.status == 401 {
            if _ps_user_id {
                expire();
            }
        }
    }

    async def periodic_refresh {
        await check_session();
        if _ps_user_id {
            if _ps_ready {
                await refresh(_ps_epoch);
            } else {
                await initialize(_ps_epoch);
            }
        }
    }

    async def mutate(path: str, method: str, body: any = None) -> bool {
        epoch = _ps_epoch;
        busy = True;
        error = "";
        notice = "";
        response = await personal_request(path, method, body);
        if epoch != _ps_epoch {
            return False;
        }
        busy = False;
        if response.status == 401 {
            expire();
            return False;
        }
        if not response.ok {
            error = response.error;
            return False;
        }
        await refresh(epoch);
        return epoch == _ps_epoch;
    }

    async def add_connection(e: any) {
        e.preventDefault();
        body: any = {
            "provider": provider,
            "label": label.strip() or provider_name(provider)
        };
        if provider == "x" {
            body.api_key = apiKey;
            body.daily_limit = int(dailyLimit);
        }
        apiKey = "";
        if await mutate("/api/me/connections", "POST", body) {
            label = "";
            connectionForm = False;
            notice = "Connection added. Choose a source to follow below.";
        }
    }

    async def add_source(e: any) {
        e.preventDefault();
        cid = selectedConnection
            or (str(connections[0].id) if len(connections) else "");
        if not cid {
            error = "Add a connection first.";
            return;
        }
        if await mutate(
            "/api/me/sources",
            "POST",
            {
                "connection_id": int(cid),
                "locator": locator.strip(),
                "alerts_enabled": newAlerts,
                "include_keywords": keywords(newInclude),
                "exclude_keywords": keywords(newExclude)
            }
        ) {
            locator = "";
            newInclude = "";
            newExclude = "";
            notice = "Source added. Recent posts will load quietly; alerts start with new posts.";
        }
    }

    async def update_source(sid: int, changes: any) {
        if await mutate("/api/me/sources/" + str(sid), "PATCH", changes) {
            notice = "Source preferences saved.";
        }
    }

    async def remove_source(sid: int) {
        await mutate("/api/me/sources/" + str(sid), "DELETE");
    }

    async def remove_connection(cid: int) {
        if await mutate("/api/me/connections/" + str(cid), "DELETE") {
            selectedConnection = "";
        }
    }

    async def reconnect_connection(cid: int, secret: str) {
        if await mutate(
            "/api/me/connections/" + str(cid), "PATCH", {"api_key": secret}
        ) {
            notice = "Key replaced. Collection will resume on the next check.";
        }
    }

    async def toggle_screen(e: any) {
        epoch = _ps_epoch;
        want = e.target.checked;
        screenHint = "";
        api: any = globalThis.Notification;  # jac:ignore[E1053]
        if want and not api {
            want = False;
            screenHint = "This browser does not support screen notifications.";
        } elif want {
            permission = await api.requestPermission();
            if epoch != _ps_epoch {
                return;
            }
            if permission != "granted" {
                want = False;
                screenHint = "Allow notifications for this site in your browser settings.";
            }
        }
        _ps_screen = want;
        screenEnabled = want;
    }

    def dismiss(nid: int) {
        _ps_alerts = [
            item
            for item in _ps_alerts
            if item.notification_id != nid
        ];
        alerts = _ps_alerts;
    }

    useEffect(
        lambda {
            check_session();
            timer = setInterval(lambda { periodic_refresh(); }, 15000);
            focus = lambda { check_session(); };
            window.addEventListener("focus", focus);
            return lambda {
                clearInterval(timer);
                window.removeEventListener("focus", focus);
                clear_session();
            };
        },
        []
    );

    <div className="ps-page">
        <header className="ps-header">
            <a href="/sources" className="ps-brand">
                newsstream
                <span> / personal</span>
            </a>
            <nav aria-label="Main navigation">
                <a href="/">Oil feed</a>
                <a href="/trading">Trading ↗</a>
            </nav>
        </header>
        <main className="ps-main">
            <div className="ps-intro">
                <div>
                    <p className="ps-eyebrow">Your watchlist</p>
                    <h1>My Sources</h1>
                    <p>
                        Follow feeds and X accounts. Choose what reaches your news feed and alerts.
                    </p>
                </div>
                {if user {
                    <span className="ps-live">
                        <span className="ps-live-dot"/>
                        {streamStatus}
                    </span>
                }}
            </div>
            <div className="ps-auth">
                <AuthPanel key={str(_ps_epoch)} onSessionChange={session_changed}/>
            </div>
            {if error {
                <div className="ps-message ps-error" role="alert">{error}</div>
            }}
            {if notice {
                <div className="ps-message ps-notice" role="status">{notice}</div>
            }}
            {if not user {
                <div className="ps-welcome">
                    <h2>A news feed built around what you follow.</h2>
                    <div className="ps-welcome-steps">
                        <div>
                            <span>01</span>
                            <strong>Connect a service</strong>
                            <p>RSS needs a feed link. X uses your TwitterAPI.io key.</p>
                        </div>
                        <div>
                            <span>02</span>
                            <strong>Pick your sources</strong>
                            <p>Follow accounts and feeds covering any topic.</p>
                        </div>
                        <div>
                            <span>03</span>
                            <strong>Set your alerts</strong>
                            <p>Choose keywords, mute a source, or keep every update.</p>
                        </div>
                    </div>
                </div>
            } else {
                <div className="ps-grid">
                    <aside className="ps-settings">
                        <section className="ps-panel">
                            <div className="ps-section-heading">
                                <h2>Connections</h2>
                                <button
                                    type="button"
                                    className="ps-small-button"
                                    onClick={lambda {
                                        connectionForm = not connectionForm;
                                        apiKey = "";
                                    }}
                                >
                                    {"Cancel" if connectionForm else "+ Add"}
                                </button>
                            </div>
                            {for connection in connections {
                                <ConnectionCard
                                    key={connection.id}
                                    connection={connection}
                                    busy={busy}
                                    onRemove={remove_connection}
                                    onReconnect={reconnect_connection}
                                />
                            }}
                            {if not len(connections) and not connectionForm {
                                <p className="ps-empty-small">
                                    Connect RSS or TwitterAPI.io to add your first source.
                                </p>
                            }}
                            {if connectionForm {
                                <form className="ps-form" onSubmit={add_connection}>
                                    <label>
                                        Service
                                        <select
                                            value={provider}
                                            onChange={lambda (e: any) {
                                                provider = e.target.value;
                                                apiKey = "";
                                            }}
                                        >
                                            <option value="rss">RSS / Atom</option>
                                            <option value="x">
                                                X through TwitterAPI.io
                                            </option>
                                        </select>
                                    </label>
                                    <label>
                                        Connection name
                                        <input
                                            value={label}
                                            maxLength={80}
                                            placeholder="My news feeds"
                                            onChange={lambda (e: any) { label = e.target.value; }}
                                        />
                                    </label>
                                    {if provider == "x" {
                                        <label>
                                            TwitterAPI.io API key
                                            <input
                                                type="password"
                                                autoComplete="off"
                                                value={apiKey}
                                                required
                                                maxLength={1024}
                                                onChange={lambda (e: any) { apiKey = e.target.value; }}
                                            />
                                        </label>
                                        <label>
                                            Daily request limit
                                            <input
                                                type="number"
                                                min="1"
                                                max="2000"
                                                value={dailyLimit}
                                                required
                                                onChange={lambda (e: any) { dailyLimit = e.target.value; }}
                                            />
                                        </label>
                                        <p className="ps-help">
                                            Uses your TwitterAPI.io credits. Accounts are checked periodically; the limit caps API requests, not dollars.
                                        </p>
                                    } else {
                                        <p className="ps-help">
                                            No API key needed. Add public RSS or Atom links after connecting.
                                        </p>
                                    } }
                                    <button type="submit" disabled={busy}>
                                        {"Connecting…" if busy else "Add connection"}
                                    </button>
                                </form>
                            }}
                        </section>
                        <section className="ps-panel">
                            <div className="ps-section-heading">
                                <h2>Following</h2>
                                <span className="ps-count">{len(sources)}</span>
                            </div>
                            {for source in sources {
                                <SourceCard
                                    key={str(_ps_user_id) + ":" + str(source.id)}
                                    source={source}
                                    busy={busy}
                                    onUpdate={update_source}
                                    onRemove={remove_source}
                                />
                            }}
                            {if not len(sources) {
                                <p className="ps-empty-small">
                                    Your followed accounts and feeds will appear here.
                                </p>
                            }}
                            {if len(connections) {
                                <form
                                    className="ps-form ps-add-source"
                                    onSubmit={add_source}
                                >
                                    <h3>Add a source</h3>
                                    <label>
                                        Connection
                                        <select
                                            value={selectedConnection
                                                or str(connections[0].id)}
                                            onChange={lambda (e: any) { selectedConnection = e.target.value; }}
                                        >
                                            {for connection in connections {
                                                <option
                                                    key={connection.id}
                                                    value={str(connection.id)}
                                                >
                                                    {connection.label}
                                                </option>
                                            }}
                                        </select>
                                    </label>
                                    <label>
                                        Feed URL or X account
                                        <input
                                            value={locator}
                                            required
                                            maxLength={2048}
                                            placeholder="https://example.com/feed or @account"
                                            onChange={lambda (e: any) { locator = e.target.value; }}
                                        />
                                    </label>
                                    <details className="ps-filters">
                                        <summary>Optional alert keywords</summary>
                                        <label>
                                            Include keywords
                                            <input
                                                value={newInclude}
                                                maxLength={1000}
                                                placeholder="earnings, technology"
                                                onChange={lambda (e: any) { newInclude = e.target.value; }}
                                            />
                                        </label>
                                        <label>
                                            Exclude keywords
                                            <input
                                                value={newExclude}
                                                maxLength={1000}
                                                placeholder="promotion"
                                                onChange={lambda (e: any) { newExclude = e.target.value; }}
                                            />
                                        </label>
                                        <p className="ps-help">
                                            Separate keywords with commas. These filter alerts; your feed keeps all collected posts.
                                        </p>
                                    </details>
                                    <label className="ps-toggle">
                                        <input
                                            type="checkbox"
                                            checked={newAlerts}
                                            onChange={lambda (e: any) { newAlerts = e.target.checked; }}
                                        />{" "}
                                        Notify me about new posts
                                    </label>
                                    <button type="submit" disabled={busy}>
                                        {"Adding…" if busy else "Follow source"}
                                    </button>
                                </form>
                            }}
                        </section>
                    </aside>
                    <section className="ps-feed-panel">
                        <div className="ps-section-heading">
                            <div>
                                <p className="ps-eyebrow">Your selected sources</p>
                                <h2>Latest news</h2>
                            </div>
                            <button
                                className="ps-quiet"
                                type="button"
                                disabled={busy}
                                onClick={lambda { refresh(_ps_epoch); }}
                            >
                                Refresh
                            </button>
                        </div>
                        <div className="ps-delivery">
                            <label className="ps-toggle">
                                <input
                                    type="checkbox"
                                    checked={screenEnabled}
                                    onChange={toggle_screen}
                                />{" "}
                                Screen notifications
                            </label>
                            <span className="ps-muted ps-small">
                                While this page is open in the background
                            </span>
                            {if screenHint {
                                <p className="ps-help">{screenHint}</p>
                            }}
                        </div>
                        {if len(alerts) {
                            <div className="ps-alerts" aria-live="polite">
                                {for alert in alerts {
                                    <div
                                        className="ps-alert"
                                        key={alert.notification_id}
                                    >
                                        <div>
                                            <span className="ps-eyebrow">
                                                {alert.source_name}
                                            </span>
                                            <strong>
                                                {alert.title or str(alert.text)[:140]}
                                            </strong>
                                        </div>
                                        <button
                                            type="button"
                                            className="ps-quiet"
                                            aria-label="Dismiss alert"
                                            onClick={lambda { dismiss(
                                                alert.notification_id
                                            ); }}
                                        >
                                            ×
                                        </button>
                                    </div>
                                }}
                            </div>
                        }}
                        {for item in feed {
                            <FeedItem key={item.id} item={item}/>
                        }}
                        {if not len(feed) {
                            <div className="ps-feed-empty">
                                <span className="ps-empty-icon">↗</span>
                                <h3>
                                    {"Your feed is ready for its first source"
                                        if not len(sources)
                                        else "Watching your sources"}
                                </h3>
                                <p>
                                    {"Add an RSS feed or X account to start collecting news on any topic."
                                        if not len(sources)
                                        else (
                                            "New posts will appear here after the next source check. Recent history loads without sending alerts."
                                                if loaded
                                                else "Loading your news…"
                                        )}
                                </p>
                            </div>
                        }}
                    </section>
                </div>
            } }
        </main>
    </div>
}

"""Publish a public channel or review individual private items before sharing."""

import "./publishing.css";
import from .public_data { SECTORS, sector_name }
import from .sector_tags { SectorPicker, SectorTags }
import from react { useEffect }

def ChannelForm(sources: list[any], request: any, created: any) -> JsxElement {
    has name: str = "",
        description: str = "",
        category: str = "energy",
        tags: list[any] = [],
        kind: str = "rss",
        mode: str = "embed",
        locator: str = "",
        busy: bool = False,
        error: str = "";

    def select_kind(nextKind: str) {
        kind = nextKind;
        mode = "embed";
        locator = "";
    }

    async def publish(e: any) {
        e.preventDefault();
        if busy {
            return;
        }
        busy = True;
        error = "";
        body: any = {
            "name": name.strip(),
            "description": description.strip(),
            "category": category,
            "tags": [category]
                + [
                    tag
                    for tag in tags
                    if tag != category
                ],
            "source_type": kind
        };
        if kind == "x" or kind == "telegram" {
            body.mode = mode;
        }
        if kind == "rss" or (kind in ["x", "telegram"] and mode == "embed") {
            body.source_url = locator.strip();
        }
        result = await request("/api/channels", "POST", body);
        busy = False;
        if not result.ok {
            error = result.error;
            return;
        }
        created(result.data.channel);
    }

    <form className="ps-form ps-public-form" onSubmit={publish}>
        <div className="ps-field-row">
            <label>
                Channel name
                <input
                    required
                    maxLength={80}
                    value={name}
                    onChange={lambda (e: any) { name = e.target.value; }}
                />
            </label>
            <label>
                Category
                <select
                    aria-label="Category"
                    value={category}
                    onChange={lambda (e: any) { category = e.target.value; }}
                >
                    {for slug in SECTORS + ["general"] {
                        <option key={slug} value={slug}>{sector_name(slug)}</option>
                    }}
                </select>
            </label>
        </div>
        <SectorPicker
            selected={tags}
            primary={category}
            label="Category tags"
            onChange={lambda (values: any) { tags = values; }}
        />
        <label>
            Description
            <textarea
                required
                maxLength={1000}
                rows={2}
                value={description}
                onChange={lambda (e: any) { description = e.target.value; }}
            />
        </label>
        <div className="ps-field-row">
            <label>
                Source type
                <select
                    aria-label="Source type"
                    value={kind}
                    onChange={lambda (e: any) { select_kind(e.target.value); }}
                >
                    <option value="rss">RSS / Atom</option>
                    <option value="community">Community</option>
                    <option value="x">X</option>
                    <option value="telegram">Telegram</option>
                </select>
            </label>
            {if kind in ["x", "telegram"] {
                <label>
                    Display
                    <select
                        value={mode}
                        onChange={lambda (e: any) {
                            mode = e.target.value;
                            locator = "";
                        }}
                    >
                        <option value="embed">Public embed or profile</option>
                        <option value="api">Selected posts via API</option>
                    </select>
                </label>
            }}
        </div>
        {if kind == "rss" or (kind in ["x", "telegram"] and mode == "embed") {
            <label>
                {"Public feed URL"
                    if kind == "rss"
                    else (
                        "Public X profile URL"
                            if kind == "x"
                            else "Public Telegram channel or post URL"
                    )}
                <input
                    required
                    type="url"
                    maxLength={2048}
                    placeholder={"https://example.com/feed"
                        if kind == "rss"
                        else (
                            "https://x.com/account"
                                if kind == "x"
                                else "https://t.me/channel/123"
                        )}
                    value={locator}
                    onChange={lambda (e: any) { locator = e.target.value; }}
                />
                <small>
                    Anyone can open this address. Use a public link without private tokens.
                </small>
            </label>
            if len(
                [
                    s
                    for s in sources
                    if s.provider == kind
                ]
            ) {
                <label>
                    Use a saved source
                    <select
                        value=""
                        onChange={lambda (e: any) { locator = e.target.value; }}
                    >
                        <option value="">Choose a public source</option>
                        {for s in [
                            source
                            for source in sources
                            if source.provider == kind
                        ] {
                            <option key={s.id} value={s.url}>{s.name}</option>
                        }}
                    </select>
                </label>
            }
        } elif mode == "api" and kind == "telegram" {
            <p className="ps-help">
                Connect Telegram below, forward a message to your private inbox, then choose the text to publish.
            </p>
        } elif mode == "api" and kind == "x" {
            <p className="ps-help">
                Connect an X provider and follow an account in Your sources. Choose individual collected posts in Share selected updates.
            </p>
        }  }
        {if error {
            <p role="alert" className="ps-inline-error">{error}</p>
        }}
        <button type="submit" disabled={busy}>
            {"Publishing…" if busy else "Publish public channel"}
        </button>
    </form>
}

def ShareForm(
    item: any, kind: str, channels: list[any], request: any, done: any
) -> JsxElement {
    has slug: str = "",
        title: str = "",
        excerpt: str = str(item.body or ""),
        confirmed: bool = False,
        busy: bool = False,
        error: str = "";
    choices = [
        c
        for c in channels
        if c.source_type == kind and c.mode == "api"
    ];
    async def share(e: any) {
        e.preventDefault();
        if busy or not confirmed or not len(choices) {
            return;
        }
        busy = True;
        body: any = {
            "provider": kind,
            "id": item.id,
            "slug": slug or choices[0].slug,
            "confirmed": True
        };
        if kind == "telegram" {
            body.title = title.strip();
            body.excerpt = excerpt.strip();
        }
        r = await request("/api/me/share-item", "POST", body);
        busy = False;
        if r.ok {
            done(body.slug);
        } else {
            error = r.error;
        }
    }
    <form className="ps-form ps-share-form" onSubmit={share}>
        {if kind == "telegram" {
            <label>
                Public headline
                <input
                    required
                    maxLength={180}
                    value={title}
                    onChange={lambda (e: any) { title = e.target.value; }}
                />
            </label>
            <label>
                Public excerpt
                <textarea
                    required
                    rows={4}
                    value={excerpt}
                    onChange={lambda (e: any) {
                        excerpt = e.target.value;
                        confirmed = False;
                    }}
                />
                <small>
                    Keep the whole message or one passage from it. Check that the text itself contains only what you intend to share.
                </small>
            </label>
        } else {
            <p className="ps-preview">{item.text}</p>
            <a href={item.url} target="_blank" rel="noopener noreferrer">
                Open original X post ↗
            </a>
        } }
        {if len(choices) {
            <label>
                Public channel
                <select
                    value={slug or choices[0].slug}
                    onChange={lambda (e: any) {
                        slug = e.target.value;
                        confirmed = False;
                    }}
                >
                    {for c in choices {
                        <option key={c.slug} value={c.slug}>{c.name}</option>
                    }}
                </select>
            </label>
            <label className="ps-toggle">
                <input
                    type="checkbox"
                    required
                    checked={confirmed}
                    onChange={lambda (e: any) { confirmed = e.target.checked; }}
                />
                I have permission to publish this selection publicly.
            </label>
            <button type="submit" disabled={busy or not confirmed}>
                {"Publishing…" if busy else "Publish selected text"}
            </button>
        } else {
            <p className="ps-help">
                {"Create a "
                    + ("Telegram" if kind == "telegram" else "X")
                    + " channel using Selected posts via API to publish this update."}
            </p>
        } }
        {if error {
            <p role="alert" className="ps-inline-error">{error}</p>
        }}
    </form>
}

def:pub PublishingPanel(
    sources: list[any], feed: list[any], request: any
) -> JsxElement {
    has channels: list[any] = [],
        telegram: any = None,
        creating: bool = False,
        pairURL: str = "",
        busy: bool = False,
        selection: any = None,
        kind: str = "",
        info: str = "",
        target: str = "",
        error: str = "",
        confirmDisconnect: bool = False;

    async def load_channels {
        r = await request("/api/channels");
        if r.ok {
            channels = [
                c
                for c in r.data.channels
                if c.owned
            ];
        } else {
            error = r.error;
        }
    }
    async def load_telegram {
        r = await request("/api/me/telegram");
        if r.ok {
            telegram = r.data;
            if r.data.linked {
                pairURL = "";
            }
        } else {
            error = r.error;
        }
    }
    useEffect(
        lambda {
            load_channels();
            load_telegram();
            focus = lambda { load_telegram(); };
            window.addEventListener("focus", focus);
            return lambda { window.removeEventListener("focus", focus); };
        },
        []
    );

    async def pair {
        busy = True;
        error = "";
        r = await request("/api/me/telegram/pair", "POST");
        busy = False;
        if r.ok {
            pairURL = r.data.url;
        } else {
            error = r.error;
        }
    }

    async def disconnect {
        busy = True;
        error = "";
        r = await request("/api/me/telegram", "DELETE");
        busy = False;
        if r.ok {
            confirmDisconnect = False;
            pairURL = "";
            selection = None;
            await load_telegram();
        } else {
            error = r.error;
        }
    }

    def choose(provider: str, item: any) {
        selection = item;
        kind = provider;
        info = "";
        target = "";
    }

    def shared(slug: str) {
        selection = None;
        info = "Published to your channel.";
        target = slug;
    }

    def created(channel: any) {
        channels = [channel] + channels;
        creating = False;
        info = "Channel published.";
        target = channel.slug;
    }

    xItems = [
        i
        for i in feed
        if i.provider == "x"
    ];
    <section className="ps-publishing">
        <div className="ps-public-heading">
            <h2>Published channels</h2>
            <button
                type="button"
                onClick={lambda {
                    creating = not creating;
                    error = "";
                    info = "";
                }}
            >
                {"Cancel" if creating else "Create channel"}
            </button>
        </div>
        {if info {
            <p className="ps-message ps-notice" role="status">
                {info}{" "}
                <a href={"/channels/" + target}>Open channel</a>
            </p>
        }}
        {if error {
            <p className="ps-inline-error" role="alert">{error}</p>
        }}
        {if len(channels) {
            <ul className="ps-channel-list">
                {for c in channels {
                    <li key={c.slug}>
                        <a href={"/channels/" + c.slug}>{c.name}</a>
                        <SectorTags tags={c.tags or [c.category]}/>
                        <span>{str(c.source_type).upper()}</span>
                    </li>
                }}
            </ul>
        } elif not creating {
            <p className="ps-help">
                Publish a channel to make it available in Discover.
            </p>
        } }
        {if creating {
            <ChannelForm sources={sources} request={request} created={created}/>
        }}
        <details className="ps-publish-details">
            <summary>Share selected updates</summary>
            <div className="ps-share-inbox">
                <div className="ps-public-heading">
                    <h3>Private Telegram inbox</h3>
                    <button
                        className="ps-quiet"
                        type="button"
                        onClick={lambda { load_telegram(); }}
                    >
                        Refresh inbox
                    </button>
                </div>
                {if telegram and telegram.linked {
                    <p className="ps-help">
                        Forward messages you have permission to share to your connected bot. Pick one below to preview its public excerpt.
                    </p>
                    for item in telegram.items {
                        <button
                            className="ps-inbox-row"
                            key={item.id}
                            type="button"
                            onClick={lambda { choose("telegram", item); }}
                        >
                            {str(item.body)[:110]}
                        </button>
                    }
                    if not len(telegram.items) {
                        <p className="ps-muted">Your inbox is empty.</p>
                    }
                    if confirmDisconnect {
                        <p>Disconnect Telegram and clear the private inbox?</p>
                        <button
                            className="ps-quiet"
                            type="button"
                            disabled={busy}
                            onClick={lambda { disconnect(); }}
                        >
                            Disconnect and clear
                        </button>
                        <button
                            className="ps-quiet"
                            type="button"
                            onClick={lambda { confirmDisconnect = False; }}
                        >
                            Cancel
                        </button>
                    } else {
                        <button
                            className="ps-quiet"
                            type="button"
                            onClick={lambda { confirmDisconnect = True; }}
                        >
                            Disconnect Telegram
                        </button>
                    }
                } elif telegram and telegram.available {
                    <button type="button" disabled={busy} onClick={lambda { pair(); }}>
                        {"Generate a new link"
                            if pairURL
                            else "Connect Telegram account"}
                    </button>
                    if pairURL {
                        <p>
                            <a href={pairURL} target="_blank" rel="noreferrer noopener">
                                Open Telegram and press Start ↗
                            </a>{" "}
                            <small>Expires in 10 minutes.</small>
                        </p>
                    }
                } elif telegram {
                    <p className="ps-help">
                        The private inbox bot is unavailable on this server. Public Telegram channels and posts can still be linked when creating a channel.
                    </p>
                }  }
                <h3>Connected X posts</h3>
                {for item in xItems {
                    <button
                        className="ps-inbox-row"
                        key={item.id}
                        type="button"
                        onClick={lambda { choose("x", item); }}
                    >
                        {str(item.title or item.text)[:110]}
                    </button>
                }}
                {if not len(xItems) {
                    <p className="ps-help">
                        Posts from your connected X sources appear here after collection.
                    </p>
                }}
                {if selection {
                    <div className="ps-public-heading">
                        <h3>Review selected update</h3>
                        <button
                            type="button"
                            className="ps-quiet"
                            onClick={lambda { selection = None; }}
                        >
                            Cancel
                        </button>
                    </div>
                    <ShareForm
                        key={kind + str(selection.id)}
                        item={selection}
                        kind={kind}
                        channels={channels}
                        request={request}
                        done={shared}
                    />
                }}
            </div>
        </details>
    </section>
}

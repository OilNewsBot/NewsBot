"""Shared public feeds and channel discovery."""

import from react { useEffect, useRef }
import from .auth { AuthPanel, SESSION_EVENT }
import from .navigation { Navigation }
import from .public_data {
    SECTORS,
    sector_name,
    source_name,
    count_label,
    by_sector,
    order_channels,
    request_json
}
import from .public_channel { ChannelPage }
import from .briefing { Briefing, Timeline }
import from .watches { useWatches, WatchManager }
import from .sector_tags { SectorTags, SectorPicker }
import from .public_story { ShareChannel, Story }
import "./directory.css";

def ChannelRow(
    channel: any, watch: any, sector: str = "", onClicks: any = None
) -> JsxElement {
    has clicks: int = int(channel.clicks or 0);
    counted: any = useRef(False);
    useEffect(lambda { clicks = int(channel.clicks or 0); }, [channel.clicks]);
    async def opened(e: any) {
        if not e.currentTarget.open or counted.current {
            return;
        }
        counted.current = True;
        res = await request_json(
            "/api/channels/" + str(channel.slug) + "/click", "POST"
        );
        if res.ok {
            clicks = int(res.data.clicks);
            if onClicks {
                onClicks(channel.slug, clicks);
            }
        } else {
            counted.current = False;
        }
    }
    def navigate {
        if counted.current {
            try {
                sessionStorage.setItem("ns-click-from-preview", str(channel.slug));
            } except Exception {}
        }
    }
    headlines = [
        item
        for item in channel.headlines
        if not sector
            or item.section == sector
            or (not item.section and sector in (channel.tags or [channel.category]))
    ][:3];
    <li>
        <details className="channel-disclosure" onToggle={opened}>
            <summary>
                <div className="row-info">
                    <span className="channel-meta">
                        {source_name(channel.source_type)}
                    </span>
                    <SectorTags tags={channel.tags or [channel.category]}/>
                    <span className="channel-name">{channel.name}</span>
                    <span className="channel-description">{channel.description}</span>
                </div>
                <span className="channel-count">
                    {count_label(clicks, "click", "clicks")}
                </span>
                <span className="disclosure-chevron" aria-hidden="true"></span>
            </summary>
            <div className="channel-stories">
                <div className="channel-byline">
                    <span>{"By " + str(channel.publisher)}</span>
                    <span>
                        {count_label(
                            channel.recommendations, "recommendation", "recommendations"
                        )}
                    </span>
                </div>
                {if len(headlines) {
                    <div className="preview-stories">
                        {for item in headlines {
                            <Story watch={watch} key={str(item.id)} item={item}/>
                        }}
                    </div>
                } else {
                    <p className="directory-muted">No published updates yet.</p>
                } }
                <div className="channel-actions">
                    <a href={"/channels/" + str(channel.slug)} onClick={navigate}>
                        Open channel →
                    </a>
                    <ShareChannel slug={channel.slug}/>
                </div>
            </div>
        </details>
    </li>
}

def ChannelList(
    channels: list[any], watch: any, sector: str = "", onClicks: any = None
) -> JsxElement {
    <ul className="channel-list" aria-label="Channels">
        {for ch in channels {
            <ChannelRow
                watch={watch}
                key={str(ch.slug)}
                channel={ch}
                sector={sector}
                onClicks={onClicks}
            />
        }}
    </ul>
}

def Home(channels: list[any], watch: any) -> JsxElement {
    favorites = order_channels(
        [
            c
            for c in channels
            if c.recommendations > 0
        ],
        "rating"
    )[:4];
    mixed = by_sector(channels, "general");
    <main className="directory">
        <header className="directory-heading">
            {if watch.data {
                <h2 id="sectors">Browse sectors</h2>
            } else {
                <h1 id="sectors">Market forums</h1>
            } }
            <p>Explore the channels covering your sectors.</p>
        </header>
        <div className="sector-grid">
            {for sector in SECTORS {
                <a className="sector-card" key={sector} href={"/categories/" + sector}>
                    <img src={"/directory-images/" + sector + ".jpg"} alt=""/>
                    <div className="sector-body">
                        <span className="sector-count">
                            {count_label(
                                len(by_sector(channels, sector)), "channel", "channels"
                            )}
                        </span>
                        <h2>
                            {sector_name(sector)}
                            <span aria-hidden="true">↗</span>
                        </h2>
                        <p>
                            {", ".join(
                                [
                                    str(ch.name)
                                    for ch in channels
                                    if ch.category == sector
                                ][:2]
                            )}
                        </p>
                    </div>
                </a>
            }}
        </div>
        {if len(favorites) {
            <section className="news-section">
                <h2>Top recommended channels</h2>
                <ChannelList watch={watch} channels={favorites}/>
            </section>
        }}
        <div className="home-links">
            <a href="/discover">Discover all channels →</a>
            {if len(mixed) {
                <a href="/categories/general">Browse General News →</a>
            }}
        </div>
    </main>
}

def Discover(channels: list[any], onClicks: any, watch: any) -> JsxElement {
    has tab: str = "all",
        sortOrder: str = "name",
        sector: str = "";
    # New uses publication time. Trending is an explicit view of recorded clicks.
    order = sortOrder if tab == "all" else ("new" if tab == "new" else "clicks");
    rows = [
        c
        for c in (by_sector(channels, sector) if sector else channels)
        if tab != "trending" or c.clicks > 0
    ];
    <main className="directory">
        <header className="directory-heading">
            <h1>Discover</h1>
            <p>
                {count_label(len(channels), "published channel", "published channels")}
            </p>
        </header>
        <div className="discover-controls">
            <div className="discover-tabs" role="group" aria-label="Channel lists">
                {for choice in ["all", "new", "trending"] {
                    <button
                        key={choice}
                        type="button"
                        aria-pressed={tab == choice}
                        className={"current" if tab == choice else ""}
                        onClick={lambda { tab = choice; }}
                    >
                        {"All channels"
                            if choice == "all"
                            else ("New channels" if choice == "new" else "Trending")}
                    </button>
                }}
            </div>
            <label className="discover-sort">
                Category
                <select
                    aria-label="Category"
                    value={sector}
                    onChange={lambda (e: any) { sector = e.target.value; }}
                >
                    <option value="">All categories</option>
                    {for slug in SECTORS + ["general"] {
                        <option key={slug} value={slug}>{sector_name(slug)}</option>
                    }}
                </select>
            </label>
            {if tab == "all" {
                <label className="discover-sort">
                    Sort by
                    <select
                        value={sortOrder}
                        onChange={lambda (e: any) { sortOrder = e.target.value; }}
                    >
                        <option value="name">Name (A–Z)</option>
                        <option value="category">Category</option>
                        <option value="clicks">Most clicks</option>
                    </select>
                </label>
            }}
        </div>
        {if tab == "new" {
            <p className="list-note">Newest publication first.</p>
        }}
        {if tab == "trending" {
            <p className="list-note">Ranked by total channel clicks.</p>
        }}
        {if len(rows) {
            <ChannelList
                watch={watch}
                channels={order_channels(rows, order)}
                sector={sector}
                onClicks={onClicks}
            />
        } else {
            <p className="public-empty">
                {"Trending channels will appear as readers open them."
                    if tab == "trending"
                    else "No channels match this category."}
            </p>
        } }
    </main>
}

def Following(data: any, reload: any, watch: any) -> JsxElement {
    has saving: bool = False,
        issue: str = "";
    names: dict[str, str] = {str(c.slug): str(c.name) for c in data.channels};
    categories = data.categories or [];
    async def save(path: str, body: any) {
        if saving {
            return;
        }
        saving = True;
        issue = "";
        res = await request_json(path, "PUT", body);
        if res.ok or res.status == 401 {
            await reload();
        } else {
            issue = res.error;
        }
        saving = False;
    }
    <main className="directory directory-reading">
        <header className="directory-heading">
            <h1>Following</h1>
            <p>Your followed channels and private sources in one feed.</p>
        </header>
        <section className="coverage-panel" aria-label="Feed preferences">
            <SectorPicker
                label="Show updates and alerts for"
                allowAll={True}
                selected={categories}
                disabled={saving}
                onChange={lambda (values: any) { save(
                    "/api/me/feed-preferences", {"categories": values}
                ); }}
            />
            <p>Choose any combination. Your selection is saved across devices.</p>
            {if issue {
                <p role="alert">{issue}</p>
            }}
        </section>
        <details className="followed-controls">
            <summary>
                {count_label(
                    len(data.channels), "followed channel", "followed channels"
                )
                    + " · Manage alerts"}
            </summary>
            {for ch in data.channels {
                <div className="followed-channel" key={ch.slug}>
                    <div>
                        <a href={"/channels/" + str(ch.slug)}>{ch.name}</a>
                        <SectorTags tags={ch.tags or [ch.category]}/>
                    </div>
                    <button
                        type="button"
                        aria-pressed={bool(ch.notifications_enabled)}
                        aria-label={"Alerts for " + str(ch.name)}
                        disabled={saving}
                        onClick={lambda { save(
                            "/api/channels/" + str(ch.slug) + "/notifications",
                            {"enabled": not ch.notifications_enabled}
                        ); }}
                    >
                        {"Alerts on" if ch.notifications_enabled else "Alerts off"}
                    </button>
                </div>
            }}
            <div className="home-links">
                <a href="/discover">Find channels →</a>
                <a href="/sources">Manage private sources →</a>
            </div>
        </details>
        <WatchManager watch={watch}/>
        <section className="news-section">
            <h2>Latest updates</h2>
            {if not len(data.items) {
                <p className="directory-muted">
                    {"No updates match these categories yet."
                        if len(categories)
                        else "No updates yet. Explore Discover or add a private source in My Sources."}
                </p>
            }}
            {for item in data.items {
                <div
                    className="following-story"
                    key={str(item.channel_slug or "private") + "/" + str(item.id)}
                >
                    <Story
                        watch={watch}
                        item={item}
                        channel_name={item.source_name
                            if item.private_source
                            else names.get(
                                str(item.channel_slug), str(item.channel_slug)
                            )}
                    />
                    {if item.sources and len(item.sources) > 1 {
                        <div className="channel-byline" aria-label="Source references">
                            <span>Sources</span>
                            {for ref in item.sources {
                                <a
                                    key={str(ref.channel_slug) + str(ref.url)}
                                    href={ref.url
                                        or ("/channels/" + str(ref.channel_slug))}
                                >
                                    {ref.name}
                                </a>
                            }}
                        </div>
                    }}
                    {if item.private_source {
                        <a href="/sources">Private source →</a>
                    } else {
                        <a
                            href={"/channels/"
                                + str(item.channel_slug)
                                + "#story-"
                                + str(item.id)}
                        >
                            Open discussion →
                        </a>
                    } }
                </div>
            }}
        </section>
    </main>
}

def Browse(path: str, watch: any) -> JsxElement {
    has data: any = None,
        error: str = "",
        unauthorized: bool = False;
    epoch: any = useRef(0);
    async def load {
        epoch.current += 1;
        seq = epoch.current;
        res = await request_json(
            "/api/following" if path == "/following" else "/api/channels"
        );
        if seq != epoch.current {
            return;
        }
        if res.ok {
            data = res.data;
            error = "";
            unauthorized = False;
        } elif res.status == 401 {
            data = None;
            unauthorized = True;
            error = "";
        } else {
            error = res.error;
        }
    }
    useEffect(
        lambda {
            load();
            on_change = lambda {
                data = None;
                unauthorized = False;
                error = "";
                load();
            };
            window.addEventListener(SESSION_EVENT, on_change);
            timer = setInterval(lambda { load(); }, 120000);
            return lambda {
                clearInterval(timer);
                epoch.current += 1;
                window.removeEventListener(SESSION_EVENT, on_change);
            };
        },
        [path]
    );
    def change_clicks(slug: str, clicks: int) {
        if data {
            # Replace the affected row so a clicks-sorted list updates in place.
            updated: list[any] = [];
            for c in data.channels {
                if c.slug == slug {
                    copy: any = {** c};
                    copy.clicks = clicks;
                    updated.append(copy);
                } else {
                    updated.append(c);
                }
            }
            data = {"channels": updated};
        }
    }
    if unauthorized {
        return
            <main className="directory directory-reading">
                <h1>Following</h1>
                <p>Sign in to see updates from the channels you follow.</p>
                <AuthPanel/>
            </main>;
    }
    if error {
        return
            <main className="directory">
                <h1>Feed unavailable</h1>
                <p role="alert">{error}</p>
                <button onClick={lambda { load(); }}>Try again</button>
            </main>;
    }
    if not data {
        return
            <main className="directory">
                <p role="status">Loading channels…</p>
            </main>;
    }
    if path == "/" {
        return <Home watch={watch} channels={data.channels}/>;
    }
    if path == "/discover" {
        return
            <Discover watch={watch} channels={data.channels} onClicks={change_clicks}/>;
    }
    if path == "/following" {
        return <Following watch={watch} data={data} reload={load}/>;
    }
    slug = path.split("/")[2] if path.startswith("/categories/") else "";
    if slug in SECTORS or slug == "general" {
        rows = by_sector(data.channels, slug);
        return
            <main className="directory directory-reading">
                <a className="directory-back" href="/">← All sectors</a>
                <header className="directory-heading">
                    <h1>{sector_name(slug)}</h1>
                    <p>{count_label(len(rows), "channel", "channels")}</p>
                </header>
                <ChannelList watch={watch} channels={rows} sector={slug}/>
            </main>;
    }
    return
        <main className="directory">
            <h1>Page not found</h1>
            <a href="/discover">Discover channels</a>
        </main>;
}

def:pub DirectoryPage(path: str) -> JsxElement {
    watch = useWatches();
    active = "home"
        if path == "/"
            or path.startswith("/categories/")
            or path.startswith("/stories/")
        else ("following" if path == "/following" else "discover");
    <div className="app-layout">
        <Navigation active={active}/>
        {if watch.issue {
            <p className="watch-error" role="alert">
                {watch.issue}{" "}
                <button type="button" onClick={lambda { watch.load(); }}>
                    Retry watch list
                </button>
            </p>
        }}
        {if path == "/" {
            <Briefing watch={watch}/>
        }}
        {if path.startswith("/stories/") {
            <Timeline storyId={path.split("/")[2]} watch={watch}/>
        } elif path.startswith("/channels/") {
            <ChannelPage watch={watch} slug={path.split("/")[2]}/>
        } else {
            <Browse watch={watch} path={path}/>
        }  }
    </div>
}

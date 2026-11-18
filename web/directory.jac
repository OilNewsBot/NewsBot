"""Shared public feeds and channel discovery."""

import from react { useEffect, useRef }
import from .auth { sign_in_url, SESSION_EVENT }
import from .navigation { Navigation }
import from .public_data {
    SECTORS,
    sector_name,
    source_name,
    count_label,
    channel_preview,
    by_sector,
    order_channels,
    request_json
}
import from .public_channel { ChannelPage }
import from .insights { ReadingDesk, CoverageInsights, FollowingInsights }
import from .briefing { Briefing, Timeline }
import from .watches { useWatches, WatchManager }
import from .sector_tags { SectorTags, SectorPicker }
import from .public_story { ShareChannel, Story }
import "./directory.css";
import "./reading_desk.css";

def ChannelRow(
    channel: any,
    watch: any,
    sector: str = "",
    onClicks: any = None,
    restored: bool = False
) -> JsxElement {
    has clicks: int = int(channel.clicks or 0);
    counted: any = useRef(restored);
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
    headlines = channel_preview(channel, sector);
    <li>
        <details
            className="channel-disclosure"
            open={restored}
            data-channel={channel.slug}
            onToggle={opened}
        >
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
    channels: list[any],
    watch: any,
    sector: str = "",
    onClicks: any = None,
    expanded: any = None
) -> JsxElement {
    <ul className="channel-list" aria-label="Channels">
        {for ch in channels {
            <ChannelRow
                watch={watch}
                key={str(ch.slug)}
                channel={ch}
                sector={sector}
                onClicks={onClicks}
                restored={bool(expanded and str(ch.slug) in expanded)}
            />
        }}
    </ul>
}

def SectorIcon(sector: str) -> JsxElement {
    paths = {
        "energy": "M13 2 4 14h7l-1 8 10-13h-7l1-7z",
        "tech": "M6 6h12v12H6z M9 9h6v6H9z M9 3v3m6-3v3M9 18v3m6-3v3M3 9h3m-3 6h3m12-6h3m-3 6h3",
        "healthcare": "M3 12h5l3-7 3 14 3-7h4",
        "industrials": "M3 20V9l6 3V8l6 4 1-9h3l2 17H3z M7 16h1m3 0h1m3 0h1",
        "consumer-discretionary": "M5 8h14l1 13H4L5 8z M9 9V6a3 3 0 0 1 6 0v3",
        "materials": "m3 8 9-5 9 5-9 5-9-5z M3 12l9 5 9-5 M3 16l9 5 9-5",
        "utilities": "M8 3v5m8-5v5M6 8h12v3a6 6 0 0 1-12 0V8z M12 17v4",
        "real-estate": "M3 21h18M5 21V7l9-4v18m0-11h5v11M8 10h2m-2 4h2m-2 4h2"
    };
    <span className={"sector-icon sector-icon-" + sector} aria-hidden="true">
        <svg
            width="23"
            height="23"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.65"
            strokeLinecap="round"
            strokeLinejoin="round"
        >
            <path d={paths[sector]}/>
        </svg>
    </span>
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
    <main className="directory forum-home">
        {if not watch.data {
            <header className="forum-intro">
                <div>
                    <h1>Market forums</h1>
                    <p>
                        Browse market coverage by sector and trace each story to its source.
                    </p>
                    <a href="/discover">
                        Discover channels{" "}
                        <span aria-hidden="true">→</span>
                    </a>
                </div>
                <img
                    className="forum-mark"
                    src="/brand/drop.svg"
                    alt=""
                    width={80}
                    height={80}
                />
            </header>
        }}
        <header className="sector-heading">
            <h2 id="sectors">Browse sectors</h2>
            {if len(mixed) {
                <a href="/categories/general">General News →</a>
            }}
        </header>
        <div className="sector-list">
            {for sector in SECTORS {
                <a className="sector-row" key={sector} href={"/categories/" + sector}>
                    <SectorIcon sector={sector}/>
                    <div className="sector-body">
                        <h3>{sector_name(sector)}</h3>
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
                    <span className="sector-count">
                        {count_label(
                            len(by_sector(channels, sector)), "channel", "channels"
                        )}
                    </span>
                    <span className="row-arrow" aria-hidden="true">›</span>
                </a>
            }}
        </div>
        {if len(favorites) {
            <section className="news-section">
                <h2>Top recommended channels</h2>
                <ChannelList watch={watch} channels={favorites}/>
            </section>
        }}
        {if watch.data {
            <a className="browse-all" href="/discover">Discover all channels →</a>
        }}
    </main>
}

# Store the directory view on its own browser history entry. A new visit
# starts fresh, while Back can restore cards after async channel loading.
def discover_entry -> any {
    win: any = window;
    state: any = win.history.state or {};
    return state.discover or {};
}

def Discover(channels: list[any], onClicks: any, watch: any) -> JsxElement {
    restoration: any = useRef(discover_entry());
    has tab: str = str(restoration.current.tab or "all"),
        sortOrder: str = str(restoration.current.sortOrder or "name"),
        sector: str = str(restoration.current.sector or ""),
        query: str = str(restoration.current.query or "");
    useEffect(
        lambda {
            win: any = window;
            frame = win.requestAnimationFrame(
                lambda { if restoration.current.scrollY {
                    win.scrollTo(0, restoration.current.scrollY);
                }}
            );
            return lambda { win.cancelAnimationFrame(frame); };
        },
        []
    );
    useEffect(
        lambda {
            win: any = window;
            doc: any = document;
            save_view = lambda {
                expanded: list[str] = [];
                for row in doc.querySelectorAll(".channel-disclosure[open]") {
                    expanded.append(str(row.dataset.channel));
                }
                state: any = win.history.state or {};
                win.history.replaceState(
                    {
                        ** state,
                        "discover": {
                            "tab": tab,
                            "sortOrder": sortOrder,
                            "sector": sector,
                            "query": query,
                            "expanded": expanded,
                            "scrollY": win.scrollY
                        }
                    },
                    ""
                );
            };
            win.addEventListener("pagehide", save_view);
            return lambda { win.removeEventListener("pagehide", save_view); };
        },
        [tab, sortOrder, sector, query]
    );
    needle = query.strip().lower();
    # New uses publication time. Trending is an explicit view of recorded clicks.
    order = sortOrder if tab == "all" else ("new" if tab == "new" else "clicks");
    rows = [
        c
        for c in (by_sector(channels, sector) if sector else channels)
        if (tab != "trending" or c.clicks > 0) and needle in str(c.name).lower()
    ];
    content = <main className="directory">
        <header className="directory-heading">
            <h1>Discover</h1>
            <p role="status">
                {count_label(len(rows), "channel", "channels")
                    + (
                        " of " + str(len(channels)) + " published"
                            if sector or needle or tab == "trending"
                            else " published"
                    )}
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
            <label className="discover-sort channel-search">
                Search channels
                <input
                    type="search"
                    placeholder="Channel name"
                    value={query}
                    onChange={lambda (e: any) { query = e.target.value; }}
                />
            </label>
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
                expanded={restoration.current.expanded}
            />
        } else {
            <p className="public-empty">
                {"No channels match your search or filters."
                    if sector or needle
                    else "Trending channels will appear as readers open them."}
            </p>
        } }
    </main>;
    <ReadingDesk
        label="Discover"
        content={content}
        insights={<CoverageInsights channels={rows} sector={sector}/>}
    />
}

def Following(data: any, reload: any, watch: any) -> JsxElement {
    has saving: bool = False,
        issue: str = "";
    anchorsReady = bool(watch.data);
    useEffect(
        lambda {
            win: any = window;
            doc: any = document;
            def reveal {
                fragment = str(win.location.hash);
                if fragment == "#watches" {
                    target = doc.querySelector("#watches .topic-directory");
                } elif fragment in ["#channel-alerts", "#followed-channels"] {
                    target = doc.querySelector("#channel-alerts");
                } else {
                    return;
                }
                if target {
                    target.open = True;
                    summary = target.querySelector("summary");
                    summary.focus({"preventScroll": True});
                    summary.scrollIntoView({"block": "start"});
                }
            }
            frame = win.requestAnimationFrame(reveal);
            win.addEventListener("hashchange", reveal);
            # Re-open a disclosure when the reader follows the same fragment again.
            def same_fragment(e: any) {
                link = e.target.closest("a");
                if link
                    and link.hash
                    and link.hash == win.location.hash
                    and link.pathname == win.location.pathname {
                    reveal();
                }
            }
            doc.addEventListener("click", same_fragment);
            return lambda {
                win.cancelAnimationFrame(frame);
                win.removeEventListener("hashchange", reveal);
                doc.removeEventListener("click", same_fragment);
            };
        },
        [anchorsReady]
    );
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
        <details className="coverage-panel feed-filters">
            <summary>
                {"Feed categories · "
                    + (
                        ", ".join([sector_name(c) for c in categories])
                            if len(categories)
                            else "All categories"
                    )}
            </summary>
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
        </details>
        <section className="news-section">
            <h2>Latest updates</h2>
            {if not len(data.items) {
                <p className="directory-muted">
                    {"No updates match these categories yet."
                        if len(categories)
                        else "No updates yet."}{" "}
                    <a href="/discover">Discover channels</a>
                    {" · "}
                    <a href="/sources">Manage private sources</a>
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
                                + "#discussion-"
                                + str(item.id)}
                        >
                            Open discussion →
                        </a>
                    } }
                </div>
            }}
        </section>
        <details id="channel-alerts" className="followed-controls">
            <summary>
                {count_label(
                    len(data.channels), "followed channel", "followed channels"
                )
                    + " · Manage alerts"}
            </summary>
            <div id="followed-channels" tabIndex={-1}>
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
            </div>
        </details>
        <WatchManager watch={watch}/>
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
    if path == "/" {
        content = <div>
            <Briefing watch={watch}/>
            {if error {
                <main className="directory">
                    <p role="alert">{error}</p>
                    <button onClick={lambda { load(); }}>Try again</button>
                </main>
            } elif data {
                <Home watch={watch} channels={data.channels}/>
            } else {
                <main className="directory">
                    <p role="status">Loading channels…</p>
                </main>
            }  }
        </div>;
        panel = <CoverageInsights channels={data.channels}/>
            if data and not error
            else <p className="insights-scope">
                {"Coverage unavailable." if error else "Loading coverage…"}
            </p>;
        return <ReadingDesk label="Home" content={content} insights={panel}/>;
    }
    if unauthorized {
        return
            <main className="directory directory-reading">
                <h1>Following</h1>
                <p>Sign in to see updates from the channels you follow.</p>
                <a className="button-link primary-action" href={sign_in_url()}>
                    Log in or register
                </a>
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
    if path == "/discover" {
        return
            <Discover watch={watch} channels={data.channels} onClicks={change_clicks}/>;
    }
    if path == "/following" {
        return
            <ReadingDesk
                label="Following"
                content={<Following watch={watch} data={data} reload={load}/>}
                insights={<FollowingInsights data={data} watch={watch}/>}
            />;
    }
    slug = path.split("/")[2] if path.startswith("/categories/") else "";
    if slug in SECTORS or slug == "general" {
        rows = by_sector(data.channels, slug);
        content = <main className="directory directory-reading">
            <a className="directory-back" href="/">← All sectors</a>
            <header className="directory-heading">
                <h1>{sector_name(slug)}</h1>
                <p>{count_label(len(rows), "channel", "channels")}</p>
            </header>
            <ChannelList watch={watch} channels={rows} sector={slug}/>
        </main>;
        return
            <ReadingDesk
                label={sector_name(slug)}
                content={content}
                insights={<CoverageInsights channels={rows} sector={slug}/>}
            />;
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
        {if path.startswith("/stories/") {
            <Timeline storyId={path.split("/")[2]} watch={watch}/>
        } elif path.startswith("/channels/") {
            <ChannelPage watch={watch} slug={path.split("/")[2]}/>
        } else {
            <Browse watch={watch} path={path}/>
        }  }
    </div>
}

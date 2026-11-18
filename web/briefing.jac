"""Reader briefing snapshots and source-attributed story timelines."""

import from react { useEffect, useRef }
import from .auth { SESSION_EVENT }
import from .public_data { display_date, public_url, request_json, sector_name }
import from .watches { StoryLabels, WatchButton }
import "./briefing.css";

def SourceLinks(sources: list[any]) -> JsxElement {
    <div className="brief-sources">
        {for source in sources {
            if public_url(source.url) {
                <a
                    key={str(source.url) + str(source.item_id)}
                    href={public_url(source.url)}
                    target="_blank"
                    rel="noopener noreferrer"
                >
                    {source.name or source.publisher or "Original source"} ↗
                </a>
            } elif source.channel_slug {
                <a
                    key={source.channel_slug}
                    href={"/channels/" + str(source.channel_slug)}
                >
                    {source.name}
                </a>
            } else {
                <span key={source.name}>{source.name}</span>
            }
        }}
    </div>
}

def BriefCard(card: any, watch: any, detail: bool = False) -> JsxElement {
    sid = card.story_id or card.id;
    <article className="brief-card">
        <div className="brief-byline">
            {if card.change and not detail {
                <strong>{card.change}</strong>
            }}
            {if card.section {
                <span>{sector_name(card.section)}</span>
            }}
            {if card.labels and len(card.labels.subsectors or []) {
                <span>{card.labels.subsectors[0].label}</span>
            }}
            {if card.published {
                <time dateTime={card.published}>{display_date(card.published)}</time>
            }}
        </div>
        {if detail {
            <h1>{card.title}</h1>
        } else {
            <h3>
                <a href={"/stories/" + str(sid)}>{card.title}</a>
            </h3>
        } }
        {if card.delta and not detail {
            <p>{card.delta}</p>
        } elif card.summary {
            <p>{card.summary}</p>
        } }
        {if card.ai_generated {
            <span className="summary-label">AI summary</span>
        }}
        {if card.reason and not detail {
            <p className="brief-reason">{card.reason}</p>
        }}
        <SourceLinks sources={card.sources or []}/>
        <div className="story-tools">
            {if not detail {
                <a href={"/stories/" + str(sid)}>Story timeline →</a>
            }}
            <WatchButton
                watch={watch}
                kind="stories"
                row={{"id": sid, "title": card.title}}
            />
        </div>
        {if detail {
            <StoryLabels labels={card.labels} watch={watch}/>
        } elif card.labels {
            <details className="story-label-details">
                <summary>Story labels</summary>
                <StoryLabels labels={card.labels} watch={watch}/>
            </details>
        } }
    </article>
}

def:pub Briefing(watch: any) -> JsxElement {
    has edition: any = None,
        failed: str = "",
        receipt: str = "",
        signedOut: bool = False,
        expanded: bool = False,
        guarded: bool = False,
        loading: bool = True;
    generation: any = useRef(0);
    seen: any = useRef("");
    writing: any = useRef("");
    async def load(reset: bool = False) {
        generation.current += 1;
        version = generation.current;
        if reset {
            edition = None;
            signedOut = False;
            seen.current = "";
            receipt = "";
        }
        failed = "";
        loading = True;
        result = await request_json("/api/briefing");
        if version != generation.current {
            return;
        }
        loading = False;
        if result.ok {
            receipt = "";
            doc: any = document;
            guarded = doc.visibilityState != "visible";
            expanded = False;
            edition = result.data;
            signedOut = False;
        } elif result.status == 401 {
            edition = None;
            signedOut = True;
        } else {
            failed = result.error;
        }
    }
    async def acknowledge(snapshot: any, version: int) {
        doc: any = document;
        if not snapshot
            or doc.visibilityState != "visible"
            or version != generation.current {
            return;
        }
        token = str(version)
            + "/"
            + str(snapshot.user_id)
            + "/"
            + str(snapshot.through)
            + "/"
            + str(snapshot.private_through or 0);
        if token == seen.current or token == writing.current {
            return;
        }
        writing.current = token;
        result = await request_json(
            "/api/briefing/seen",
            "POST",
            {
                "through": snapshot.through,
                "private_through": snapshot.private_through or 0,
                "user_id": snapshot.user_id
            }
        );
        if writing.current == token {
            writing.current = "";
        }
        if version != generation.current {
            return;
        }
        if result.ok {
            seen.current = token;
            receipt = "saved";
        } elif result.status in [401, 409] {
            await load(True);
        } else {
            receipt = "failed";
        }
    }
    useEffect(
        lambda {
            load(True);
            change = lambda { load(True); };
            window.addEventListener(SESSION_EVENT, change);
            return lambda {
                generation.current += 1;
                window.removeEventListener(SESSION_EVENT, change);
            };
        },
        []
    );
    useEffect(
        lambda {
            if not edition {
                return;
            }
            snapshot = edition;
            version = generation.current;
            doc: any = document;
            win: any = window;
            async def visible {
                if version != generation.current {
                    return;
                }
                if doc.visibilityState != "visible" {
                    guarded = True;
                    return;
                }
                current = await request_json("/me");
                if version != generation.current or doc.visibilityState != "visible" {
                    return;
                }
                if current.ok and current.data.user_id == snapshot.user_id {
                    guarded = False;
                } elif current.ok or current.status == 401 {
                    win.dispatchEvent(new(Event, SESSION_EVENT));  # jac:ignore[E1053]
                } else {
                    guarded = True;
                    failed = current.error;
                }
            }
            doc.addEventListener("visibilitychange", visible);
            return lambda { doc.removeEventListener("visibilitychange", visible); };
        },
        [edition, loading]
    );
    useEffect(
        lambda {
            if not edition or guarded or receipt == "saved" {
                return;
            }
            version = generation.current;
            win: any = window;
            frame = win.requestAnimationFrame(
                lambda { acknowledge(edition, version); }
            );
            return lambda { win.cancelAnimationFrame(frame); };
        },
        [edition, guarded]
    );
    <div>
        {if not signedOut and edition and not guarded {
            <section className="directory home-briefing" aria-label="Your briefing">
                <header className="directory-heading">
                    <p className="section-marker">Your briefing</p>
                    <h1>
                        {"Your first briefing"
                            if edition.first_visit
                            else "Since your last visit"}
                    </h1>
                    {if edition.since and not edition.first_visit {
                        <p>
                            {"New reporting since "
                                + new(Date, str(edition.since)).toLocaleString()
                                + "."}
                        </p>
                    }}
                    <div className="brief-links">
                        <a href="/following#watches">Manage topics and stories</a>
                        <a href="#sectors">Browse sectors ↓</a>
                    </div>
                </header>
                {for card in (edition.cards if expanded else edition.cards[:5]) {
                    <BriefCard key={str(card.story_id)} card={card} watch={watch}/>
                }}
                {if len(edition.cards) > 5 {
                    <button
                        type="button"
                        aria-expanded={expanded}
                        onClick={lambda { expanded = not expanded; }}
                    >
                        {"Show fewer stories"
                            if expanded
                            else "Show "
                                + str(len(edition.cards) - 5)
                                + " more in this briefing"}
                    </button>
                }}
                {if not len(edition.cards) {
                    <p className="brief-empty">
                        {"Follow channels, topics, or stories to build your briefing."
                            if edition.first_visit
                            else "You're caught up. New developments from your channels and watches will appear here."}
                    </p>
                }}
                {if receipt == "failed" {
                    <p role="status">
                        Your visit could not be saved.{" "}
                        <button
                            type="button"
                            onClick={lambda { acknowledge(
                                edition, generation.current
                            ); }}
                        >
                            Retry saving visit
                        </button>
                    </p>
                }}
                {if failed {
                    <p role="alert">{failed}</p>
                }}
                {if edition.has_more {
                    <button
                        type="button"
                        disabled={loading or receipt != "saved"}
                        onClick={lambda { load(); }}
                    >
                        More developments
                    </button>
                }}
            </section>
        } elif failed {
            <section className="directory">
                <h2>Briefing unavailable</h2>
                <p role="alert">{failed}</p>
                <button onClick={lambda { load(True); }}>Try again</button>
            </section>
        } }
    </div>
}

def:pub Timeline(storyId: str, watch: any) -> JsxElement {
    has card: any = None,
        issue: str = "",
        unavailable: bool = False;
    revision: any = useRef(0);
    async def load {
        revision.current += 1;
        version = revision.current;
        res = await request_json("/api/stories/" + encodeURIComponent(storyId));
        if version != revision.current {
            return;
        }
        card = res.data.story if res.ok else None;
        unavailable = res.status in [401, 403, 404];
        issue = ""
            if res.ok
            else (
                "This story is unavailable for this account."
                    if unavailable
                    else res.error
            );
    }
    useEffect(
        lambda {
            load();
            change = lambda {
                card = None;
                issue = "";
                load();
            };
            doc: any = document;
            visible = lambda { if storyId.startswith("private-") {
                if doc.visibilityState == "visible" {
                    load();
                } else {
                    revision.current += 1;
                    card = None;
                }
            }};
            doc.addEventListener("visibilitychange", visible);
            window.addEventListener(SESSION_EVENT, change);
            return lambda {
                revision.current += 1;
                doc.removeEventListener("visibilitychange", visible);
                window.removeEventListener(SESSION_EVENT, change);
            };
        },
        [storyId]
    );
    <main className="directory directory-reading timeline">
        <a className="directory-back" href="/">← Home</a>
        {if card {
            <p className="section-marker">Story timeline</p>
            <BriefCard card={card} watch={watch} detail={True}/>
            <section className="news-section">
                <h2>Developments</h2>
                {if not len(card.developments or []) {
                    <p>No further developments yet.</p>
                }}
                <ol className="development-list">
                    {for event in (card.developments or []) {
                        <li key={str(event.id)}>
                            <div className="brief-byline">
                                <strong>
                                    {event.change
                                        or (
                                            "Publisher update"
                                                if event.kind == "update"
                                                else "Report"
                                        )}
                                </strong>
                                <span>{event.publisher or event.channel_name}</span>
                                {if event.observed_at or event.published {
                                    <time
                                        dateTime={event.observed_at or event.published}
                                    >
                                        {new(
                                            Date,
                                            str(event.observed_at or event.published)
                                        ).toLocaleString()}
                                    </time>
                                }}
                            </div>
                            <h3>{event.title}</h3>
                            {if event.delta or event.summary {
                                <p>{event.delta or event.summary}</p>
                            }}
                            {if public_url(event.url) {
                                <a
                                    href={public_url(event.url)}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                >
                                    Original source ↗
                                </a>
                            }}
                        </li>
                    }}
                </ol>
            </section>
        } elif issue {
            <h1>Story unavailable</h1>
            <p role="alert">{issue}</p>
            if not unavailable {
                <button type="button" onClick={lambda { load(); }}>Try again</button>
            }
        } else {
            <p role="status">Loading story…</p>
        }  }
    </main>
}

"""Channel detail, source-specific views, publishing and discussion."""

import from react { useEffect, useRef }
import from .auth { SESSION_EVENT }
import from .public_data {
    count_label,
    display_date,
    request_json,
    sector_name,
    source_name
}
import from .sector_tags { SectorTags }
import from .public_story { ShareChannel, SourceEmbed, Story }

def Thread(
    comments: list[any], item_id: any, slug: str, signed_in: bool, onChange: any
) -> JsxElement {
    has draft: str = "",
        target: any = None,
        error: str = "",
        busy: bool = False;
    relevant = [
        c
        for c in comments
        if (c.item_id or 0) == (item_id or 0)
    ];
    inputRef: any = useRef(None);
    async def submit(e: any) {
        e.preventDefault();
        if busy or not draft.strip() {
            return;
        }
        busy = True;
        error = "";
        payload: any = {"text": draft.strip()};
        if item_id {
            payload.item_id = item_id;
        }
        if target {
            payload.parent_id = target.id;
        }
        result = await request_json(
            "/api/channels/" + slug + "/comments", "POST", payload
        );
        if result.ok {
            draft = "";
            target = None;
            await onChange();
        } else {
            error = result.error;
        }
        busy = False;
    }
    <div className="comment-thread">
        {if len(relevant) {
            <ol aria-label="Comments">
                {for c in relevant {
                    <li
                        key={str(c.id)}
                        className={"thread-reply" if c.parent_id else "thread-comment"}
                    >
                        <div className="comment-byline">
                            <strong>{c.author}</strong>
                            {for parent in relevant {
                                if parent.id == c.parent_id {
                                    <span key={str(parent.id)}>
                                        {"↳ " + str(parent.author)}
                                    </span>
                                }
                            }}
                            <time dateTime={c.created_at}>
                                {display_date(c.created_at)}
                            </time>
                        </div>
                        <p>
                            {for word in str(c.text).split(" ") {
                                if word.startswith("https://")
                                    or word.startswith("http://") {
                                    <span>
                                        <a
                                            href={word}
                                            target="_blank"
                                            rel="noopener noreferrer"
                                        >
                                            {word}
                                        </a>
                                    </span>
                                } else {
                                    <span>{word + " "}</span>
                                }
                            }}
                        </p>
                        {if signed_in {
                            <button
                                type="button"
                                className="text-action"
                                onClick={lambda {
                                    target = c;
                                    if inputRef.current {
                                        inputRef.current.focus();
                                    }
                                }}
                            >
                                Reply
                            </button>
                        }}
                    </li>
                }}
            </ol>
        } else {
            <p className="directory-muted">No comments yet.</p>
        } }
        {if signed_in {
            <form className="public-form" onSubmit={submit}>
                {if target {
                    <div className="channel-actions">
                        <span>{"Replying to " + str(target.author)}</span>
                        <button
                            type="button"
                            className="text-action"
                            onClick={lambda { target = None; }}
                        >
                            Cancel reply
                        </button>
                    </div>
                }}
                <label>
                    {"Your reply" if target else "Your comment"}
                    <textarea
                        ref={inputRef}
                        rows={2}
                        maxLength={2000}
                        value={draft}
                        required
                        onChange={lambda (e: any) { draft = e.target.value; }}
                    />
                </label>
                <button type="submit" disabled={busy or not draft.strip()}>
                    Post comment
                </button>
            </form>
        } else {
            <a href="/sources">Sign in to join the discussion</a>
        } }
        {if error {
            <p className="public-error" role="alert">{error}</p>
        }}
    </div>
}

def PostForm(slug: str, onChange: any) -> JsxElement {
    has title: str = "",
        textBody: str = "",
        url: str = "",
        error: str = "",
        busy: bool = False;
    async def submit(e: any) {
        e.preventDefault();
        if busy {
            return;
        }
        busy = True;
        error = "";
        res = await request_json(
            "/api/channels/" + slug + "/posts",
            "POST",
            {"title": title.strip(), "text": textBody.strip(), "url": url.strip()}
        );
        if res.ok {
            title = "";
            textBody = "";
            url = "";
            await onChange();
        } else {
            error = res.error;
        }
        busy = False;
    }
    <details className="write-post">
        <summary>Write a post</summary>
        <form className="public-form" onSubmit={submit}>
            <label>
                Title
                <input
                    value={title}
                    required
                    maxLength={180}
                    onChange={lambda (e: any) { title = e.target.value; }}
                />
            </label>
            <label>
                Post
                <textarea
                    value={textBody}
                    required
                    rows={4}
                    maxLength={8000}
                    onChange={lambda (e: any) { textBody = e.target.value; }}
                />
            </label>
            <label>
                Source link (optional)
                <input
                    type="url"
                    value={url}
                    onChange={lambda (e: any) { url = e.target.value; }}
                />
            </label>
            {if error {
                <p role="alert" className="public-error">{error}</p>
            }}
            <button
                type="submit"
                disabled={busy or not title.strip() or not textBody.strip()}
            >
                Publish post
            </button>
        </form>
    </details>
}

def:pub ChannelPage(slug: str) -> JsxElement {
    has channel: any = None,
        comments: list[any] = [],
        signed_in: bool = False,
        error: str = "",
        actionError: str = "",
        busy: bool = False,
        missing: bool = False;
    revision: any = useRef(0);
    counted: any = useRef(False);
    async def load {
        revision.current += 1;
        seq = revision.current;
        result = await request_json("/api/channels/" + slug);
        if revision.current != seq {
            return;
        }
        if not result.ok {
            error = result.error;
            missing = result.status == 404;
            return;
        }
        error = "";
        channel = result.data.channel;
        comments = result.data.comments;
        who = await request_json("/me");
        if revision.current == seq {
            signed_in = who.ok;
        }
    }
    async def entered {
        if not counted.current {
            counted.current = True;
            fromPreview = False;
            try {
                key = "ns-click-from-preview";
                fromPreview = sessionStorage.getItem(key) == slug;
                sessionStorage.removeItem(key);
            } except Exception {}
            if not fromPreview {
                await request_json("/api/channels/" + slug + "/click", "POST");
            }
        }
        await load();
    }
    useEffect(
        lambda {
            entered();
            timer = setInterval(lambda { load(); }, 120000);
            on_change = lambda { load(); };
            window.addEventListener(SESSION_EVENT, on_change);
            return lambda {
                clearInterval(timer);
                revision.current += 1;
                window.removeEventListener(SESSION_EVENT, on_change);
            };
        },
        [slug]
    );
    async def modify(field: str, enabled: bool) {
        if busy {
            return;
        }
        busy = True;
        actionError = "";
        result = await request_json(
            "/api/channels/" + slug + "/" + field, "PUT", {"enabled": enabled}
        );
        if result.ok {
            await load();
        } else {
            actionError = result.error;
        }
        busy = False;
    }
    if not channel {
        return
            <main className="directory directory-reading">
                <a className="directory-back" href="/discover">← Discover</a>
                {if missing {
                    <h1>Channel not found</h1>
                } elif error {
                    <p role="alert">{error}</p>
                    <button type="button" onClick={lambda { load(); }}>
                        Try again
                    </button>
                } else {
                    <p role="status">Loading channel…</p>
                }  }
            </main>;
    }
    return
        <main className="directory directory-reading">
            <a className="directory-back" href={"/categories/" + str(channel.category)}>
                {"← " + sector_name(channel.category)}
            </a>
            <header className="directory-heading">
                <p className="section-marker">
                    {source_name(channel.source_type) + " channel"}
                </p>
                <h1>{channel.name}</h1>
                <SectorTags tags={channel.tags or [channel.category]}/>
                <p className="directory-deck">{channel.description}</p>
                <div className="channel-byline">
                    <span>{"By " + str(channel.publisher)}</span>
                    <span>{count_label(channel.clicks, "click", "clicks")}</span>
                    <span>
                        {count_label(channel.subscribers, "follower", "followers")}
                    </span>
                    <span>
                        {count_label(
                            channel.recommendations, "recommendation", "recommendations"
                        )}
                    </span>
                </div>
            </header>
            <div className="channel-toolbar">
                {if signed_in {
                    <button
                        type="button"
                        className="primary-action"
                        disabled={busy}
                        aria-pressed={bool(channel.subscribed)}
                        onClick={lambda { modify(
                            "subscription", not channel.subscribed
                        ); }}
                    >
                        {"Unfollow" if channel.subscribed else "Follow channel"}
                    </button>
                    if channel.subscribed {
                        <button
                            type="button"
                            disabled={busy}
                            aria-pressed={bool(channel.notifications_enabled)}
                            onClick={lambda { modify(
                                "notifications", not channel.notifications_enabled
                            ); }}
                        >
                            {"Alerts on"
                                if channel.notifications_enabled
                                else "Alerts off"}
                        </button>
                    }
                    <button
                        type="button"
                        disabled={busy}
                        aria-pressed={bool(channel.recommended)}
                        onClick={lambda { modify(
                            "recommendation", not channel.recommended
                        ); }}
                    >
                        {"Recommended ✓" if channel.recommended else "Recommend"}
                    </button>
                } else {
                    <a className="button-link" href="/sources">Sign in to follow</a>
                } }
                <ShareChannel slug={slug}/>
            </div>
            {if actionError or error {
                <p className="public-error" role="alert">{actionError or error}</p>
            }}
            {if channel.mode == "embed" {
                <SourceEmbed channel={channel}/>
            }}
            <section className="news-section">
                <h2>Recent updates</h2>
                {if channel.source_type == "rss" {
                    <p className="directory-muted" role="status">
                        {"Last refreshed " + display_date(channel.checked_at) + ". "
                            if channel.checked_at
                            else ""}{"Publisher unavailable. Showing the saved edition."
                            if channel.refresh_status == "retrying"
                            else ""}
                    </p>
                }}
                {if signed_in
                    and (
                        channel.source_type == "community"
                        or (channel.owned and channel.source_type in ["x", "telegram"])
                    ) {
                    <PostForm slug={slug} onChange={load}/>
                }}
                {if not len(channel.headlines) {
                    <p className="directory-muted">No published updates yet.</p>
                }}
                {for item in channel.headlines {
                    <div key={str(item.id)} className="story-with-thread">
                        <Story item={item} full={True}/>
                        <details className="story-discussion">
                            <summary>
                                {"Discussion ("
                                    + str(
                                        len(
                                            [
                                                c
                                                for c in comments
                                                if c.item_id == item.id
                                            ]
                                        )
                                    )
                                    + ")"}
                            </summary>
                            <Thread
                                comments={comments}
                                item_id={item.id}
                                slug={slug}
                                signed_in={signed_in}
                                onChange={load}
                            />
                        </details>
                    </div>
                }}
            </section>
            <section className="news-section" id="discussion">
                <h2>Channel discussion</h2>
                <Thread
                    comments={comments}
                    item_id={None}
                    slug={slug}
                    signed_in={signed_in}
                    onChange={load}
                />
            </section>
        </main>;
}

"""Attributed stories, source links and official social embeds."""

import from .public_data { display_date, public_url }

def:pub Story(item: any, channel_name: str = "", full: bool = False) -> JsxElement {
    href = public_url(item.url);
    <article className="public-story" id={"story-" + str(item.id)}>
        <div className="story-byline">
            {if channel_name {
                <a href={"/channels/" + str(item.channel_slug)}>{channel_name}</a>
            } else {
                <span>{item.author}</span>
            } }
            {if item.published {
                <time dateTime={item.published}>{display_date(item.published)}</time>
            }}
        </div>
        <h3>
            {if href {
                <a href={href} target="_blank" rel="noopener noreferrer">
                    {item.title}
                </a>
            } else {
                <span>{item.title}</span>
            } }
        </h3>
        {if item.ai_generated {
            <span className="summary-label">
                AI summary{" · " + display_date(item.generated_at)
                    if item.generated_at
                    else ""}
            </span>
        }}
        {if item.summary or item.text {
            <p>
                {item.text
                    if full and not item.ai_generated and item.text
                    else (item.summary or item.text)}
            </p>
        }}
        {if full and item.ai_generated and item.text {
            <details>
                <summary>Source text</summary>
                <p>{item.text}</p>
            </details>
        }}
        {if href {
            <a
                className="story-source"
                href={href}
                target="_blank"
                rel="noopener noreferrer"
            >
                Original source ↗
            </a>
        }}
    </article>
}

def:pub ShareChannel(slug: str) -> JsxElement {
    has feedback: str = "";
    win: any = window;
    url = str(win.location.origin) + "/channels/" + slug;
    async def copy_link {
        try {
            nav: any = navigator;
            await nav.clipboard.writeText(url);
            feedback = "copied";
        } except Exception {
            feedback = "manual";
        }
    }
    <div className="directory-share">
        <button type="button" onClick={lambda { copy_link(); }}>Copy link</button>
        {if feedback == "copied" {
            <span role="status">Link copied</span>
        }}
        {if feedback == "manual" {
            <label>
                Channel address
                <input
                    readOnly={True}
                    value={url}
                    onFocus={lambda (e: any) { e.target.select(); }}
                />
            </label>
        }}
    </div>
}

def:pub SourceEmbed(channel: any) -> JsxElement {
    # Keep third-party scripts off the application's origin. Only characters
    # valid in a public handle can enter the widget's embedded document.
    url = str(channel.source_url or "");
    chunks = url.split("/");
    host = chunks[2] if len(chunks) > 2 else "";
    handle = chunks[3] if len(chunks) > 3 else "";
    valid = len(handle) > 0 and len(handle) <= 32;
    for c in handle {
        if c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_" {
            valid = False;
        }
    }
    if valid
        and channel.source_type == "x"
        and host in ["x.com", "twitter.com", "www.x.com", "www.twitter.com"] {
        profile = "https://x.com/" + handle;
        frame = "<!doctype html><meta name='color-scheme' content='dark'><a class='twitter-timeline' data-theme='dark' data-height='420' href='https://twitter.com/"
            + handle
            + "'>Posts by @"
            + handle
            + "</a><script async src='https://platform.twitter.com/widgets.js'></script>";
        return
            <section className="source-embed">
                <h2>Account activity</h2>
                <iframe
                    title={"X timeline for @" + handle}
                    srcDoc={frame}
                    sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox"
                    loading="lazy"
                    referrerPolicy="no-referrer"
                />
                <a href={profile} target="_blank" rel="noopener noreferrer">
                    {"Open @" + handle + " on X ↗"}
                </a>
            </section>;
    }
    if valid and channel.source_type == "telegram" and host == "t.me" {
        post = chunks[4] if len(chunks) > 4 else "";
        numeric = bool(post);
        for c in post {
            if c not in "0123456789" {
                numeric = False;
            }
        }
        return
            <section className="source-embed">
                {if numeric {
                    <iframe
                        title="Public Telegram post"
                        src={"https://t.me/" + handle + "/" + post + "?embed=1"}
                        sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox"
                        loading="lazy"
                        referrerPolicy="no-referrer"
                    />
                }}
                <a href={url} target="_blank" rel="noopener noreferrer">
                    Open on Telegram ↗
                </a>
            </section>;
    }
    return <span/>;
}

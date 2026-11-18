"""Public, read-only views of the editorial RSS snapshot."""

import from react { useEffect }
import from .navigation { Navigation }
import "./directory.css";

obj Headline {
    has title: str,
        url: str,
        published: str,
        summary: str,
        section: str | None = None;
}

obj Channel {
    has slug: str,
        name: str,
        publisher: str,
        description: str,
        headlines: list[Headline],
        checked_at: str | None = None;
}

obj Category {
    has slug: str,
        name: str,
        channels: list[Channel],
        image_url: str | None = None;
}

obj Directory {
    has captured_at: str,
        curator: str,
        categories: list[Category],
        publishers: list[Channel];
}

def display_date(iso: str) -> str {
    return new(Date, iso).toLocaleDateString(
        "en-US", {"month": "short", "day": "numeric", "year": "numeric"}
    );
}

def Headlines(channel: Channel) -> JsxElement {
    <ul className="directory-headlines">
        {for item in channel.headlines {
            <li key={item.url}>
                <a href={item.url} target="_blank" rel="noopener noreferrer">
                    {item.title}
                </a>
                {if item.summary {
                    <p>{item.summary}</p>
                }}
                <span>
                    {channel.publisher}
                    {" · "}
                    <time dateTime={item.published}>
                        {display_date(item.published)}
                    </time>
                </span>
                {if item.section {
                    <a className="story-section" href={"/categories/" + item.section}>
                        {"General News" if item.section == "general" else item.section}
                    </a>
                }}
            </li>
        }}
    </ul>
}

def ShareChannel(slug: str) -> JsxElement {
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
        <button type="button" onClick={lambda { copy_link(); }}>
            Copy channel link
        </button>
        <span role="status">{"Link copied" if feedback == "copied" else ""}</span>
        {if feedback == "manual" {
            <label>
                Copy this address
                <input
                    readOnly={True}
                    value={url}
                    onFocus={lambda (e: any) { e.target.select(); }}
                />
            </label>
        }}
    </div>
}

def CategoryRow(category: Category) -> JsxElement {
    count = len(category.channels);
    <li>
        <a className="category-row" href={"/categories/" + category.slug}>
            {if category.image_url {
                <img
                    className="category-thumb"
                    src={category.image_url}
                    alt=""
                    loading="lazy"
                />
            }}
            <div className="category-summary">
                <h2>{category.name}</h2>
                {if count {
                    <p>
                        {", ".join([channel.name for channel in category.channels[:2]])}
                    </p>
                }}
            </div>
            <span className="category-count">
                {str(count) + (" channel" if count == 1 else " channels")}
            </span>
            <span className="category-arrow" aria-hidden="true">→</span>
        </a>
    </li>
}

def ChannelRow(channel: Channel, captured: str) -> JsxElement {
    <li>
        <details className="channel-disclosure">
            <summary>
                <span className="channel-name">{channel.name}</span>
                <span className="channel-description">{channel.description}</span>
            </summary>
            <div className="channel-stories">
                <p className="directory-byline">
                    {"Latest news · " + display_date(channel.checked_at or captured)}
                </p>
                <Headlines channel={channel}/>
                <div className="channel-actions">
                    <a href={"/channels/" + channel.slug}>Open channel page</a>
                    <ShareChannel slug={channel.slug}/>
                </div>
            </div>
        </details>
    </li>
}

def ChannelPage(
    channel: Channel, data: Directory, back_url: str, back_label: str
) -> JsxElement {
    return
        <main className="directory directory-reading">
            <a className="directory-back" href={back_url}>{"← " + back_label}</a>
            <header className="directory-heading">
                <h1>{channel.name}</h1>
                <p>{"Curated by " + data.curator}</p>
            </header>
            <p className="directory-deck">{channel.description}</p>
            <ShareChannel slug={channel.slug}/>
            <section className="channel-card">
                <h2>Latest headlines</h2>
                <span className="directory-byline">
                    {"Snapshot " + display_date(channel.checked_at or data.captured_at)}
                </span>
                <Headlines channel={channel}/>
            </section>
        </main>;
}

def DirectoryContent(data: Directory, path: str) -> JsxElement {
    if path == "/" {
        return
            <main className="directory">
                <header className="directory-heading">
                    <h1>Forums</h1>
                    <p>{str(len(data.categories)) + " categories"}</p>
                </header>
                <ul className="category-list" aria-label="Forum categories">
                    {for category in data.categories {
                        <CategoryRow key={category.slug} category={category}/>
                    }}
                </ul>
            </main>;
    }
    for publisher in data.publishers {
        if path == "/channels/" + publisher.slug {
            return
                <ChannelPage
                    channel={publisher}
                    data={data}
                    back_url="/"
                    back_label="All forums"
                />;
        }
    }
    for category in data.categories {
        if path == "/categories/" + category.slug {
            return
                <main className="directory directory-reading">
                    <a className="directory-back" href="/">← All forums</a>
                    <header className="directory-heading">
                        <h1>{category.name}</h1>
                        <p>{"Curated by " + data.curator}</p>
                    </header>
                    <ul className="channel-list" aria-label="Channels">
                        {for channel in category.channels {
                            <ChannelRow
                                key={channel.slug}
                                channel={channel}
                                captured={data.captured_at}
                            />
                        }}
                    </ul>
                </main>;
        }
        for channel in category.channels {
            if path == "/channels/" + channel.slug {
                return
                    <ChannelPage
                        channel={channel}
                        data={data}
                        back_url={"/categories/" + category.slug}
                        back_label={category.name}
                    />;
            }
        }
    }
    return
        <main className="directory">
            <h1>Page not found</h1>
            <a href="/">Browse all categories</a>
        </main>;
}

def:pub DirectoryPage(path: str) -> JsxElement {
    has data: Directory | None = None,
        failed: bool = False;
    async def load_directory {
        failed = False;
        try {
            resp = await fetch("/api/directory");
            if resp.ok {
                data = (await resp.json()) as Directory;
                return;
            }
        } except Exception {
            # The retry action is also available after network errors.
            failed = True;
            return;
        }
        failed = True;
    }
    useEffect(lambda { load_directory(); }, []);
    <div className="app-layout">
        <Navigation active={"home" if path == "/" else "directory"}/>
        {if data {
            <DirectoryContent data={data} path={path}/>
        } elif failed {
            <main className="directory">
                <h1>Channel directory unavailable</h1>
                <button type="button" onClick={lambda { load_directory(); }}>
                    Try again
                </button>
            </main>
        } else {
            <main className="directory">
                <p role="status">Loading channels…</p>
            </main>
        }  }
    </div>
}

"""Public, read-only views of the editorial RSS snapshot."""

import from react { useEffect }
import from .navigation { Navigation }
import "./directory.css";

obj Headline {
    has title: str,
        url: str,
        published: str;
}

obj Channel {
    has slug: str,
        name: str,
        publisher: str,
        description: str,
        headlines: list[Headline];
}

obj Category {
    has slug: str,
        name: str,
        channels: list[Channel];
}

obj Directory {
    has captured_at: str,
        curator: str,
        categories: list[Category];
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
                <span>
                    {channel.publisher}
                    {" · "}
                    <time dateTime={item.published}>
                        {display_date(item.published)}
                    </time>
                </span>
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

def CategoryTile(category: Category) -> JsxElement {
    lead = category.channels[0];
    <a className="sector-tile" href={"/categories/" + category.slug}>
        <div className="sector-photo">
            <img src={"/directory-images/" + category.slug + ".jpg"} alt=""/>
            <h2>{category.name}</h2>
            <span aria-hidden="true">↗</span>
        </div>
        <div className="sector-preview">
            <span className="directory-label">{"Featured · " + lead.name}</span>
            <p>{lead.headlines[0].title}</p>
        </div>
    </a>
}

def ChannelCard(channel: Channel, curator: str) -> JsxElement {
    <article className="channel-card">
        <h2>
            <a href={"/channels/" + channel.slug}>{channel.name}</a>
        </h2>
        <span className="directory-byline">{"Curated by " + curator}</span>
        <p>{channel.description}</p>
        <details>
            <summary>
                {"Latest headlines (" + str(len(channel.headlines)) + ")"}
            </summary>
            <Headlines channel={channel}/>
        </details>
        <ShareChannel slug={channel.slug}/>
    </article>
}

def DirectoryContent(data: Directory, path: str) -> JsxElement {
    captured = display_date(data.captured_at);
    if path == "/" {
        return
            <main className="directory">
                <header className="directory-heading">
                    <h1>Channel directory</h1>
                    <p>{"Editorial picks by sector · Snapshot " + captured}</p>
                </header>
                <div className="sector-grid">
                    {for category in data.categories {
                        <CategoryTile key={category.slug} category={category}/>
                    }}
                </div>
            </main>;
    }
    for category in data.categories {
        if path == "/categories/" + category.slug {
            return
                <main className="directory directory-reading">
                    <a className="directory-back" href="/">← Channel directory</a>
                    <header className="directory-heading">
                        <h1>{category.name}</h1>
                        <p>{"Featured channels · Snapshot " + captured}</p>
                    </header>
                    {for channel in category.channels {
                        <ChannelCard
                            key={channel.slug}
                            channel={channel}
                            curator={data.curator}
                        />
                    }}
                    {if category.slug == "energy" {
                        <a className="directory-monitor" href="/oil">
                            Open Crude Oil Monitor →
                        </a>
                    }}
                </main>;
        }
        for channel in category.channels {
            if path == "/channels/" + channel.slug {
                return
                    <main className="directory directory-reading">
                        <a
                            className="directory-back"
                            href={"/categories/" + category.slug}
                        >
                            {"← " + category.name}
                        </a>
                        <header className="directory-heading">
                            <h1>{channel.name}</h1>
                            <p>
                                {"Curated by "
                                    + data.curator
                                    + " · Featured in "
                                    + category.name}
                            </p>
                        </header>
                        <p className="directory-deck">{channel.description}</p>
                        <ShareChannel slug={channel.slug}/>
                        <section className="channel-card">
                            <h2>Latest headlines</h2>
                            <span className="directory-byline">
                                {"Snapshot " + captured}
                            </span>
                            <Headlines channel={channel}/>
                        </section>
                    </main>;
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

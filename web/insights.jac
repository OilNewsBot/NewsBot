"""Reader context computed from the same edition displayed on the page."""

import from react { useEffect }
import from .public_data { channel_preview, display_date, sector_name, source_name }

"""The panel preference is local to this browser. Small windows start closed."""
def:pub ReadingDesk(
    label: str, content: JsxElement, insights: JsxElement
) -> JsxElement {
    has opened: bool = False;
    useEffect(
        lambda {
            win: any = window;
            wide = win.matchMedia("(min-width: 1120px)").matches;
            try {
                saved = localStorage.getItem("ns-coverage-panel");
                opened = wide if saved is None else saved == "open";
            } except Exception {
                opened = wide;
            }
        },
        []
    );
    def toggle {
        value = not opened;
        opened = value;
        try {
            localStorage.setItem("ns-coverage-panel", "open" if value else "closed");
        } except Exception {}
    }
    <div className="reading-desk">
        <header className="desk-bar">
            <div className="desk-location">
                <a href="/">Newsstream</a>
                <span aria-hidden="true">/</span>
                <strong>{label}</strong>
            </div>
            <button
                type="button"
                className="insights-toggle"
                onClick={toggle}
                aria-expanded={opened}
                aria-controls="reading-insights"
            >
                <svg
                    width="16"
                    height="16"
                    viewBox="0 0 20 20"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="1.5"
                    aria-hidden="true"
                >
                    <rect x="2.5" y="3.5" width="15" height="13" rx="2"/>
                    <path d="M12 4v12"/>
                </svg>
                Insights
            </button>
        </header>
        <div className="desk-columns">
            <aside
                id="reading-insights"
                aria-label="Reading insights"
                hidden={not opened}
            >
                {insights}
            </aside>
            <div className="desk-reading">{content}</div>
        </div>
    </div>
}

def Metric(label: str, value: int) -> JsxElement {
    <div>
        <dt>{label}</dt>
        <dd>{value}</dd>
    </div>
}

"""Channels can share a source, so count each report ID once. Keep only the
newest preview for each dated story timeline in the quick links."""
def:pub CoverageInsights(channels: list[any], sector: str = "") -> JsxElement {
    reports: any = new(Set);
    recent: any = [];
    for channel in channels {
        for item in channel_preview(channel, sector) {
            if reports.has(item.id) {
                continue;
            }
            reports.add(item.id);
            stamp = new(Date, str(item.published)).getTime();
            if item.story_id and not isNaN(stamp) {
                recent.append({"item": item, "stamp": stamp, "channel": channel.name});
            }
        }
    }
    recent.sort(lambda (row: any) { return -row.stamp; });
    timelines: any = new(Set);
    latest: list[any] = [];
    for row in recent {
        if not timelines.has(row.item.story_id) {
            timelines.add(row.item.story_id);
            latest.append(row);
            if len(latest) == 3 {
                break;
            }
        }
    }
    <div className="insights-body">
        <h2>Coverage insights</h2>
        <p className="insights-scope">
            {sector_name(sector) if sector else "Channels in this view"}
        </p>
        <dl className="insight-metrics">
            <Metric label="Channels" value={len(channels)}/>
            <Metric label="Preview reports" value={reports.size}/>
        </dl>
        <section className="insight-section">
            <h3>Latest story timelines</h3>
            {if len(latest) {
                <ul className="insight-stories">
                    {for row in latest {
                        <li key={str(row.item.story_id)}>
                            <a href={"/stories/" + str(row.item.story_id)}>
                                {row.item.title}
                            </a>
                            <small>
                                {row.channel + " · " + display_date(row.item.published)}
                            </small>
                        </li>
                    }}
                </ul>
            } else {
                <p>No dated timelines in these previews yet.</p>
            } }
        </section>
        <section className="insight-section">
            <h3>Source mix</h3>
            <ul className="source-mix">
                {for kind in ["rss", "x", "telegram", "community"] {
                    <SourceShare key={kind} kind={kind} channels={channels}/>
                }}
            </ul>
            {if not len(channels) {
                <p>No channels in this view.</p>
            }}
        </section>
    </div>
}


def SourceShare(kind: str, channels: list[any]) -> JsxElement {
    count = len(
        [
            c
            for c in channels
            if c.source_type == kind
        ]
    );
    if not count {
        return <></>;
    }
    <li>
        <span>{source_name(kind)}</span>
        <strong>{count}</strong>
        <progress
            aria-label={source_name(kind) + " channels"}
            value={count}
            max={len(channels)}
        />
    </li>
}

def:pub FollowingInsights(data: any, watch: any) -> JsxElement {
    enabled = len(
        [
            c
            for c in data.channels
            if c.notifications_enabled
        ]
    );
    <div className="insights-body">
        <h2>Your coverage</h2>
        <p className="insights-scope">Following</p>
        <dl className="insight-metrics">
            <Metric label="Followed channels" value={len(data.channels)}/>
            <Metric label="Feed updates" value={len(data.items)}/>
        </dl>
        <section className="insight-section">
            <h3>Channel alerts</h3>
            <p>
                {str(enabled)
                    + " of "
                    + str(len(data.channels))
                    + " channels have alerts on."}
            </p>
            <a href="#followed-channels">Manage alerts →</a>
        </section>
        {if watch.data {
            <section className="insight-section">
                <h3>Saved watches</h3>
                <dl className="watch-totals">
                    <Metric label="Stories" value={len(watch.data.stories)}/>
                    <Metric label="Topics" value={len(watch.data.topics)}/>
                </dl>
                <a href="#watches">Manage watches →</a>
            </section>
        }}
    </div>
}

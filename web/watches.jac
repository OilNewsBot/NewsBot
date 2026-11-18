"""Account-owned story and topic watches shared by the home, directory and timelines."""

import from react { useEffect, useRef }
import from .auth { SESSION_EVENT }
import from .public_data { request_json, sector_name }

def:pub useWatches -> any {
    has data: any = None,
        pending: str = "",
        issue: str = "",
        ready: bool = False;
    revision: any = useRef(0);
    saving: any = useRef(False);
    async def load {
        revision.current += 1;
        version = revision.current;
        result = await request_json("/api/watches");
        if version != revision.current {
            return;
        }
        ready = True;
        if result.ok {
            data = result.data;
            issue = "";
        } elif result.status == 401 {
            data = None;
            issue = "";
        } else {
            issue = result.error;
        }
    }
    async def toggle(kind: str, row: any, enabled: bool) {
        if saving.current or not data {
            return;
        }
        saving.current = True;
        pending = kind + "/" + str(row.id);
        revision.current += 1;
        version = revision.current;
        result = await request_json(
            "/api/watches/" + kind + "/" + encodeURIComponent(str(row.id)),
            "PUT",
            {"enabled": enabled, "user_id": data.user_id}
        );
        if version != revision.current {
            return;
        }
        saving.current = False;
        pending = "";
        if result.ok or result.status in [401, 409] {
            await load();
        } else {
            issue = result.error;
        }
    }
    useEffect(
        lambda {
            load();
            change = lambda {
                data = None;
                ready = False;
                issue = "";
                pending = "";
                saving.current = False;
                load();
            };
            focus = lambda { if not saving.current { load(); }};
            window.addEventListener(SESSION_EVENT, change);
            window.addEventListener("focus", focus);
            return lambda {
                revision.current += 1;
                window.removeEventListener(SESSION_EVENT, change);
                window.removeEventListener("focus", focus);
            };
        },
        []
    );
    return {
        "data": data,
        "issue": issue,
        "pending": pending,
        "toggle": toggle,
        "ready": ready,
        "load": load
    };
}

def:pub WatchButton(watch: any, kind: str, row: any) -> JsxElement {
    current = watch.data[kind] if watch and watch.data else [];
    active = len(
        [
            w
            for w in current
            if str(w.id) == str(row.id)
        ]
    )
        > 0;
    name = "story" if kind == "stories" else "topic";
    caption = ("Following " if active else "Follow ") + name;
    <span className="watch-control">
        {if watch and watch.data {
            <button
                className="watch-button"
                type="button"
                disabled={bool(watch.pending)}
                aria-pressed={active}
                aria-label={caption + " · " + str(row.title or row.label)}
                onClick={lambda { watch.toggle(kind, row, not active); }}
            >
                {caption}
            </button>
        }}
    </span>
}

def:pub StoryLabels(labels: any, watch: any = None) -> JsxElement {
    groups = [
        ["subsectors", "Topics"],
        ["events", "Events"],
        ["entities", "Organizations and people"],
        ["places", "Places"]
    ];
    <div className="story-facets">
        {for group in groups {
            if labels and labels[group[0]] and len(labels[group[0]]) {
                <div className="facet-line" key={group[0]}>
                    <span className="facet-key">{group[1]}</span>
                    <div className="facet-values">
                        {for row in labels[group[0]] {
                            <span key={row.id} className="facet-value">
                                {row.label}
                                {if watch and watch.data {
                                    <WatchButton watch={watch} kind="topics" row={row}/>
                                }}
                            </span>
                        }}
                    </div>
                </div>
            }
        }}
    </div>
}

def:pub WatchManager(watch: any) -> JsxElement {
    has groupId: str = "",
        query: str = "",
        picked: list[any] = [];
    groups: list[any] = [];
    if watch.data {
        for group in watch.data.taxonomy {
            groups.append(
                {
                    "id": group.sector,
                    "name": sector_name(group.sector),
                    "entries": group.topics
                }
            );
        }
        facets = watch.data.facets or {};
        for pair in [
            ["events", "Events"],
            ["entities", "Organizations and people"],
            ["places", "Places"]
        ] {
            if facets[pair[0]] and len(facets[pair[0]]) {
                groups.append(
                    {"id": pair[0], "name": pair[1], "entries": facets[pair[0]]}
                );
            }
        }
    }
    shown: list[any] = [];
    for group in groups {
        if not groupId or group.id == groupId {
            rows = [
                row
                for row in group.entries
                if query.strip().lower() in str(row.label).lower()
            ];
            if len(rows) {
                shown.append({"id": group.id, "name": group.name, "entries": rows});
            }
        }
    }
    ids: any = [row.id for row in picked];
    ids.sort();
    combination = {
        "id": "~".join(ids),
        "label": " + ".join([row.label for row in picked])
    };
    def choose(row: any) {
        if row.id in ids {
            picked = [
                p
                for p in picked
                if p.id != row.id
            ];
        } elif len(picked) < 4 {
            picked = picked + [row];
        }
    }
    data = watch.data;
    <section
        id="watches"
        className="watch-manager"
        aria-label="Manage followed stories and topics"
    >
        <h2>Followed stories and topics</h2>
        {if data {
            <p>
                Follow a story for new reporting on that event. Follow a topic to add related stories to your home briefing.
            </p>
            <h3>Stories</h3>
            if len(data.stories) {
                <ul className="watch-list">
                    {for row in data.stories {
                        <li key={row.id}>
                            <a href={"/stories/" + str(row.id)}>{row.title}</a>
                            <WatchButton watch={watch} kind="stories" row={row}/>
                        </li>
                    }}
                </ul>
            } else {
                <p>No stories followed yet.</p>
            }
            <h3>Topics</h3>
            if len(data.topics) {
                <div className="facet-values">
                    {for row in data.topics {
                        <span key={row.id} className="facet-value">
                            {row.label}
                            <WatchButton watch={watch} kind="topics" row={row}/>
                        </span>
                    }}
                </div>
            } else {
                <p>No topics followed yet.</p>
            }
            <details className="topic-directory">
                <summary>Browse and combine topics</summary>
                <p>
                    Choose up to four labels. A story must match every selected label.
                </p>
                <div className="topic-search">
                    <label>
                        Label group
                        <select
                            aria-label="Label group"
                            value={groupId}
                            onChange={lambda (e: any) { groupId = e.target.value; }}
                        >
                            <option value="">All labels</option>
                            {for group in groups {
                                <option key={group.id} value={group.id}>
                                    {group.name}
                                </option>
                            }}
                        </select>
                    </label>
                    <label>
                        Find a label
                        <input
                            type="search"
                            value={query}
                            onChange={lambda (e: any) { query = e.target.value; }}
                        />
                    </label>
                </div>
                {if len(picked) {
                    <div className="topic-selection">
                        <strong>{combination["label"]}</strong>
                        <WatchButton watch={watch} kind="topics" row={combination}/>
                        <button type="button" onClick={lambda { picked = []; }}>
                            Clear selection
                        </button>
                    </div>
                }}
                {for group in shown {
                    <section className="taxonomy-group" key={group.id}>
                        <h4>{group.name}</h4>
                        <div className="facet-values">
                            {for row in group.entries {
                                <button
                                    type="button"
                                    className="facet-choice"
                                    key={row.id}
                                    aria-pressed={row.id in ids}
                                    disabled={len(picked) >= 4 and not (row.id in ids)}
                                    onClick={lambda { choose(row); }}
                                >
                                    {row.label}
                                </button>
                            }}
                        </div>
                    </section>
                }}
                {if not len(shown) {
                    <p>No labels match your search.</p>
                }}
            </details>
        } elif watch.issue {
            <button type="button" onClick={lambda { watch.load(); }}>
                Retry watch list
            </button>
        } else {
            <p>Loading watches…</p>
        }  }
    </section>
}

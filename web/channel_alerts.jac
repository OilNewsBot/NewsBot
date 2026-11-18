"""Live, account-scoped notifications for explicitly enabled public subscriptions."""

import from react { useEffect, useRef }
import from .auth { SESSION_EVENT }
import from .public_data { request_json }

def:pub ChannelAlerts -> JsxElement {
    has signedIn: bool = False,
        openTray: bool = False,
        notices: list[any] = [],
        desktop: bool = False,
        hint: str = "",
        offline: bool = False;
    owner: any = useRef(0);
    epoch: any = useRef(0);
    cursor: any = useRef(0);
    running: any = useRef(False);
    screen: any = useRef(False);
    history: any = useRef([]);
    popups: any = useRef([]);
    container: any = useRef(None);
    trigger: any = useRef(None);
    unread = len(
        [
            n
            for n in notices
            if not n.read
        ]
    );
    def alert_url(item: any) -> str {
        return "/channels/"
            + str(item.channel_slug)
            + ("#story-" + str(item.item_id) if item.item_id else "");
    }
    def clear {
        epoch.current += 1;
        running.current = False;
        for popup in popups.current {
            if popup.close {
                popup.close();
            }
        }
        popups.current = [];
        owner.current = 0;
        cursor.current = 0;
        screen.current = False;
        desktop = False;
        history.current = [];
        notices = [];
        openTray = False;
        signedIn = False;
        hint = "";
        offline = False;
    }
    def persist {
        try {
            sessionStorage.setItem(
                "ns-channel-alerts-" + str(owner.current),
                JSON.stringify({"head": cursor.current, "items": history.current})
            );
        } except Exception {}
    }
    def mark_read(item: any) {
        openTray = False;
        for saved in history.current {
            if saved.id == item.id {
                saved.read = True;
            }
        }
        notices = [n for n in history.current];
        persist();
    }
    def close_tray {
        openTray = False;
        if trigger.current {
            trigger.current.focus();
        }
    }
    useEffect(
        lambda {
            if not openTray {
                return;
            }
            doc: any = document;
            keydown = lambda (event: any) { if event.key == "Escape" { close_tray(); }};
            outside = lambda (event: any) { if container.current
                and not container.current.contains(event.target) {
                openTray = False;
            }};
            doc.addEventListener("keydown", keydown);
            doc.addEventListener("pointerdown", outside);
            return lambda {
                doc.removeEventListener("keydown", keydown);
                doc.removeEventListener("pointerdown", outside);
            };
        },
        [openTray]
    );
    def show_popup(item: any) {
        api: any = globalThis.Notification;  # jac:ignore[E1053]
        doc: any = document;
        win: any = window;
        if screen.current
            and api
            and api.permission == "granted"
            and (doc.visibilityState != "visible" or not doc.hasFocus()) {
            try {
                popup = new(
                    api,
                    str(item.channel_name),
                    {
                        "body": str(item.title)[:180],
                        "tag": "ns-channel-" + str(owner.current) + "-" + str(item.id)
                    }
                );
                popup.onclick = lambda {
                    win.focus();
                    mark_read(item);
                    win.location.href = alert_url(item);
                };
                if len(popups.current) >= 15 and popups.current[0].close {
                    popups.current[0].close();
                }
                popups.current = (popups.current + [popup])[-15:];
            } except Exception {}
        }
    }
    async def poll {
        if running.current {
            return;
        }
        running.current = True;
        version = epoch.current;
        starting = not owner.current;
        path = "/api/following/notifications/head"
            if starting
            else "/api/following/notifications?since=" + str(cursor.current);
        result = await request_json(path);
        if version != epoch.current {
            return;
        }
        running.current = False;
        if not result.ok {
            if result.status == 401 {
                clear();
            } else {
                offline = True;
            }
            return;
        }
        offline = False;
        uid = int(result.data.user_id or 0);
        if not uid or (owner.current and owner.current != uid) {
            clear();
            return;
        }
        if starting {
            owner.current = uid;
            signedIn = True;
            cursor.current = int(result.data.head);
            try {
                stored = sessionStorage.getItem("ns-channel-alerts-" + str(uid));
                if stored {
                    prev: any = JSON.parse(stored);
                    if int(prev.head) <= cursor.current {
                        cursor.current = int(prev.head);
                        history.current = prev.items or [];
                        notices = history.current;
                    }
                }
                screen.current = localStorage.getItem("ns-channel-screen-" + str(uid))
                    == "1";
                desktop = screen.current;
            } except Exception {}
        } else {
            fresh: list[any] = [];
            for item in result.data.notifications {
                if int(item.id) > cursor.current {
                    fresh.append(item);
                    show_popup(item);
                }
            }
            if len(fresh) {
                fresh.reverse();
                history.current = (fresh + history.current)[:15];
                notices = history.current;
            }
            cursor.current = int(result.data.head);
        }
        persist();
    }
    useEffect(
        lambda {
            poll();
            timer = setInterval(poll, 15000);
            change = lambda {
                if owner.current {
                    try {
                        sessionStorage.removeItem(
                            "ns-channel-alerts-" + str(owner.current)
                        );
                    } except Exception {}
                }
                clear();
                poll();
            };
            window.addEventListener(SESSION_EVENT, change);
            window.addEventListener("focus", poll);
            return lambda {
                window.removeEventListener(SESSION_EVENT, change);
                window.removeEventListener("focus", poll);
                clearInterval(timer);
                clear();
            };
        },
        []
    );
    async def toggle_screen {
        version = epoch.current;
        want = not screen.current;
        hint = "";
        if want {
            api: any = globalThis.Notification;  # jac:ignore[E1053]
            if not api {
                hint = "Screen notifications are unavailable on this device.";
                return;
            }
            try {
                permission = await api.requestPermission();
                if version != epoch.current {
                    return;
                }
                if permission != "granted" {
                    hint = "Allow notifications in your browser settings.";
                    return;
                }
            } except Exception {
                hint = "Screen notifications are unavailable on this device.";
                return;
            }
        }
        screen.current = want;
        desktop = want;
        try {
            localStorage.setItem(
                "ns-channel-screen-" + str(owner.current), "1" if want else "0"
            );
        } except Exception {}
    }
    <div className="nav-alerts" ref={container}>
        {if signedIn {
            <button
                type="button"
                ref={trigger}
                className="site-nav-link alerts-button"
                title="Channel alerts"
                aria-label={"Channel alerts (" + str(unread) + " unread)"}
                aria-expanded={openTray}
                onClick={lambda { openTray = not openTray; }}
            >
                <svg
                    viewBox="0 0 24 24"
                    width="20"
                    height="20"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="1.6"
                    aria-hidden="true"
                >
                    <path d="M4 17h16l-2-3V9a6 6 0 0 0-12 0v5z M10 20a2 2 0 0 0 4 0"/>
                </svg>
                <span className="site-nav-text">Channel alerts</span>
                {if unread {
                    <span className="alert-count">{unread}</span>
                }}
            </button>
            if openTray {
                <section className="alerts-popover" aria-label="Channel alerts">
                    <header>
                        <h2>Channel alerts</h2>
                        <button
                            type="button"
                            aria-label="Close channel alerts"
                            onClick={close_tray}
                        >
                            ×
                        </button>
                    </header>
                    {if offline {
                        <p role="status">Reconnecting…</p>
                    }}
                    {if len(notices) {
                        <ul>
                            {for item in notices {
                                <li key={item.id}>
                                    <a
                                        href={alert_url(item)}
                                        onClick={lambda { mark_read(item); }}
                                    >
                                        {item.title}
                                    </a>
                                    <small>
                                        {item.channel_name
                                            + (" · Read" if item.read else "")}
                                    </small>
                                </li>
                            }}
                        </ul>
                        <button
                            type="button"
                            onClick={lambda {
                                history.current = [];
                                notices = [];
                                persist();
                            }}
                        >
                            Clear alerts
                        </button>
                    } else {
                        <p>
                            New stories from channels with alerts on appear here while NewsDrop is open.
                        </p>
                    } }
                    <label>
                        <input
                            type="checkbox"
                            checked={desktop}
                            onChange={toggle_screen}
                        />{" "}
                        Screen notifications on this device
                    </label>
                    {if hint {
                        <p role="status">{hint}</p>
                    }}
                    <a
                        href="/following#channel-alerts"
                        onClick={lambda { openTray = False; }}
                    >
                        Manage channel alerts →
                    </a>
                </section>
            }
        }}
    </div>
}

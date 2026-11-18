"""Shared navigation for Newsstream's three main pages."""

def:pub Navigation(active: str) -> JsxElement {
    return
        <nav className="site-nav" aria-label="Main navigation">
            <a href="/" className="site-nav-brand">{"◉ NewsStream"}</a>
            <div className="site-nav-links">
                <a
                    href="/"
                    className={"site-nav-link active"
                        if active == "news"
                        else "site-nav-link"}
                    aria-current={"page" if active == "news" else None}
                >
                    <span className="site-nav-icon">
                        <svg
                            width="22"
                            height="22"
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            strokeWidth="1.8"
                            strokeLinecap="round"
                            strokeLinejoin="round"
                            aria-hidden="true"
                        >
                            <rect x="4" y="3" width="16" height="18" rx="2"/>
                            <path d="M8 7h8M8 11h8M8 15h3M14 15h2"/>
                        </svg>
                    </span>
                    <span className="site-nav-copy">
                        <strong>{"News Feed"}</strong>
                        <small>{"Live news and alerts"}</small>
                    </span>
                </a>
                <a
                    href="/trading"
                    className={"site-nav-link active"
                        if active == "trading"
                        else "site-nav-link"}
                    aria-current={"page" if active == "trading" else None}
                >
                    <span className="site-nav-icon">
                        <svg
                            width="22"
                            height="22"
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            strokeWidth="1.8"
                            strokeLinecap="round"
                            strokeLinejoin="round"
                            aria-hidden="true"
                        >
                            <path d="M3 17l6-6 4 4 8-9"/>
                            <path d="M15 6h6v6"/>
                            <path d="M3 3v18h18"/>
                        </svg>
                    </span>
                    <span className="site-nav-copy">
                        <strong>{"Trading Insights"}</strong>
                        <small>{"Charts and trade ideas"}</small>
                    </span>
                </a>
                <a
                    href="/sources"
                    className={"site-nav-link active"
                        if active == "sources"
                        else "site-nav-link"}
                    aria-current={"page" if active == "sources" else None}
                >
                    <span className="site-nav-icon">
                        <svg
                            width="22"
                            height="22"
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            strokeWidth="1.8"
                            strokeLinecap="round"
                            strokeLinejoin="round"
                            aria-hidden="true"
                        >
                            <path d="M4 11a9 9 0 0 1 9 9"/>
                            <path d="M4 4a16 16 0 0 1 16 16"/>
                            <circle
                                cx="5"
                                cy="19"
                                r="1"
                                fill="currentColor"
                                stroke="none"
                            />
                        </svg>
                    </span>
                    <span className="site-nav-copy">
                        <strong>{"My Sources"}</strong>
                        <small>{"Personalize your feed"}</small>
                    </span>
                </a>
            </div>
            <SidebarResizer/>
        </nav>;
}

import from react { useEffect }

glob SIDEBAR_KEY: str = "ns_sidebar_width",
     SIDEBAR_DEFAULT: int = 200,
     SIDEBAR_MIN: int = 160,
     SIDEBAR_MAX: int = 420,
     SIDEBAR_STEP: int = 16;

"""Set the desktop sidebar width (clamped) through the --sidebar-w CSS
variable, which sizes the sidebar and the space pages leave for it."""
def apply_sidebar_width(px: float) -> int {
    clamped: any = Math.round(Math.max(SIDEBAR_MIN, Math.min(SIDEBAR_MAX, px)));
    html: any = document.documentElement;
    html.style.setProperty("--sidebar-w", str(clamped) + "px");
    return clamped;
}

def saved_sidebar_width -> int {
    try {
        saved: any = parseInt(localStorage.getItem(SIDEBAR_KEY) or "");
        if not isNaN(saved) {
            return saved;
        }
    } except Exception {}
    return SIDEBAR_DEFAULT;
}

"""Drag handle on the sidebar's right edge (desktop layout only). Arrow keys
resize it too, Home/End jump to the limits, and a double-click resets it.
The width is remembered per browser."""
def SidebarResizer -> JsxElement {
    has width: int = SIDEBAR_DEFAULT;

    def settle(px: float) {
        width = apply_sidebar_width(px);
        try {
            localStorage.setItem(SIDEBAR_KEY, str(width));
        } except Exception {}
    }

    def start_drag(e: any) {
        e.preventDefault();
        handle: any = e.currentTarget;
        body: any = document.body;
        handle.setPointerCapture(e.pointerId);
        body.classList.add("sidebar-resizing");

        def on_move(ev: any) {
            # the sidebar starts at the window's left edge
            width = apply_sidebar_width(ev.clientX);
        }

        def on_stop(ev: any) {
            handle.removeEventListener("pointermove", on_move);
            handle.removeEventListener("pointerup", on_stop);
            handle.removeEventListener("pointercancel", on_stop);
            body.classList.remove("sidebar-resizing");
            settle(ev.clientX);
        }

        handle.addEventListener("pointermove", on_move);
        handle.addEventListener("pointerup", on_stop);
        handle.addEventListener("pointercancel", on_stop);
    }

    def on_key(e: any) {
        moves = {
            "ArrowLeft": width - SIDEBAR_STEP,
            "ArrowRight": width + SIDEBAR_STEP,
            "Home": SIDEBAR_MIN,
            "End": SIDEBAR_MAX
        };
        if e.key in moves {
            e.preventDefault();
            settle(moves[e.key]);
        }
    }

    useEffect(lambda { width = apply_sidebar_width(saved_sidebar_width()); }, []);

    <div
        className="site-nav-resizer"
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize sidebar"
        aria-valuemin={SIDEBAR_MIN}
        aria-valuemax={SIDEBAR_MAX}
        aria-valuenow={width}
        tabIndex={0}
        title="Drag to resize. Double-click to reset."
        onPointerDown={start_drag}
        onKeyDown={on_key}
        onDoubleClick={lambda { settle(SIDEBAR_DEFAULT); }}
    />
}

"""Navigation shared by public pages and the private workspace."""

import from .auth { AuthPanel }
import from .channel_alerts { ChannelAlerts }
import from react { useEffect, useRef }

def NavLink(path: str, title: str, active: bool, icon: str) -> JsxElement {
    <a
        href={path}
        className={"site-nav-link active" if active else "site-nav-link"}
        aria-current={"page" if active else None}
        title={title}
        aria-label={title}
    >
        <svg
            viewBox="0 0 24 24"
            width="20"
            height="20"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.6"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
        >
            <path d={icon}/>
        </svg>
        <span className="site-nav-text">{title}</span>
    </a>
}

def:pub Navigation(active: str) -> JsxElement {
    has compact: bool = False,
        opened: bool = False;
    toggleRef: any = useRef(None);
    def dismiss(e: any) {
        if e.key == "Escape" {
            opened = False;
            if toggleRef.current {
                toggleRef.current.focus();
            }
        }
    }
    useEffect(
        lambda { try {
            compact = localStorage.getItem("newsstream-nav-compact") == "1";
        } except Exception {}},
        []
    );
    useEffect(
        lambda { if opened {
            window.addEventListener("keydown", dismiss);
            return lambda { window.removeEventListener("keydown", dismiss); };
        }},
        [opened]
    );
    def toggle_compact {
        next_value = not compact;
        compact = next_value;
        try {
            localStorage.setItem("newsstream-nav-compact", "1" if next_value else "0");
        } except Exception {}
    }
    <nav
        className={"site-nav"
            + (" compact" if compact else "")
            + (" open" if opened else "")}
        aria-label="Main navigation"
    >
        <div className="site-nav-head">
            <a
                href="/"
                className="site-nav-brand"
                aria-label="NewsDrop home"
                title="NewsDrop"
            >
                <img
                    className="site-nav-mark"
                    src="/brand/drop.svg"
                    alt=""
                    width={36}
                    height={36}
                />
                <span className="site-nav-text">NewsDrop</span>
            </a>
            <button
                ref={toggleRef}
                className="site-nav-menu"
                type="button"
                aria-controls="site-nav-links"
                aria-expanded={opened}
                onClick={lambda { opened = not opened; }}
            >
                {"Close menu" if opened else "Menu"}
            </button>
        </div>
        <div id="site-nav-links" className="site-nav-links">
            <NavLink
                path="/"
                title="Home"
                active={active == "home"}
                icon="M3 10.5 12 3l9 7.5V21h-6v-7H9v7H3z"
            />
            <NavLink
                path="/discover"
                title="Discover"
                active={active == "discover"}
                icon="M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0z M15.5 8.5l-2.2 4.8-4.8 2.2 2.2-4.8z"
            />
            <NavLink
                path="/following"
                title="Following"
                active={active == "following"}
                icon="M6 3.5h12v17l-6-4-6 4z"
            />
            <NavLink
                path="/sources"
                title="My Sources"
                active={active == "sources"}
                icon="M3 5h7l2 2h9v13H3z M8 13h8 M12 9v8"
            />
            <ChannelAlerts/>
        </div>
        <AuthPanel navigation={True}/>
        <button
            className="site-nav-collapse"
            type="button"
            onClick={toggle_compact}
            aria-expanded={not compact}
            aria-controls="site-nav-links"
            aria-label={"Expand sidebar" if compact else "Collapse sidebar"}
            title={"Expand sidebar" if compact else "Collapse sidebar"}
        >
            <span aria-hidden="true">{"»" if compact else "«"}</span>
            <span className="site-nav-text">Collapse sidebar</span>
        </button>
        <SidebarResizer/>
    </nav>
}


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
        start_x: float = e.clientX;
        start_width: int = width;
        handle.setPointerCapture(e.pointerId);
        body.classList.add("sidebar-resizing");

        def on_move(ev: any) {
            width = apply_sidebar_width(start_width + ev.clientX - start_x);
        }

        def on_stop(ev: any) {
            handle.removeEventListener("pointermove", on_move);
            handle.removeEventListener("pointerup", on_stop);
            handle.removeEventListener("pointercancel", on_stop);
            body.classList.remove("sidebar-resizing");
            settle(start_width + ev.clientX - start_x);
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

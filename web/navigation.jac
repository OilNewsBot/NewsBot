"""Navigation shared by public pages and the private workspace."""

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
                aria-label="Newsstream home"
                title="Newsstream"
            >
                <span className="site-nav-mark" aria-hidden="true">N</span>
                <span className="site-nav-text">Newsstream</span>
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
        </div>
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
    </nav>
}

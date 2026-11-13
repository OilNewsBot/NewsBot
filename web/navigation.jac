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
        </nav>;
}

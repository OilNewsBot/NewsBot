"""Registration and login UI for NewsDrop."""
import from react { useEffect, useRef }

"""Window event fired after a login or logout, so the sign-in gate in
main.jac can lock or unlock whichever page is showing."""
glob:pub SESSION_EVENT: str = "ns-session";

def announce_session_change {
    # the checker has no browser typings for Event
    try {
        localStorage.setItem("ns-session-change", str(new(Date).getTime()));
    } except Exception {}
    window.dispatchEvent(new(Event, SESSION_EVENT));  # jac:ignore[E1053]
}

def:pub sign_in_url(destination: str = "") -> str {
    win: any = window;
    if not destination and win.location.pathname == "/login" {
        return "/login" + win.location.search;
    }
    target = destination
        or (win.location.pathname + win.location.search + win.location.hash);
    return "/login?next=" + encodeURIComponent(target);
}

def login_destination -> str {
    win: any = window;
    current = new(win.URL, win.location.href);
    value = current.searchParams.get("next");
    if value {
        try {
            url = new(win.URL, value, current.origin);
            path = str(url.pathname);
            if url.origin == current.origin
                and (
                    path in ["/", "/discover", "/following", "/sources"]
                    or path.startswith("/channels/")
                    or path.startswith("/stories/")
                    or path.startswith("/categories/")
                ) {
                return str(url.href);
            }
        } except Exception {}
    }
    return "/";
}

def:pub AuthPanel(navigation: bool = False) -> JsxElement {
    authEpoch: any = useRef(0);
    firstField: any = useRef(None);
    modeChanged: any = useRef(False);
    has checked: bool = False,
        mode: str = "login",
        username: str = "",
        email: str = "",
        password: str = "",
        message: str = "",
        error: str = "",
        loading: bool = False,
        loggedIn: bool = False,
        currentUsername: str = "";
    async def check_session {
        epoch = authEpoch.current;
        try {
            response = await fetch(
                "/me", {"credentials": "same-origin", "cache": "no-store"}
            );
            if epoch != authEpoch.current {
                return;
            }

            if response.ok {
                user: any = await response.json();
                if epoch != authEpoch.current {
                    return;
                }
                currentUsername = str(user["username"]);
                loggedIn = True;
            } else {
                loggedIn = False;
            }
        } except Exception {
            loggedIn = False;
        }
        if epoch == authEpoch.current {
            checked = True;
        }
    }

    useEffect(
        lambda {
            authEpoch.current += 1;
            check_session();
            refresh = lambda {
                authEpoch.current += 1;
                check_session();
            };
            window.addEventListener(SESSION_EVENT, refresh);
            if navigation {
                window.addEventListener("focus", refresh);
            }
            return lambda {
                authEpoch.current += 1;
                window.removeEventListener(SESSION_EVENT, refresh);
                window.removeEventListener("focus", refresh);
            };
        },
        []
    );

    useEffect(
        lambda { if modeChanged.current and firstField.current {
            firstField.current.focus();
        }},
        [mode]
    );

    async def logout {
        authEpoch.current += 1;
        epoch = authEpoch.current;
        try {
            response = await fetch(
                "/logout", {"method": "POST", "credentials": "same-origin"}
            );
            if epoch != authEpoch.current {
                return;
            }

            if response.ok {
                loggedIn = False;
                currentUsername = "";
                password = "";
                message = "You have been logged out.";
                error = "";
                mode = "login";

                announce_session_change();
            } else {
                error = "Could not log out. Please try again.";
            }
        } except Exception {
            error = "Could not connect to the server.";
        }
    }

    async def submit(e: any) {
        e.preventDefault();
        authEpoch.current += 1;
        epoch = authEpoch.current;
        loading = True;
        error = "";
        message = "";

        try {
            endpoint = "/register" if mode == "register" else "/login";
            data: any = {"email": email, "password": password};

            if mode == "register" {
                data["username"] = username;
            }

            async def send(path: str, payload: any) -> any {
                return await fetch(
                    path,
                    {
                        "method": "POST",
                        "headers": {"Content-Type": "application/json"},
                        "credentials": "same-origin",
                        "body": JSON.stringify(payload)
                    }
                );
            }
            response = await send(endpoint, data);
            if epoch != authEpoch.current {
                return;
            }
            if response.ok and mode == "register" {
                # Registration and login use the service's existing session contract.
                modeChanged.current = True;
                mode = "login";
                message = "Account created.";
                response = await send("/login", {"email": email, "password": password});
            }
            if epoch != authEpoch.current {
                return;
            }
            if not response.ok {
                result = await response.json();
                error = str(result["detail"] or "Please try again.");
            } else {
                password = "";
                announce_session_change();
                win: any = window;
                if win.location.pathname == "/login" {
                    win.location.replace(login_destination());
                }
            }
        } except Exception {
            error = "Could not connect to the server. Please try again.";
        }

        loading = False;
    }

    if navigation {
        if not checked {
            return <></>;
        }
        return
            <div className="nav-account">
                {if loggedIn {
                    <span className="nav-account-name" title={currentUsername}>
                        {currentUsername}
                    </span>
                    <button
                        type="button"
                        onClick={logout}
                        title="Log out"
                        aria-label="Log out"
                    >
                        Log out
                    </button>
                } else {
                    <a href={sign_in_url()} aria-label="Log in" title="Log in">
                        Log in
                    </a>
                } }
                {if error {
                    <p role="alert">{error}</p>
                }}
            </div>;
    }
    if not checked {
        return <p role="status">Checking sign-in…</p>;
    }
    if loggedIn {
        return <a href={login_destination()}>Continue</a>;
    }
    <section className="auth-panel">
        <h2>{"Create an account" if mode == "register" else "Log in"}</h2>
        <form onSubmit={submit}>
            {if mode == "register" {
                <label>
                    Username
                    <input
                        ref={firstField}
                        autoComplete="username"
                        type="text"
                        value={username}
                        onChange={lambda (e: any) { username = e.target.value; }}
                        required
                    />
                </label>
            }}
            <label>
                Email
                <input
                    ref={firstField if mode == "login" else None}
                    autoComplete="email"
                    type="email"
                    value={email}
                    onChange={lambda (e: any) { email = e.target.value; }}
                    required
                />
            </label>
            <label>
                Password
                <input
                    type="password"
                    autoComplete={"new-password"
                        if mode == "register"
                        else "current-password"}
                    aria-describedby={"register-password-hint"
                        if mode == "register"
                        else None}
                    value={password}
                    onChange={lambda (e: any) { password = e.target.value; }}
                    minLength={12 if mode == "register" else 1}
                    required
                />
            </label>
            {if mode == "register" {
                <small id="register-password-hint">Use at least 12 characters.</small>
            }}
            <button type="submit" disabled={loading}>
                {"Please wait..."
                    if loading
                    else ("Register" if mode == "register" else "Log in")}
            </button>
        </form>
        {if error {
            <p className="auth-error" role="alert">{error}</p>
        }}
        {if message {
            <p className="auth-success" role="status">{message}</p>
        }}
        <button
            type="button"
            disabled={loading}
            onClick={lambda {
                modeChanged.current = True;
                mode = "register" if mode == "login" else "login";
                error = "";
                message = "";
                password = "";
            }}
        >
            {"Need an account? Register"
                if mode == "login"
                else "Already have an account? Log in"}
        </button>
    </section>
}

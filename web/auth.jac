"""Registration and login UI for NewsBot."""
import from react { useEffect, useRef }

def:pub AuthPanel(onSessionChange: any = None) -> JsxElement {
    authEpoch: any = useRef(0);
    has mode: str = "login",
        username: str = "",
        email: str = "",
        password: str = "",
        message: str = "",
        error: str = "",
        loading: bool = False,
        loggedIn: bool = False,
        currentUsername: str = "",
        currentEmail: str = "";
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
                currentEmail = str(user["email"]);
                loggedIn = True;
                if onSessionChange {
                    onSessionChange(user);
                }
            } else {
                loggedIn = False;
                if onSessionChange {
                    onSessionChange(None);
                }
            }
        } except Exception {
            loggedIn = False;
        }
    }

    useEffect(
        lambda {
            authEpoch.current += 1;
            check_session();
            return lambda { authEpoch.current += 1; };
        },
        []
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
                currentEmail = "";
                password = "";
                message = "You have been logged out.";
                error = "";
                mode = "login";
                if onSessionChange {
                    onSessionChange(None);
                }
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

            response = await fetch(
                endpoint,
                {
                    "method": "POST",
                    "headers": {"Content-Type": "application/json"},
                    "credentials": "same-origin",
                    "body": JSON.stringify(data)
                }
            );

            result = await response.json();
            if epoch != authEpoch.current {
                return;
            }

            if not response.ok {
                error = str(result["detail"])
                    if result["detail"]
                    else "Something went wrong.";
            } elif mode == "register" {
                message = "Account created! You can now log in.";
                mode = "login";
                password = "";
            } else {
                password = "";
                await check_session();
            }
        } except Exception {
            error = "Could not connect to the server.";
        }

        loading = False;
    }

    <section className="auth-panel">
        {if loggedIn {
            <div>
                <h2>{"Welcome, " + currentUsername + "!"}</h2>
                <p>{"Signed in as " + currentEmail}</p>
                <button type="button" onClick={logout}>Log out</button>
            </div>
        } else {
            <h2>{"Create an account" if mode == "register" else "Log in"}</h2>
            <form onSubmit={submit}>
                {if mode == "register" {
                    <label>
                        Username
                        <input
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
                        value={password}
                        onChange={lambda (e: any) { password = e.target.value; }}
                        minLength={12 if mode == "register" else 1}
                        required
                    />
                </label>
                <button type="submit" disabled={loading}>
                    {"Please wait..."
                        if loading
                        else ("Register" if mode == "register" else "Log in")}
                </button>
            </form>
            if error {
                <p className="auth-error">{error}</p>
            }
            if message {
                <p className="auth-success">{message}</p>
            }
            <button
                type="button"
                onClick={lambda {
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
        } }
    </section>
}

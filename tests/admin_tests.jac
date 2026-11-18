"""Admin route access: POST /ingest and POST /refetch on a server others can reach."""

import hashlib;
import os;
import httpx;
import from unittest.mock { patch }
import from fastapi { FastAPI, Request }
import from auth { admin_allowed, require_admin, require_user_or_admin }
import from db.repo { Repo }
import from tests.helpers { make_settings }

glob REMOTE: tuple[str, int] = ("203.0.113.5", 40000),
     LOCAL: tuple[str, int] = ("127.0.0.1", 40000);

"""Two routes guarded like /ingest (admin) and /refetch (user or admin)."""
def guarded_app(repo: Repo) -> FastAPI {
    app = FastAPI();

    @app.post("/admin")
    async def admin_route(request: Request) -> dict[str, bool] {
        await require_admin(request);
        return {"ok": True};
    }

    @app.post("/user-or-admin")
    async def user_route(request: Request) -> dict[str, bool] {
        await require_user_or_admin(request, repo);
        return {"ok": True};
    }

    return app;
}

def client_from(app: FastAPI, peer: tuple[str, int]) -> httpx.AsyncClient {
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app, client=peer), base_url="http://test"
    );
}

test "a configured admin token is required from every client" {
    assert admin_allowed("203.0.113.5", "s3cret", "s3cret");
    assert not admin_allowed("203.0.113.5", "wrong", "s3cret");
    assert not admin_allowed("203.0.113.5", None, "s3cret");
    # loopback is no bypass once a token is set (a proxy may sit on loopback)
    assert not admin_allowed("127.0.0.1", None, "s3cret");
    assert admin_allowed("127.0.0.1", "s3cret", "s3cret");
}

test "without a token only loopback clients are admins" {
    assert admin_allowed("127.0.0.1", None, "");
    assert admin_allowed("::1", None, "");
    assert not admin_allowed("203.0.113.5", None, "");
    assert not admin_allowed("203.0.113.5", "anything", "");
    assert not admin_allowed(None, None, "");
}

test "ingest-style and refetch-style routes enforce admin and session access" {
    async def run {
        settings = make_settings();
        repo = Repo(settings.db_path);
        await repo.connect();
        try {
            uid = await repo.create_user("demo", "demo@example.org", "unused");
            await repo.create_session(
                hashlib.sha256(b"demo-session").hexdigest(), uid, "2099-01-01 00:00:00"
            );
            app = guarded_app(repo);
            signed_in = {"Cookie": "session=demo-session"};

            with patch.dict(os.environ, {"NEWSBOT_ADMIN_TOKEN": ""}) {
                local = client_from(app, LOCAL);
                async with local {
                    assert (await local.post("/admin")).status_code == 200;
                    assert (await local.post("/user-or-admin")).status_code == 200;
                }
                remote = client_from(app, REMOTE);
                async with remote {
                    assert (await remote.post("/admin")).status_code == 403;
                    assert (await remote.post("/user-or-admin")).status_code == 401;
                    assert (
                        await remote.post("/user-or-admin", headers=signed_in)
                    ).status_code
                        == 200;
                }
            }

            with patch.dict(os.environ, {"NEWSBOT_ADMIN_TOKEN": "s3cret"}) {
                remote = client_from(app, REMOTE);
                async with remote {
                    assert (await remote.post("/admin")).status_code == 403;
                    assert (
                        await remote.post("/admin", headers={"X-Admin-Token": "nope"})
                    ).status_code
                        == 403;
                    assert (
                        await remote.post("/admin", headers={"X-Admin-Token": "s3cret"})
                    ).status_code
                        == 200;
                    # a signed-in user is not an admin
                    assert (await remote.post("/admin", headers=signed_in)).status_code
                        == 403;
                    assert (
                        await remote.post("/user-or-admin", headers=signed_in)
                    ).status_code
                        == 200;
                }
                local = client_from(app, LOCAL);
                async with local {
                    assert (await local.post("/admin")).status_code == 403;
                }
            }
        } finally {
            await repo.close();
        }
    }
    import asyncio;
    asyncio.run(run());
}

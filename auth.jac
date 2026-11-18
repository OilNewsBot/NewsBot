import hashlib;
import hmac;
import os;
import secrets;
import from fastapi { HTTPException, Request }
import from db.repo { Repo, Row }

glob LOOPBACK_HOSTS: tuple[str, str, str] = ("127.0.0.1", "::1", "localhost");

"""Admin routes (POST /ingest) on any server reachable beyond this machine.
With NEWSBOT_ADMIN_TOKEN set, the X-Admin-Token header must match it from
every client; without one, only loopback clients (local replay) qualify."""
def admin_allowed(
    client_host: str | None, header_token: str | None, configured: str
) -> bool {
    if configured {
        return bool(header_token)
            and hmac.compare_digest(str(header_token).encode(), configured.encode());
    }
    return client_host in LOOPBACK_HOSTS;
}

def is_admin(request: Request) -> bool {
    return admin_allowed(
        request.client.host if request.client else None,
        request.headers.get("x-admin-token"),
        os.environ.get("NEWSBOT_ADMIN_TOKEN", "")
    );
}

async def require_admin(request: Request) {
    if not is_admin(request) {
        raise HTTPException(403, "admin token required");
    }
}

"""Signed-in users (the UI) or an admin client."""
async def require_user_or_admin(request: Request, repo: Repo) {
    if not is_admin(request) {
        await require_user(request, repo);
    }
}

"""Resolve ownership from the authenticated cookie, never a request user_id."""
async def require_user(request: Request, repo: Repo) -> Row {
    token = request.cookies.get("session");
    if not token {
        raise HTTPException(401, "Sign in to manage your sources");
    }
    token_hash = hashlib.sha256(token.encode()).hexdigest();
    user = await repo.get_session(token_hash);
    if user is None {
        raise HTTPException(401, "Session expired; sign in again");
    }
    return user | {"token_hash": token_hash};
}

def hash_password(password: str) -> str {
    salt = secrets.token_bytes(16);
    hashed = hashlib.scrypt(
        password.encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=32
    );
    return salt.hex() + ":" + hashed.hex();
}

def verify_password(password: str, stored_hash: str) -> bool {
    try {
        parts = stored_hash.split(":");
        salt_hex = parts[0];
        hash_hex = parts[1];
        salt = bytes.fromhex(salt_hex);
        expected = bytes.fromhex(hash_hex);

        actual = hashlib.scrypt(
            password.encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=len(expected)
        );

        return hmac.compare_digest(actual, expected);
    } except (ValueError, TypeError) {
        return False;
    }
}

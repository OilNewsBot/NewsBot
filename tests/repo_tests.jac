"""Repository behavior that other database connections depend on."""

import asyncio;
import sqlite3;
import from tests.helpers { load_fixture, make_settings, open_repo }

"""True when another connection can take the database's write lock now."""
def write_lock_free(path: str) -> bool {
    other = sqlite3.connect(path, timeout=0.5, isolation_level=None);
    try {
        other.execute("BEGIN IMMEDIATE");
        other.execute("ROLLBACK");
        return True;
    } except sqlite3.OperationalError {
        return False;
    } finally {
        other.close();
    }
}

test "a duplicate post leaves no open transaction or write lock" {
    async def body {
        settings = make_settings();
        async with open_repo(settings) as repo {
            first = load_fixture("kharg_strikes")[0][0];
            assert await repo.insert_post(first) is not None;
            # the X push feed redelivers its newest post every check interval
            assert await repo.insert_post(first) is None;
            assert not repo.db.in_transaction;
            assert write_lock_free(str(settings.db_path));
            # and the next new post still inserts
            second = load_fixture("khasab_vlcc")[0][0];
            assert await repo.insert_post(second) is not None;
            assert write_lock_free(str(settings.db_path));
        }
    }
    asyncio.run(body());
}

"""Loopback fixture for the accounts browser regression, using a temporary DB."""

import os;
import uvicorn;
import from pathlib { Path }
import from app { create_app }
import from config { load_settings }

with entry:__main__ {
    db_path = Path(os.environ["NEWSBOT_BROWSER_TEST_DB"]);
    settings = load_settings(db_path=db_path, env_path=db_path.parent / ".env");
    uvicorn.run(
        create_app(settings), host="127.0.0.1", port=0, timeout_graceful_shutdown=2
    );
}

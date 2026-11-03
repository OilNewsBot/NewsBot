"""Single-process personal-source collector; all durable state lives in Store.

One X request per claim, no vendor rule mutations, and at most one source from
each connection per ten-second sweep. Personal data never enters the oil queue.
"""

import asyncio;
import logging;
import from datetime { UTC, datetime, timedelta }
import from personal.providers { ProviderError, fetch_source }
import from db.repo { Row }

glob log: logging.Logger = logging.getLogger("newsstream.personal");

def after_seconds(seconds: int) -> str {
    return (datetime.now(UTC) + timedelta(seconds=seconds)).isoformat();
}

obj PersonalWorker {
    # Structural interface permits a fixture store/fetcher without live calls.
    has store: any,
        fetcher: any = None,
        _running: bool = False;

    async def collect(source: Row) {
        source_id = int(source["id"]);
        connection_id = int(source["connection_id"]);
        provider = str(source["provider"]);
        source_revision = int(source.get("revision", 0));
        connection_revision = int(source.get("connection_revision", 0));
        try {
            secret = "";
            if provider == "x" {
                if not await self.store.claim_request(
                    connection_id, connection_revision=connection_revision
                ) {
                    # The Store knows whether this is quota, cooldown, deletion
                    # or stale credentials. Do not overwrite its current state.
                    return;
                }
                secret = await self.store.connection_secret(connection_id);
            }
            fetch = self.fetcher or fetch_source;
            (items, cursor) = (
                await asyncio.wait_for(fetch(source, secret), timeout=45)
            ) as tuple[list[Row], str];
            # The Store verifies that the source is still owned/enabled and
            # commits post, notification and cursor atomically. A disconnect
            # during an HTTP request therefore cannot resurrect collection.
            await self.store.persist_batch(
                source_id,
                items,
                cursor,
                initial=not bool(source.get("initialized")),
                source_revision=source_revision,
                connection_revision=connection_revision
            );
            await self.store.source_success(
                source_id,
                after_seconds(60 if provider == "x" else 300),
                source_revision=source_revision,
                connection_revision=connection_revision
            );
        } except ProviderError as error {
            await self.store.source_failure(
                source_id,
                error.status if provider == "x" else "error",
                error.detail,
                after_seconds(error.retry_after),
                source_revision=source_revision,
                connection_revision=connection_revision
            );
        } except (ValueError, RuntimeError) {
            await self.store.source_failure(
                source_id,
                "needs_reconnect" if provider == "x" else "error",
                "Connection unavailable; reconnect this service"
                    if provider == "x"
                    else "Feed unavailable; collection will retry",
                after_seconds(3600),
                source_revision=source_revision,
                connection_revision=connection_revision
            );
        } except Exception {
            # Never log provider exception strings, headers, URLs, or secrets.
            log.warning("personal collection failed for source %d", source_id);
            await self.store.source_failure(
                source_id,
                "error",
                "Collection failed; it will retry",
                after_seconds(300),
                source_revision=source_revision,
                connection_revision=connection_revision
            );
        }
    }

    async def tick {
        seen: set[int] = set();
        sources = await self.store.active_sources();
        batch: list[Row] = [];
        for source in sources {
            cid = int(source["connection_id"]);
            if cid in seen {
                continue;
            }
            seen.add(cid);
            batch.append(source);
            if len(batch) >= 20 {
                break;
            }
        }
        # Bound both connection concurrency and total outstanding responses.
        for offset in range(0, len(batch), 4) {
            await asyncio.gather(
                *(self.collect(source) for source in batch[offset:offset + 4])
            );
        }
    }

    async def run {
        if self._running {
            raise RuntimeError("Personal collector is already running");
        }
        self._running = True;
        try {
            while True {
                try {
                    await self.tick();
                } except Exception {
                    log.warning("personal collector sweep failed; retrying");
                }
                await asyncio.sleep(10);
            }
        } finally {
            self._running = False;
        }
    }
}

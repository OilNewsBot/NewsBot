"""Regression scenarios for public storage, refresh, model budgets and source privacy."""
import json
import sqlite3
import tempfile
from pathlib import Path
from unittest.mock import patch

import httpx
from fastapi import HTTPException

from publicnews.catalog import Catalog, PROMPT_VERSION, channel_address
from publicnews.providers import ChatCompletions, select_provider
from publicnews.worker import PublicWorker


async def catalog_regressions():
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "news.db"
        with sqlite3.connect(db_path) as db:
            db.execute("CREATE TABLE users(id INTEGER PRIMARY KEY)")
            db.executemany("INSERT INTO users VALUES(?)", [(1,), (2,)])
        edition = {"curator": "Editors", "captured_at": "2025-01-01T00:00:00+00:00",
                   "categories": [{"slug": "tech", "name": "Tech", "channels": []}], "publishers": []}
        catalog = Catalog(db_path, edition, "small-test")
        await catalog.start()
        opts = {"name": "Chip supply", "description": "Production updates", "category": "tech",
                "source_type": "rss", "source_url": "https://publisher.example/news.xml"}
        first = await catalog.create(1, "alice", opts)
        second = await catalog.create(2, "sam", {**opts, "name": "Watch list"})
        for c in (first, second):
            await catalog.toggle(c["slug"], 2, "subscription", True)
        item = {"external_id": "guid-abc", "url": "https://publisher.example/report", "title": "Quarterly production results",
                "text": "The preliminary filing reports two shipments.", "posted_at": "2025-01-02T00:00:00+00:00"}
        # A bad item URL must not suppress the rest of the feed.
        other = {**item, "external_id": "guid-zzz", "url": "file:///tmp/story",
                 "text": "", "title": "A headline-only report"}
        articles = [item, other]
        seen_validators = []
        async def fetch(url, validators):
            seen_validators.append(validators)
            return b"feed", {"url": url, "etag": "test-edition"}, url
        class Model:
            def __init__(self):
                self.calls = []
                self.offline = False
            async def call_json(self, purpose, model, prompt, content, **options):
                self.calls.append(json.loads(content))
                if self.offline:
                    raise RuntimeError("test outage")
                return {"summary": "The publisher reports " + self.calls[-1]["excerpt"]}
        model = Model()
        worker = PublicWorker(catalog, fetch, lambda body, base: ("Publisher", articles),
                              lambda story, sections: "tech", model, 4)
        async def due():
            await catalog.run_db(lambda db: db.execute("UPDATE news_sources SET next_poll=0").rowcount, write=True)
        with patch.dict("os.environ", {"NEWSSTREAM_DEMO_RSS": "0"}):
            assert await worker.refresh_one()
            assert not await worker.refresh_one(), "Two curators should share one RSS refresh"
            assert await worker.summarize_one()
            assert not await worker.summarize_one()
            assert len(model.calls) == 1
            feed = await catalog.following(2)
            report = next(s for s in feed["items"] if s["title"] == item["title"])
            assert report["ai_generated"] and report["generated_at"] and len(report["sources"]) == 2
            assert len(feed["items"]) == 2
            assert next(s for s in feed["items"] if s["title"] == other["title"])["url"] == ""
            await due()
            assert await worker.refresh_one()
            assert seen_validators[-1]["etag"] == "test-edition"
            assert not await worker.summarize_one(), "An unchanged article must reuse its summary"
            item["text"] = "The corrected filing says four shipments."
            await due()
            await worker.refresh_one()
            model.offline = True
            assert await worker.summarize_one()
            assert len(model.calls) == 2
            corrected = next(s for s in (await catalog.following(2))["items"] if s["id"] == report["id"])
            assert corrected["summary"] == item["text"] and not corrected["ai_generated"]
            assert corrected["status"] == "retry"
            await catalog.run_db(lambda db: db.execute("UPDATE news_summaries SET retry_at=0").rowcount, write=True)
            assert not await worker.summarize_one(), "Persisted daily budget applies even to retries"
            worker.daily_limit = 6
            model.offline = False
            assert await worker.summarize_one()
            assert (await catalog.detail(first["slug"]))["channel"]["headlines"]
            restarted = Catalog(db_path, edition, "small-test")
            await restarted.start()
            refreshed = next(s for s in (await restarted.following(2))["items"] if s["id"] == report["id"])
            assert refreshed["ai_generated"] and "four shipments" in refreshed["summary"]

        social = await catalog.create(1, "alice", {**opts, "name": "Community", "source_type": "community",
                                                   "source_url": ""})
        post = await catalog.post(social["slug"], 2, "sam", {"title": "Update", "text": "Reader report"})
        comment = await catalog.comment(social["slug"], 1, "alice", {"text": "Source?", "item_id": post["id"]})
        reply = await catalog.comment(social["slug"], 2, "sam", {"text": "I was there.", "item_id": post["id"],
                                                                "parent_id": comment["id"]})
        assert reply["parent_id"] == comment["id"]
        try:
            await catalog.comment(first["slug"], 1, "alice", {"text": "wrong channel", "item_id": post["id"]})
        except HTTPException as exc:
            assert exc.status_code == 404
        else:
            raise AssertionError("Cross-channel thread accepted")

        tg = await catalog.create(1, "alice", {**opts, "name": "Curated updates", "source_type": "telegram",
                                              "mode": "api", "source_url": ""})
        args = ("Public contributor", "Selected update", "Explicitly chosen text", "",
                "private-source:opaque-message", "2025-01-01T00:00:00+00:00", "telegram")
        try:
            await catalog.publish_selected(tg["slug"], 2, *args)
        except HTTPException as exc:
            assert exc.status_code == 403
        else:
            raise AssertionError("A second account published into the first user's Telegram channel")
        saved = await catalog.publish_selected(tg["slug"], 1, *args)
        duplicate = await catalog.publish_selected(tg["slug"], 1, *args)
        assert saved["id"] == duplicate["id"]
        public = await catalog.detail(tg["slug"])
        assert len(public["channel"]["headlines"]) == 1 and "private-source" not in json.dumps(public)
        assert public["channel"]["headlines"][0]["status"] == "source"
        for url in ["https://t.me/example_news", "https://t.me/example_news/456"]:
            assert channel_address("telegram", "embed", url) == url
        for url in ["https://t.me/joinchat/123", "https://t.me/c/100/2", "https://t.me/+privateinvite"]:
            try:
                channel_address("telegram", "embed", url)
            except HTTPException as exc:
                assert exc.status_code == 422
            else:
                raise AssertionError("An invite or private message was accepted as a public embed")

        api = await catalog.create(1, "alice", {**opts, "name": "Publisher X", "source_type": "x",
                                                "mode": "api", "source_url": "https://x.com/publisher"})
        await catalog.publish_selected(api["slug"], 1, "publisher", "Update", "Provider-supplied text",
                                       "https://x.com/publisher/status/123", "provider-123",
                                       "2025-01-01T00:00:00+00:00", "x")
        await catalog.post(api["slug"], 1, "alice", {"title": "Shared link", "text": "See the link",
                                                    "url": "https://x.com/publisher/status/789"})
        assert not await worker.summarize_one(), "RSS-first default must leave social sources alone"
        opted_in = Catalog(db_path, edition, "small-test", "rss,x,community,telegram")
        await opted_in.start()
        worker = PublicWorker(opted_in, fetch, None, None, model, 20)
        assert await worker.summarize_one() and await worker.summarize_one()
        assert not await worker.summarize_one(), "Only the community post and selected X record are eligible"
        assert model.calls[-1]["publisher"] == "publisher"
        # Turning the model off preserves summaries of unchanged inputs.
        opted_in.ai_enabled = False
        result = (await opted_in.detail(api["slug"]))["channel"]
        assert result["curator"] == "alice" and result["source_type"] == "x"
        selected = next(s for s in result["headlines"] if s["url"].endswith("/123"))
        assert selected["source_type"] == "x" and selected["author"] == "publisher" and selected["ai_generated"]
        assert selected["generated_at"]
        link = next(s for s in result["headlines"] if s["url"].endswith("/789"))
        assert not link["ai_generated"] and link["status"] == "source"
        assert not (await opted_in.detail(tg["slug"]))["channel"]["headlines"][0]["ai_generated"]


async def provider_regressions():
    model = "test-model"
    endpoint = "http://127.0.0.1:11434/v1"
    config = {"NEWSSTREAM_SUMMARY_PROVIDER": "openai-compatible", "NEWSSTREAM_SUMMARY_BASE_URL": endpoint,
              "NEWSSTREAM_SUMMARY_MODEL": model, "NEWSSTREAM_SUMMARY_API_KEY": "test-credential"}
    native = object()
    assert select_provider(model, True, native, {}) == (model, native)
    assert select_provider(model, False, native, {}) == (model, None)
    identity, client = select_provider(model, False, native, config)
    assert client and identity != model and endpoint not in identity and "test-credential" not in identity
    assert select_provider(model, False, native, {**config, "NEWSSTREAM_SUMMARY_API_KEY": ""})[0] == identity
    assert select_provider(model, False, native, {**config, "NEWSSTREAM_SUMMARY_BASE_URL": "https://model.example/v1"})[0] != identity
    for changes in ({"NEWSSTREAM_SUMMARY_PROVIDER": "unknown"}, {"NEWSSTREAM_SUMMARY_BASE_URL": ""},
                    {"NEWSSTREAM_SUMMARY_BASE_URL": "https://test:password@host/v1"},
                    {"NEWSSTREAM_SUMMARY_MODEL": ""}, {"NEWSSTREAM_SUMMARY_PROVIDER": "disabled"}):
        assert select_provider(model, True, native, {**config, **changes})[1] is None

    requests = []
    def handle(request):
        requests.append(request)
        assert str(request.url) == endpoint + "/chat/completions"
        assert request.headers["authorization"] == "Bearer test-credential"
        body = json.loads(request.content)
        assert body["model"] == model and body["max_tokens"] == 150
        assert [m["role"] for m in body["messages"]] == ["system", "user"]
        return httpx.Response(200, json={"choices": [{"finish_reason": "stop", "message": {
            "content": json.dumps({"summary": "The publisher revised its schedule."})}}]})
    client.transport = httpx.MockTransport(handle)
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "summary.db"
        with sqlite3.connect(db_path) as db:
            db.execute("CREATE TABLE users(id INTEGER PRIMARY KEY)")
        channel = {"slug": "press", "name": "Press", "publisher": "Publisher", "description": "Updates",
                   "feed_url": "https://publisher.example/feed", "headlines": [{
                       "title": "New schedule", "summary": "The publisher revised its schedule.",
                       "url": "https://publisher.example/news", "published": "2025-01-10T00:00:00+00:00"}]}
        edition = {"curator": "Editors", "captured_at": "2025-01-10T00:00:00+00:00",
                   "categories": [{"slug": "tech", "name": "Tech", "channels": [channel]}]}
        original = Catalog(db_path, edition, model)
        await original.start()
        with sqlite3.connect(db_path) as db:
            db.execute("UPDATE news_items SET eligible=1")
            db.execute("""INSERT INTO news_summaries(revision,model,prompt_version,summary,generated_at)
                       SELECT revision,?,?,?,? FROM news_items""",
                       (model, PROMPT_VERSION, "Previously cached native summary.", edition["captured_at"]))
        assert (await original.detail("press"))["channel"]["headlines"][0]["ai_generated"]
        switched = Catalog(db_path, edition, identity)
        assert not (await switched.detail("press"))["channel"]["headlines"][0]["ai_generated"]
        worker = PublicWorker(switched, None, None, None, client, 1)
        assert await worker.summarize_one()
        assert not await worker.summarize_one() and len(requests) == 1
        assert (await switched.detail("press"))["channel"]["headlines"][0]["summary"] == "The publisher revised its schedule."
        assert (await original.detail("press"))["channel"]["headlines"][0]["summary"] == "Previously cached native summary."
        stopped = Catalog(db_path, edition, "unused-model")
        stopped.ai_enabled = False
        assert (await stopped.detail("press"))["channel"]["headlines"][0]["summary"] == "The publisher revised its schedule."

    failed = []
    replies = [httpx.Response(303, headers={"Location": "https://elsewhere.example/"}),
               httpx.Response(200, content=b"x" * 32769), httpx.Response(200, json={"choices": []}),
               httpx.Response(200, json={"choices": [{"message": {"content": "unstructured"}}]}),
               httpx.Response(200, json={"choices": [{"finish_reason": "length", "message": {"content": "{}"}}]})]
    for reply in replies:
        def respond(request):
            failed.append(request)
            assert "authorization" not in request.headers
            return reply
        invalid = ChatCompletions(endpoint, model, transport=httpx.MockTransport(respond))
        try:
            await invalid.call_json("test", invalid.cache_model, "System prompt", "Story", max_tokens=150)
        except ValueError:
            pass
        else:
            raise AssertionError("Invalid model completion was accepted")
    assert len(failed) == len(replies), "Provider redirects must not forward content or credentials"

"""Verify the signed-out directory without external feeds or a running worker."""

import asyncio;
import json;
import httpx;
import from datetime { datetime }
import from app { create_app }
import from db.directory { PublicDirectory }
import from pipeline.forum_routing { ForumRouter }
import from personal.providers { ProviderError }
import from tests.helpers { make_settings }

test "the public snapshot has dated headlines and unique channel addresses" {
    async def run {
        service = create_app(make_settings());
        client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=service), base_url="http://test"
        );
        async with client {
            response = await client.get("/api/directory");
            assert response.status_code == 200;
            data = response.json();
            captured = datetime.fromisoformat(data["captured_at"]);
            categories = data["categories"];
            assert [c["name"] for c in categories]
                == ["Energy", "Tech", "Healthcare", "Industrials", "General News"];
            slugs: set[str] = set();
            publisher = data["publishers"][0];
            assert publisher["slug"] == "new-york-times";
            destinations: set[str] = set();
            for category in categories {
                dedicated = [
                    c
                    for c in category["channels"]
                    if c["slug"] != publisher["slug"]
                ];
                if category["slug"] != "general" {
                    assert len(dedicated) >= 3;
                    image = await client.get(category["image_url"]);
                    assert image.status_code == 200;
                }
                for channel in category["channels"] {
                    assert channel["description"];
                    stories = channel["headlines"];
                    if channel["slug"] == publisher["slug"] {
                        assert 1 <= len(stories) <= 3;
                        assert all(s["section"] == category["slug"] for s in stories);
                        destinations.add(category["slug"]);
                    } else {
                        assert channel["slug"] not in slugs;
                        slugs.add(channel["slug"]);
                        assert len(stories) == 3;
                    }
                    dates = [
                        datetime.fromisoformat(story["published"]) for story in stories
                    ];
                    assert dates == sorted(dates, reverse=True);
                    assert dates[0] <= captured;
                    for story in stories {
                        assert story["url"].startswith("https://") and story["title"];
                        assert story["summary"] and story["summary"] != story["title"];
                    }
                }
            }
            assert {"tech", "healthcare", "general"}.issubset(destinations);
            private = await client.get("/api/me/feed");
            assert private.status_code == 401;
        }
    }
    asyncio.run(run());
}

obj ModelStub {
    has calls: int = 0;

    async def call_json(
        purpose: str, model: str, system: str, user: str, *, max_tokens: int
    ) -> dict[str, any] {
        self.calls += 1;
        assert purpose == "forum_routing" and model == "test-small";
        return {"labels": {"0": "industrials", "1": "unknown"}};
    }
}

test "local and model routing preserve valid assignments and reject unknown forums" {
    async def run {
        stub = ModelStub();
        router = ForumRouter(stub, "test-small");
        sections = ["tech", "energy", "industrials", "healthcare", "general"];
        stories = [
            {
                "title": "Rail freight and shipping delays",
                "summary": "Ports report cargo backlogs."
            },
            {
                "title": "New vaccine trial",
                "summary": "Doctors test a treatment for measles."
            }
        ];
        assert router.local(
            {
                "title": "Power grid adds solar storage",
                "summary": "Utility builds a battery plant."
            },
            sections
        )
            == "energy";
        assert router.local(
            {
                "title": "Festival announces award nominees",
                "summary": "Actors attend a film premiere."
            },
            sections
        )
            == "general";
        assert router.local(
            {
                "title": "Trade talks at international summit",
                "summary": "Leaders face export worries."
            },
            sections
        )
            == "general";
        router.assign_local(stories, sections);
        assert await router.review(stories, sections);
        assert stories[0]["section"] == "industrials"
            and stories[0]["routed_by"] == "test-small";
        assert stories[1]["section"] == "healthcare"
            and stories[1]["routed_by"] == "local";
        assert not await router.review(stories[:1], sections);
        assert stub.calls == 1;
    }
    asyncio.run(run());
}

test "a public RSS refresh keeps offline channels and survives a restart" {
    async def run {
        cache = make_settings().db_path.parent / "directory-rss.json";
        directory = PublicDirectory(cache);
        directory.load();
        energy = directory.catalog["categories"][0]["channels"];
        first = energy[0];
        other = energy[1]["headlines"];
        first["headlines"] = [];
        async def fixture(url: str) -> any {
            if url != first["feed_url"] {
                raise ProviderError("Offline fixture");
            }
            return (
                b"<rss><channel><item><title>New plant</title><link>http://www.eia.gov/new</link><description>A &lt;b&gt;solar&lt;/b&gt; plant opened.</description><pubDate>Mon, 02 Nov 2020 12:00:00 GMT</pubDate></item></channel></rss>",
                {},
                url
            );
        }
        await directory.refresh(fixture);
        assert first["headlines"][0]["summary"] == "A solar plant opened.";
        assert first["headlines"][0]["url"] == "https://www.eia.gov/new";
        assert energy[1]["headlines"] == other;
        assert "checked_at" not in energy[1];
        # Model a refresh newer than the seed even when CI has an earlier clock.
        saved = json.loads(cache.read_text());
        saved[first["feed_url"]]["checked_at"] = "2099-01-01T00:00:00+00:00";
        cache.write_text(json.dumps(saved));
        restored = PublicDirectory(cache);
        restored.load();
        assert restored.catalog["categories"][0]["channels"][0]["headlines"]
            == first["headlines"];
        cache.write_text("{");
        restored.load();
        assert len(restored.catalog["categories"][0]["channels"][0]["headlines"]) == 3;
    }
    asyncio.run(run());
}


test "retired oil and trading bookmarks lead to the public forum home" {
    async def run {
        client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=create_app(make_settings())),
            base_url="http://test"
        );
        async with client {
            for path in ["/oil", "/trading"] {
                response = await client.get(path);
                assert response.status_code == 307;
                assert response.headers["location"] == "/";
            }
        }
    }
    asyncio.run(run());
}

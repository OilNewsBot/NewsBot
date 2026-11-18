"""Verify the signed-out directory without external feeds or a running worker."""

import asyncio;
import httpx;
import from datetime { datetime }
import from app { create_app }
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
                == ["Energy", "Tech", "Healthcare", "Industrials"];
            slugs: set[str] = set();
            for category in categories {
                assert len(category["channels"]) == 2;
                image = await client.get(category["image_url"]);
                assert image.status_code == 200;
                for channel in category["channels"] {
                    assert channel["slug"] not in slugs;
                    slugs.add(channel["slug"]);
                    stories = channel["headlines"];
                    assert len(stories) == 3;
                    dates = [
                        datetime.fromisoformat(story["published"]) for story in stories
                    ];
                    assert dates == sorted(dates, reverse=True);
                    assert dates[0] <= captured;
                    for story in stories {
                        assert story["url"].startswith("https://") and story["title"];
                    }
                }
            }
            private = await client.get("/api/me/feed");
            assert private.status_code == 401;
        }
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

"""Run after jac build web using a Python environment with Playwright and Chromium."""
import os
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import expect, sync_playwright


INDEX = Path(__file__).resolve().parents[2] / ".jac/client/web/dist/index.html"
STATUS = {
    "adapters": [{"name": name, "state": "disabled", "detail": "not configured"}
                 for name in ("telegram", "x_api", "x_push")],
    "latency": {key: {"p50": None, "p95": None} for key in ("platform", "surface")},
    "counts": {"posts_seen": 0, "surfaced": 0}, "llm_spend_today": 0,
    "llm_fail_open": False, "x_reads_today": 0, "x_daily_read_budget": 100,
    "refetch_configured": False, "refetch_running": False, "threshold": 70, "max_stacked": 5,
    "inactive_accounts": [],
}


def card(number, kind="NEW_EVENT"):
    return {"notification_id": number, "kind": kind, "category": None,
            "one_line": f"Bulletin {number}", "handle": "tracker", "tier": "tracker",
            "url": f"https://example.test/story/{number}", "posted_at": "2026-11-18T12:00:00Z",
            "platform_latency_s": 2, "event_title": "", "what_changed": "",
            "badges": ["unfiltered"] if kind == "UNFILTERED" else []}


class NewsFeed(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(executable_path=os.getenv("CHROME_BIN"))

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()

    def setUp(self):
        self.page = self.browser.new_page(viewport={"width": 1280, "height": 950})
        self.addCleanup(self.page.context.close)
        self.history = []
        self.cursor_requests = []
        self.failed_routes = set()
        self.events = []
        self.suppressed = []
        self.status = dict(STATUS)
        self.page_errors = []
        self.page.on("pageerror", lambda error: self.page_errors.append(str(error)))
        self.page.add_init_script("""
            window.EventSource = class extends EventTarget {
                constructor() { super(); window.testStream = this; }
                close() {}
                publish(card) {
                    this.dispatchEvent(new MessageEvent("notification", {data:JSON.stringify(card)}));
                }
            };
        """)
        self.page.route("http://newsbot.test/**", self.route)

    def route(self, route):
        url = urlparse(route.request.url)
        if url.path in self.failed_routes:
            return route.fulfill(status=503, json={"detail": "temporarily unavailable"})
        if url.path == "/":
            return route.fulfill(content_type="text/html", body=INDEX.read_bytes())
        if url.path == "/notifications":
            after = int(parse_qs(url.query)["since"][0])
            self.cursor_requests.append(after)
            return route.fulfill(json=[n for n in self.history if n["notification_id"] > after][:200])
        if url.path == "/feed":
            return route.fulfill(json={"events": self.events, "notification_head": len(self.history),
                                       "unfiltered": [n for n in self.history if n["kind"] == "UNFILTERED"]})
        if url.path == "/status":
            return route.fulfill(json=self.status)
        if url.path == "/me":
            return route.fulfill(json={"username": "reader", "email": "reader@example.test", "user_id": 1})
        if url.path == "/refetch":
            return route.fulfill(status=409, json={"detail": "refetch already running"})
        if url.path == "/suppressed":
            return route.fulfill(json={"posts": self.suppressed})
        return route.fulfill(status=404, json={"detail": "unknown endpoint"})

    def open(self):
        self.page.goto("http://newsbot.test/")
        self.page.wait_for_function("!!window.testStream")

    def test_unfiltered_history_survives_ack_and_reload(self):
        self.open()
        self.history.extend(card(i, "UNFILTERED") for i in range(1, 4))
        self.page.evaluate("cards => cards.forEach(c => testStream.publish(c))", self.history)
        expect(self.page.locator("#tray .card")).to_have_count(3)
        self.page.keyboard.press("Escape")
        expect(self.page.locator("#tray .card")).to_have_count(2)
        self.page.reload()
        expect(self.page.locator("#tray .card")).to_have_count(0)
        expect(self.page.locator("#feed .unfiltered-history")).to_have_count(3)
        expect(self.page.locator("#feed")).to_contain_text("Bulletin 3")
        self.assertEqual(self.page_errors, [])

    def test_tray_fits_phone_and_all_cards_are_reachable(self):
        self.page.set_viewport_size({"width": 320, "height": 600})
        self.open()
        self.history.extend(card(i, "UNFILTERED") for i in range(1, 13))
        for c in self.history:
            c["one_line"] += " with enough words to wrap onto a second line"
        self.page.evaluate("cards => cards.forEach(c => testStream.publish(c))", self.history)
        first = self.page.locator("#tray .card").first
        expect(first.locator(".badge.warn")).to_have_count(1)
        handle = first.get_by_text("@tracker")
        expect(handle).to_be_in_viewport()
        for element in first.locator(".meta > *").all():
            box = element.bounding_box()
            self.assertGreaterEqual(box["x"], 0)
            self.assertLessEqual(box["x"] + box["width"], 320)
        # Tab through the source links to the native overflow button.
        first.locator("a").focus()
        more = self.page.get_by_role("button", name="+7 more")
        for _ in range(5):
            self.page.keyboard.press("Tab")
        expect(more).to_be_focused()
        expect(more).to_be_in_viewport()
        self.page.keyboard.press("Enter")
        all_cards = self.page.locator("#tray .card")
        expect(all_cards).to_have_count(12)
        for size in ({"width": 1280, "height": 950}, {"width": 320, "height": 600}):
            self.page.set_viewport_size(size)
            all_cards.last.scroll_into_view_if_needed()
            expect(all_cards.last).to_be_in_viewport()

    def test_live_status_and_footer_access(self):
        self.page.clock.install()
        self.open()
        expect(self.page.get_by_role("button", name="Log out")).to_have_count(1)
        expect(self.page.locator(".news-live-label")).to_have_text("No live feeds")
        expect(self.page.locator(".news-live-indicator.live")).to_have_count(0)
        for name in ("telegram", "x_api", "x_push"):
            chip = self.page.locator("footer span[title]").filter(has_text=name)
            self.assertTrue(chip.evaluate("""e => {
              const r=e.getBoundingClientRect();
              return e.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2));
            }"""))
        self.status["adapters"] = [{"name":"telegram","state":"live","detail":"connected"}]
        self.page.evaluate("testStream.onopen()")
        self.page.clock.fast_forward(10000)
        expect(self.page.locator(".news-live-label")).to_have_text("Live monitoring")
        self.failed_routes.add("/status")
        self.page.clock.fast_forward(10000)
        expect(self.page.locator("footer")).to_have_text("server unreachable")
        expect(self.page.locator(".news-live-indicator.live")).to_have_count(0)
        expect(self.page.get_by_role("heading", name="News Feed")).to_be_visible()
        self.assertEqual(self.page_errors, [])

    def test_lists_recover_and_open_suppressed_list_refreshes(self):
        self.page.clock.install()
        self.failed_routes.update(("/feed", "/suppressed"))
        self.page.goto("http://newsbot.test/")
        retry = self.page.get_by_role("button", name="Retry feed")
        expect(retry).to_be_visible()
        self.failed_routes.remove("/feed")
        retry.click()
        expect(self.page.get_by_text("No market events yet")).to_be_visible()
        self.page.get_by_label("Show suppressed").check()
        retry = self.page.get_by_role("button", name="Retry suppressed posts")
        expect(retry).to_be_visible()
        expect(self.page.get_by_text("Nothing suppressed yet.")).to_have_count(0)
        self.failed_routes.remove("/suppressed")
        retry.click()
        expect(self.page.get_by_text("Nothing suppressed yet.")).to_be_visible()
        self.suppressed.extend({"id":i, "account_handle":"reporter", "url":"https://example.test",
                                "text":f"Held report {i}", "materiality_score":30} for i in range(1,6))
        self.page.clock.fast_forward(10000)
        expect(self.page.locator("#suppressed .sup")).to_have_count(5)
        expect(retry).to_have_count(0)
        self.assertEqual(self.page_errors, [])

    def test_refetch_configuration_and_rejected_request(self):
        self.page.clock.install()
        self.open()
        button = self.page.locator(".news-refetch")
        expect(button).to_be_disabled()
        expect(self.page.get_by_text("Configure the X push provider to refetch posts.")).to_be_visible()
        self.status["refetch_configured"] = True
        self.page.clock.fast_forward(10000)
        expect(button).to_be_enabled()
        button.click()
        expect(self.page.get_by_text("refetch already running")).to_be_visible()
        expect(button).to_be_enabled()

    def test_origin_does_not_repeat_headline_and_preserves_source(self):
        self.events.append({"id":1, "category":"market", "title":"Port closure", "summary":"Port closure",
                            "status":"open", "origin_posted_at":"2026-11-18T12:00:00Z",
                            "posts":[{"id":1,"role":"origin","url":"https://example.test/source",
                                      "posted_at":"2026-11-18T12:00:00Z","tier":"tracker",
                                      "account_handle":"tracker","one_line":"Port closure","text":"Original report."}]})
        self.open()
        feed = self.page.locator("#feed")
        expect(feed.locator("h3")).to_contain_text("Port closure")
        self.assertEqual(feed.inner_text().count("Port closure"), 1)
        expect(feed.locator(".post a")).to_have_attribute("href", "https://example.test/source")
        self.history.append({**card(1, "UNFILTERED"), "posted_at":"2026-11-18T13:00:00Z"})
        self.events.append({**self.events[0], "id":2, "status":"stale", "title":"Old report",
                            "origin_posted_at":"2026-11-18T14:00:00Z"})
        self.events[0]["summary"] = "Traffic has stopped."
        self.page.reload()
        expect(feed).to_contain_text("Traffic has stopped.")
        headings = feed.locator("h3").all_text_contents()
        self.assertIn("Bulletin 1", headings[0], headings)
        self.assertIn("Port closure", headings[1])
        self.assertIn("Old report", headings[2])

    def test_reconnect_reads_every_page_through_racing_live_alert(self):
        self.open()
        self.history.extend(card(i) for i in range(1, 206))
        # A new live event arrives in the same JS turn as the read for the
        # persisted backlog. The history endpoint limits each response to 200.
        self.history.append(card(206))
        self.page.evaluate("n => { testStream.onopen(); testStream.publish(n); }", self.history[-1])
        expect(self.page.locator("#morepill")).to_have_text("+201 more")
        self.page.locator("#morepill").click()
        alerts = self.page.locator("#tray .oneline")
        expect(alerts).to_have_count(206)
        self.assertEqual(alerts.all_text_contents(), [f"Bulletin {i}" for i in range(206, 0, -1)])
        self.assertIn(200, self.cursor_requests)
        self.assertEqual(self.page_errors, [])


if __name__ == "__main__":
    unittest.main()


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
    "refetch_running": False, "threshold": 70, "max_stacked": 5,
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
        self.fail = set()
        self.events = []
        self.suppressed = []
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
        if url.path in self.fail:
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
            return route.fulfill(json=STATUS)
        if url.path == "/me":
            return route.fulfill(json={"username": "reader", "email": "reader@example.test", "user_id": 1})
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


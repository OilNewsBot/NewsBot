"""Browser regressions for the trading audit. Run after jac build web.

Requires Playwright for Python and its Chromium browser. Every HTTP request is
handled locally, including the deterministic session, quote and portfolio data.
"""

import json
import unittest
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import expect, sync_playwright


ROOT = Path(__file__).resolve().parents[2]
ORIGIN = "http://trading.test"


class TradingAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.html = (ROOT / ".jac/client/web/dist/index.html").read_text()
        cls.demo = json.loads((ROOT / "db/demo_seed.json").read_text())["trade_suggestions"][0]
        cls.pw = sync_playwright().start()
        cls.browser = cls.pw.chromium.launch()

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.pw.stop()

    def setUp(self):
        self.context = self.browser.new_context(timezone_id="America/New_York")
        self.addCleanup(self.context.close)
        self.page = self.context.new_page()
        self.portfolio = {"portfolio_value": 60000, "available_cash": 30000,
                          "aggressiveness": "medium", "max_hold_minutes": 45}
        self.enabled = True
        self.suggestions = [dict(self.demo, id=1, event_title=None)]
        self.context.route("**/*", self.respond)

    def respond(self, route):
        path = urlsplit(route.request.url).path
        if path == "/trading":
            route.fulfill(content_type="text/html", body=self.html)
        elif path == "/me":
            route.fulfill(json={"id": 1, "username": "tester"})
        elif path == "/portfolio":
            if route.request.method == "PUT":
                self.portfolio = route.request.post_data_json
            route.fulfill(json={"portfolio": self.portfolio, "enabled": self.enabled,
                                "aggressiveness": ["low", "medium", "high"], "contracts": {}})
        elif path == "/suggestions":
            route.fulfill(json={"suggestions": self.suggestions})
        elif path == "/prices":
            route.fulfill(json={"bars": []})
        else:
            route.abort()

    def open_page(self):
        self.page.goto(ORIGIN + "/trading")
        expect(self.page.get_by_role("heading", name="Trading Insights")).to_be_visible()

    def test_shared_portfolio_and_demo_disclosures(self):
        self.suggestions.append(dict(self.demo, id=2, model="test-model", event_title="New story"))
        self.open_page()
        demo, live = self.page.locator(".sugg").all()
        expect(demo).to_contain_text("Manual demo")
        expect(demo).to_contain_text("$169,524")
        expect(live).not_to_contain_text("Manual demo")
        notice = self.page.locator("#portfolio-sharing")
        expect(notice).to_contain_text("Everyone using this Newsstream server can view and change")
        expect(notice).to_be_visible()
        self.assertTrue(notice.evaluate("""el => Boolean(el.compareDocumentPosition(
            document.querySelector('.portfolio input')) & Node.DOCUMENT_POSITION_FOLLOWING)"""))


if __name__ == "__main__":
    unittest.main()

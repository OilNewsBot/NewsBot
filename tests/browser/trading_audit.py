"""Browser regressions for the trading audit. Run after jac build web.

Requires Playwright for Python and its Chromium browser. Every HTTP request is
handled locally, including the deterministic session, quote and portfolio data.
"""

import json
import unittest
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

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
        self.errors = set()
        self.price_mode = "series"
        self.requested_days = []
        self.context.route("**/*", self.respond)

    def respond(self, route):
        target = urlsplit(route.request.url)
        path = target.path
        if path in self.errors:
            route.fulfill(status=502 if path == "/prices" else 503, json={"detail": "Temporary outage"})
        elif path == "/trading":
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
            day = parse_qs(target.query)["start"][0]
            self.requested_days.append(day)
            epoch = int(datetime.fromisoformat(day.replace("Z", "+00:00")).timestamp())
            bars = [{"t": epoch, "c": 70.55}]
            if self.price_mode == "series":
                bars.append({"t": epoch + 86399, "c": 70.60})
            route.fulfill(json={"bars": bars})
        else:
            route.abort()

    def open_page(self):
        self.page.goto(ORIGIN + "/trading")
        expect(self.page.get_by_role("heading", name="Trading Insights")).to_be_visible()

    def test_shared_portfolio_and_demo_disclosures(self):
        self.suggestions.append(dict(self.demo, id=2, model="test-model", event_title="New story"))
        self.open_page()
        expect(self.page.locator(".sugg")).to_have_count(2)
        demo, live = self.page.locator(".sugg").all()
        expect(demo).to_contain_text("Manual demo")
        expect(demo).to_contain_text("$169,524")
        expect(live).not_to_contain_text("Manual demo")
        notice = self.page.locator("#portfolio-sharing")
        expect(notice).to_contain_text("Everyone using this Newsstream server can view and change")
        expect(notice).to_be_visible()
        self.assertTrue(notice.evaluate("""el => Boolean(el.compareDocumentPosition(
            document.querySelector('.portfolio input')) & Node.DOCUMENT_POSITION_FOLLOWING)"""))

    def test_slow_load_horizon_and_unsaved_edits(self):
        # Hold the initial read until the user can see the form.
        self.page.add_init_script("""if (!sessionStorage.getItem('delay-tested')) {
            sessionStorage.setItem('delay-tested', '1');
            const original = window.fetch;
            const ready = new Promise(resolve => { window.releaseRead = resolve; });
            window.fetch = async (...args) => {
                if (args[0] === '/portfolio') await ready;
                return original(...args);
            };
        }""")
        self.open_page()
        value = self.page.get_by_label("Portfolio size")
        expect(value).to_be_disabled()
        expect(self.page.get_by_role("button", name="Save")).to_be_disabled()
        self.page.evaluate("window.releaseRead()")
        expect(value).to_be_enabled()
        horizon = self.page.get_by_label("Time horizon")
        expect(horizon).to_have_value("45")
        self.page.get_by_role("button", name="Save").click()
        expect(self.page.get_by_text("Saved.", exact=True)).to_be_visible()
        self.assertEqual(self.portfolio["max_hold_minutes"], 45)
        value.fill("60001")
        expect(self.page.get_by_text("Saved.", exact=True)).to_have_count(0)
        self.page.reload()
        expect(value).to_have_value("60000")

    def test_portfolio_and_suggestions_outages_and_disabled_trading(self):
        self.errors.update({"/suggestions", "/portfolio"})
        self.open_page()
        retry_suggestions = self.page.get_by_role("button", name="Retry suggestions")
        retry_portfolio = self.page.get_by_role("button", name="Retry portfolio")
        expect(retry_suggestions).to_be_visible()
        expect(retry_portfolio).to_be_visible()
        expect(self.page.get_by_text("No suggestions today.")).to_have_count(0)
        expect(self.page.get_by_text("None yet.")).to_have_count(0)
        expect(self.page.get_by_text("Enter simulated balances")).to_have_count(0)
        self.errors.clear()
        retry_suggestions.click()
        retry_portfolio.click()
        expect(self.page.locator(".sugg")).to_have_count(1)
        expect(self.page.get_by_label("Portfolio size")).to_have_value("60000")
        self.enabled = False
        self.portfolio = None
        self.page.reload()
        expect(self.page.get_by_text("New trading suggestions are disabled")).to_be_visible()
        expect(self.page.get_by_text("Enter simulated balances")).to_have_count(0)

    def test_calendar_rollover_and_keyboard_overnight_trade(self):
        self.page.clock.install(time=datetime.fromisoformat("2026-11-17T23:59:30-05:00"))
        self.suggestions = [dict(self.demo, id=39, created_at="2026-11-15T23:45:00-05:00",
                                 closeout_at="2026-11-16T00:15:00-05:00", hold_minutes=30)]
        self.open_page()
        row = self.page.get_by_role("button", name="Manual demo", exact=False)
        expect(row).to_be_visible()
        self.page.get_by_role("button", name="Save").focus()
        self.page.keyboard.press("Tab")
        expect(row).to_be_focused()
        self.page.keyboard.press("Enter")
        expect(row).to_have_attribute("aria-pressed", "true")
        expect(self.page.locator(".chart .mark title")).to_have_text(
            "Open short Nov 15, 11:45 PM @ 99.72"
        )
        monday = self.page.get_by_role("button", name="Mon, Nov 16")
        monday.click()
        expect(row).to_have_attribute("aria-pressed", "true")
        expect(self.page.locator(".chart .mark title")).to_contain_text("Close short")
        self.assertEqual(self.requested_days[-1], "2026-11-16T05:00:00.000Z")
        self.page.clock.fast_forward(70000)
        expect(monday).to_have_class("on")
        self.assertEqual(self.requested_days[-1], "2026-11-16T05:00:00.000Z")

    def test_quote_boundaries_chart_errors_and_mobile_text(self):
        self.price_mode = "single"
        self.open_page()
        expect(self.page.locator(".market-price strong")).to_have_text("70.55")
        expect(self.page.locator("svg.chart circle")).to_have_count(1)
        expect(self.page.locator(".chart-empty")).to_have_count(0)
        self.errors.add("/prices")
        self.page.locator(".days button").nth(1).click()
        retry = self.page.get_by_role("button", name="Retry prices")
        expect(retry).to_be_visible()
        expect(self.page.locator(".chart-empty")).to_contain_text("could not be loaded")
        self.price_mode = "series"
        self.errors.clear()
        retry.click()
        expect(self.page.locator("svg.chart polyline")).to_have_count(1)
        for width in (320, 390):
            self.page.set_viewport_size({"width": width, "height": 800})
            self.page.wait_for_function("""() => {
                const tick = document.querySelector('.chart text.axis');
                return tick && parseFloat(getComputedStyle(tick).fontSize) * tick.getScreenCTM().a >= 10;
            }""")
            self.assertEqual(self.page.evaluate("document.documentElement.scrollWidth"), width)


if __name__ == "__main__":
    unittest.main()

"""Account and My Sources regressions against the actual app and a disposable DB.

Run after jac build web with Jac on PATH and Playwright Chromium installed.
The transient feed error and OS notification permission use local test doubles.
"""

import os
import re
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

ROOT = Path(__file__).resolve().parents[2]
PASSWORD = "temporary-local-test-only"


class AccountAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temp.cleanup)
        cls.db = Path(temp.name) / "accounts.db"
        log_path = Path(temp.name) / "server.log"
        env = os.environ.copy()
        for key in ("ANTHROPIC_API_KEY", "TELEGRAM_API_ID", "TELEGRAM_API_HASH", "TELEGRAM_BOT_TOKEN",
                    "X_BEARER_TOKEN", "X_PUSH_API_KEY", "NEWSBOT_PUBLIC_PWA", "NEWSBOT_MOBILE_PUSH",
                    "NEWSBOT_VAPID_PRIVATE_KEY", "NEWSBOT_VAPID_SUBJECT", "EXPO_ACCESS_TOKEN"):
            env[key] = ""
        env["NEWSBOT_BROWSER_TEST_DB"] = str(cls.db)
        with log_path.open("w") as log:
            server = subprocess.Popen(["jac", "run", "tests/browser/accounts_server.jac"], cwd=ROOT,
                                      env=env, stdout=log, stderr=log)

        def stop():
            server.terminate()
            try:
                server.wait(timeout=15)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()

        cls.addClassCleanup(stop)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            output = log_path.read_text()
            match = re.search(r"Uvicorn running on (http://127\.0\.0\.1:\d+)", output)
            if match:
                cls.origin = match[1]
                break
            if server.poll() is not None:
                raise RuntimeError(output[-3500:])
            time.sleep(.2)
        else:
            raise TimeoutError(log_path.read_text()[-3500:])
        pw = sync_playwright().start()
        cls.addClassCleanup(pw.stop)
        cls.browser = pw.chromium.launch()
        cls.addClassCleanup(cls.browser.close)

    def setUp(self):
        self.context = self.browser.new_context(service_workers="block")
        self.addCleanup(self.context.close)
        self.page = self.context.new_page()
        self.name = self._testMethodName
        self.email = self.name + "@example.test"
        registered = self.context.request.post(self.origin + "/register",
            data={"username": self.name, "email": self.email, "password": PASSWORD})
        self.assertTrue(registered.ok, registered.text())
        self.uid = registered.json()["user_id"]

    def sign_in(self):
        login = self.context.request.post(self.origin + "/login", data={"email": self.email, "password": PASSWORD})
        self.assertTrue(login.ok, login.text())
        self.page.goto(self.origin + "/sources")
        expect(self.page.locator(".account-username")).to_contain_text(self.name)

    def test_registration_and_account_switch(self):
        self.page.goto(self.origin + "/sources")
        self.page.get_by_role("button", name="Need an account? Register").click()
        self.page.get_by_label("Username").fill(self.name)
        self.page.get_by_label("Email").fill("alternative@example.test")
        self.page.get_by_label("Password").fill(PASSWORD)
        self.page.get_by_role("button", name="Register", exact=True).click()
        expect(self.page.get_by_role("paragraph").filter(has_text="This username is already taken")).to_be_visible()
        self.sign_in()
        second = self.context.new_page()
        second.goto(self.origin + "/sources")
        second.get_by_role("button", name="Log out").click()
        expect(self.page.get_by_role("button", name="Log in", exact=True)).to_be_visible()
        registered = self.context.request.post(self.origin + "/register", data={
            "username": "Second account", "email": "second@example.test", "password": PASSWORD})
        self.assertTrue(registered.ok)
        second.get_by_label("Email").fill("second@example.test")
        second.get_by_label("Password").fill(PASSWORD)
        second.get_by_role("button", name="Log in", exact=True).click()
        expect(second.locator(".account-username")).to_contain_text("Second account")
        expect(self.page.locator(".account-username")).to_contain_text("Second account")

    def test_older_personal_alert_link(self):
        with sqlite3.connect(self.db) as db:
            connection = db.execute("""INSERT INTO personal_connections (user_id,provider,label,created_at)
                VALUES (?,'rss','Archive',CURRENT_TIMESTAMP)""", (self.uid,)).lastrowid
            source = db.execute("""INSERT INTO personal_sources
                (user_id,connection_id,remote_id,name,url,next_poll_at,created_at)
                VALUES (?,?,'archive','News archive','https://example.invalid/feed',
                '2099-01-01T00:00:00+00:00',CURRENT_TIMESTAMP)""", (self.uid, connection)).lastrowid
            db.executemany("""INSERT INTO personal_items
                (user_id,source_id,external_id,title,text,url,posted_at,received_at)
                VALUES (?,?,?,?,?, 'https://example.invalid/story', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)""",
                [(self.uid, source, str(i), f"Archive item {i}", "News article") for i in range(101)])
            oldest = db.execute("SELECT MIN(id) FROM personal_items WHERE source_id=?", (source,)).fetchone()[0]
        self.sign_in()
        self.page.goto(f"{self.origin}/sources#personal-item-{oldest}")
        expect(self.page.locator(f"#personal-item-{oldest}")).to_contain_text("Archive item 0")
        expect(self.page.locator(".ps-feed-item")).to_have_count(101)
        self.page.goto(f"{self.origin}/sources#personal-item-900000")
        expect(self.page.get_by_text("This article is no longer available in your sources.")).to_be_visible()

    def test_installed_app_retries_original_route(self):
        context = self.browser.new_context()
        self.addCleanup(context.close)
        page = context.new_page()
        page.goto(self.origin + "/trading")
        page.wait_for_function("!!navigator.serviceWorker.controller", timeout=15000)
        context.set_offline(True)
        page.reload()
        retry = page.get_by_role("link", name="Try again")
        expect(retry).to_be_visible()
        context.set_offline(False)
        retry.click()
        expect(page).to_have_url(self.origin + "/trading")
        expect(retry).to_have_count(0)

    def test_independent_filters_across_tabs(self):
        with sqlite3.connect(self.db) as db:
            cid = db.execute("""INSERT INTO personal_connections (user_id,provider,label,created_at)
                VALUES (?,'rss','Test RSS',CURRENT_TIMESTAMP)""", (self.uid,)).lastrowid
            sid = db.execute("""INSERT INTO personal_sources
                (user_id,connection_id,remote_id,name,url,include_keywords,next_poll_at,created_at)
                VALUES (?,?,'offline','Bulletins','https://example.invalid/feed','["original"]',
                '2099-01-01T00:00:00+00:00',CURRENT_TIMESTAMP)""", (self.uid,cid)).lastrowid
        self.sign_in()
        first = self.page
        second = self.context.new_page()
        second.goto(self.origin + "/sources")
        for page in [first, second]:
            page.get_by_text("Alert keyword filters").click()
        second.get_by_label("Include any of these keywords").fill("updated")
        second.get_by_role("button", name="Save filters").click()
        expect(second.get_by_text("Source preferences saved.")).to_be_visible()
        first.get_by_role("button", name="Refresh", exact=True).click()
        expect(first.get_by_label("Include any of these keywords")).to_have_value("updated")
        first.get_by_label("Exclude these keywords").fill("unrelated")
        with first.expect_request(lambda req: req.method == "PATCH") as sent:
            first.get_by_role("button", name="Save filters").click()
        self.assertEqual(sent.value.post_data_json, {"exclude_keywords": ["unrelated"]})
        expect(first.get_by_text("Source preferences saved.")).to_be_visible()
        with sqlite3.connect(self.db) as db:
            self.assertEqual(db.execute("SELECT include_keywords,exclude_keywords FROM personal_sources WHERE id=?",
                                        (sid,)).fetchone(), ('["updated"]', '["unrelated"]'))

    def test_refresh_error_recovery_and_screen_preference(self):
        # Headless Chromium has no OS permission UI. Model a browser in which
        # the user has already granted this site's notification permission.
        self.context.add_init_script("""Object.defineProperty(window, 'Notification', {
            configurable: true,
            value: class {
                static get permission() { return localStorage.getItem('qa-permission') || 'granted'; }
                static async requestPermission() { return this.permission; }
            }
        })""")
        self.sign_in()
        toggle = self.page.get_by_role("checkbox", name="Screen notifications")
        toggle.check()
        self.page.wait_for_function("key => localStorage.getItem(key) === '1'",
                                    arg=f"ns_personal_screen_{self.uid}", timeout=5000)
        self.page.reload()
        expect(toggle).to_be_checked()
        self.page.route("**/api/me/feed*", lambda route: route.abort())
        refresh = self.page.get_by_role("button", name="Refresh", exact=True)
        refresh.click()
        error = self.page.get_by_text("Cannot reach Newsstream. Try again shortly.")
        expect(error).to_be_visible()
        self.page.unroute("**/api/me/feed*")
        refresh.click()
        expect(error).to_have_count(0)
        toggle.uncheck()
        self.page.reload()
        expect(toggle).not_to_be_checked()
        toggle.check()
        self.page.evaluate("localStorage.setItem('qa-permission', 'denied')")
        self.page.reload()
        expect(toggle).not_to_be_checked()


if __name__ == "__main__":
    unittest.main()

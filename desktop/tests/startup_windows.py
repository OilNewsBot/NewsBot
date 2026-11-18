"""Run on Windows with Playwright and NEWSBOT_TEST_BINARY set to a release executable."""
import contextlib
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

from playwright.sync_api import expect, sync_playwright


def free_ipv4_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextlib.contextmanager
def fixture(host="127.0.0.1", port=0, news=True):
    class Server(ThreadingHTTPServer):
        address_family = socket.AF_INET6 if ":" in host else socket.AF_INET

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if news and self.path == "/openapi.json":
                payload = json.dumps({"info":{"title":"NewsDrop"},
                                      "paths":{"/feed":{"get":{}}, "/notifications":{"get":{}}}}).encode()
                content_type = "application/json"
            else:
                heading = "NewsDrop test feed" if news else "Unrelated test calendar"
                payload = f"<h1>{heading}</h1>".encode()
                content_type = "text/html"
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    with Server((host, port), Handler) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            yield server.server_port
        finally:
            server.shutdown()
            worker.join()


@unittest.skipUnless(os.name == "nt", "requires the Windows desktop release and WebView2")
class DesktopStartup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Path(os.environ["NEWSBOT_TEST_BINARY"]).resolve(strict=True)
        cls.playwright = sync_playwright().start()

    @classmethod
    def tearDownClass(cls):
        cls.playwright.stop()

    @contextlib.contextmanager
    def app(self, host, port, remote=""):
        debug = free_ipv4_port()
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as temp:
            root = Path(temp)
            (root/"config.yaml").write_text(f"server:\n  host: {host}\n  port: {port}\n")
            proc = subprocess.Popen([self.binary], creationflags=subprocess.CREATE_NO_WINDOW,
                env={**os.environ, "NEWSBOT_ROOT":temp, "NEWSBOT_URL":remote,
                     "WEBVIEW2_USER_DATA_FOLDER":str(root/"profile"),
                     "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS":f"--remote-debugging-port={debug}"})
            try:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    self.assertIsNone(proc.poll(), "desktop exited before WebView2 startup")
                    try:
                        with urlopen(f"http://127.0.0.1:{debug}/json/version", timeout=0.3) as r:
                            websocket = json.load(r)["webSocketDebuggerUrl"]
                        break
                    except (OSError, URLError):
                        time.sleep(0.1)
                else:
                    self.fail("WebView2 did not start")
                browser = self.playwright.chromium.connect_over_cdp(websocket)
                try:
                    ctx = browser.contexts[0]
                    yield ctx.pages[0] if ctx.pages else ctx.wait_for_event("page")
                finally:
                    browser.close()
            finally:
                if proc.poll() is None:
                    proc.terminate()
                proc.wait(timeout=10)

    def test_another_app_is_not_reused(self):
        with fixture(news=False) as port, self.app("127.0.0.1", port) as page:
            expect(page.get_by_role("heading", name="The configured port did not return NewsDrop")).to_be_visible()
            self.assertNotIn(f":{port}", page.url)

    def test_ipv6_local_service_opens(self):
        with fixture("::1") as port, self.app("::1", port) as page:
            expect(page.get_by_role("heading", name="NewsDrop test feed")).to_be_visible()
            self.assertEqual(page.url, f"http://[::1]:{port}/")

    def test_ipv4_service_opens_at_localhost(self):
        with fixture() as port, self.app("127.0.0.1", port, f"http://localhost:{port}") as page:
            expect(page.get_by_role("heading", name="NewsDrop test feed")).to_be_visible(timeout=12000)
            self.assertEqual(page.url, f"http://localhost:{port}/")

    def test_returning_remote_service_recovers(self):
        port = free_ipv4_port()
        with self.app("127.0.0.1", port, f"http://127.0.0.1:{port}") as page:
            expect(page.get_by_role("heading", name="Cannot reach the NewsDrop server")).to_be_visible(timeout=32000)
            expect(page.get_by_text("retry automatically", exact=False)).to_be_visible()
            with fixture(port=port):
                expect(page.get_by_role("heading", name="NewsDrop test feed")).to_be_visible(timeout=10000)

    def test_missing_scheme_has_actionable_error(self):
        with fixture(news=False) as port, self.app("127.0.0.1", port, f"localhost:{port}") as page:
            expect(page.get_by_role("heading", name="Invalid NewsDrop server address")).to_be_visible()
            expect(page.get_by_text("including http:// or https://.", exact=False)).to_be_visible()
            self.assertNotIn(f":{port}", page.url)


if __name__ == "__main__":
    unittest.main()

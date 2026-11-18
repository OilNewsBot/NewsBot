# News feed and alerts

The rows follow the order in the [November audit](../2026-11-18-feature-audit.html#news-feed-and-alerts). Build the web client, then run `python tests/browser/news_feed.py -v` with Playwright Chromium installed. `CHROME_BIN` optionally selects another Chromium executable. The seven browser cases serve the actual client bundle with controlled same-origin APIs and SSE. The classifier outage also ran against the local FastAPI application and a disposable SQLite database with live credentials disabled.

| Finding | Verification |
| --- | --- |
| 1. Unfiltered news vanishes after acknowledgment | Five tracker posts during a classifier outage yielded three alerts. After Escape and reload, all three remained in the feed with source links and the tray started empty. The normal Jac classifier test also asserts the persisted history and cursor. |
| 2. Reconnect skips a page | After 205 stored alerts, live ID 206 arrived as the first catch-up read began. Expanding the tray showed exactly 206 distinct headlines in descending ID order, including IDs 201–205. |
| 3. Narrow tray clips source | At 320×600 the tracker handle and the entire source link row fit inside the viewport. |
| 4. Older alerts cannot be scrolled to | With 12 two-line alerts, the overflow control scrolled into view on keyboard focus. The twelfth card was reachable by scrolling at both 320×600 and 1280×950. |
| 5. Open suppressed list stays stale | The offline server added two held posts to the open list on its next refresh. A separate browser case added five rows without toggling the checkbox. |
| 6. Sidebar covers adapter status | At 1280×950, hit-testing the center of each footer indicator returned that chip or its child for Telegram, official X, and X Push. |
| 7. Status 503 crashes the page | An HTTP 503 JSON response changed the footer to “server unreachable.” The News Feed remained mounted with zero page errors. |
| 8. Failed feed load is blank | A 503 displayed Retry feed. The next successful request dismissed the error and displayed the actual empty feed. |
| 9. Suppressed failure looks empty | A 503 displayed Retry suppressed posts and hid the empty message. Retrying after recovery displayed the genuine empty result. |
| 10. Inaccurate live indicator | The browser displayed No live feeds for disabled adapters, Live monitoring for a connected stream and live adapter, and Server unreachable without a green light after a status outage. |
| 11. Duplicate Log out | Exactly one accessible Log out button was present on the signed-in dashboard. |
| 12. Refetch hides failure reason | Without an X provider key, the control was disabled with setup guidance. With the provider configured, a 409 displayed the server’s reason and re-enabled the control. |
| 13. Overflow cannot be opened from keyboard | Tabbing from the first source link through the visible cards reached the overflow button. Enter expanded all 12 alerts. |
| 14. Repeated event headline | An event with identical title, summary, and origin text displayed the headline once and retained its original source link. A distinct summary remained visible. |
| 15. Unfiltered badge repeated | Each unfiltered card showed one warning badge even when both its kind and its stored badges identified it as unfiltered. |

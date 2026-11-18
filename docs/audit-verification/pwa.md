# Installed web app and Web Push

| Finding | Reproduction after the fix |
| --- | --- |
| Older personal alert has no visible article | Seeded 101 posts in a disposable SQLite database, signed into the running demo in Chromium, and opened the oldest article’s alert link. All 101 rows including the addressed article rendered. Changing the hash to a missing article showed a visible explanation. The API regression also checks that another account cannot retrieve the linked item. |
| Offline retry opens the wrong page | In Chromium, opened Trading, took the context offline, reloaded, restored connectivity and clicked Try again. The browser returned to /trading. The worker test checks that the retry URL resolves to the original route. |
| A rate limit permanently drops a web banner | The real worker and SQLite saw an explicit 429 for two subscribed devices. An immediate sweep sent nothing while the claims were in backoff. Once eligible, two concurrent sweeps obtained exactly one successful submission per device. Existing terminal and ambiguous outcomes retain their duplicate-suppression behavior. |

The Jac regression lives in `tests/web_push_tests.jac`. The worker navigation test runs with `node --test tests/pwa_worker_test.cjs`. Provider responses and device registrations are offline fixtures.

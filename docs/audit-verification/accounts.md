# Accounts and My Sources audit verification

The browser checks run the compiled app in Chromium with a disposable SQLite database, real session cookies and two tabs. The provider tests use local data. The browser test simulates the brief feed outage and the operating system notification permission.

| Original finding | Regression and observed result |
| --- | --- |
| [1. Duplicate username](../2026-11-18-feature-audit.html#accounts-and-my-sources-1) | Reusing a username with a different email returns HTTP 409 and displays “This username is already taken” on the registration form. A second SQLite connection can write immediately, and registering a new name succeeds. |
| [2. Description-only RSS bulletins](../2026-11-18-feature-audit.html#accounts-and-my-sources-2) | “First bulletin” and “Second bulletin” produce two persistent items and two alerts. Replaying the batch, including a database row with the old identity, keeps both counts at two. |
| [3. Atom article host](../2026-11-18-feature-audit.html#accounts-and-my-sources-3) | An Atom document loaded from `feeds.example.net` with an absolute feed base plus relative entry and link bases resolves `dispatch.html` to `https://news.example.org/articles/daily/reports/dispatch.html`. |
| [4. Keywords in full text](../2026-11-18-feature-audit.html#accounts-and-my-sources-4) | The fixture places “Read more” before its full text. With `refinery` as the include keyword, ingestion delivers an alert containing “Refinery closed due to flooding.” |
| [5. Cross-tab account identity](../2026-11-18-feature-audit.html#accounts-and-my-sources-5) | After tab two logs out, tab one displays the login form. After tab two signs in to a different account, both badges show the new username. |
| [6. Concurrent source filter edits](../2026-11-18-feature-audit.html#accounts-and-my-sources-6) | Tab two changes `original` to `updated`. After a refresh, tab one displays `updated`. Its save sends only `exclude_keywords`, and SQLite retains both edits. |
| [7. X locator request allowance](../2026-11-18-feature-audit.html#accounts-and-my-sources-7) | An invalid locator returns HTTP 422 with zero requests spent. `https://x.com/Example?s=21` resolves to `Example` using one fixture request. A further valid lookup receives the configured HTTP 429. |
| [8. Retry after a feed outage](../2026-11-18-feature-audit.html#accounts-and-my-sources-8) | Aborting the feed request displays “Cannot reach Newsstream.” Restoring the real server route and clicking Refresh clears the message. |
| [9. Screen notifications on reload](../2026-11-18-feature-audit.html#accounts-and-my-sources-9) | With permission granted, the setting survives reload in both the enabled and disabled states. Revoking permission leaves the checkbox off on the next load. |

`python3 scripts/check.py` includes the [registration and RSS regressions](../../tests/account_audit_tests.jac), the [personal API budget test](../../tests/personal_api_tests.jac) and the production web build. Run `python3 tests/browser/accounts_audit.py -v` after that build with Jac on `PATH` and Playwright Chromium installed to replay the browser scenarios.

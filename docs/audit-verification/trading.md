# Trading verification

The five Chromium tests in `tests/browser/trading_audit.py` exercise the built web app. They supply deterministic HTTP responses for the session, portfolio and price service, including the shipped suggestion from `db/demo_seed.json`. Run `jac build web`, then `python tests/browser/trading_audit.py -v` with Playwright and its Chromium browser installed.

| Audit entry | Verified result |
| --- | --- |
| trading-1 | The $169,524 seeded short displays “Manual demo.” A model-generated fixture in the same list has no demo label. |
| trading-2 | The visible shared-portfolio disclosure precedes the first balance input and identifies who can view and change the figures. The one shared portfolio is intentional. |
| trading-3 | A 45-minute horizon displays as 45, and Save submits 45. The field supports whole minutes from 1 through 120. |
| trading-4 | While the initial read is pending, the balance fields and Save are disabled. Editing becomes available after the existing figures arrive. |
| trading-5 | A historical November 16 chart remains selected with November 16 prices after local midnight in New York. |
| trading-6 | For a 23:45–00:15 suggestion, the entry day shows the open marker. Changing to the close day retains selection and shows the close marker. |
| trading-7 | Tabbing from Save reaches the suggestion button. Enter selects the overlay and sets the button's pressed state. |
| trading-8 | HTTP 503 for suggestions and portfolio produces independent errors and retry controls. Retrying restores the stored balance and suggestion. The empty-data messages stay hidden during the outage. |
| trading-9 | With trading disabled and an empty portfolio, the page reports that the server has disabled new suggestions. The invitation to start receiving suggestions is absent. |
| trading-10 | A suggestion sized at $99.72 displays $99.72 on its entry marker, even with conflicting historical bars around $70. |
| trading-11 | Editing a saved balance hides “Saved.” Reloading restores the last submitted amount. |
| trading-12 | A one-quote session shows the quote ($70.55) and a chart point. |
| trading-13 | HTTP 502 on a historical day shows a price-loading error. Retry restores the chart when prices return. |
| trading-14 | At widths of 320 and 390 CSS pixels, SVG tick text renders at least 10 CSS pixels high with no horizontal page overflow. |

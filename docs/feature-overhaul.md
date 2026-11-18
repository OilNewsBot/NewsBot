# Newsstream forum roadmap

Work in small parts on `feature-overhaul`. Part 1 passed review checks. Part 2 is deferred. Part 3 uses a saved RSS snapshot so browsing works independently of publisher availability. Confirm the next part before starting it.

| Part | Deliverable | Acceptance check |
| --- | --- | --- |
| 1 | Repair the feed footer and duplicate navigation. | News Feed, Trading Insights and My Sources each show one navigation. At desktop, narrow-window and phone widths, a reader can scroll to the last feed item, expand its updates, use its links and open System status below it. |
| 2 | Add a retractable sidebar. | On desktop, collapsing the sidebar expands the content area and the choice persists. On a phone, the drawer closes after navigation and returns focus to its toggle when dismissed. |
| 3 | Make Home a public directory for Energy, Tech, Healthcare and Industrials. | A signed-out visitor can browse two editorial picks per category, expand the latest three headlines and share a channel link. Crude Oil Monitor is accessible under Energy. |
| 4 | Publish and subscribe to channels. | From My Sources, a user can preview one RSS feed and publish it with a title, description, category and curator byline. A second account finds it in Discover, subscribes and sees its news in Following after signing in again. Private sources require an explicit publish action. |
| 5 | Add forum threads and channel recommendations. | Each headline links to the original publisher and has a thread for replies. Each account can recommend a channel once. Category rankings show real vote counts. Discover lists new channels in publication order. |
| 6 | Show 14-day paper performance for channels with timestamped trade signals. | Readers can trace each simulated result to its published signal and see the entry, exit, sizing, cost assumptions and trade count. Open trades, missing prices, insufficient history and historical replays are identified separately. |
| 7 | Prepare the shared 48-hour demo. | Two devices on one hosted service can publish, discover, subscribe and reply. Seeded RSS channels retain their latest headlines across restarts and upstream outages. The core experience works without X, Telegram or LLM credentials. |

## Directory assets

The publisher feed URLs, article links, publication times and snapshot timestamp are in `db/directory_seed.json`. Refresh that snapshot before the hosted demo. The sector photographs are illustrative and are stored locally.

| Category | Photograph |
| --- | --- |
| Energy | [NASA Kennedy Space Center, Solar Farm at KSC](https://images.nasa.gov/details/KSC-20210405-PH-NAS01_0001) |
| Tech | [NASA/JPL-Caltech, InSight’s Second Microchip](https://images.nasa.gov/details/PIA22206) |
| Healthcare | [NASA Johnson Space Center, Moon Microscope](https://images.nasa.gov/details/jsc2022e083574) |
| Industrials | [NASA/Charles Beason, friction stir welding](https://images.nasa.gov/details/MSFC-1701231) |

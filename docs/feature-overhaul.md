# Newsstream forum roadmap

Work in small parts on `feature-overhaul`. Part 1 passed review checks. Part 2 is deferred. Part 3 uses a saved RSS snapshot so browsing works independently of publisher availability. Confirm the next part before starting it.

| Part | Deliverable | Acceptance check |
| --- | --- | --- |
| 1 | Repair the feed footer and duplicate navigation. | News Feed, Trading Insights and My Sources each show one navigation. At desktop, narrow-window and phone widths, a reader can scroll to the last feed item, expand its updates, use its links and open System status below it. |
| 2 | Add a retractable sidebar. | On desktop, collapsing the sidebar expands the content area and the choice persists. On a phone, the drawer closes after navigation and returns focus to its toggle when dismissed. |
| 3 | Make Home a public directory for Energy, Tech, Healthcare and Industrials. | A signed-out visitor can browse two editorial picks per category, expand the latest three headlines and share a channel link. Home lists one category per row at every width. Old oil and trading bookmarks open Home. |
| 4 | Publish and subscribe to channels. | From My Sources, a user can preview one RSS feed and publish it with a title, description, category and curator byline. A second account finds it in Discover, subscribes and sees its news in Following after signing in again. Private sources require an explicit publish action. |
| 5 | Add forum threads and channel recommendations. | Each headline links to the original publisher and has a thread for replies. Each account can recommend a channel once. Category rankings show real vote counts. Discover lists new channels in publication order. |
| 6 | Prepare the shared 48-hour demo. | Two devices on one hosted service can publish, discover, subscribe and reply. Seeded RSS channels retain their latest headlines across restarts and upstream outages. The core experience works without X, Telegram or LLM credentials. |

## Run the public directory for demo days

In the bootstrapped Ubuntu checkout, start the demo with `NEWSSTREAM_DEMO_RSS=1 jac run` and open `http://127.0.0.1:8000/`. Click a channel name or description to expand its latest stories. Each story includes a summary, publication date and link to the publisher.

The service opens immediately with a saved edition and checks public RSS feeds on startup and hourly. Each channel shows the date of its last successful snapshot. If a publisher is unavailable, its stories and snapshot date stay available. The service stores successful refreshes in `directory-rss.json` beside its configured database and reuses that file after a restart.

Visitors and operators can run this mode without X, Telegram, LLM or SSH keys. SSH is an operator option for managing a remote server. The default service address is local to the demo machine. Sharing a public URL across devices requires a hosted instance.

### Multi-topic publishers

The New York Times Top Stories is a public RSS publisher. Each article is classified from its headline and summary. A publisher can appear in several forums, with up to three matching stories in each. Its shared channel URL opens the full recent edition. Stories with no clear sector fit go to General News.

The key-free demo runs a small local text classifier fitted to the labeled examples in `db/forum_training.json`. If the server has an Anthropic API key, a feed refresh also sends new articles to the configured `TRIAGE_MODEL` in one batch per publisher. Valid model assignments are saved with the edition and reused. An unavailable model or an invalid label leaves the local assignment in place.

To include another public multi-topic RSS feed, add it to the `publishers` array in `db/directory_seed.json` with a unique slug, publisher name, description, feed URL and a dated starter edition. The hourly refresh handles it automatically.

## Directory assets

The bundled edition in `db/directory_seed.json` includes publisher URLs, dates and editorial summaries. New stories use short excerpts from the publisher feed. The sector photographs are illustrative and are stored locally.

| Category | Photograph |
| --- | --- |
| Energy | [NASA Kennedy Space Center, Solar Farm at KSC](https://images.nasa.gov/details/KSC-20210405-PH-NAS01_0001) |
| Tech | [NASA/JPL-Caltech, InSight’s Second Microchip](https://images.nasa.gov/details/PIA22206) |
| Healthcare | [NASA Johnson Space Center, Moon Microscope](https://images.nasa.gov/details/jsc2022e083574) |
| Industrials | [NASA/Charles Beason, friction stir welding](https://images.nasa.gov/details/MSFC-1701231) |

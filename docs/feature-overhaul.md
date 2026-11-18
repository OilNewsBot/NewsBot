# Newsstream feature overhaul

Newsstream supports news-based trading across Energy, Tech, Healthcare and Industrials. Home opens the public directory. Readers can already expand publisher stories, open a shareable channel page and sign in to My Sources. The branch includes an earlier footer and duplicate-navigation repair. Work proceeds one approved part at a time on `feature-overhaul`.

## Implementation sequence

| Part | Deliverable | Acceptance check |
| --- | --- | --- |
| 1 | Finish layout and shared navigation on Home, category pages, channel pages and My Sources. | Each view has one main navigation. Collapsing the desktop sidebar releases space and the choice survives reload. On a phone, selecting a destination closes the drawer, and dismissing it with Escape returns focus to the toggle. At 375, 720 and 1280 pixels, readers can scroll to the final item, expand a story and follow its publisher link without an overlay covering it. |
| 2 | Verify the four-sector home and its seeded channels. | Each sector opens at least two genuine publisher feeds with dates and source links. Saved editions survive upstream outages. Editorial picks are labeled, with top-rated rankings introduced once votes exist. |
| 3 | Introduce the unified public channel and item schema, and test the shared deployment. | RSS, X profile and community channels use the same channel page and feed contract. An X profile offers an official embed and direct profile link. Two devices open the same saved channel after a service restart. |
| 4 | Add publishing, Discover, subscriptions and Following. | One account publishes a channel. Another discovers and follows it, sees its updates after a fresh login, then unsubscribes. Private history and connector credentials stay owner-scoped. |
| 5 | Add RSS-first automatic summaries. | Duplicate deliveries generate one summary per revision. A material correction updates its cited summary. When budget or retries run out, readers still see the dated source text. |
| 6 | Add community posts, threads and recommendations. | Users can post a title, description and optional source, discuss an article or shared X link, and recommend a channel once per account. Counts and rankings reflect recorded votes. |
| 7 | Rehearse the shared 48-hour demo. | Two accounts on different devices can publish, discover, follow and reply. Exercise a restart, an unavailable feed and an exhausted AI budget. |
| 8 | Extend authorized X ingestion and generalized trading in separately approved increments. | Eligible structured posts use the same summary worker. A channel with actual signals can later show hypothetical performance with explicit price, timing, fees and sizing assumptions. |

Part 3 establishes shared hosting early because subscriptions and discussion need a common database across devices. The demo can proceed independently of optional X data access and paper performance.

## Data and summarization decisions

- **Channels and sources.** Use additive SQLite migrations for public channels, source identities and channel membership. Record creator, sector, slug, type, description and visibility. Collect a distinct public RSS feed once across subscribers. Publishing from My Sources requires an explicit choice of public metadata.
- **Items.** Store original title and text, publisher or user byline, original URL or thread link, source-local identity, publication and collection times, content revision and processing status. Preserve separate source references when several channels carry the same story.
- **Jobs and summaries.** Persist content and pending work together. Deduplicate by source ID and stable item identity. Cache by substantive revision, model and prompt version. Start with one small server-configured model producing attributed summaries from RSS text. Store the generation timestamp and evidence links, and label AI copy. Group related items when a new fact or correction changes the story. Bound concurrency, retries and daily spend and keep the last successful edition available.
- **Public X and community channels.** The embed is a display feature. Only authorized provider data or legitimately user-supplied content is eligible for backend summaries. A shared link alone can start a discussion. Community submissions carry an authenticated author and use the same public item and discussion model.
- **Deployment.** The demo uses one persistent backend and one collection worker, with account-specific subscriptions, comments and unique channel votes in SQLite. The Tauri app also supports local use.

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

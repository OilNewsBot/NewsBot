# NewsDrop product overview

## 1. Purpose

NewsDrop helps people who follow markets see what has changed since their last visit and trace each development to its source. A reader can start with a publisher, narrow their interest to a subject and then follow a single developing story across reports and corrections.

## 2. Reader experience

| Page | What a reader can do |
| --- | --- |
| Home | Browse sectors when signed out. When signed in, read a personal briefing and then browse the sectors below it. |
| Discover | Browse every public channel. Filter by sector, sort by name, category or clicks, and open the New channels or Trending views. Trending uses recorded clicks. |
| Following | Read updates from subscribed channels and enabled private sources, filter the feed, manage channel alerts and save topic or story watches. |
| My Sources | Manage private connections, publish public channels and review selected items before sharing. |
| Channel and story pages | Inspect source information and coverage tags, recommend or follow a channel, join a discussion, or open the dated timeline for a particular story. |

## 3. Service architecture

The browser and desktop window use the same Jac web interface. FastAPI handles sessions, reads and writes. SQLite stores accounts, public news, private source data and the shared market monitor in separate tables. One server process runs collection and publishing for everyone using that deployment. [Architecture](project.md)

## 4. Content sources

| Source | What NewsDrop can display or collect |
| --- | --- |
| RSS | The backend retrieves public feeds and stores dated headlines, publisher text and original links. Readers need no API key. |
| X | Official timeline embeds display public profiles. An authorized personal provider connection can collect structured posts for private use and selective sharing. Timelines themselves supply no post text to the collector. |
| Telegram | Public message links can be embedded. A paired account can send or forward permitted text to a dedicated bot, review the private inbox and publish a selection. |
| Community | Signed-in readers can post a title with text or a source link, comment on a channel or report and reply in a thread. |

The separate market monitor receives posts from its configured Telegram and X adapters. It identifies accounts by platform ID and retains original publication and collection times.

## 5. Directory and coverage

The initial directory has **22 RSS channels and 20 X profiles**. It covers Energy, Tech, Healthcare, Industrials, Consumer Discretionary, Materials, Utilities and Real Estate, plus General News. A channel has a primary sector and can carry additional coverage tags. A multi-topic publisher's individual reports can appear in different sectors. Readers can subscribe to The New York Times front page or choose its dedicated Technology feed. [Default channels and publishers](default-sources.md)

## 6. From report to briefing

NewsDrop saves the source report before enrichment. It associates the item with a story timeline, identifies mentions in the text and records substantive developments. The first signed-in briefing offers recent matching reports, or editorial coverage for a new reader with no sources or watches. Later briefings show matching developments received since the previous displayed briefing. Each card explains why it appeared and links to its evidence.

The shared market monitor has a separate flow. It persists incoming posts, scores materiality, clusters events and emits notifications.

## 7. Labels, watches and summaries

A source describes **who** a reader follows. A topic watch describes **what** they want to hear about. A story follow tracks **one developing event**. The vocabulary includes 49 subsector labels, 12 event types, 19 named entities and 14 places. A combined watch matches when one report carries all selected labels, up to four. For example, a reader can combine semiconductor equipment and export restrictions without subscribing to a particular publisher.

The briefing uses excerpts and changed source text. Optional model-generated article summaries are labeled and dated. RSS is the default eligible source. Server-side settings select the provider, model, eligible sources and daily budget. Story timelines and source links work with summaries disabled.

## 8. Duplicate reports and corrections

Redelivery of the same item keeps its identity. Source URLs, headline similarity and matching named details can group related public reporting. New evidence or a material correction can add a development to the same timeline. Reports with ambiguous connections can remain separate. Readers can inspect publication and observation times and open the underlying reporting. A private story's history belongs to its source owner.

## 9. Configuration

Public news, personal collectors, the optional summary provider and the market monitor have separate settings. The server reads its configuration and credentials locally. A shared deployment uses a persistent database and a stable encryption key for personal X credentials. [Run and configure NewsDrop](getting-started.md)

## 10. Notifications

Following a public channel adds its reports to Following. Channel alerts are a separate opt-in. A reader can mute a channel and keep reading it. Private sources have independent collection, notification and keyword controls. Sector preferences apply across eligible updates and alerts. Topic and story watches surface matching coverage on Home. [Personal sources and notifications](personal-sources.md)

## 11. Verification and replay

The offline checks cover account isolation, publishing, watch persistence, story revisions, briefing checkpoints, provider failure and the web build. A separate replay tool sends example sequences through the market-event pipeline. [Replay data and usage](../tests/fixtures/README.md)

## 12. Hosting and operation

Devices using the same service URL share the catalog and sign in with individual accounts. The desktop wrapper can start or reuse a local backend. A shared demo uses one worker, persistent SQLite storage and HTTPS. The Expo app delivers shared market-event alerts to registered devices. [Desktop guide](../desktop/README.md) · [Mobile guide](../mobile/README.md)

## 13. Accounts and privacy

Anonymous visitors can read public channels and stories. Account sessions control publishing, follows, recommendations, comments and private connections. A private source is visible to its owner. Sharing eligible private material creates a public item with the chosen content.

## 14. Publishing and discussion

A creator supplies the channel name, description, source type and sector tags. Published channels become discoverable on that server and have a shareable address. Readers can recommend a channel once per account and discuss either the channel or one of its items.

## 15. Visit tracking

Home saves the visit position when the reader explicitly marks the briefing as read. Older tabs cannot move that position backward. A return visit with no matching developments shows a caught-up state with access to the previous edition. Public and private changes have separate checkpoints, so an update from an owner-only source can appear alongside a public story while retaining its access controls.

## 16. Market monitoring and trading

The market-monitor backend can record quotes, a manually entered operator portfolio and speculative suggestions for its supported instruments. The browser home is the news briefing. The portfolio endpoints use the server's admin access rules. Generalized trading theses and per-channel paper performance are future product goals. [Market service endpoints](contracts.md)

# Newsstream product specification

## 1. Purpose

Newsstream helps people follow market-moving news across Energy, Tech, Healthcare, Industrials, Consumer Discretionary, Materials, Utilities and Real Estate. A reader can find a source, inspect the original report, discuss it and follow subsequent updates. A clinical trial result, a change in manufacturing capacity and a grid investment decision each belong in the same news experience.

## 2. Public and personal views

| View | Reader action |
| --- | --- |
| Home | Browse the eight sectors, their editorial channels and recommendations. General News collects stories from multi-topic publishers that have no clear sector fit. |
| Discover | Browse the complete public catalog, sort by name, category or clicks, and switch to New or Trending. Display click totals in channel disclosures. Use observable activity for the initial lists. More elaborate trending logic is a later product decision. |
| Following | Read updates from the signed-in user's subscriptions and open the originating channel or publisher. |
| My Sources | Manage private connections, publish channels and select content to share. Connecting a source grants no public access to its history or credential. |
| Channel | Read the description and byline, see source type and reader activity, follow or recommend the channel, open source links, and discuss the channel or its stories. |

## 3. Architecture

One FastAPI service runs the Jac web client, authentication, background collection and SQLite persistence. The demo uses one server worker against persistent storage. Existing Tauri packaging starts a local service. A shared URL lets separate accounts and devices use the same database.

The public catalog connects channels to normalized items and readers' subscriptions, recommendations and comments. Private sources use separate owner-scoped tables. The market-event backend keeps its adapter contracts, classification records, notifications and trade suggestions.

## 4. Sources and authorization

- **RSS.** A public feed requires a URL. Reuse the bounded RSS, Atom and RDF collector, publisher links and dated fallback editions. Readers need no API credentials.
- **X.** Public account channels can display an official profile embed. An authorized data provider can supply structured posts for selective sharing. A shared URL or an embed supplies no backend post text by itself.
- **Telegram.** Public posts may use Telegram's post widget. A signed-in account can pair with a configured Telegram bot, send or forward an eligible message into a private inbox, and decide which text to publish. Membership, sender identity, private invite links and chat history stay outside the public catalog.
- **Community.** A signed-in user can publish a titled post with text and an optional source link. Persist its byline, channel and timestamps. Replies belong to a channel or item thread.

The separate event monitor also supports configured Telegram, X push and budgeted X polling. Adapter identities use stable platform IDs. Drop replies at that boundary, preserve quoted text and record publication and collection time.

## 5. Directory and ownership

The initial edition includes dedicated RSS and official X timeline channels in each sector, along with multi-topic publishers. A public channel has a stable shareable URL. Each subscriber and recommender contributes at most one active relation per channel. Article references keep their publisher attribution across channels.

## 6. Processing

Persist source text and metadata before model work. Use source identity and a stable item identifier to suppress redelivery. Changes to substantive content may create a new revision. Keep a readable source record when a feed or model is temporarily unavailable.

The existing event monitor persists raw posts and decisions, clusters accepted posts, records notifications and broadcasts them over SSE. Existing clients backfill by notification ID.

## 7. Classification and summaries

The public directory routes multi-topic articles to sectors. A public AI summary must cite its input, identify AI authorship, preserve uncertainty and distinguish allegations from established facts. Start automatic summaries with RSS. Source excerpts and author text remain readable without a model.

The market monitor separately scores materiality against a configurable rubric. Its review model handles near-threshold cases. Its error and fail-open paths preserve source visibility.

## 8. Duplicate and related reports

A redelivered item should neither produce another public story nor consume a new summary call. Coalesce exact source references while retaining channel attribution. Preserve corrections and update references when facts change. The market monitor additionally distinguishes new events, material updates and duplicates using recent event candidates.

## 9. Configuration

Keep secrets and model/provider selection on the server. Record attempt state, limit model concurrency and daily usage, and back off transient failures. Model IDs and prices used by the existing monitor are configured centrally. See the [demo guide](feature-overhaul.md) for the public service settings.

## 10. Interface and notifications

Navigation works on desktop and phone, supports keyboard dismissal, and leaves the last channel, post and action reachable. Readers can inspect a channel from its dropdown or share the full page. Show dates, authors and direct links with story text. The market-event and private-source clients retain their existing notification contracts.

## 11. Verification

The offline gate runs helper tests, formatting, type checks, application tests and the web build. Provider tests use fixtures or stub responses. Use isolated accounts to verify publishing, Following, recommendation counts and comments. Exercise private sharing with an unrelated account and verify that only explicitly selected content reaches public reads.

## 12. Operation

Use one worker for collection and the in-process notification bus. Keep the database and its WAL on durable local storage. Startup with a missing provider credential should leave public browsing available. Set the admin token before exposing the service beyond loopback. The operator's portfolio is shared state and requires admin access.

## 16. News-based trading

Trading commentary should identify the event, the affected instrument and the reasoning connecting them. An ordinary news channel can run without any trading signals. The existing backend supports a limited instrument set and stores a shared operator portfolio and suggestions. See [contracts](contracts.md) and `pipeline/trade.jac` for current behavior.

A future paper-performance view applies only to channels with explicit signals. Its results must identify the entry, exit, sizing, fees, slippage and missing-price assumptions. Generalized performance scoring is outside the public news demo.

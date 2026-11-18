# Newsstream channel and demo guide

## Find and follow channels

Home opens the sector directory for visitors. Signed-in readers see their briefing first and can jump to the sectors below. Discover lists public channels across sources. Choose a sort order to compare names, categories or click totals. Open a channel dropdown to see its activity and recent stories, or open the channel page for the full discussion. New and Trending use basic ordering for this demo. Following collects updates for the current account.

### Follow a topic or developing story

- Open **Following** to manage watches. Follow a single label or combine up to four, such as **Semiconductor equipment + Export restrictions** or **Electric utilities + Rate decisions + Texas**. A combined watch requires every selected label on the same report. Separate watches can match independently.
- Article labels identify the subsectors, events, organizations and places mentioned in source text. Open a story timeline for the dated evidence and original reporting. Use **Follow story** to track that particular development, including material corrections, even without following its channel.
- On the first signed-in visit, Home shows a selection of recent matching reports. An account with no sources or watches gets a starting selection from the editorial directory. Return to Home for developments received since your last displayed briefing. Each card explains why it appeared. Topic and story watches surface updates on Home. Channel alert settings continue to control notifications.
- A visible briefing saves its checkpoint per account across devices. A background tab waits until it becomes visible. A feed retry or an AI summary refresh does not create another development. Source text is available without model credentials.
- A private report has its own owner-only timeline. Public stories can combine coverage using the same source link, matching headlines, or closely related reports with a shared named entity and event or place. Ambiguous reports can appear as separate stories. Timelines distinguish publisher updates from additional sources.

### Personalize Following

1. Sign in and follow channels from Discover or a channel page. Following collects their updates alongside items from your enabled private sources. The account that added a private source is the only one who can read it.
2. Select one or more categories in Following. Selecting Tech and Utilities includes articles in either sector across your sources. Clear the selection to show all categories. Your selection is saved on the server and follows you across devices.
3. Each followed public channel starts with alerts off. Turn alerts on for the channels you want to hear from. Muting a channel keeps it in Following. Private sources have independent collection, alert and keyword settings in My Sources. The same account category selection applies to eligible public and private alerts.
4. Alerts start with newly received updates after the initial baseline. Official X timelines can be opened directly on a channel page. They provide display only, so new timeline posts do not trigger Newsstream alerts or summaries. An explicitly shared post with authorized content can appear in Following.

Channels show their coverage tags. A mixed publisher such as The New York Times can produce an Energy story marked Oil & gas and a Tech story marked Semiconductors. The article determines which Following filter matches. Stories without a clear sector stay in General News. For a narrower subscription, follow the publisher's dedicated section feed where available. [Default source directory](default-sources.md)

## Publish and discuss

Sign in and open My Sources. Choose the channel type, give it a name and description, and select its sector. A channel URL can be shared with a different browser or device. Followers see new public items. Each account can recommend a channel and participate in its discussions.

| Channel type | Public source and private controls |
| --- | --- |
| RSS | Supply a public RSS, Atom or RDF URL. Changes and source links are saved on the server. |
| Community | Publish an original title and description, with an optional source link. |
| X | A public profile can use an official timeline embed. For authorized data access, use a personal provider connection and select the post to share. |
| Telegram | A public message can be embedded from its post URL. For private material, pair your Telegram account and send or forward eligible text to the dedicated bot. Review what will be public and choose an owned destination channel. |

## Run the shared demo

Run `python3 scripts/bootstrap.py` in a Linux or macOS checkout, or `python scripts/bootstrap.py` on Windows with Ubuntu/WSL. Use one server for all devices. Put the HTTPS reverse proxy in front of that service. Keep the process and its database volume available throughout the demo.

```sh
jac run
```

The default listener is `127.0.0.1:8000`. Set `NEWSSTREAM_HOST` and `NEWSSTREAM_PORT` if the host needs a different bind address or port. Point `NEWSSTREAM_DB_PATH` at the persistent SQLite database. Use the same `NEWSBOT_CONNECTION_KEY` across restarts if using encrypted private X connections. Set a random `NEWSBOT_ADMIN_TOKEN` in the server environment before exposing the service. Forward the original HTTPS scheme and host from the trusted reverse proxy so cookie and origin checks work correctly.

### Publisher refresh and AI

The bundled edition contains dated stories from dedicated RSS feeds across all eight sectors and a multi-topic front page. Each sector also has public X profiles. Public RSS refresh runs automatically. To skip refreshing just the bundled feeds, set `NEWSSTREAM_DEMO_RSS=0`. Disable public RSS networking with `NEWSSTREAM_PUBLIC_RSS=0` for offline verification. The last successful edition remains readable through upstream outages.

To enable RSS summaries, supply the server-side `ANTHROPIC_API_KEY`. Set `NEWSSTREAM_SUMMARY_MODEL` to override the small model slot. `NEWSSTREAM_SUMMARY_DAILY_LIMIT` caps daily request reservations, including a possible JSON retry. `NEWSSTREAM_SUMMARY_PROVIDER=disabled` turns off hosted summaries. The default eligible source is RSS. Set `NEWSSTREAM_SUMMARY_SOURCES=rss,x,community` to include explicitly published provider-supplied X text and original community posts. Embed views and Telegram inbox messages do not enter the model worker. See each story's source links for the original reporting.

For a local or hosted Chat Completions-compatible model, set
`NEWSSTREAM_SUMMARY_PROVIDER=openai-compatible`, `NEWSSTREAM_SUMMARY_BASE_URL`
to the operator's API base (for example `http://127.0.0.1:11434/v1`) and
`NEWSSTREAM_SUMMARY_MODEL` to an installed model on that server. Supply
`NEWSSTREAM_SUMMARY_API_KEY` if the endpoint requires authentication. The
backend sends eligible public item text to this endpoint.

### Telegram account pairing

Create a dedicated Telegram bot for Newsstream, keep its bot token on the operator's machine, and set `NEWSSTREAM_TELEGRAM_BOT_USERNAME` and `NEWSSTREAM_TELEGRAM_WEBHOOK_SECRET` in the server environment. Use a random URL-safe secret of at least 32 characters. Register the bot's HTTPS webhook with Telegram's `setWebhook`, setting `url` to `https://YOUR_HOST/api/telegram/updates`, `secret_token` to the same secret and `allowed_updates` to `["message"]`. Use a dedicated bot so another service does not consume its updates. [Telegram Bot API](https://core.telegram.org/bots/api#setwebhook)

In My Sources, open the pairing link and start the bot in your own Telegram account. Send it the message you want to review. Use a private chat with the bot. Telegram's forwarding permissions still apply. Discover readers see the material you choose to publish. The bot does not sign into your Telegram account or import a group's history. Public embeds require a publicly viewable post. [Telegram post widget](https://core.telegram.org/widgets/post)

## Verify the demo

Use two separate browser profiles. Publish a community channel with the first, then discover, follow, recommend and comment from the second. Open the channel dropdown, inspect its click count and switch sort order. Restart the service and confirm the channel, following state and discussion persist. Use the built-in offline tests for provider failure and retry behavior. A real provider handshake requires that provider's credentials and a public Telegram webhook requires an HTTPS host.

## Directory assets

The bundled edition in `db/directory_seed.json` includes publisher URLs, dates and editorial summaries. New stories use short excerpts from the publisher feed. The sector photographs are illustrative and are stored locally.

| Category | Photograph |
| --- | --- |
| Energy | [NASA Kennedy Space Center, Solar Farm at KSC](https://images.nasa.gov/details/KSC-20210405-PH-NAS01_0001) |
| Tech | [NASA/JPL-Caltech, InSightâ€™s Second Microchip](https://images.nasa.gov/details/PIA22206) |
| Healthcare | [NASA Johnson Space Center, Moon Microscope](https://images.nasa.gov/details/jsc2022e083574) |
| Industrials | [NASA/Charles Beason, friction stir welding](https://images.nasa.gov/details/MSFC-1701231) |
| Consumer Discretionary | [NASA, Durrat Al Bahrain residential and tourism development](https://images.nasa.gov/details/iss026e020126) |
| Materials | [NASA/JPL, Morenci copper mine](https://images.nasa.gov/details/PIA10617) |
| Utilities | [NASA, Three Gorges Dam](https://images.nasa.gov/details/iss019e007720) |
| Real Estate | [NASA, Lisbon and its suburbs](https://images.nasa.gov/details/iss073e0078399) |

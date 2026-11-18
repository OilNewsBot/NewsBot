# My Sources

Sign in and open **My Sources** to connect a private feed or account, manage its alerts, or publish a channel in Discover. Your saved sources, provider credentials and Telegram inbox belong to your account. The website and desktop app use the same controls. To access the same account from multiple devices, connect to the same backend.

## Add a private source

1. Add an **RSS** or **X** connection. RSS needs a name and accepts public RSS 2.0, Atom and RDF feeds without an API key. X uses a TwitterAPI.io account key and a daily request budget.
2. Under **Private sources**, add the feed URL or X handle/profile through that connection. Select the categories it covers. **General News** suits a publisher covering many sectors. NewsDrop can assign a more specific sector and topic to an individual article.
3. Use **Categories and alert keywords** to edit the tags, include words or exclude words. Matching is case-insensitive. A match on any included word qualifies and an excluded word takes precedence. Empty keyword lists allow all otherwise eligible alerts.
4. Use **Alerts** to turn notifications on or off while collecting. **Pause** stops collection. **Remove** hides the source and its items from your views. Removing a connection also hides its sources.

New and resumed sources load recent history silently. Later posts appear as the collector retrieves them. Matching posts can generate alerts. An edit to an existing item can add a development to its private timeline without producing another new-post alert.

## Read across your sources

**My Sources** shows the collected items for your private connections. **Following** combines enabled private sources with public channels you follow. Select any combination of categories at the top of Following or use **All categories**. The selection is stored with your account and applies to the combined feed and eligible alerts across devices.

Open a **Story timeline** to inspect developments and sources. Following a story or topic adds matching developments to the signed-in home briefing. Under **Following → Followed stories and topics**, you can also combine up to four labels. All selected labels must match. A private story timeline is available only to its owner.

For **public channel alerts**, enable the individual channel switch in Following. Open **Channel alerts** in the navigation to read incoming alerts or enable screen notifications for this device. For **private source alerts**, keep My Sources open. The page shows in-app alerts and offers its own screen-notification switch for background delivery. A fresh session starts with new alerts. A temporary stream interruption replays eligible alerts after the last received ID.

## Publish and share

Use **Published channels** in My Sources to create an RSS, X, Telegram or community channel. Choose a name, description, primary category and any additional category tags. A public RSS channel uses a public feed URL. A public X account can use an official timeline embed. Public social embeds and profile links work independently of private connection keys.

For an API-backed X or Telegram channel, use **Share selected updates**. Pick an item from your connected X feed or your paired Telegram bot inbox, review the excerpt and destination, then choose **Publish selected text**. Send or forward only Telegram messages you have permission to share. Readers see the material you publish. See the [reader guide](feature-overhaul.md) and [Telegram setup](getting-started.md#private-telegram-inbox).

## Backend settings

The private collector runs inside the backend process. Use one service worker per database and keep the service running for regular updates. Successful RSS polls are normally scheduled at least five minutes apart and X polls at least a minute apart. Backoff and exhausted budgets can extend those intervals. Closing the desktop wrapper stops a collector started by that wrapper. A separately hosted backend can continue collecting.

Personal X connections require a stable 32-byte server encryption key. Generate one with

```sh
python3 -c "import base64,secrets; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())"
```

Store it in `NEWSBOT_CONNECTION_KEY` on the server, back it up separately from the database, and keep it out of client settings and Git. The service uses AES-GCM for provider credentials. Losing the key requires users to reconnect. RSS needs no encryption key.

A new X connection defaults to **200 requests per UTC day**, shared across its sources. A lookup or a paginated fetch can consume a request, and one response can contain multiple posts. Choose a cap consistent with the provider plan. The server permits limits from 1 to 2,000. Provider limits or exhausted budgets can delay X collection while other connections continue.

Private feed collection and private briefing excerpts run without an LLM. Public summarization has separate server settings and source eligibility. For installation, hosting and API routes, see the [setup guide](getting-started.md) and [API contracts](contracts.md).

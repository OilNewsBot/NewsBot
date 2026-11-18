# Read and publish with NewsDrop

You can browse public channels and read discussions without signing in. Open **My Sources** to create an account or sign in. Your subscriptions, watches and private sources are available on other devices that use the same NewsDrop server.

## Find a channel

**Home** lists the eight market sectors and a separate link to General News. Choose a sector to see channels covering it. Reader recommendations also appear on Home when channels have received votes. [Default channels and publisher links](default-sources.md)

In **Discover**, choose a category or leave **All categories** selected. **All channels** sorts by name, category or clicks. **New channels** shows the most recently published channels first. **Trending** ranks channels with at least one click by their total recorded clicks.

Expand a channel to see its publisher, coverage tags, click count, recommendations and up to three recent items. Opening the preview records a click. Continue to **Open channel** for the full discussion, or use **Copy link** to share its address. On the channel page, **Follow channel** adds it to your feed. **Recommend** adds one vote for your account and can be toggled off.

## Read the insights panel

Select **Insights** on Home, Discover, or a sector page to see the number of channels and distinct reports in the current channel previews. The source mix shows how many of those channels use RSS, X, Telegram, or community posts. The three latest dated story timelines open the underlying reporting. Changing a Discover tab or sector updates the panel.

On **Following**, Insights shows your followed channels, the updates in your current feed, channel alert settings, and saved story and topic counts. The panel opens at the side on wide screens and above the feed on smaller screens. NewsDrop remembers your choice in this browser.

## Set up your feed and alerts

1. In **Following**, select the sectors you want to read. Selecting Tech and Utilities includes articles from either sector across your followed channels and enabled private sources. Clear the selection to see all sectors. NewsDrop saves this preference on your account.
2. Expand the followed-channel controls to turn **Alerts on** or **Alerts off** for individual channels. New subscriptions start with alerts off. Muting alerts keeps the subscription and its articles in Following.
3. Open **Channel alerts** in the navigation to see new matching updates while the app is open. For system banners, enable **Screen notifications on this device** and allow notifications when prompted. A new RSS channel's first collection establishes its baseline.
4. In **My Sources**, manage private sources separately. You can pause collection, set alert preferences and choose keywords. Keywords narrow private alerts while the feed retains all collected posts. The shared sector preference also filters eligible alerts.

Channel tags cover an entire source. Article labels describe an individual report. For example, following the New York Times front page can give you reports across several sectors. A Tech filter selects its technology stories. Following the separate New York Times Technology feed subscribes you to that desk.

## Track a subject or a developing story

Open **Following → Followed stories and topics → Browse and combine topics**. Choose a single label or combine up to four. For example, combine **Electric utilities**, **Rate decisions** and **Texas** to see reports carrying all three labels. To track semiconductor equipment regardless of geography, choose **Semiconductor equipment** alone. Saving separate watches lets each match independently.

On an article, open **Story timeline** for dated reports, revisions and original source links. **Follow story** tracks that development as further reporting arrives, even if you do not follow its channel. A public timeline can group coverage of the same development from different publishers. Private-source timelines are visible only to the account that owns the source. Watch labels describe mentions in the article, including proposals and disputed claims.

## Read your Home briefing

Your first signed-in visit shows recent reports from your sources and watches. If you have none, Home draws from the public directory. Each briefing card explains why it appeared and links to the evidence. Later visits show developments received since your last displayed briefing, including new reporting and material revisions. Visible briefings save the visit on your account across devices. A background tab waits until you view it.

Following a topic or story adds matches to Home. Channel alert settings control notifications. Publisher text is available when AI is off or a summary is pending. When NewsDrop generates a summary, the article displays **AI summary**, its generation date and the available source link.

## Publish a public channel

In **My Sources**, select **Create channel** under **Published channels**. Enter a name, description and primary category. Select any additional category tags and choose the source type. Select **Publish public channel**. Other readers can now find the channel in Discover and open its shareable address.

| Source | What to enter or publish |
| --- | --- |
| RSS / Atom | Enter a publicly accessible feed URL. NewsDrop periodically collects new articles and keeps the publisher links. No reader API key is required. |
| Community | Publish the channel, then open it to create a post with a title, text and an optional source link. Signed-in readers can contribute posts and replies. |
| X | Choose **Public embed or profile** and enter a public profile URL. Readers can view the official timeline, open X directly and discuss the channel. The channel owner can also share individual post links. For selected provider-supplied posts, use the API mode below. |
| Telegram | Choose **Public embed or profile** and enter a public Telegram channel or post URL. A post URL displays the specific public message. A channel URL provides a link to Telegram. For permitted private material, use the inbox below. |

Use the channel discussion for questions about the source. Open an individual update’s **Discussion** to reply to the article or to an existing comment. A recommendation applies to the channel as a whole.

### Share a selected X or Telegram update

Create a public channel of the appropriate type and choose **Selected posts via API**. In My Sources, open **Share selected updates**, choose the individual update, review the material, select one of your compatible published channels and confirm that you may share it. Readers see the published selection. Private connections and unshared inbox items remain visible only to their owner.

- **X.** Add an authorized TwitterAPI.io connection under your private sources and follow the account you want to collect. **Connected X posts** lets you choose a collected post to publish. An embedded timeline supplies display only. New posts inside the widget do not generate feed items, alerts or AI summaries.
- **Telegram.** Under **Private Telegram inbox**, open the pairing link and start the dedicated bot in your own Telegram account. Send or forward permitted text to your private chat with the bot. Select a message and review the excerpt you want to publish. Pairing gives the bot access to messages you send it. Telegram’s forwarding restrictions apply. [Telegram post widgets](https://core.telegram.org/widgets/post)

These private provider options depend on the services configured for your NewsDrop server. [Installation and optional services](getting-started.md)

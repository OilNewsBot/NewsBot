# Default channel sources

The directory has eight market sectors and a General News section. Channel tags describe an account or feed's coverage. The first tag is its home section. Each publisher's RSS feed and X timeline can be followed separately. The New York Times front page covers several sectors and its stories receive individual section labels. Its Technology desk also has a dedicated RSS channel for readers who want that desk alone.

## Sector sources

The table links directly to the RSS editions and to the publisher websites that identify their X handles. On November 17, 2026 (U.S. Eastern time), Newsstream’s production RSS fetcher and XML parser read all 22 feeds without credentials. The nine newly added feeds returned dated articles with original links. Each new feed ships with three attributed headlines and short editorial descriptions for offline viewing. The other thirteen RSS editions retain their existing snapshots.

| Sector | Default RSS editions | Publisher X timeline and ownership reference |
| --- | --- | --- |
| Energy | [EIA Today in Energy](https://www.eia.gov/rss/todayinenergy.xml), [MIT Energy](https://news.mit.edu/rss/topic/energy), [Utility Dive](https://www.utilitydive.com/feeds/news/) | [@EIAgov](https://x.com/EIAgov) publishes agency data and forecasts. [U.S. EIA](https://www.eia.gov/about/) |
| Tech | [GitHub Changelog](https://github.blog/changelog/feed/), [Cloudflare](https://blog.cloudflare.com/rss/), [The Register](https://www.theregister.com/headlines.atom), [New York Times Technology](https://rss.nytimes.com/services/xml/rss/nyt/Technology.xml) | [@Cloudflare](https://x.com/Cloudflare) covers networking and security from the company's perspective. [Cloudflare Blog](https://blog.cloudflare.com/) |
| Healthcare | [FDA announcements](https://www.fda.gov/about-fda/contact-fda/stay-informed/rss-feeds/press-releases/rss.xml), [MIT Health Sciences](https://news.mit.edu/rss/topic/health-sciences-and-technology), [Healthcare Dive](https://www.healthcaredive.com/feeds/news/) | [@healthcaredive](https://x.com/healthcaredive) covers providers and insurers. [Healthcare Dive](https://www.healthcaredive.com/) |
| Industrials | [MIT Mechanical Engineering](https://news.mit.edu/rss/topic/mechanical-engineering), [NASA Aeronautics](https://www.nasa.gov/aeronautics/feed/), [Manufacturing Dive](https://www.manufacturingdive.com/feeds/news/) | [@ManufactureDive](https://x.com/ManufactureDive) covers factories and industrial policy. [Manufacturing Dive](https://www.manufacturingdive.com/) |
| Consumer Discretionary | [Retail Dive](https://www.retaildive.com/feeds/news/), [Restaurant Dive](https://www.restaurantdive.com/feeds/news/) | [@RetailDive](https://x.com/RetailDive) covers retailers and consumer brands. [Retail Dive](https://www.retaildive.com/) |
| Materials | [Canadian Mining Journal](https://www.canadianminingjournal.com/feed/), [ScienceDaily Materials Science](https://www.sciencedaily.com/rss/matter_energy/materials_science.xml) | [@mining](https://x.com/mining) covers mining operations and metals markets. [MINING.COM](https://www.mining.com/) |
| Utilities | [POWER Magazine](https://www.powermag.com/feed/), [Power Engineering](https://www.power-eng.com/feed/). The Utility Dive RSS channel also carries the Utilities tag. | [@UtilityDive](https://x.com/UtilityDive) covers electric utilities and regulation. [Utility Dive](https://www.utilitydive.com/) |
| Real Estate | [HousingWire](https://www.housingwire.com/feed/), [Multifamily Dive](https://www.multifamilydive.com/feeds/news/) | [@multifamilydive](https://x.com/multifamilydive) covers apartment ownership and operations. [Multifamily Dive](https://www.multifamilydive.com/) |
| General News | [The New York Times front page](https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml) | See the cross-sector accounts below. |

## Previously monitored accounts

All twelve handles in the original top-level `accounts` list are available as public X channels. Every one carries the Energy tag. Their primary sections reflect what they cover. A government notice, a commercial tracking estimate and an individual account's interpretation have different provenance. The publisher field uses the account handle when the operator's identity has not been independently established.

| Primary section | Account | Coverage |
| --- | --- | --- |
| Energy | [@TankerTrackers](https://x.com/TankerTrackers) | Independent commercial tracking of oil shipments. Also tagged Industrials for seaborne trade. [TankerTrackers publisher site](https://tankertrackers.com/) |
| Energy | [@HFI_Research](https://x.com/HFI_Research) | Investment research on oil and gas. The adviser lists this handle in its filing. [SEC Form ADV](https://reports.adviserinfo.sec.gov/reports/ADV/168526/PDF/168526.pdf) |
| Energy | [@HormuzLetter](https://x.com/HormuzLetter) | Independent commentary on Middle East oil markets and trade. |
| Energy | [@CRUDEOIL231](https://x.com/CRUDEOIL231) | Individual commodity and crude-market commentary. Also tagged Materials. |
| Industrials | [@UK_MTO](https://x.com/UK_MTO) | Official UK Maritime Trade Operations incident notices for commercial shipping, including tanker routes. [UKMTO notice identifying the account](https://www.ukmto.org/-/media/ukmto/products/20250404-ukmto_notice--update-1.pdf) |
| General News | [@financialjuice](https://x.com/financialjuice) | Cross-market financial news. [FinancialJuice](https://www.financialjuice.com/) |
| General News | [@FaytuksNetwork](https://x.com/FaytuksNetwork) | Geopolitical reporting, including developments affecting energy supply. [Faytuks Network](https://faytuksnetwork.com/) |
| General News | [@Osint613](https://x.com/Osint613) | Middle East geopolitical and conflict reporting. [OSINT613](https://www.osint613.com/about) |
| General News | [@MenchOsint](https://x.com/MenchOsint) | Independent conflict monitoring across several regions. [Creator profile](https://ko-fi.com/menchosint) |
| General News | [@MoloWarMonitor](https://x.com/MoloWarMonitor) | Independent conflict monitoring. |
| General News | [@GavMcCracken](https://x.com/GavMcCracken) | Individual macroeconomic and commodity commentary. Also tagged Materials. |
| General News | [@AB4_Ali3](https://x.com/AB4_Ali3) | Independent regional news and Middle East coverage. |

Each default X URL was checked through the official profile oEmbed endpoint. That check verifies returned timeline markup. X controls timeline display in each visitor's browser. The seed stores the profile URL and an empty headline list. No X posts enter the feed or summary queue through these embeds. [X embedded timeline documentation](https://developer.x.com/en/docs/x-for-websites/timelines/overview)

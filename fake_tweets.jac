"""Inject five fake, significant tweets through the twitterapi.io path.

    jac run fake_tweets [-- --no-wait] [--exit] [--interval 10] [--port 8000]
                        [--vendor-port 8790] [--keep-db] [--verbose]
    jac run fake_tweets -- --remote https://<server> [--no-wait] [--interval 10]

The engine (fake twitterapi.io, isolated NewsBot, --remote, reporting) is in
fake_tweets_core.jac; fake_tweets2.jac sends a second, non-overlapping set.
"""

import from fake_tweets_core { FakeTweet, main }

# Five separate oil-material events (the live classifier is crude-oil
# specific), from configured accounts across the three tiers.
glob TWEETS: list[FakeTweet] = [
         FakeTweet(
             handle="UK_MTO",
             text="UKMTO WARNING: Incident 47NM east of Fujairah. At {hhmm} UTC a laden crude tanker reported being struck by an unknown projectile on her starboard side. Fire on deck, crew reported safe, vessel proceeding to anchorage. Vessels are advised to transit with caution and report any suspicious activity to UKMTO."
         ),
         FakeTweet(
             handle="TankerTrackers",
             text="BREAKING: IRGC Navy fast boats have boarded and seized the Panama-flagged VLCC ARCTIC DAWN in the Strait of Hormuz. AIS shows the tanker turned toward Bandar Abbas at {hhmm} UTC. She was carrying roughly 2 million barrels of Saudi crude loaded at Ras Tanura."
         ),
         FakeTweet(
             handle="FaytuksNetwork",
             text="BREAKING: Israeli Air Force jets have struck Iran's Kharg Island crude export terminal, two Israeli officials say. Iranian state TV confirms explosions and large fires at the loading jetties, which handle about 90% of Iran's crude exports."
         ),
         FakeTweet(
             handle="financialjuice",
             text="WHITE HOUSE: PRESIDENT ORDERS EMERGENCY SALE OF 60 MILLION BARRELS FROM THE STRATEGIC PETROLEUM RESERVE, CITING SUPPLY DISRUPTION IN THE GULF. FIRST DELIVERIES WITHIN 14 DAYS - ENERGY DEPARTMENT"
         ),
         FakeTweet(
             handle="MoloWarMonitor",
             text="Houthi military spokesman announces the group will target every oil tanker transiting Bab el-Mandeb, effective immediately, and claims a ballistic missile strike on a Greek-owned crude tanker in the southern Red Sea at {hhmm} UTC."
         )
     ];

with entry:__main__ {
    main(TWEETS);
}

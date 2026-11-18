"""A second set of five fake, significant demo tweets (see fake_tweets.jac).

    jac run fake_tweets2 [-- same options as fake_tweets]
    jac run fake_tweets2 -- --remote https://<server>

Same isolation, options and reporting as fake_tweets; only the tweets differ.
Their places, vessels and actors avoid the first set (Fujairah, the Hormuz
seizure, Kharg Island, the SPR, Bab el-Mandeb), so running both against one
server the same day produces ten new cards rather than updates or duplicates
of the first five.
"""

import from fake_tweets_core { FakeTweet, main }

# Five separate oil-material events from configured accounts across the three
# tiers; {hhmm} is the UTC send time.
glob SECOND_SET: list[FakeTweet] = [
         FakeTweet(
             handle="UK_MTO",
             text="UKMTO WARNING: At {hhmm} UTC a crude tanker reported being boarded by armed persons 60NM southeast of Ras al Hadd, Oman. The master reports loss of communication with the bridge. Vessels are advised to transit with caution and report any suspicious approach to UKMTO."
         ),
         FakeTweet(
             handle="TankerTrackers",
             text="BREAKING: Fresh satellite imagery shows a large fire at Saudi Aramco's Abqaiq processing facility after a drone attack at {hhmm} UTC. Abqaiq stabilises about 7 million barrels per day of Saudi crude for export."
         ),
         FakeTweet(
             handle="Osint613",
             text="BREAKING: CENTCOM confirms US strikes on IRGC naval bases on Qeshm Island and at Jask in response to attacks on commercial shipping. US officials say operations are ongoing."
         ),
         FakeTweet(
             handle="financialjuice",
             text="OPEC+ CALLS EMERGENCY MEETING; SAUDI ENERGY MINISTRY SAYS THE KINGDOM WILL RAISE CRUDE OUTPUT BY 1 MILLION BPD WITH IMMEDIATE EFFECT TO OFFSET GULF SUPPLY DISRUPTION"
         ),
         FakeTweet(
             handle="MenchOsint",
             text="Iraq's oil ministry halts all crude exports from the Basra Oil Terminal after a drone strike on an offshore loading platform at {hhmm} UTC. About 3.3 million barrels per day of shipments are suspended, a ministry statement says."
         )
     ];

with entry:__main__ {
    main(SECOND_SET);
}

# Ingestion and replay audit verification

The findings refer to the [November feature audit](../2026-11-18-feature-audit.html).

| Audit finding | Offline regression and outcome |
| --- | --- |
| Official X exceeds the daily cap | Three accounts with a one-read budget made zero timeline requests. With six available reads and empty timelines, requests allowed at most six and five results, used two reads in total, then paused before an oversized request. X requires a minimum page size of five. [X timeline endpoint](https://docs.x.com/x-api/users/get-posts) |
| Official X drops posts in a burst | A two-page fixture contained IDs 101–130. The first 25 reads exhausted the cap. A fresh adapter resumed at the saved second page and delivered all 30 IDs in ascending order before advancing the checkpoint to 130. |
| Telegram Bot admits unselected channels | The Bot API fixture resolved the selected username to a stable ID, then delivered both a renamed selected channel and an unselected channel. Only the selected channel reached the sink, and the update offset advanced past both messages. |
| Official X claims all failed polls were live | Simulated connection failures on all three accounts produced reconnecting status with 3/3 failures. The next successful cycle returned to live. |
| Switching Telegram transports duplicates messages | The converters produced identical post keys. In SQLite a cross-transport redelivery created one row, including tests starting from historical Bot IDs in both legacy formats. Existing post keys remained intact. |
| Renamed Telegram channel links point at the previous address | A simulated Telethon client invoked the registered event callback with a new username and the same account ID. The emitted link used alpha_renamed/38 and retained the channel's official tier. |
| Replay sorts offsets in the wrong order | The fixture loader ordered a timezone-free noon (UTC), 13:30 UTC and 09:00 at UTC-05:00 from earliest to latest. |
| Invalid replay speed submits a partial batch | A two-row batch with zero, negative, NaN and infinite speeds exited before constructing an HTTP client or sending any records. |

All eight regression scenarios passed with `jac test tests/adapter_audit_tests.jac`. Provider responses are generated locally using HTTPX MockTransport or a simulated Telethon client.

## Follow-up checks on official X polling

| Scenario | Offline verification |
| --- | --- |
| Expired pagination token after a pause | Starting at committed ID 100, SQLite already held IDs 104 and 105. The rejected token cost one read, leaving too little quota for another request. After replenishment, repeated token rejections triggered at most one immediate restart per poll. Recovery used `since_id=100` and an exclusive `until_id` derived from the oldest buffered post. A new adapter resumed the same checkpoint, delivered IDs 101–105 once in order, and advanced to 105. The six HTTP attempts used six reads. [X timeline parameters](https://docs.x.com/x-api/users/get-posts) |
| Configured handle deferred by the daily cap | The running adapter resolved `alpha` with the last available read and reported a budget pause before contacting X for `beta`. A simulated UTC rollover resumed the same adapter, resolved `beta` once, polled both accounts and returned to live. The new day recorded three reads. |

Both follow-up scenarios use HTTPX MockTransport, the production adapter and disposable SQLite databases. They run alongside the eight original scenarios in [the adapter audit tests](../../tests/adapter_audit_tests.jac).

# Ingestion and replay audit verification

The numbered findings refer to the [November feature audit](../2026-11-18-feature-audit.html).

| Audit finding | Offline regression and outcome |
| --- | --- |
| Official X exceeds the daily cap | Three accounts with a one-read budget made zero timeline requests. With six available reads and empty timelines, requests allowed at most six and five results, used two reads in total, then paused before an oversized request. X requires a minimum page size of five. [X timeline endpoint](https://docs.x.com/x-api/users/get-posts) |
| Official X drops posts in a burst | A two-page fixture contained IDs 101–130. The first 25 reads exhausted the cap. A fresh adapter resumed at the saved second page and delivered all 30 IDs in ascending order before advancing the checkpoint to 130. |
| Telegram Bot admits unselected channels | The Bot API fixture resolved the selected username to a stable ID, then delivered both a renamed selected channel and an unselected channel. Only the selected channel reached the sink, and the update offset advanced past both messages. |

The three regression tests run with `jac test tests/adapter_audit_tests.jac`. Provider responses are generated locally using HTTPX MockTransport.

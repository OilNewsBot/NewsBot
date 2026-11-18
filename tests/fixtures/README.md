# Market-event replay fixtures

These six JSON files contain 21 reconstructed posts for testing market-event classification, suppression and deduplication. Their wording and identifiers are test inputs. The bundled public-channel content used by Home and Discover comes from [the directory seed](../../db/directory_seed.json).

| Fixture | Posts | Scenario |
| --- | ---: | --- |
| `khasab_vlcc.json` | 5 | Initial shipping incident report and later coverage near Khasab |
| `kharg_strikes.json` | 6 | Multiple vessel reports, updates and repeated reporting |
| `jazan_refinery.json` | 3 | Reports about an infrastructure incident at Jazan |
| `irgc_warning.json` | 2 | A warning to shipping and subsequent coverage |
| `noise.json` | 3 | Commentary, recaps and engagement posts expected to stay below the alert threshold |
| `stale_reports.json` | 2 | Distinguishing historical evidence from newly published aggregate data |

Each file contains a `posts` list. A post includes source identity, text, timestamp and an `expect` object. Tests use `surfaced`, `category_in`, `dedup` and, on some suppressed posts, `max_score`. Surfaced posts can start an event, update one, or repeat an existing report.

## Replay on a local test server

Start a Newsstream backend using a separate test database. For offline model responses, set `NEWSSTREAM_CASSETTE=tests/cassettes/llm.json` and `NEWSSTREAM_CASSETTE_MODE=replay` in the **server** environment. From another terminal in the same checkout, run

```sh
jac run replay -- tests/fixtures/ --preserve-timestamps
```

Replay reads every fixture, sorts posts by `posted_at`, removes the test expectations and sends the posts to the running server's `/ingest` endpoint. By default it uses `http://localhost:8000`, shifts timestamps close to the present and plays capped gaps at 10× speed. The example preserves fixture dates because model replay depends on matching recorded prompts. Use `--speed` to change playback speed or `--base-url` to select the test server. If the backend requires `NEWSBOT_ADMIN_TOKEN`, supply its value in the replay process's environment.

The replay command queues real records in the selected backend. For repeatable assertions against temporary databases, use the [classification tests](../classify_tests.jac) and [deduplication tests](../dedup_tests.jac).

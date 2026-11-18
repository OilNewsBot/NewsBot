# Ingestion restart recovery

The acceptance test holds the first model call open, accepts three posts, cancels the worker, and reopens the same SQLite database. All three raw posts and pending jobs survive shutdown. Redelivering the first does not create more work. The restarted worker records exactly three final decisions and empties the queue.

A second test injects a SQLite failure during notification insertion. The decision, event, membership, card and dequeue roll back together. Retrying commits one event and one alert. Both cases passed with the pinned Jac runtime in `tests/pipeline_recovery_tests.jac`.

# Native mobile audit verification

[November feature audit](../2026-11-18-feature-audit.html)

| Finding | Regression and observed outcome |
| --- | --- |
| Installation reset with the same Expo token | The original registration was enabled, then disabled, before a new installation registered the same token. Only news created after the new registration produced an Expo submission. A stale receipt for the previous installation left the new registration enabled. The HTTP test continues to require a conflict for a token owned by another active installation. A disabled legacy row also released its token on backend initialization. |
| Off stalls behind a token lookup | A controlled promise held the Expo lookup open. Off finished and persisted before the promise was released. Late completion generated no new registration. The server saw one enable followed by one disable. |
| Token rotation fails silently | A simulated native-token change and failed lookup saved enabled with sync pending. A fresh controller loaded the saved state, retrieved the rotated token, sent it and cleared pending. |
| Foreground storage failure suppresses an alert | A failed write for alert 501 still allowed its first presentation. Redelivery after storage recovered suppressed the duplicate and saved the pending ID history. |
| Unchanged registrations repeat | Two unchanged resume checks produced no additional saves, pending transitions or backend registrations. Two periodic retries on the synced phone made zero additional Expo lookups. |

The client used its production subscription and foreground controllers with simulated permissions, Expo tokens and storage. TypeScript checking and all 13 client tests passed. All 8 mobile Jac integration tests passed with SQLite, the application routes and an offline Expo transport. Production JavaScript bundles were exported for iOS and Android. Signed-device push delivery was outside this offline check.

# Night Automation Queue
# Updated by each cycle agent. Format: - [ ] task | - [x] DONE | - [~] SKIP

## TODO
- [x] debug: check _checkNewSignals() for edge cases — null pair/symbol, malformed JSON lines in events.jsonl, duplicate signal ids
- [x] debug: verify WebSocket reconnect actually recovers after 60s network drop (check onDone/onError handler timing)
- [ ] debug: check _downloadAndInstall — what happens if storage permission denied mid-download
- [ ] feature: pull-to-refresh on signals list (RefreshIndicator wrapper)
- [ ] feature: signal list sorting toggle (newest first / by pair / by P&L)
- [ ] feature: long-press on signal card to copy pair to clipboard
- [ ] feature: haptic feedback on new signal push notification
- [ ] feature: show timestamp "2h ago" style on each signal card (relative time, refresh every minute)
- [ ] research: search web for "flutter crypto trading app ux improvements 2025" and add new ideas here
- [ ] research: search web for "flutter android performance optimization tips" and add relevant ones

## IN PROGRESS
(none)

## DONE
- [x] Connection status indicator ONLINE/OFFLINE — v1.5.6+39
- [x] Download progress bar — v1.5.6+39
- [x] GitHub fallback _checkUpdate() timer — v1.5.6+39
- [x] Enriched push notifications (pair+direction+price) — v1.5.7+40
- [x] Signal outcome badges TP/SL/OPEN — v1.5.7+40
- [x] Bot health dot + /health endpoint — v1.5.7+40
- [x] Funding rate display + /funding endpoint — v1.5.7+40

## NIGHT LOG
(each cycle appends one line: timestamp | action | result)
- 23:30 UTC | debug: _checkNewSignals() edge cases — null guard on cast, empty id check, explicit toString on pair | done | build 41
- 00:03 UTC | debug: WebSocket reconnect — added _pendingReconnect field, prevent duplicate reconnects, exponential backoff (5/10/30/60s), cancel on dispose | done | build 42

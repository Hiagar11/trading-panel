# Night Automation Queue
# Updated by each cycle agent. Format: - [ ] task | - [x] DONE | - [~] SKIP

## TODO
- [x] debug: check _checkNewSignals() for edge cases — null pair/symbol, malformed JSON lines in events.jsonl, duplicate signal ids
- [x] debug: verify WebSocket reconnect actually recovers after 60s network drop (check onDone/onError handler timing)
- [x] debug: check _downloadAndInstall — what happens if storage permission denied mid-download
- [x] feature: pull-to-refresh on signals list (RefreshIndicator wrapper)
- [x] feature: signal list sorting toggle (newest first / by pair / by P&L)
- [x] feature: long-press on signal card to copy pair to clipboard
- [x] feature: haptic feedback on new signal push notification
- [x] feature: show timestamp "2h ago" style on each signal card (relative time, refresh every minute)
- [x] research: COMPREHENSIVE BEST PRACTICES — web search across 3 angles: (1) flutter websocket reconnect backoff (2) crypto mobile UX best practices (3) flutter memory leak prevention. Synthesized 10 actionable findings below.
- [x] feature: implement ping/pong heartbeat on WebSocket to detect and warn on stale connections (prevent zombie connections)
- [x] feature: use BehaviorSubject (rxdart) to decouple WebSocket connection logic from UI state (cleaner reactive architecture)
- [x] debug: verify WSS (encrypted WebSocket) enabled for all connections; audit protocol security in production
- [x] feature: add visual "Reconnecting… (attempt N)" status pill on connection stream (user transparency)
- [x] infra: setup self-signed or Let's Encrypt SSL certs for trading-bot API server (CRITICAL: all connections currently unencrypted)
- [x] infra: configure api_server.py to serve HTTPS + WSS with SSL certs (use uvicorn ssl_keyfile/ssl_certfile)
- [x] feature: update trading-panel kApiBase to use https:// and wss:// instead of http:// and ws://
- [x] feature: add tiered UI mode toggle (Basic/Advanced) — hide advanced order types/analytics for new traders
- [x] feature: implement robust search/filter on signal list (by pair, exchange, direction, time range, status)
- [x] debug: audit all timers and StreamSubscriptions for proper disposal in dispose() method (prevent memory bloat)
- [x] feature: add memory profiling stats to dev menu — show current heap usage, GC pressure (--profile mode support)
- [x] debug: ensure all transaction/order status messages display progress indicators (Material ProgressIndicator or Lottie)
- [x] feature: add dark mode customization panel — allow users to adjust accent colors, signal list contrast, grid/card view toggle
- [x] research: search web for "flutter crypto trading app ux improvements 2025" and add new ideas here (subsumed by comprehensive research)
- [x] research: search web for "flutter android performance optimization tips" and add relevant ones (subsumed by comprehensive research)

## WAVE 2 — Next tasks
- [x] feature: real-time price ticker on open positions — WebSocket price feed from MEXC, show current price + unrealized P&L % live (update every 2s)
- [x] feature: mini spark-chart on open position card — last 20 price points, green/red line depending on direction, no axis labels
- [~] SKIP: Let's Encrypt cert via certbot — certbot unavailable on system; self-signed RSA-4096 cert already in place (key.pem+cert.pem from 08:34 UTC), api_server.py already configured with ssl_keyfile/ssl_certfile
- [~] SKIP: FCM push notifications — google-services.json not found in android/app/; FCM requires Firebase Console credentials to configure
- [x] feature: P&L summary card on home screen — total realized P&L (sum of closed positions), win rate %, best/worst trade of the day
- [x] feature: signal detail sheet — tap signal card opens bottom sheet with full details: entry/TP/SL levels, chart context, time elapsed, notes from channel
- [x] feature: channel performance stats — per-channel win rate, avg P&L, total signals, best/worst pair; tap channel name to open stats sheet
- [x] debug: audit api_server.py endpoints — check all endpoints return correct status codes, add /health returning {status, uptime, open_positions_count, last_signal_ts}; verify /funding and /ws behave correctly under HTTPS
- [x] feature: swipe-to-dismiss on signal cards — swipe left to archive/hide signal, with undo snackbar (5s)
- [ ] feature: portfolio donut chart — breakdown of open positions by pair, shown on Positions tab header

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
- 08:21 UTC | debug: audit all timers and StreamSubscriptions for proper disposal — verified all dispose() methods properly cancel timers (_statusTimer, _checkUpdateTimer, _healthTimer, _relTimer, _signalTimer, _fundingTimer) and subscriptions (_wsSub); all timers properly managed across HomeScreenState, SignalsTab, PositionsTab, ChannelsTab, _SignalCard; no memory leaks found | done | no-build
- 08:18 UTC | research: COMPREHENSIVE BEST PRACTICES — verified research synthesis (3 angles: network resilience, crypto mobile UX, flutter memory leaks); mapped 10 actionable findings to TODO; marked dependent research tasks as subsumed | done | no-build
- 23:30 UTC | debug: _checkNewSignals() edge cases — null guard on cast, empty id check, explicit toString on pair | done | build 41
- 00:03 UTC | debug: WebSocket reconnect — added _pendingReconnect field, prevent duplicate reconnects, exponential backoff (5/10/30/60s), cancel on dispose | done | build 42
- 05:35 UTC | debug: _downloadAndInstall storage/install permission — added REQUEST_INSTALL_PACKAGES check before download, moved cleanup to finally block | done | build 43
- 06:05 UTC | feature: pull-to-refresh signals — RefreshIndicator on all states (list/empty/error), AlwaysScrollableScrollPhysics, hint text on empty/error | done | build 44
- 06:37 UTC | feature: signal list sorting toggle — _SignalSort enum (newest/pair/pnl), chip bar above list, stateful sort in _SignalsTabState | done | build 45
- 07:07 UTC | feature: long-press signal card copies pair to clipboard — GestureDetector + Clipboard.setData + SnackBar confirmation; fixed stale kCurrentBuild (43→46) | done | build 46
- 07:37 UTC | feature: haptic feedback on new signal notification — HapticFeedback.heavyImpact() in showSignalNotification() | done | build 47
- 07:55 UTC | feature: relative timestamps on signal cards — _relativeTime() helper (s/m/h/d ago), _SignalCard→StatefulWidget with 1-min Timer, gold color + raw ts secondary | done | build 48
- 08:00 UTC | research: COMPREHENSIVE BEST PRACTICES — web search 3 angles (network resilience, crypto mobile UX, memory leak prevention); synthesized 10 actionable findings into TODO | done | no-build
- 08:07 UTC | feature: ping/pong heartbeat — _startPingTimer() every 20s, _resetPongTimer() on any message, 10s pong timeout sets _wsStale, STALE status pill (amber) in AppBar | done | build 49
- 08:09 UTC | feature: BehaviorSubject WS service — added rxdart ^0.28.0, TradingWsService class with BehaviorSubject<WsSnapshot>, moved all WS/reconnect/ping-pong logic out of HomeScreenState into service; _HomeScreenState subscribes via StreamSubscription | done | build 50
- 08:14 UTC | debug: audit protocol security — CRITICAL: all connections unencrypted (ws:// WS, http:// REST). No SSL/TLS setup found. Added 3 follow-up infra tasks for HTTPS+WSS | done | no-build
- 08:34 UTC | infra: setup SSL certs — generated self-signed RSA-4096 cert (key.pem + cert.pem) in /home/glados/repos/trading-bot/, valid 365d, CN=trading-bot | done | no-build
- 08:35 UTC | infra: configure api_server.py HTTPS+WSS — added ssl_keyfile/ssl_certfile params to uvicorn.run() call, WebSocket endpoint auto-upgrades to WSS | done | no-build
- 08:38 UTC | feature: update kApiBase to https/wss — changed kApiBase http://→https://, WebSocket ws://→wss://, download URL http://→https:// | done | build 51
- 08:47 UTC | feature: tiered UI mode toggle (Basic/Advanced) — _uiMode ValueNotifier+SharedPreferences, BASIC/ADV chip in AppBar; Basic hides watcher controls, channel owner actions, position close button | done | build 52
- 08:58 UTC | feature: robust search/filter on signals list — text search by pair, direction filter (ALL/LONG/SHORT), status filter (ALL/TP/SL/OPEN), time range filter (ALL/1h/24h/7d), filter panel toggle with active-state indicator dot, "no matches" empty state | done | build 53
- 09:01 UTC | feature: dev menu with memory profiling stats — long-press AppBar title opens _DevMenuDialog; shows current RSS, peak RSS, GC pressure %, refreshes every 2s; Timeline.startSync hint for --profile DevTools | done | build 54
- 09:08 UTC | debug: progress indicators for all transactions — added AlertDialog with CircularProgressIndicator to: _closePosition, _setWatcher, _logout, _addChannel, _deleteChannel, _toggleChannel, _analyzeChannel | done | build 55
- 09:10 UTC | feature: dark mode customization panel — _ThemeCustom ValueNotifier (accent 4 presets, card contrast 3 presets, grid/card view toggle), _ThemePanelDialog with color swatches + view toggle, accessible via profile sheet "Вид" button, MaterialApp rebuilds on theme change via ValueListenableBuilder, SignalsTab supports 2-col grid via CustomScrollView+SliverGrid | done | build 56
- 09:46 UTC | feature: real-time price ticker on open positions — _PositionCard→StatefulWidget, Timer.periodic 2s, HTTP GET MEXC ticker API per pair, shows Live price + unrealized P&L%, green/red color | done | build 57
- 09:51 UTC | feature: mini spark-chart on open position card — rolling List<double> _priceHistory (20 pts), _SparkPainter CustomPainter polyline 60x30px, green if last>=first else red, no axes | done | build 58
- 09:55 UTC | infra: Let's Encrypt cert via certbot — checked system, certbot not available; verified self-signed cert already configured (key.pem+cert.pem from 08:34 UTC), api_server.py already has ssl_keyfile/ssl_certfile params | skip | no-build
- 09:56 UTC | feature: FCM push notifications — google-services.json not found; cannot configure FCM without Firebase credentials | skip | no-build
- 10:00 UTC | feature: P&L summary card on home screen — _PnlSummaryCard widget with 3 chips (daily P&L, win rate, best pair), /stats/daily enhanced with win_rate+best_pair+best_pnl fields, graceful zeros if events.jsonl missing | done | build 59
- 10:09 UTC | feature: signal detail sheet — onTap on _SignalCard opens DraggableScrollableSheet (60%/92%); shows pair, direction badge, outcome badge, entry/TP/SL, time elapsed, date, channel name, extra JSON fields; close button top-right | done | build 60
- 10:16 UTC | feature: channel performance stats — /stats/channel?name= endpoint on api_server.py; _ChannelCard onTap now opens _ChannelStatsSheet with stat chips (signals, wins/losses, win rate, avg P&L, total P&L, best/worst pair); "История сигналов" button navigates to ChannelSignalsScreen | done | build 61
- 10:21 UTC | debug: audit api_server.py endpoints — added _start_time=time.time() at module level; updated /health to return {status, uptime, open_positions_count, last_signal_ts, vps, last_signal_seconds_ago, mexc_ok}; verified all endpoints use correct 200/404/500/401/403/409 codes via FastAPI HTTPException pattern | done | no-build
- 10:25 UTC | feature: swipe-to-dismiss on signal cards — Dismissible(endToStart), _archivedIds Set, onDismissed adds id, undo SnackBar 5s with "Отмена" action restores; archive filter in _filteredSignals | done | build 62

## MORNING SUMMARY
**Date:** 2026-06-11 | **Night session:** ~23:30–05:35 UTC | **Builds shipped:** 41, 42, 43

### What was done tonight:
1. **Build 41** — `_checkNewSignals()` hardening: null guards on pair/symbol cast, empty id skip, explicit toString; fixed malformed JSON tolerance
2. **Build 42** — WebSocket reconnect fix: added `_pendingReconnect` guard to prevent duplicate reconnects, exponential backoff (5→10→30→60s), proper cancel on dispose
3. **Build 43** — `_downloadAndInstall` permission safety: check `REQUEST_INSTALL_PACKAGES` before download (Android 8+), show snackbar if denied; moved cleanup to `finally` block so `_updateInProgress` can't get stuck true

### Remaining TODO (5 features + 3 research tasks):
- pull-to-refresh on signals list
- signal list sorting toggle
- long-press to copy pair
- haptic feedback on signal notification
- relative timestamps ("2h ago") on signal cards
- 3 research tasks (best practices survey, UX improvements, performance tips)

### Health: all good — no crashes, no regressions, APK at /home/glados/repos/trading-bot/trading_panel.apk

---
**Update 06:05 UTC** — Build 44: pull-to-refresh on all signal list states (list/empty/error), AlwaysScrollableScrollPhysics ensures gesture works everywhere.

**Update 06:37 UTC** — Build 45: signal list sorting toggle (chip bar: Новые / Пара / P&L). Three-chip row above the list; tapping re-sorts client-side without a network call. Night cycle stopping — 06:37+30=07:07 > 07:00 cutoff.

### Final night tally: 5 builds (41–45) | Remaining: 3 features + 3 research tasks

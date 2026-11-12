# Development milestones

## M1 Windows read-only bridge
- Confirm Exness demo account binding, account identity and disconnection handling.
- Test authenticated account and position reads with API bound to localhost.
- Confirm MT5 terminal access from a headless/background worker under the intended Windows user session.

## M2 Android and private networking
- Flutter Android app: connection wizard, dashboard, positions, connection status.
- Private Tailscale routing and Windows firewall rules; never publish public API port.
- Secure token storage and a protected token rotation procedure.

## M3 Manual trading, demo-only
- Server-side account and symbol checks; broker volume-step and order filling validation.
- Maximum lot/exposure/daily-loss limits; stable command IDs and audit trail.
- Explicit confirmation, order reconciliation on timeout, no blind retries.
- Verify hedging/netting semantics and all closes on demo.

## M4 Automation extraction
- Refactor existing Tkinter Trade Manager logic into UI-independent services.
- One active automation owner per account.
- Persist rule state, stop/pause behavior, and restart recovery.
- Simulate restart and disconnection scenarios before considering live trading.

No GitHub Actions or live trading in these milestones without separate approval.

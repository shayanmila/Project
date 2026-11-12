# MT5 Remote Manager

Private-network Android remote control for a locally running MetaTrader 5 terminal.

## Status
Phase 1 scaffold: **read-only**, **demo-account-only**, no order execution endpoints.

## Architecture
- Windows: Python FastAPI bridge using official MetaTrader5 Python package.
- Android: Flutter application (planned).
- Connectivity: private Tailscale network; never forward the API port to the public internet.
- Existing Trade Manager integration: planned after extracting shared trading logic and applying safety checks.

## Windows quick start
1. Install 64-bit Python and MT5 on Windows. Log into an **Exness demo MT5** account.
2. `cd backend`
3. `py -m venv .venv`
4. `.venv\Scripts\activate`
5. `pip install -r requirements.txt`
6. `copy .env.example .env`
7. Edit `.env`: set `MT5_TERMINAL_PATH` and generate a long random `API_TOKEN`. Never commit `.env`.
8. `uvicorn app.main:app --host 127.0.0.1 --port 8765`
9. Test `http://127.0.0.1:8765/health` and authenticated `/account` locally.

Remote connectivity and secure Windows service registration will be configured after local tests. Use a private Tailscale interface and host firewall restrictions when enabling remote access.

## Security
- Do not expose port 8765 via router forwarding or public proxy.
- Keep secrets out of Git. The repository should be private before uploading proprietary trading logic.
- Never store broker credentials in the Android app.
- Fail closed if terminal disconnected, selected account mismatches, or an account is not demonstrably a demo account.
- Start read-only; enable orders only after explicit demo testing and independent risk controls.
- One MT5 Python binding session targets one active terminal at a time. Multiple concurrent accounts require isolated worker processes and explicit account routing.
- Nothing in this repository is a trading strategy or assurance of profitability.

## Roadmap
- [x] Read-only demo bridge scaffold
- [ ] Windows local smoke test
- [ ] Tailscale authorization and Android dashboard
- [ ] Audit log and idempotent trade-command queue
- [ ] Safe manual orders on demo account
- [ ] Existing Trade Manager automation engine extraction and single-owner execution
- [ ] Recovery tests and Android APK packaging

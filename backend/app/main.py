"""Phase 1: read-only, demo-only MT5 bridge. Not for public internet exposure."""
import os
import threading
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException

load_dotenv()
_lock = threading.RLock()


def auth(authorization: str | None = Header(default=None)) -> None:
    import hmac
    expected = os.getenv("API_TOKEN", "")
    if len(expected) < 32 or expected == "replace-with-a-long-random-token":
        raise HTTPException(status_code=503, detail="API token not configured")
    if not authorization or not hmac.compare_digest(authorization, f"Bearer {expected}"):
        raise HTTPException(status_code=401, detail="Unauthorized")


def _session():
    try:
        import MetaTrader5 as mt5
    except ImportError as exc:
        raise HTTPException(status_code=503, detail="MetaTrader5 package unavailable") from exc

    path = os.getenv("MT5_TERMINAL_PATH", "").strip()
    if not path or not os.path.isfile(path):
        raise HTTPException(status_code=503, detail="MT5 terminal path not configured")
    expected_login = os.getenv("MT5_EXPECTED_LOGIN", "").strip()
    if not expected_login.isdigit() or int(expected_login) <= 0:
        raise HTTPException(status_code=503, detail="Expected demo account login missing")
    if not mt5.initialize(path=path, timeout=6000):
        raise HTTPException(status_code=503, detail="MT5 not connected")
    account = mt5.account_info()
    if account is None:
        raise HTTPException(status_code=503, detail="MT5 account unavailable")
    if int(account.login) != int(expected_login):
        raise HTTPException(status_code=409, detail="Unexpected MT5 account")
    # Real accounts must never be accepted by the initial demo-only bridge.
    demo_flag = getattr(mt5, "ACCOUNT_TRADE_MODE_DEMO", None)
    if demo_flag is None or account.trade_mode != demo_flag:
        raise HTTPException(status_code=403, detail="Only demo MT5 accounts permitted")
    return mt5, account


app = FastAPI(title="MT5 Remote Manager", version="0.1.0", docs_url=None, redoc_url=None)


@app.get("/health")
def health():
    return {"api": "online", "mode": "read-only-demo"}


@app.get("/account", dependencies=[Depends(auth)])
def account():
    with _lock:
        mt5, a = _session()
        return {
            "login": a.login, "server": a.server, "currency": a.currency,
            "balance": a.balance, "equity": a.equity,
            "margin": a.margin, "margin_free": a.margin_free,
            "profit": a.profit,
        }


@app.get("/positions", dependencies=[Depends(auth)])
def positions():
    with _lock:
        mt5, _ = _session()
        data = mt5.positions_get()
        if data is None:
            raise HTTPException(status_code=503, detail="MT5 positions unavailable")
        return [
            {
                "ticket": p.ticket, "symbol": p.symbol, "type": p.type,
                "volume": p.volume, "price_open": p.price_open,
                "price_current": p.price_current, "sl": p.sl, "tp": p.tp,
                "profit": p.profit, "magic": p.magic,
            }
            for p in data
        ]

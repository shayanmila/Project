"""Private MT5 bridge. Live trading requires separate server-side activation."""
import os
import threading
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
from typing import Literal
import math
import time
import hashlib
import json
import uuid

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
        raise HTTPException(status_code=503, detail="Expected MT5 account login missing")
    if not mt5.initialize(path=path, timeout=6000):
        raise HTTPException(status_code=503, detail="MT5 not connected")
    account = mt5.account_info()
    if account is None:
        raise HTTPException(status_code=503, detail="MT5 account unavailable")
    if int(account.login) != int(expected_login):
        raise HTTPException(status_code=409, detail="Unexpected MT5 account")
    # The configured login is mandatory for both real and demo monitoring.
    return mt5, account


app = FastAPI(title="MT5 Remote Manager", version="0.1.0", docs_url=None, redoc_url=None)


@app.get("/health")
def health():
    return {"api": "online", "mode": "execution-disabled" if not _enabled() else "live-execution-enabled"}


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


# All write routes are independently guarded on the server. The mobile app cannot
# enable execution by changing a local setting.
def _enabled():
    return os.getenv("MT5_LIVE_EXECUTION", "false").lower() == "true"

def _require_live():
    if not _enabled():
        raise HTTPException(status_code=423, detail="Live execution disabled on backend")
    if os.getenv("MT5_LIVE_APPROVAL", "") != "I_APPROVE_REAL_ACCOUNT_TRADING":
        raise HTTPException(status_code=423, detail="Server approval missing")

class TradeRequest(BaseModel):
    symbol: str = Field(min_length=1, max_length=32, pattern=r"^[A-Za-z0-9._-]+$")
    side: Literal["BUY", "SELL"]
    lots: float = Field(gt=0)
    sl: float = Field(default=0, ge=0)
    tp: float = Field(default=0, ge=0)
    confirm: bool = False

class StopsRequest(BaseModel):
    ticket: int = Field(gt=0)
    sl: float = Field(ge=0)
    tp: float = Field(ge=0)
    confirm: bool = False

class CloseRequest(BaseModel):
    ticket: int = Field(gt=0)
    confirm: bool = False

class CloseSymbolRequest(BaseModel):
    symbol: str = Field(min_length=1, max_length=32, pattern=r"^[A-Za-z0-9._-]+$")
    confirm: bool = False

class GridRequest(TradeRequest):
    count: int = Field(ge=1, le=20)
    spacing: float = Field(gt=0)
    plan_id: str | None = None
    confirmation_code: str | None = None

def _max_lots():
    return float(os.getenv("MT5_MAX_LOTS_PER_ORDER", "0.10"))

def _max_total():
    return float(os.getenv("MT5_MAX_TOTAL_LOTS", "0.50"))

def _symbol(mt5, symbol):
    info = mt5.symbol_info(symbol)
    if info is None or info.name != symbol:
        raise HTTPException(status_code=422, detail="Exact MT5 symbol not found")
    if not info.visible and not mt5.symbol_select(symbol, True):
        raise HTTPException(status_code=422, detail="Symbol not available")
    return info

def _volume(info, lots):
    if not math.isfinite(lots) or lots <= 0 or lots > _max_lots():
        raise HTTPException(status_code=422, detail="Lot size exceeds configured limit")
    step = float(info.volume_step)
    if step <= 0 or lots < info.volume_min - 1e-8 or lots > info.volume_max + 1e-8:
        raise HTTPException(status_code=422, detail="Lot size outside broker limits")
    if abs(lots / step - round(lots / step)) > 1e-6:
        raise HTTPException(status_code=422, detail="Lot size not aligned with broker step")

def _finite_prices(*prices):
    if any(not math.isfinite(p) or p < 0 for p in prices):
        raise HTTPException(status_code=422, detail="Invalid SL/TP or spacing")

def _position(mt5, ticket):
    data = mt5.positions_get(ticket=ticket)
    if not data or len(data) != 1:
        raise HTTPException(status_code=404, detail="Position no longer exists")
    return data[0]

def _send(mt5, request):
    # No automatic retry: an uncertain response must be reconciled against MT5.
    result = mt5.order_send(request)
    if result is None:
        raise HTTPException(status_code=502, detail="MT5 did not return order result; inspect terminal before retrying")
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        raise HTTPException(status_code=409, detail=f"MT5 rejected request: {result.retcode}")
    return {"retcode": result.retcode, "order": result.order, "deal": result.deal}

def _market(mt5, req):
    info = _symbol(mt5, req.symbol)
    _volume(info, req.lots)
    _finite_prices(req.sl, req.tp)
    tick = mt5.symbol_info_tick(req.symbol)
    if tick is None:
        raise HTTPException(status_code=503, detail="Quote unavailable")
    buy = req.side == "BUY"
    price = tick.ask if buy else tick.bid
    if price <= 0:
        raise HTTPException(status_code=503, detail="Invalid quote")
    if req.sl and ((buy and req.sl >= price) or (not buy and req.sl <= price)):
        raise HTTPException(status_code=422, detail="SL is on wrong side of market")
    if req.tp and ((buy and req.tp <= price) or (not buy and req.tp >= price)):
        raise HTTPException(status_code=422, detail="TP is on wrong side of market")
    stops = info.trade_stops_level * info.point
    if (req.sl and abs(price - req.sl) < stops) or (req.tp and abs(price - req.tp) < stops):
        raise HTTPException(status_code=422, detail="SL/TP too close to market")
    order = {"action": mt5.TRADE_ACTION_DEAL, "symbol": req.symbol,
             "volume": req.lots, "type": mt5.ORDER_TYPE_BUY if buy else mt5.ORDER_TYPE_SELL,
             "price": price, "sl": req.sl, "tp": req.tp, "deviation": 20,
             "type_time": mt5.ORDER_TIME_GTC, "comment": "ExnessDashboard"}
    check = mt5.order_check(order)
    if check is None or check.retcode not in (0, mt5.TRADE_RETCODE_DONE):
        raise HTTPException(status_code=422, detail="Broker order_check rejected trade")
    return order

def _close(mt5, p):
    tick = mt5.symbol_info_tick(p.symbol)
    if tick is None:
        raise HTTPException(status_code=503, detail="Quote unavailable")
    buy = p.type == mt5.POSITION_TYPE_SELL
    return _send(mt5, {"action": mt5.TRADE_ACTION_DEAL, "symbol": p.symbol,
        "position": p.ticket, "volume": p.volume,
        "type": mt5.ORDER_TYPE_BUY if buy else mt5.ORDER_TYPE_SELL,
        "price": tick.ask if buy else tick.bid, "deviation": 20,
        "type_time": mt5.ORDER_TIME_GTC, "comment": "ExnessDashboardClose"})

@app.get("/trading/status", dependencies=[Depends(auth)])
def trading_status():
    return {"execution_enabled": _enabled() and os.getenv("MT5_LIVE_APPROVAL", "") == "I_APPROVE_REAL_ACCOUNT_TRADING",
            "max_lots_per_order": _max_lots(), "max_total_lots": _max_total(),
            "max_grid_orders": min(20, int(os.getenv("MT5_MAX_GRID_ORDERS", "5")))}

@app.post("/trading/open", dependencies=[Depends(auth)])
def open_trade(req: TradeRequest):
    _require_live()
    if not req.confirm:
        raise HTTPException(status_code=428, detail="Explicit confirmation required")
    with _lock:
        mt5, _ = _session()
        return _send(mt5, _market(mt5, req))

@app.post("/trading/stops", dependencies=[Depends(auth)])
def modify_stops(req: StopsRequest):
    _require_live()
    if not req.confirm:
        raise HTTPException(status_code=428, detail="Explicit confirmation required")
    _finite_prices(req.sl, req.tp)
    with _lock:
        mt5, _ = _session()
        p = _position(mt5, req.ticket)
        _symbol(mt5, p.symbol)
        return _send(mt5, {"action": mt5.TRADE_ACTION_SLTP, "position": p.ticket,
                           "symbol": p.symbol, "sl": req.sl, "tp": req.tp})

@app.post("/trading/close", dependencies=[Depends(auth)])
def close_trade(req: CloseRequest):
    _require_live()
    if not req.confirm:
        raise HTTPException(status_code=428, detail="Explicit confirmation required")
    with _lock:
        mt5, _ = _session()
        return _close(mt5, _position(mt5, req.ticket))

@app.post("/trading/close-symbol", dependencies=[Depends(auth)])
def close_symbol(req: CloseSymbolRequest):
    _require_live()
    if not req.confirm:
        raise HTTPException(status_code=428, detail="Explicit confirmation required")
    with _lock:
        mt5, _ = _session()
        _symbol(mt5, req.symbol)
        positions = mt5.positions_get(symbol=req.symbol)
        if positions is None:
            raise HTTPException(status_code=503, detail="Could not enumerate positions")
        if len(positions) > int(os.getenv("MT5_MAX_BULK_CLOSE", "5")):
            raise HTTPException(status_code=422, detail="Bulk-close count exceeds limit")
        results = []
        for p in positions:
            if p.symbol != req.symbol:
                continue
            try:
                results.append({"ticket": p.ticket, "result": _close(mt5, p)})
            except HTTPException as exc:
                results.append({"ticket": p.ticket, "error": exc.detail})
                break  # Never continue blindly after an uncertain execution.
        return {"symbol": req.symbol, "results": results}


# Preview plans are short lived, bound to exact parameters and the MT5 account.
# Store only in process memory; a restart invalidates all confirmations.
_grid_plans = {}
_grid_used = set()

def _grid_plan(mt5, account, req):
    if req.count > min(20, int(os.getenv("MT5_MAX_GRID_ORDERS", "5"))):
        raise HTTPException(status_code=422, detail="Grid quantity exceeds server limit")
    info = _symbol(mt5, req.symbol)
    _volume(info, req.lots)
    _finite_prices(req.sl, req.tp, req.spacing)
    if not math.isfinite(req.spacing) or req.spacing <= 0:
        raise HTTPException(status_code=422, detail="Invalid grid spacing")
    if req.count * req.lots > _max_total() + 1e-9:
        raise HTTPException(status_code=422, detail="Grid total lots exceeds limit")
    tick = mt5.symbol_info_tick(req.symbol)
    if tick is None or tick.ask <= 0 or tick.bid <= 0:
        raise HTTPException(status_code=503, detail="Quote unavailable")
    digits = int(info.digits)
    point = float(info.point)
    if point <= 0:
        raise HTTPException(status_code=422, detail="Invalid broker point size")
    # First pending order is one spacing unit away; never execute at market.
    anchor = float(tick.ask if req.side == "BUY" else tick.bid)
    min_distance = max(int(info.trade_stops_level), int(info.trade_freeze_level)) * point
    orders = []
    for i in range(1, req.count + 1):
        raw = anchor + (-1 if req.side == "BUY" else 1) * i * req.spacing
        price = round(raw, digits)
        if price <= 0 or abs(anchor - price) < min_distance + point * 0.5:
            raise HTTPException(status_code=422, detail=f"Grid level {i} too close to market")
        if orders and abs(orders[-1]["price"] - price) < point * 0.5:
            raise HTTPException(status_code=422, detail="Grid spacing smaller than price precision")
        if req.sl and ((req.side == "BUY" and req.sl >= price) or
                       (req.side == "SELL" and req.sl <= price)):
            raise HTTPException(status_code=422, detail=f"SL invalid at grid level {i}")
        if req.tp and ((req.side == "BUY" and req.tp <= price) or
                       (req.side == "SELL" and req.tp >= price)):
            raise HTTPException(status_code=422, detail=f"TP invalid at grid level {i}")
        if (req.sl and abs(req.sl - price) < min_distance) or (req.tp and abs(req.tp - price) < min_distance):
            raise HTTPException(status_code=422, detail=f"SL/TP too close to grid level {i}")
        order = {"action": mt5.TRADE_ACTION_PENDING, "symbol": req.symbol,
                 "volume": req.lots,
                 "type": mt5.ORDER_TYPE_BUY_LIMIT if req.side == "BUY" else mt5.ORDER_TYPE_SELL_LIMIT,
                 "price": price, "sl": round(req.sl, digits), "tp": round(req.tp, digits),
                 "type_time": mt5.ORDER_TIME_GTC, "comment": "ExnessGrid"}
        orders.append(order)
    # Include existing exposure, including pending orders, in a conservative cap.
    existing_positions = mt5.positions_get(symbol=req.symbol)
    existing_orders = mt5.orders_get(symbol=req.symbol)
    if existing_positions is None or existing_orders is None:
        raise HTTPException(status_code=503, detail="Cannot determine existing symbol exposure")
    existing_lots = sum(float(p.volume) for p in existing_positions) + sum(float(o.volume_current) for o in existing_orders)
    if existing_lots + req.count * req.lots > _max_total() + 1e-9:
        raise HTTPException(status_code=422, detail="Existing symbol exposure plus grid exceeds total-lot limit")
    return orders

@app.post("/trading/grid/preview", dependencies=[Depends(auth)])
def grid_preview(req: GridRequest):
    with _lock:
        mt5, account = _session()
        orders = _grid_plan(mt5, account, req)
        plan_id = uuid.uuid4().hex
        confirmation_code = uuid.uuid4().hex[:8].upper()
        params = req.model_dump(exclude={"confirm", "plan_id", "confirmation_code"})
        _grid_plans.clear()  # Only the latest preview can be executed.
        _grid_plans[plan_id] = {"created": time.monotonic(), "login": account.login,
                                "params": params, "orders": orders, "code": confirmation_code}
        return {"plan_id": plan_id, "confirmation_code": confirmation_code,
                "expires_in_seconds": 30, "execution_enabled": _enabled(),
                "orders": [{"symbol": o["symbol"], "type": "BUY_LIMIT" if req.side == "BUY" else "SELL_LIMIT",
                            "price": o["price"], "volume": o["volume"], "sl": o["sl"], "tp": o["tp"]}
                           for o in orders],
                "total_lots": req.lots * req.count}

@app.post("/trading/grid", dependencies=[Depends(auth)])
def open_grid(req: GridRequest):
    _require_live()
    if not req.confirm or not req.plan_id or not req.confirmation_code:
        raise HTTPException(status_code=428, detail="Fresh preview and explicit confirmation required")
    with _lock:
        plan = _grid_plans.get(req.plan_id)
        if not plan or req.plan_id in _grid_used or time.monotonic() - plan["created"] > 30:
            raise HTTPException(status_code=409, detail="Grid preview missing, used or expired")
        if req.confirmation_code != plan["code"] or req.model_dump(exclude={"confirm", "plan_id", "confirmation_code"}) != plan["params"]:
            raise HTTPException(status_code=409, detail="Grid confirmation mismatch")
        # Consume before any order is sent: no duplicate submission on retry.
        _grid_used.add(req.plan_id)
        _grid_plans.pop(req.plan_id, None)
        mt5, account = _session()
        if account.login != plan["login"]:
            raise HTTPException(status_code=409, detail="Account changed since preview")
        current = _grid_plan(mt5, account, req)
        if any(abs(a["price"] - b["price"]) > 1e-9 for a, b in zip(current, plan["orders"])):
            raise HTTPException(status_code=409, detail="Market moved; preview grid again")
        # Preflight all orders before sending any. MT5 may still reject later orders.
        for order in current:
            check = mt5.order_check(order)
            if check is None or check.retcode not in (0, mt5.TRADE_RETCODE_DONE):
                raise HTTPException(status_code=422, detail="Broker rejected grid preflight; no orders sent")
        results = []
        for order in current:
            result = mt5.order_send(order)
            if result is None:
                return {"status": "partial_or_unknown", "results": results,
                        "warning": "MT5 result unknown; inspect pending orders before any retry"}
            if result.retcode != mt5.TRADE_RETCODE_PLACED:
                return {"status": "partial", "results": results,
                        "rejected_retcode": result.retcode,
                        "warning": "Stopped after broker rejection; inspect pending orders"}
            results.append({"ticket": result.order, "price": order["price"]})
        return {"status": "placed", "results": results}

#!/usr/bin/env python3
"""Generate a random sample portfolio priced at real historical closes.

Majors (BTC, ETH, SOL) are bought on random days; altcoins are bought mostly near their
local highs, so the performance chart shows real drawdowns, not only profit.
Every price is CoinGecko's USD daily close on that day. Dates fall within the last year.

  python3 scripts/make-sample-portfolio.py              # writes into the app's sandbox container
  python3 scripts/make-sample-portfolio.py out.json     # or anywhere (then import it in the app)
  python3 scripts/make-sample-portfolio.py --force      # replace an existing portfolio.json
"""
import json, random, sys, time, uuid, urllib.request
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

ASSETS = [  # internal id, symbol, name, coingecko id, binance symbol, rough $ budget per buy, alt?
    ("cg:bitcoin", "BTC", "Bitcoin", "bitcoin", "BTCUSDT", (3000, 8000), False),
    ("cg:ethereum", "ETH", "Ethereum", "ethereum", "ETHUSDT", (1500, 5000), False),
    ("cg:solana", "SOL", "Solana", "solana", "SOLUSDT", (800, 3000), False),
    ("cg:chainlink", "LINK", "Chainlink", "chainlink", "LINKUSDT", (600, 2000), True),
    ("cg:avalanche-2", "AVAX", "Avalanche", "avalanche-2", "AVAXUSDT", (600, 2000), True),
    ("cg:dogecoin", "DOGE", "Dogecoin", "dogecoin", "DOGEUSDT", (500, 1800), True),
    ("cg:arbitrum", "ARB", "Arbitrum", "arbitrum", "ARBUSDT", (400, 1500), True),
    ("cg:sui", "SUI", "Sui", "sui", "SUIUSDT", (400, 1500), True),
]
DEFAULT_OUT = Path.home() / "Library/Containers/io.github.troskinpavel.pf/Data/Library/Application Support/pf/portfolio.json"


def daily_closes(cg_id):
    url = f"https://api.coingecko.com/api/v3/coins/{cg_id}/market_chart?vs_currency=usd&days=365&interval=daily"
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/json"}), timeout=20) as r:
                return [(int(t / 1000), p) for t, p in json.load(r)["prices"]]
        except Exception as e:  # rate limit on the keyless tier: wait and retry
            print(f"  {cg_id}: {e}, retrying…"); time.sleep(15 * (attempt + 1))
    sys.exit(f"could not fetch history for {cg_id}")


def sig(x, digits):
    return format(Decimal(f"{x:.{digits}g}").normalize(), "f")  # never scientific notation


def main():
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = Path(paths[0]) if paths else DEFAULT_OUT
    if out.exists() and "--force" not in sys.argv:
        sys.exit(f"{out} already exists — not overwriting. Pass --force or another path.")
    now = time.time()
    assets, txs = [], []
    for aid, sym, name, cg, bn, (lo, hi), alt in ASSETS:
        closes = [c for c in daily_closes(cg) if c[0] < now - 2 * 86400]
        time.sleep(4)
        n = random.randint(2, 4)
        if alt:
            # Buy mostly near local highs: sample from the top 35% of closes, over the whole year.
            ranked = sorted(closes, key=lambda c: c[1], reverse=True)[: max(n, int(len(closes) * 0.35))]
            days = sorted(random.sample(ranked, n), key=lambda c: c[0])
        else:
            # Majors: spread through the year, earlier buys weighted so the history is long.
            days = sorted(random.sample(closes[: int(len(closes) * 0.8)], n), key=lambda c: c[0])
        held = Decimal(0)
        for i, (ts, price) in enumerate(days):
            px = Decimal(sig(price, 6))
            # Mostly buys; occasionally trim part of the position after the first buy.
            if i > 0 and held > 0 and random.random() < 0.2:
                qty, kind = Decimal(sig(float(held) * random.uniform(0.15, 0.4), 4)), "SELL"
                held -= qty
            else:
                qty, kind = Decimal(sig(random.uniform(lo, hi) / price, 4)), "BUY"
                held += qty
            fee = Decimal(sig(float(qty * px) * 0.001, 3))  # ~0.1% exchange fee
            when = datetime.fromtimestamp(ts + 12 * 3600 + random.randint(0, 6 * 3600), tz=timezone.utc)
            txs.append({"id": str(uuid.uuid4()).upper(), "assetID": aid, "type": kind, "quantity": str(qty), "price": str(px),
                        "currency": "USD", "timestamp": when.strftime("%Y-%m-%dT%H:%M:%SZ"), "fee": str(fee), "note": "sample"})
        assets.append({"id": aid, "symbol": sym, "name": name, "coingeckoID": cg, "binanceSymbol": bn})
        print(f"  {sym}: {len(days)} tx, holding {held}")
    txs.sort(key=lambda t: t["timestamp"])
    doc = {"schemaVersion": 1, "app": "pf Terminal",
           "portfolio": {"name": "sample", "isDemo": False, "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
           "assets": assets, "transactions": txs}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=2, sort_keys=True))
    print(f"wrote {len(txs)} transactions → {out}")


if __name__ == "__main__":
    main()

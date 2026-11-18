#!/usr/bin/env python3
"""Steady load and analysis for the chaos experiments (standard library only).

  chaos-load.py run    --out requests.csv --stop-file STOP [--rate 20]
  chaos-load.py report --requests requests.csv --events events.txt [--json out.json]

`run` sends an open-loop load (a new request every 1/rate seconds, whether or not the previous one finished) through
Traefik on localhost: 80% GET /api/products, 20% POST /api/orders. Every request is logged as
`epoch,route,status,milliseconds,kind`. `kind` is `ok`, `payment` (the app's simulated payment failure, a 502 whose
JSON body says so: expected, not a fault) or `fault` (connection error, timeout, any other 5xx or unexpected status).

`report` reads the events file (lines of `<label> <epoch>`, with labels `fault` and `recovered`) and prints what
happened before, during and after the fault.
"""
import argparse, csv, http.client, json, os, random, statistics, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

HOST_HEADER = "shop.localtest.me"   # the ingress rule; we connect to 127.0.0.1 so no DNS is involved
ERROR_BUDGET = 0.01                 # availability SLO: 99% of requests not 5xx


def one_request(addr, route):
    t0 = time.time()
    status, kind = 0, "fault"
    try:
        conn = http.client.HTTPConnection(addr[0], addr[1], timeout=5)
        headers = {"Host": HOST_HEADER}
        if route == "orders":
            body = json.dumps({"product": "mouse"})
            headers["Content-Type"] = "application/json"
            conn.request("POST", "/api/orders", body, headers)
        else:
            conn.request("GET", "/api/products", headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        status = resp.status
        if status in (200, 201):
            kind = "ok"
        elif status == 502 and route == "orders" and b"payment failed" in data:
            kind = "payment"
        elif status == 400:
            kind = "fault"
        else:
            kind = "fault"
    except Exception:
        status, kind = 0, "fault"
    return t0, route, status, round((time.time() - t0) * 1000, 1), kind


def run(args):
    addr = (args.host, args.port)
    lock = threading.Lock()
    with open(args.out, "w", newline="") as fh, ThreadPoolExecutor(max_workers=128) as pool:
        writer = csv.writer(fh)
        writer.writerow(["epoch", "route", "status", "ms", "kind"])

        def work(route):
            row = one_request(addr, route)
            with lock:
                writer.writerow([f"{row[0]:.3f}", row[1], row[2], row[3], row[4]])

        interval = 1.0 / args.rate
        nxt = time.time()
        while not os.path.exists(args.stop_file):
            pool.submit(work, "orders" if random.random() < 0.2 else "products")
            nxt += interval
            delay = nxt - time.time()
            if delay > 0:
                time.sleep(delay)
        pool.shutdown(wait=True)
        fh.flush()


def pct(values, p):
    if not values:
        return None
    values = sorted(values)
    k = min(len(values) - 1, int(round((p / 100) * (len(values) - 1))))
    return values[k]


def summarize(rows):
    n = len(rows)
    faults = [r for r in rows if r["kind"] == "fault"]
    lat = [r["ms"] for r in rows if r["kind"] == "ok"]
    out = {
        "requests": n,
        "fault_errors": len(faults),
        "fault_error_pct": round(100 * len(faults) / n, 2) if n else 0.0,
        "payment_502": sum(1 for r in rows if r["kind"] == "payment"),
        "fault_errors_products": sum(1 for r in faults if r["route"] == "products"),
        "fault_errors_orders": sum(1 for r in faults if r["route"] == "orders"),
        "p50_ms": pct(lat, 50), "p95_ms": pct(lat, 95), "p99_ms": pct(lat, 99), "max_ms": max(lat) if lat else None,
    }
    return out


def longest_products_gap(rows):
    ok = sorted(r["epoch"] for r in rows if r["route"] == "products" and r["kind"] == "ok")
    if len(ok) < 2:
        return None
    return round(max(b - a for a, b in zip(ok, ok[1:])), 1)


def report(args):
    rows = []
    with open(args.requests) as fh:
        for r in csv.DictReader(fh):
            rows.append({"epoch": float(r["epoch"]), "route": r["route"], "status": int(r["status"]),
                         "ms": float(r["ms"]), "kind": r["kind"]})
    rows.sort(key=lambda r: r["epoch"])
    ev = {}
    for line in open(args.events):
        parts = line.split()
        if len(parts) == 2:
            ev[parts[0]] = float(parts[1])
    t0, fault, rec = rows[0]["epoch"], ev["fault"], ev.get("recovered", rows[-1]["epoch"])
    before = [r for r in rows if t0 + 5 <= r["epoch"] < fault]       # skip the first 5 s of warm-up
    during = [r for r in rows if fault <= r["epoch"] <= rec]
    after = [r for r in rows if r["epoch"] > rec]

    res = {"before": summarize(before), "during": summarize(during), "after": summarize(after),
           "fault_window_s": round(rec - fault, 1)}
    f = [r["epoch"] for r in rows if r["kind"] == "fault" and r["epoch"] >= fault]
    res["first_fault_error_after_s"] = round(f[0] - fault, 1) if f else None
    res["last_fault_error_after_s"] = round(f[-1] - fault, 1) if f else None
    res["outage_span_s"] = round(f[-1] - f[0], 1) if f else 0.0
    res["longest_gap_without_a_successful_products_response_s"] = longest_products_gap(
        [r for r in rows if r["epoch"] >= fault - 5])
    d = res["during"]
    ratio = d["fault_errors"] / d["requests"] if d["requests"] else 0
    res["burn_rate_during_fault_window"] = round(ratio / ERROR_BUDGET, 1)
    res["fault_status_codes"] = {}
    for r in rows:
        if r["kind"] == "fault" and r["epoch"] >= fault:
            res["fault_status_codes"][str(r["status"])] = res["fault_status_codes"].get(str(r["status"]), 0) + 1

    print(f"  fault window: {res['fault_window_s']} s   requests: before {res['before']['requests']}, "
          f"during {d['requests']}, after {res['after']['requests']}")
    for label in ("before", "during", "after"):
        s = res[label]
        print(f"  {label:7s} fault errors {s['fault_errors']:4d} ({s['fault_error_pct']:5.2f}%)  "
              f"products {s['fault_errors_products']:4d}  orders {s['fault_errors_orders']:4d}  "
              f"payment-502 {s['payment_502']:3d}   p50/p95/p99 ms {s['p50_ms']}/{s['p95_ms']}/{s['p99_ms']}")
    print(f"  first fault error {res['first_fault_error_after_s']} s after the fault, last {res['last_fault_error_after_s']} s, "
          f"span {res['outage_span_s']} s; longest gap in successful product responses {res['longest_gap_without_a_successful_products_response_s']} s")
    print(f"  burn rate over the fault window: {res['burn_rate_during_fault_window']}x   fault status codes: {res['fault_status_codes'] or 'none'}")
    if args.json:
        json.dump(res, open(args.json, "w"), indent=2)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--out", required=True)
    r.add_argument("--stop-file", required=True)
    r.add_argument("--rate", type=float, default=20)
    r.add_argument("--host", default="127.0.0.1")
    r.add_argument("--port", type=int, default=8080)
    p = sub.add_parser("report")
    p.add_argument("--requests", required=True)
    p.add_argument("--events", required=True)
    p.add_argument("--json")
    args = ap.parse_args()
    return run(args) if args.cmd == "run" else report(args)


if __name__ == "__main__":
    sys.exit(main())

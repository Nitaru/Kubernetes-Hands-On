#!/usr/bin/env python3
"""Draw failed requests per second from two chaos runs side by side (standard library only).

  chaos-chart.py --before DIR --after DIR --out chart.svg [--title TEXT]

DIR holds `requests.csv` and `events.txt` as written by chaos.sh. Bars are fault errors per second, split into
products (the part that should have kept working) and orders; dashed lines mark the fault and the restore.
"""
import argparse, csv, html

FONT = "-apple-system,'Segoe UI',Helvetica,Arial,sans-serif"


def load(d):
    rows = [(float(r["epoch"]), r["route"], r["kind"]) for r in csv.DictReader(open(f"{d}/requests.csv"))]
    ev = {l.split()[0]: float(l.split()[1]) for l in open(f"{d}/events.txt") if len(l.split()) == 2}
    t0 = ev["fault"] - 20
    sec = {}
    for t, route, kind in rows:
        s = int(t - t0)
        if kind == "fault" and 0 <= s <= 95:
            sec.setdefault(s, {"products": 0, "orders": 0})[route] += 1
    return sec, ev["fault"] - t0, ev.get("redis_restored", ev["recovered"]) - t0


def panel(x0, y0, w, h, sec, fault, restored, title, ymax):
    out = [f'<text x="{x0}" y="{y0 - 14}" font-family="{FONT}" font-size="14" font-weight="700" fill="#e6edf3">{html.escape(title)}</text>']
    out.append(f'<rect x="{x0}" y="{y0}" width="{w}" height="{h}" fill="none" stroke="#30363d"/>')
    bw = w / 96
    for s in range(96):
        d = sec.get(s)
        if not d:
            continue
        hp, ho = d["products"] / ymax * h, d["orders"] / ymax * h
        x = x0 + s * bw
        out.append(f'<rect x="{x:.1f}" y="{y0 + h - hp:.1f}" width="{bw - 0.6:.1f}" height="{hp:.1f}" fill="#f85149"/>')
        out.append(f'<rect x="{x:.1f}" y="{y0 + h - hp - ho:.1f}" width="{bw - 0.6:.1f}" height="{ho:.1f}" fill="#d29922"/>')
    for t, label in ((fault, "Redis down"), (restored, "Redis back")):
        x = x0 + t * bw
        out.append(f'<line x1="{x:.1f}" y1="{y0}" x2="{x:.1f}" y2="{y0 + h}" stroke="#8b98a9" stroke-dasharray="4 3"/>'
                   f'<text x="{x + 4:.1f}" y="{y0 + 14}" font-family="{FONT}" font-size="11" fill="#8b98a9">{label}</text>')
    for v in (0, ymax // 2, ymax):
        y = y0 + h - v / ymax * h
        out.append(f'<text x="{x0 - 6}" y="{y + 4:.1f}" text-anchor="end" font-family="{FONT}" font-size="11" fill="#8b98a9">{v}</text>')
    for s in range(0, 96, 20):
        out.append(f'<text x="{x0 + s * bw:.1f}" y="{y0 + h + 16}" text-anchor="middle" font-family="{FONT}" font-size="11" fill="#8b98a9">{s - 20:+d}s</text>')
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--before", required=True); ap.add_argument("--after", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--title", default="Failed requests per second during a 45 s Redis outage")
    a = ap.parse_args()
    b, bf, br = load(a.before); f, ff, fr = load(a.after)
    ymax = max(5, max(sum(d.values()) for d in list(b.values()) + list(f.values())))
    ymax = ((ymax + 4) // 5) * 5
    W, H = 1040, 330
    body = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
            f'aria-label="{html.escape(a.title)}: before the fix product and order requests fail; after the fix only orders fail">',
            f'<rect width="{W}" height="{H}" rx="14" fill="#0d1117"/>',
            f'<text x="24" y="30" font-family="{FONT}" font-size="16" font-weight="700" fill="#e6edf3">{html.escape(a.title)}</text>',
            panel(60, 80, 440, 190, b, bf, br, "Before the fix: readiness needs Redis", ymax),
            panel(570, 80, 440, 190, f, ff, fr, "After the fix: readiness ignores Redis", ymax),
            f'<rect x="60" y="300" width="12" height="12" fill="#f85149"/><text x="78" y="311" font-family="{FONT}" font-size="12" fill="#e6edf3">GET /api/products (never needs Redis)</text>',
            f'<rect x="330" y="300" width="12" height="12" fill="#d29922"/><text x="348" y="311" font-family="{FONT}" font-size="12" fill="#e6edf3">POST /api/orders (needs Redis)</text>',
            f'<text x="{W - 24}" y="311" text-anchor="end" font-family="{FONT}" font-size="11" fill="#8b98a9">fault errors per second, about 20 requests per second of load, one run each</text>',
            "</svg>"]
    open(a.out, "w").write("\n".join(body) + "\n")


if __name__ == "__main__":
    main()

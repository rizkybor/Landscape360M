#!/usr/bin/env python3
"""Builds assets/data/villages.tsv.gz: every desa/kelurahan with its Kemendagri code (the
ADM4 code BMKG's forecast API takes) and the centre of its boundary, so the app can find
the village nearest to the user without sending their position anywhere.

Source: Badan Informasi Geospasial (BIG), "Batas Wilayah Kelurahan/Desa" 1:10.000
(geoservices.big.go.id, RBI BATASWILAYAH/Administrasi_AR_KelDesa_10K). Run by a developer
when the data needs refreshing; the app only reads the output.

Usage: python3 tool/wilayah/build_villages.py
"""
import gzip
import json
import os
import sys
import time
import urllib.parse
import urllib.request

SERVICE = "https://geoservices.big.go.id/rbi/rest/services/BATASWILAYAH/Administrasi_AR_KelDesa_10K/MapServer/0"
BATCH = 4000  # the service's maxRecordCount
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "data", "villages.tsv.gz")


def get(params):
    url = f"{SERVICE}/query?{urllib.parse.urlencode(params)}"
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=180) as r:
                data = json.load(r)
            if "error" in data:
                raise RuntimeError(data["error"])
            return data
        except Exception as e:  # network hiccup: wait and retry
            if attempt == 3:
                raise
            print(f"  retry after {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))


def centroid(rings):
    """Area-weighted centroid of the largest ring (the village's main body)."""
    best = None
    for ring in rings:
        a = cx = cy = 0.0
        for (x0, y0), (x1, y1) in zip(ring, ring[1:]):
            cross = x0 * y1 - x1 * y0
            a += cross
            cx += (x0 + x1) * cross
            cy += (y0 + y1) * cross
        if a == 0:
            continue
        a *= 0.5
        if best is None or abs(a) > abs(best[0]):
            best = (a, cx / (6 * a), cy / (6 * a))
    if best is None:  # degenerate: average of the points
        pts = [p for ring in rings for p in ring]
        return sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)
    return best[1], best[2]


def clean(text):
    return " ".join(str(text or "").replace("\t", " ").split())


def main():
    found = get({"where": "1=1", "returnIdsOnly": "true", "f": "json"})
    id_field = found["objectIdFieldName"]  # "FID" on this service
    ids = sorted(found["objectIds"])
    print(f"{len(ids)} villages", file=sys.stderr)
    rows = {}
    for start in range(0, len(ids), BATCH):
        lo, hi = ids[start], ids[min(start + BATCH, len(ids)) - 1]
        data = get({
            "where": f"{id_field}>={lo} AND {id_field}<={hi}",
            "outFields": "KDEPUM,WADMKD,WADMKC,WADMKK",
            "returnGeometry": "true",
            "outSR": "4326",
            "maxAllowableOffset": "0.0005",  # ~50 m: plenty for a centre point, much smaller download
            "geometryPrecision": "6",
            "f": "json",
        })
        for f in data["features"]:
            a, g = f["attributes"], f.get("geometry") or {}
            code = clean(a.get("KDEPUM"))
            if len(code.split(".")) != 4 or not g.get("rings"):
                continue
            lng, lat = centroid(g["rings"])
            # A code split over several polygons keeps the one seen first
            rows.setdefault(code, (code, clean(a.get("WADMKD")), clean(a.get("WADMKC")), clean(a.get("WADMKK")), lat, lng))
        print(f"  {min(start + BATCH, len(ids))}/{len(ids)}", file=sys.stderr)
        time.sleep(1)  # be gentle with the public service

    if len(rows) < 80000:
        sys.exit(f"only {len(rows)} villages read; expected ~83,000. Nothing written.")
    lines = ["code\tdesa\tkecamatan\tkabkota\tlat\tlon"]
    for code in sorted(rows):
        c, d, k, kk, lat, lng = rows[code]
        lines.append(f"{c}\t{d}\t{k}\t{kk}\t{lat:.5f}\t{lng:.5f}")
    with gzip.open(OUT, "wt", encoding="utf-8", compresslevel=9) as out:
        out.write("\n".join(lines) + "\n")
    print(f"wrote {len(rows)} villages to {os.path.normpath(OUT)} ({os.path.getsize(OUT) // 1024} KB)", file=sys.stderr)


if __name__ == "__main__":
    main()

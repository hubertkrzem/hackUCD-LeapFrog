#!/usr/bin/env python3
"""Build the compact static data bundled with the LeapFrog app.

Reads the TFI static GTFS (the variant whose IDs match the NTA GTFS-R feed) and
writes to hackUCD-LeapFrog/Resources/:

  stops.json  - every bus, Luas and DART stop: [{i, n, c, la, lo, m, a?}]
  routes.json - route_id -> {s: short name, l: long name, m: mode, o: operator}
  lines.json  - simplified polylines for the Luas Red/Green lines and DART
  stop_routes.json - stop_id -> [[route_id, direction_id], ...] serving it
  luas.json   - Luas stop patterns + trip_id -> pattern, used to estimate tram
                positions from GTFS-R TripUpdates

Usage:
  python3 tools/build_static_data.py                 # downloads the GTFS zip
  python3 tools/build_static_data.py --gtfs-dir DIR  # use an extracted feed
"""

import argparse
import csv
import io
import json
import math
import os
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from collections import defaultdict

GTFS_URL = "https://www.transportforireland.ie/transitData/Data/GTFS_Realtime.zip"
LUAS_STOPS_URL = "https://luasforecasts.rpa.ie/xml/get.ashx?action=stops&encrypt=false"
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "hackUCD-LeapFrog", "Resources")

BUS, LUAS, DART = "bus", "luas", "dart"
MODE_PRIORITY = {LUAS: 0, DART: 1, BUS: 2}


def route_mode(row):
    route_type = row["route_type"].strip()
    if route_type == "0":
        return LUAS
    if route_type == "2":
        return DART if row["route_short_name"].strip().upper() == "DART" else None
    if route_type == "3":
        return BUS
    return None


def parse_time(value):
    h, m, s = value.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


def open_csv(gtfs_dir, name):
    f = open(os.path.join(gtfs_dir, name), encoding="utf-8-sig", newline="")
    return f, csv.DictReader(f)


def haversine_m(lat1, lon1, lat2, lon2):
    r = 6371000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def simplify(points, tolerance_m=6.0):
    """Douglas-Peucker on lat/lon using a local equirectangular projection."""
    if len(points) < 3:
        return points
    lat0 = math.radians(points[0][0])
    xy = [(p[1] * math.cos(lat0) * 111320, p[0] * 110540) for p in points]

    def perp(i, a, b):
        (x, y), (x1, y1), (x2, y2) = xy[i], xy[a], xy[b]
        dx, dy = x2 - x1, y2 - y1
        if dx == dy == 0:
            return math.hypot(x - x1, y - y1)
        return abs(dy * x - dx * y + x2 * y1 - y2 * x1) / math.hypot(dx, dy)

    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        a, b = stack.pop()
        best, idx = 0.0, -1
        for i in range(a + 1, b):
            d = perp(i, a, b)
            if d > best:
                best, idx = d, i
        if best > tolerance_m:
            keep[idx] = True
            stack += [(a, idx), (idx, b)]
    return [p for p, k in zip(points, keep) if k]


def fetch_luas_abbreviations():
    with urllib.request.urlopen(LUAS_STOPS_URL, timeout=30) as resp:
        root = ET.fromstring(resp.read())
    stops = []
    for line in root.iter("line"):
        for stop in line.iter("stop"):
            stops.append((stop.get("abrev"), float(stop.get("lat")), float(stop.get("long"))))
    return stops


def download_gtfs(dest_dir):
    print(f"Downloading {GTFS_URL} ...", file=sys.stderr)
    with urllib.request.urlopen(GTFS_URL, timeout=600) as resp:
        data = resp.read()
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        zf.extractall(dest_dir)
    return dest_dir


def build(gtfs_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)

    # Routes
    agencies = {}
    f, rows = open_csv(gtfs_dir, "agency.txt")
    for row in rows:
        agencies[row["agency_id"]] = row["agency_name"]
    f.close()

    routes, route_modes = {}, {}
    f, rows = open_csv(gtfs_dir, "routes.txt")
    for row in rows:
        mode = route_mode(row)
        if mode is None:
            continue
        rid = row["route_id"]
        route_modes[rid] = mode
        routes[rid] = {
            "s": row["route_short_name"],
            "l": row["route_long_name"],
            "m": mode,
            "o": agencies.get(row["agency_id"], ""),
        }
    f.close()

    # Trips
    trip_route, trip_shape, trip_direction = {}, {}, {}
    f, rows = open_csv(gtfs_dir, "trips.txt")
    for row in rows:
        rid = row["route_id"]
        if rid not in route_modes:
            continue
        trip_route[row["trip_id"]] = rid
        trip_shape[row["trip_id"]] = row["shape_id"]
        trip_direction[row["trip_id"]] = int(row["direction_id"] or 0)
    f.close()

    # Stop times: stop -> modes, plus Luas trip patterns
    stop_modes = defaultdict(set)
    stop_routes = defaultdict(set)  # stop_id -> {(route_id, direction_id)}
    luas_trips = defaultdict(list)  # trip_id -> [(seq, stop_id, arrival_secs)]
    print("Scanning stop_times.txt ...", file=sys.stderr)
    f, rows = open_csv(gtfs_dir, "stop_times.txt")
    for row in rows:
        rid = trip_route.get(row["trip_id"])
        if rid is None:
            continue
        mode = route_modes[rid]
        stop_modes[row["stop_id"]].add(mode)
        stop_routes[row["stop_id"]].add((rid, trip_direction[row["trip_id"]]))
        if mode == LUAS:
            luas_trips[row["trip_id"]].append(
                (int(row["stop_sequence"]), row["stop_id"], parse_time(row["arrival_time"]))
            )
    f.close()

    # Stops
    luas_abbrevs = fetch_luas_abbreviations()
    stops, stop_coords = [], {}
    f, rows = open_csv(gtfs_dir, "stops.txt")
    for row in rows:
        modes = stop_modes.get(row["stop_id"])
        if not modes:
            continue
        mode = min(modes, key=MODE_PRIORITY.get)
        lat, lon = round(float(row["stop_lat"]), 5), round(float(row["stop_lon"]), 5)
        stop_coords[row["stop_id"]] = (lat, lon)
        entry = {"i": row["stop_id"], "n": row["stop_name"], "c": row["stop_code"],
                 "la": lat, "lo": lon, "m": mode}
        if mode == LUAS:
            nearest = min(luas_abbrevs, key=lambda s: haversine_m(lat, lon, s[1], s[2]))
            if haversine_m(lat, lon, nearest[1], nearest[2]) < 250:
                entry["a"] = nearest[0]
        stops.append(entry)
    f.close()

    # Luas patterns: unique stop sequences with scheduled offsets from the first stop
    patterns, pattern_index, trip_patterns = [], {}, {}
    for trip_id, entries in luas_trips.items():
        entries.sort()
        key = (trip_route[trip_id], tuple(e[1] for e in entries))
        idx = pattern_index.get(key)
        if idx is None:
            t0 = entries[0][2]
            idx = pattern_index[key] = len(patterns)
            patterns.append({"r": key[0], "s": list(key[1]), "t": [e[2] - t0 for e in entries]})
        trip_patterns[trip_id] = idx

    # Line geometry: every distinct Luas/DART shape (branches like Saggart differ)
    wanted_shapes = defaultdict(set)
    for trip_id, rid in trip_route.items():
        if route_modes[rid] in (LUAS, DART):
            wanted_shapes[rid].add(trip_shape[trip_id])
    all_wanted = set().union(*wanted_shapes.values()) if wanted_shapes else set()
    shape_points = defaultdict(list)
    print("Scanning shapes.txt ...", file=sys.stderr)
    f, rows = open_csv(gtfs_dir, "shapes.txt")
    for row in rows:
        if row["shape_id"] in all_wanted:
            shape_points[row["shape_id"]].append(
                (int(row["shape_pt_sequence"]), float(row["shape_pt_lat"]), float(row["shape_pt_lon"]))
            )
    f.close()
    # Short workings and opposite directions retrace the same track, so keep a
    # shape only if a meaningful share of it lies off the track drawn so far.
    def cells(pts):
        return {(round(la * 500), round(lo * 300)) for la, lo in pts}  # ~200m grid

    lines = []
    for rid, shape_ids in wanted_shapes.items():
        drawn = set()
        dense = sorted((sorted(shape_points[s]) for s in shape_ids), key=len, reverse=True)
        for raw in dense:
            pts = [(round(la, 5), round(lo, 5)) for _, la, lo in raw]
            shape_cells = cells(pts)
            if len(pts) < 2 or len(shape_cells - drawn) < 0.2 * len(shape_cells):
                continue
            drawn |= shape_cells
            lines.append({"r": rid, "m": route_modes[rid], "n": routes[rid]["s"],
                          "p": [list(p) for p in simplify(pts)]})

    def dump(name, obj):
        path = os.path.join(out_dir, name)
        with open(path, "w", encoding="utf-8") as out:
            json.dump(obj, out, ensure_ascii=False, separators=(",", ":"))
        print(f"wrote {path} ({os.path.getsize(path) // 1024} KB)", file=sys.stderr)

    dump("stops.json", stops)
    dump("routes.json", routes)
    dump("lines.json", lines)
    dump("luas.json", {"patterns": patterns, "trips": trip_patterns})
    dump("stop_routes.json", {stop: sorted([r, d] for r, d in pairs) for stop, pairs in stop_routes.items()})

    counts = defaultdict(int)
    for s in stops:
        counts[s["m"]] += 1
    print(f"stops by mode: {dict(counts)}; luas patterns: {len(patterns)}, "
          f"luas trips: {len(trip_patterns)}, lines: {[l['n'] for l in lines]}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gtfs-dir", help="directory containing an extracted GTFS feed")
    parser.add_argument("--out-dir", default=OUT_DIR)
    args = parser.parse_args()
    if args.gtfs_dir:
        build(args.gtfs_dir, args.out_dir)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            build(download_gtfs(tmp), args.out_dir)


if __name__ == "__main__":
    main()

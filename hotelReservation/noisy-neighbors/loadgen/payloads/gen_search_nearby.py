#!/usr/bin/env python3
"""
Generate a randomized JSON array of search.Search/Nearby requests for ghz -D.

Distribution mirrors mixed-workload_type_1.lua:
    lat ~ U[37.783, 38.264]   (38.0235 +/- 0.2405)
    lon ~ U[-122.252, -121.927]  (-122.095 +/- ~0.16)
    inDate  ~ "2015-04-{09..23}"
    outDate ~ "2015-04-{10..24}"

Each request is independent (lua does not enforce outDate > inDate, and
search.Nearby / rate.GetRates do not validate the ordering, so identical
work is performed in either case -- HW counters are unbiased).

Usage: gen_search_nearby.py [count]   (default 5000)
"""
import json
import random
import sys


def make_request() -> dict:
    return {
        "lat": round(random.uniform(37.783, 38.264), 4),
        "lon": round(random.uniform(-122.252, -121.927), 4),
        "inDate":  f"2015-04-{random.randint(9, 23):02d}",
        "outDate": f"2015-04-{random.randint(10, 24):02d}",
    }


def main() -> None:
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    payload = [make_request() for _ in range(count)]
    json.dump(payload, sys.stdout, separators=(",", ":"))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Generate a randomized JSON array of profile.Profile/GetProfiles requests for
ghz -D.

Distribution mirrors the lua-driven fan-out into profile.GetProfiles:
    60% of lua /hotels traffic       -> ~5 hotelIds
        (search.Nearby returns up to maxSearchResults=5 from geo)
    40% of lua /recommendations path -> ~1 hotelId
        (recommendation extremum filters typically yield 1 hotel)
    locale always "en" (lua never sets it; frontend default is "en").

Each hotelId drawn uniformly from "1".."80" (matches the seeded MongoDB
hotel range and the 80-entry profile.s.hotelCache).

Usage: gen_profile_getprofiles.py [count]   (default 5000)
"""
import json
import random
import sys


def make_request() -> dict:
    if random.random() < 0.4:
        ids = [str(random.randint(1, 80))]
    else:
        ids = [str(random.randint(1, 80)) for _ in range(5)]
    return {"hotelIds": ids, "locale": "en"}


def main() -> None:
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    payload = [make_request() for _ in range(count)]
    json.dump(payload, sys.stdout, separators=(",", ":"))


if __name__ == "__main__":
    main()

"""
Step 1: Export all data from old mediBO Supabase project via REST API.
Saves medicines.json, pharmacy_profiles.json, orders.json in the same folder.
"""

import json
import urllib.request
import urllib.error
import os

OLD_URL = "https://qkcuoaqrpnmdnejzahdv.supabase.co"
OLD_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFrY3VvYXFycG5tZG5lanphaGR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkzNzk3NjYsImV4cCI6MjA5NDk1NTc2Nn0"
    ".IBj9QYmYjfaHYU40lfTvuTj8YO4Brz4P-6k7TWcM_hE"
)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BATCH = 1000


def fetch_all(table: str) -> list:
    rows = []
    offset = 0
    while True:
        url = (
            f"{OLD_URL}/rest/v1/{table}"
            f"?select=*&limit={BATCH}&offset={offset}"
        )
        req = urllib.request.Request(url, headers={
            "apikey": OLD_KEY,
            "Authorization": f"Bearer {OLD_KEY}",
            "Content-Type": "application/json",
        })
        try:
            with urllib.request.urlopen(req) as resp:
                batch = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            body = e.read().decode()
            raise RuntimeError(f"HTTP {e.code} fetching {table}: {body}") from e

        rows.extend(batch)
        print(f"  {table}: fetched {len(rows)} rows so far …")
        if len(batch) < BATCH:
            break
        offset += BATCH
    return rows


def save(table: str, rows: list):
    path = os.path.join(SCRIPT_DIR, f"{table}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2, default=str)
    print(f"  Saved {len(rows)} rows → {path}")


def main():
    for table in ("MEDICINE", "pharmacy_profiles", "orders", "contact_inquiries"):
        print(f"\nExporting {table} …")
        rows = fetch_all(table)
        save(table, rows)
        print(f"  DONE: {len(rows)} rows exported from {table}")


if __name__ == "__main__":
    main()

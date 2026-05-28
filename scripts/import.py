"""
Step 3: Import exported JSON data into new mediBO Supabase project.

Prerequisites:
  1. Run schema.sql in the new project's SQL editor first.
  2. Add NEW_SUPABASE_SERVICE_KEY to ~/mediBO/.env
     (Dashboard → Settings → API → service_role key)
  3. Run: python3 import.py

Never prints credentials to screen.
"""

import json
import os
import sys
import urllib.request
import urllib.error

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_FILE   = os.path.join(os.path.dirname(SCRIPT_DIR), ".env")
BATCH_SIZE = 500


# ── helpers ──────────────────────────────────────────────────────────────────

def load_env() -> dict:
    if not os.path.exists(ENV_FILE):
        sys.exit(f"ERROR: .env not found at {ENV_FILE}")
    env = {}
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def rest_insert(base_url: str, key: str, table: str, rows: list):
    url  = f"{base_url}/rest/v1/{table}"
    data = json.dumps(rows, ensure_ascii=False, default=str).encode("utf-8")
    req  = urllib.request.Request(
        url, data=data,
        headers={
            "apikey":        key,
            "Authorization": f"Bearer {key}",
            "Content-Type":  "application/json",
            "Prefer":        "return=minimal,resolution=ignore-duplicates",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise RuntimeError(f"HTTP {e.code} on {table}: {body}") from e


def load_json(name: str) -> list:
    path = os.path.join(SCRIPT_DIR, f"{name}.json")
    if not os.path.exists(path):
        print(f"  WARNING: {name}.json not found — skipping")
        return []
    with open(path) as f:
        return json.load(f)


def insert_table(base_url: str, key: str, table: str, rows: list):
    if not rows:
        print(f"  {table}: 0 rows — skipping")
        return
    total = 0
    for i in range(0, len(rows), BATCH_SIZE):
        batch = rows[i : i + BATCH_SIZE]
        rest_insert(base_url, key, table, batch)
        total += len(batch)
        print(f"  {table}: {total}/{len(rows)} rows inserted …", flush=True)
    print(f"  {table}: DONE — {total} rows")


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    env         = load_env()
    new_url     = env.get("NEW_SUPABASE_URL", "").rstrip("/")
    service_key = env.get("NEW_SUPABASE_SERVICE_KEY", "")

    if not new_url:
        sys.exit("ERROR: NEW_SUPABASE_URL missing from .env")
    if not service_key or service_key == "your-service-role-key-here":
        sys.exit(
            "ERROR: NEW_SUPABASE_SERVICE_KEY not set in .env\n"
            "       Get it from the Dashboard → Settings → API → service_role"
        )

    print(f"Target project: {new_url}\n")

    # MEDICINE — largest table, preserve existing id / _row_id
    medicine_rows = load_json("MEDICINE")
    insert_table(new_url, service_key, "MEDICINE", medicine_rows)

    # remaining tables (empty, but import any future data in the JSON files)
    for table in ("pharmacy_profiles", "orders", "contact_inquiries", "customers"):
        insert_table(new_url, service_key, table, load_json(table))

    # Compute max ids so the caller can reset sequences
    if medicine_rows:
        max_id     = max(r["id"]      for r in medicine_rows)
        max_row_id = max(r["_row_id"] for r in medicine_rows)
        print(
            "\n✔  Import complete!\n"
            "\nFinal step — reset MEDICINE sequences to avoid future ID conflicts.\n"
            "Run this SQL in the new project's SQL editor:\n"
            f"\n    SELECT setval('\"MEDICINE_id_seq\"',     {max_id});"
            f"\n    SELECT setval('\"MEDICINE__row_id_seq\"', {max_row_id});\n"
        )
    else:
        print("\n✔  Import complete!")


if __name__ == "__main__":
    main()

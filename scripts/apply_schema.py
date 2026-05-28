"""
Applies schema.sql to the new Supabase project using the Management API.
Requires a Personal Access Token (PAT) passed as SUPABASE_PAT env var.
Get one at: https://supabase.com/dashboard/account/tokens
"""

import json
import os
import sys
import urllib.request
import urllib.error

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
PROJECT_REF = "swojhmarmaijkshsbeih"
MGMT_API    = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"


def run_sql(pat: str, sql: str, label: str):
    data = json.dumps({"query": sql}).encode("utf-8")
    req  = urllib.request.Request(
        MGMT_API,
        data=data,
        headers={
            "Authorization": f"Bearer {pat}",
            "Content-Type":  "application/json",
            "User-Agent":    "supabase-cli/1.0",
            "Accept":        "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            print(f"  ✔  {label}")
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"  ✘  {label}: HTTP {e.code} — {body}", file=sys.stderr)
        sys.exit(1)


def split_statements(sql: str) -> list[tuple[str, str]]:
    """Split SQL file into (label, statement) pairs, skipping comments/blanks."""
    statements = []
    current    = []
    label      = ""

    for line in sql.splitlines():
        stripped = line.strip()
        if stripped.startswith("--"):
            if current:
                stmt = "\n".join(current).strip()
                if stmt:
                    statements.append((label or stmt[:60], stmt))
                current = []
            label = stripped.lstrip("- ").strip("─ ").strip()
            continue
        if stripped:
            current.append(line)
        elif current:
            stmt = "\n".join(current).strip()
            if stmt:
                statements.append((label or stmt[:60], stmt))
            current = []
            label   = ""

    if current:
        stmt = "\n".join(current).strip()
        if stmt:
            statements.append((label or stmt[:60], stmt))

    return statements


def main():
    pat = os.environ.get("SUPABASE_PAT", "").strip()
    if not pat:
        sys.exit(
            "ERROR: SUPABASE_PAT not set.\n"
            "Usage: SUPABASE_PAT=your-token python3 apply_schema.py\n"
            "Get a token at: https://supabase.com/dashboard/account/tokens"
        )

    schema_path = os.path.join(SCRIPT_DIR, "schema.sql")
    with open(schema_path) as f:
        sql = f.read()

    statements = split_statements(sql)
    print(f"Applying {len(statements)} SQL statements to project {PROJECT_REF} …\n")

    for label, stmt in statements:
        run_sql(pat, stmt, label)

    print("\nSchema applied successfully!")


if __name__ == "__main__":
    main()

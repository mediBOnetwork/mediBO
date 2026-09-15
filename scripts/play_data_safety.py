#!/usr/bin/env python3
"""Play Data safety — the ONE door that answers Play's form without a human.

    python3 scripts/play_data_safety.py submit --sa <key.json> --csv <labels.csv>
    python3 scripts/play_data_safety.py submit --sa <key.json> --csv - < labels.csv

WHY THIS EXISTS (CMD #2050)
Every other step of a mediBO release is scripted; the Data safety section was
the one place the lane still said "open the Console". androidpublisher v3 has a
single method for it —

    POST /androidpublisher/v3/applications/{package}/dataSafety
    { "safetyLabels": "<the Console's own CSV, verbatim>" }

— and it takes the SAME CSV the Console exports, so the source of truth stays
the export, not a JSON shape invented here.

WHAT IT DELIBERATELY DOES NOT DO
It never GENERATES a CSV. The call is an UPSERT over a LIVE, already-approved
listing: a plausible-looking CSV assembled from guesswork would silently replace
answers Google accepted. So this tool transmits a file somebody produced and
refuses to invent one — `--csv` is required and an empty body is rejected here,
before Play sees it.

FAIL LOUDLY, VERBATIM. Play's own response body is printed on any non-2xx, the
way play_publish.py and play_ops.py do. Nothing here logs the credential.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def _play_module():
    """Reuse play_publish.py's OAuth + client: one Play client in this repo."""
    spec = importlib.util.spec_from_file_location(
        "play_publish", os.path.join(_HERE, "play_publish.py")
    )
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("submit", help="upsert the Data safety labels from a CSV")
    s.add_argument("--sa", required=True, help="path to the Play service-account key")
    s.add_argument("--csv", required=True, help="CSV file, or - for stdin")
    args = ap.parse_args()

    play = _play_module()

    body = sys.stdin.read() if args.csv == "-" else open(args.csv, "r").read()
    if not body.strip():
        print("play_data_safety: refusing to submit an EMPTY safety-labels body — "
              "that would blank a live, approved declaration", file=sys.stderr)
        return 2

    client = play.Play(args.sa)
    url = f"{play.API}/applications/{play.PKG}/dataSafety"
    try:
        res = client._req(
            "POST", url, "applications.dataSafety",
            headers={"Content-Type": "application/json"},
            data=json.dumps({"safetyLabels": body}),
        )
    except play.PlayError as e:
        print(str(e), file=sys.stderr)
        print(json.dumps({"ok": False, "status": e.status, "body": e.body}))
        return 1

    print(json.dumps({"ok": True, "result": res}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

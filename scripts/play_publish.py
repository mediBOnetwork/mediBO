#!/usr/bin/env python3
"""Google Play Developer API client for mediBO — the whole publish, no console.

    python3 scripts/play_publish.py probe        --sa <key.json>
    python3 scripts/play_publish.py maxcode      --sa <key.json>
    python3 scripts/play_publish.py publish      --sa <key.json> --aab app.aab \
        --notes-file notes.txt [--track production] [--apk app.apk] [--draft]

CHANGE #280 — Om never uploads an AAB or types release notes by hand again.

WHY THIS FILE HAS NO GOOGLE SDK
`google-api-python-client` is a ~40 MB dependency tree on a disk-constrained
builder that already lost a build to a full disk. The Play API is plain REST and
the only hard part is the OAuth assertion, which PyJWT (already installed for the
runner) signs in four lines. So: requests + PyJWT, nothing else.

SECRETS HYGIENE
The service-account JSON is read from a chmod-600 file the caller owns and is
never echoed, never logged, never included in any error string. Errors print the
Play API's own response body VERBATIM (rule: "report any Play error verbatim") —
Play never echoes the credential back, only the request that used it.

FAIL LOUDLY
Every non-2xx from Play raises PlayError with the HTTP status and the raw body.
A duplicate versionCode, a wrong signing key and a rejected release all arrive
that way and stop the run with exit 1 — the pipeline never reports a success it
did not get.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

import jwt
import requests

PKG = "in.medibo.app"
AUD = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
API = "https://androidpublisher.googleapis.com/androidpublisher/v3"
UPLOAD = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3"
TIMEOUT = 600  # an AAB upload on a home-grade uplink is minutes, not seconds


class PlayError(RuntimeError):
    """A non-2xx from Play, carrying the response body verbatim."""

    def __init__(self, what: str, status: int, body: str):
        self.status = status
        self.body = body
        super().__init__(f"{what} → HTTP {status}\n{body}")


def access_token(sa_path: str) -> str:
    """Mint a Play-scoped OAuth token from the service-account key."""
    with open(sa_path, "r") as fh:
        sa = json.load(fh)
    if sa.get("type") != "service_account":
        raise SystemExit("play: credential is not a service_account key")
    now = int(time.time())
    assertion = jwt.encode(
        {
            "iss": sa["client_email"],
            "scope": SCOPE,
            "aud": AUD,
            "iat": now,
            "exp": now + 3600,
        },
        sa["private_key"],
        algorithm="RS256",
    )
    r = requests.post(
        AUD,
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        },
        timeout=60,
    )
    if r.status_code != 200:
        raise PlayError("oauth token exchange", r.status_code, r.text)
    return r.json()["access_token"]


class Play:
    def __init__(self, sa_path: str):
        self.tok = access_token(sa_path)
        self.edit_id: str | None = None

    # ── plumbing ────────────────────────────────────────────────────────────
    def _hdr(self, extra: dict | None = None) -> dict:
        h = {"Authorization": f"Bearer {self.tok}"}
        if extra:
            h.update(extra)
        return h

    def _req(self, method: str, url: str, what: str, **kw) -> dict:
        r = requests.request(method, url, headers=self._hdr(kw.pop("headers", None)),
                             timeout=kw.pop("timeout", TIMEOUT), **kw)
        if not (200 <= r.status_code < 300):
            raise PlayError(what, r.status_code, r.text)
        return r.json() if r.text.strip() else {}

    # ── edits ───────────────────────────────────────────────────────────────
    def open_edit(self) -> str:
        self.edit_id = self._req("POST", f"{API}/applications/{PKG}/edits",
                                 "edits.insert")["id"]
        return self.edit_id

    def delete_edit(self) -> None:
        if not self.edit_id:
            return
        try:
            requests.delete(f"{API}/applications/{PKG}/edits/{self.edit_id}",
                            headers=self._hdr(), timeout=60)
        except Exception:
            pass  # an abandoned edit expires on its own; never mask the real error
        self.edit_id = None

    def details(self) -> dict:
        return self._req("GET", f"{API}/applications/{PKG}/edits/{self.edit_id}/details",
                         "edits.details.get")

    # ── version discovery ───────────────────────────────────────────────────
    def known_version_codes(self) -> list[int]:
        """Every versionCode Play has ever accepted for this package.

        bundles.list + apks.list are the authoritative "never reuse this code"
        source — a code burned by a deleted draft is still burned.
        """
        codes: list[int] = []
        for kind in ("bundles", "apks"):
            got = self._req("GET",
                            f"{API}/applications/{PKG}/edits/{self.edit_id}/{kind}",
                            f"{kind}.list")
            codes += [int(x["versionCode"]) for x in got.get(kind, [])]
        for tr in self._req("GET",
                            f"{API}/applications/{PKG}/edits/{self.edit_id}/tracks",
                            "tracks.list").get("tracks", []):
            for rel in tr.get("releases", []):
                codes += [int(c) for c in rel.get("versionCodes", []) or []]
        return sorted(set(codes))

    def track(self, name: str) -> dict:
        return self._req("GET",
                         f"{API}/applications/{PKG}/edits/{self.edit_id}/tracks/{name}",
                         f"tracks.get({name})")

    # ── the publish itself ──────────────────────────────────────────────────
    def upload_bundle(self, path: str) -> int:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            r = requests.post(
                f"{UPLOAD}/applications/{PKG}/edits/{self.edit_id}/bundles?uploadType=media",
                headers=self._hdr({"Content-Type": "application/octet-stream",
                                   "Content-Length": str(size)}),
                data=fh, timeout=TIMEOUT)
        if not (200 <= r.status_code < 300):
            raise PlayError("bundles.upload", r.status_code, r.text)
        return int(r.json()["versionCode"])

    def set_track(self, track: str, code: int, notes: str, draft: bool = False) -> dict:
        body = {
            "track": track,
            "releases": [{
                "versionCodes": [str(code)],
                "status": "draft" if draft else "completed",
                "releaseNotes": [{"language": "en-US", "text": notes}],
            }],
        }
        return self._req(
            "PUT", f"{API}/applications/{PKG}/edits/{self.edit_id}/tracks/{track}",
            f"tracks.update({track})",
            headers={"Content-Type": "application/json"}, json=body)

    def commit(self) -> dict:
        # changesNotSentForReview=false → Play takes the release into review and,
        # once approved, rolls it out. Anything else would leave Om a manual step.
        out = self._req(
            "POST",
            f"{API}/applications/{PKG}/edits/{self.edit_id}:commit"
            "?changesNotSentForReview=false",
            "edits.commit")
        self.edit_id = None
        return out


def _emit(obj: dict) -> None:
    print(json.dumps(obj, indent=2, sort_keys=True))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["probe", "maxcode", "publish", "notes"])
    ap.add_argument("--sa", required=True, help="path to the service-account JSON")
    ap.add_argument("--aab")
    ap.add_argument("--notes-file")
    ap.add_argument("--code", help="versionCode to patch (notes)")
    ap.add_argument("--track", default="production")
    ap.add_argument("--draft", action="store_true",
                    help="stage the release without sending it for review")
    a = ap.parse_args()

    play = Play(a.sa)
    try:
        if a.cmd == "probe":
            play.open_edit()
            d = play.details()
            codes = play.known_version_codes()
            tracks = play._req(
                "GET", f"{API}/applications/{PKG}/edits/{play.edit_id}/tracks",
                "tracks.list")
            _emit({"ok": True, "package": PKG, "default_language": d.get("defaultLanguage"),
                   "contact_email": d.get("contactEmail"),
                   "known_version_codes": codes,
                   "highest_version_code": max(codes) if codes else 0,
                   "tracks": [{"track": t.get("track"),
                               "releases": [{"status": r.get("status"),
                                             "name": r.get("name"),
                                             "versionCodes": r.get("versionCodes")}
                                            for r in t.get("releases", [])]}
                              for t in tracks.get("tracks", [])]})
            play.delete_edit()
            return 0

        if a.cmd == "maxcode":
            play.open_edit()
            codes = play.known_version_codes()
            _emit({"ok": True, "highest_version_code": max(codes) if codes else 0,
                   "known_version_codes": codes,
                   "next_version_code": (max(codes) if codes else 0) + 1})
            play.delete_edit()
            return 0

        if a.cmd == "notes":
            # CHANGE #293 — rewrite the release notes of a versionCode Play
            # ALREADY has, without rebuilding or re-uploading anything. `publish`
            # takes its notes from the queued row, so a release that shipped with
            # the generic default can be given the real ones afterwards instead
            # of burning a version code to fix a sentence.
            if not a.notes_file or not a.code:
                raise SystemExit("notes needs --notes-file and --code")
            notes = open(a.notes_file).read().strip()
            if not notes:
                raise SystemExit("release notes are empty — refusing to patch")
            if len(notes) > 500:
                raise SystemExit(f"release notes are {len(notes)} chars; Play's limit is 500")
            play.open_edit()
            play.set_track(a.track, int(a.code), notes)
            committed = play.commit()
            play.open_edit()
            tr = play.track(a.track)
            play.delete_edit()
            _emit({"ok": True, "package": PKG, "track": a.track,
                   "version_code": int(a.code), "committed_edit": committed.get("id"),
                   "release_notes": notes, "track_state": tr})
            return 0

        # publish
        if not a.aab or not a.notes_file:
            raise SystemExit("publish needs --aab and --notes-file")
        notes = open(a.notes_file).read().strip()
        if not notes:
            raise SystemExit("release notes are empty — refusing to publish")
        if len(notes) > 500:  # Play's hard limit for a release-notes body
            raise SystemExit(f"release notes are {len(notes)} chars; Play's limit is 500")

        play.open_edit()
        code = play.upload_bundle(a.aab)
        play.set_track(a.track, code, notes, draft=a.draft)
        committed = play.commit()

        # Re-open a read-only edit to read back what Play now believes.
        play.open_edit()
        tr = play.track(a.track)
        play.delete_edit()
        _emit({"ok": True, "package": PKG, "track": a.track,
               "version_code": code, "committed_edit": committed.get("id"),
               "release_notes": notes,
               "track_state": tr})
        return 0
    except PlayError as e:
        play.delete_edit()
        print(json.dumps({"ok": False, "error": "play_api",
                          "status": e.status, "body": e.body}, indent=2),
              file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001 — the pipeline needs the real reason
        play.delete_edit()
        print(json.dumps({"ok": False, "error": type(e).__name__, "message": str(e)},
                         indent=2), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

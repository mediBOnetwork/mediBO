#!/usr/bin/env python3
"""Play track reads and promotions — the two verbs CHANGE #281 added.

    python3 scripts/play_ops.py tracks  --sa <key.json>
    python3 scripts/play_ops.py promote --sa <key.json> --code 25 \
        --from internal --to production --notes-file notes.txt [--fraction 0.1]

WHY A SECOND FILE
`play_publish.py` (#280) is the build-and-upload path: it takes an AAB and puts
it somewhere. #281 needs two verbs that touch no artifact at all —

  tracks   read what Play believes about every track (version, release status,
           staged-rollout fraction, notes). This is the ONLY source the app's
           per-track panel is allowed to render; nothing is inferred from our
           own queue.

  promote  move a versionCode Play ALREADY HAS from one track to another and
           submit it for review. No build, no upload, no new artifact — the
           bytes Om installed from internal testing are the bytes that go to
           production. That is the whole point of the button.

Both reuse the Play client in play_publish.py rather than re-implementing OAuth
and edits, so there is exactly one Play API client in this repo.

FAIL LOUDLY, VERBATIM. Every non-2xx from Play surfaces as PlayError and is
printed to stderr as Play's own response body — the pipeline never softens or
summarises a rejection. Nothing here logs or echoes the credential.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def _play_module():
    """Load play_publish.py as a module regardless of how this script was invoked."""
    spec = importlib.util.spec_from_file_location(
        "play_publish", os.path.join(_HERE, "play_publish.py"))
    if spec is None or spec.loader is None:  # pragma: no cover - install error
        raise SystemExit("play_ops: cannot load scripts/play_publish.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_pp = _play_module()
Play = _pp.Play
PlayError = _pp.PlayError
API = _pp.API
PKG = _pp.PKG

# The tracks worth showing. Play returns only tracks that have ever had a
# release, so a listing is authoritative about what exists.
KNOWN = ("internal", "alpha", "beta", "production")


def read_tracks(play: Play) -> list[dict]:
    """Every track Play knows, flattened to what the panel renders.

    A track can hold several releases (e.g. a completed one plus a draft); the
    one that matters to a reader is the newest non-draft, falling back to
    whatever is there. We keep the raw release list alongside so nothing is
    lost and the backend can always be taught to show more.
    """
    listing = play._req(
        "GET", f"{API}/applications/{PKG}/edits/{play.edit_id}/tracks", "tracks.list")
    out: list[dict] = []
    for tr in listing.get("tracks", []):
        rels = tr.get("releases", []) or []
        pick = next((r for r in rels if r.get("status") != "draft"), rels[0] if rels else None)
        codes = [str(c) for c in (pick or {}).get("versionCodes", []) or []]
        notes = ""
        for n in (pick or {}).get("releaseNotes", []) or []:
            if n.get("language") == "en-US":
                notes = n.get("text", "")
                break
        out.append({
            "track": tr.get("track"),
            "version_name": (pick or {}).get("name"),
            "version_codes": codes,
            "status": (pick or {}).get("status"),
            # Play omits userFraction on a full rollout; null means "everyone".
            "user_fraction": (None if (pick or {}).get("userFraction") is None
                              else str((pick or {}).get("userFraction"))),
            "release_notes": notes,
            "raw": tr,
        })
    return out


def promote(play: Play, code: int, to_track: str, notes: str,
            fraction: float | None = None, from_track: str | None = None) -> dict:
    """Put an existing versionCode onto another track and send it for review.

    The code must already be on Play — this refuses rather than silently
    creating a release for a bundle that was never uploaded, which is how a
    "promote" could quietly become "ship something nobody tested".
    """
    known = play.known_version_codes()
    if code not in known:
        raise SystemExit(
            f"play_ops: version code {code} is not on Play (known: {known}). "
            "Refusing to promote a bundle Play does not have.")

    if from_track:
        src = play.track(from_track)
        on_src = {int(c) for r in src.get("releases", []) or []
                  for c in (r.get("versionCodes") or [])}
        if code not in on_src:
            raise SystemExit(
                f"play_ops: version code {code} is not on the {from_track} track "
                f"(it has {sorted(on_src)}). Refusing to promote an untested build.")

    release: dict = {
        "versionCodes": [str(code)],
        "status": "inProgress" if fraction else "completed",
        "releaseNotes": [{"language": "en-US", "text": notes}],
    }
    if fraction:
        release["userFraction"] = float(fraction)

    play._req("PUT",
              f"{API}/applications/{PKG}/edits/{play.edit_id}/tracks/{to_track}",
              f"tracks.update({to_track})",
              headers={"Content-Type": "application/json"},
              json={"track": to_track, "releases": [release]})
    committed = play.commit()

    # Read back what Play now believes, rather than reporting what we asked for.
    play.open_edit()
    state = play.track(to_track)
    tracks = read_tracks(play)
    play.delete_edit()
    return {"ok": True, "package": PKG, "promoted": code, "track": to_track,
            "from_track": from_track, "committed_edit": committed.get("id"),
            "release_notes": notes, "track_state": state, "tracks": tracks}



# ── store listing text (CHANGE #644) ────────────────────────────────────────
# The Play listing is COPY, not code: it changes far more often than the app
# does and must never require a build, an AAB or a release to update. This is
# the whole edits.listings lane — read the default language, PATCH only the two
# description fields, commit, then re-read to prove what is live.
#
# PATCH, deliberately, not PUT: edits.listings.patch merges, so `title` and
# `video` keep whatever Play already holds. A PUT would blank every field this
# script did not name, which is exactly how a listing loses its promo video.

SHORT_MAX = 80
FULL_MAX = 4000


def default_language(play: Play) -> str:
    """The listing language Play treats as this app's default.

    edits.details.get is authoritative (`defaultLanguage`); the listings.list
    fallback exists only for the case where details omits it, and then the sole
    existing listing IS the default by definition.
    """
    lang = (play.details() or {}).get("defaultLanguage") or ""
    if lang:
        return lang
    langs = [l.get("language") for l in list_listings(play) if l.get("language")]
    if len(langs) == 1:
        return langs[0]
    raise SystemExit(
        "Play did not report a defaultLanguage and there are %d listings (%s) — "
        "refusing to guess which one to edit" % (len(langs), ", ".join(langs) or "none"))


def list_listings(play: Play) -> list[dict]:
    got = play._req("GET",
                    f"{API}/applications/{PKG}/edits/{play.edit_id}/listings",
                    "listings.list")
    return got.get("listings", []) or []


def get_listing(play: Play, lang: str) -> dict:
    return play._req("GET",
                     f"{API}/applications/{PKG}/edits/{play.edit_id}/listings/{lang}",
                     f"listings.get({lang})")


def patch_listing(play: Play, lang: str, short: str, full: str) -> dict:
    body = {"shortDescription": short, "fullDescription": full}
    return play._req("PATCH",
                     f"{API}/applications/{PKG}/edits/{play.edit_id}/listings/{lang}",
                     f"listings.patch({lang})",
                     headers={"Content-Type": "application/json"}, json=body)


def commit_listing(play: Play) -> tuple[dict, bool]:
    """Commit a text-only edit, and say whether Play took it into review.

    An edit that carries no app release cannot always be sent for review
    automatically; Play answers that with an explicit instruction to set
    changesNotSentForReview=true. We follow Play's own instruction rather than
    failing, and report which path was taken so the caller never has to guess
    whether a human still owes the console a click.
    """
    edit_id = play.edit_id
    try:
        out = play._req(
            "POST",
            f"{API}/applications/{PKG}/edits/{edit_id}:commit"
            "?changesNotSentForReview=false",
            "edits.commit")
        play.edit_id = None
        return out, True
    except PlayError as e:
        if "changesNotSentForReview" not in (e.body or ""):
            raise
        play.edit_id = edit_id
        out = play._req(
            "POST",
            f"{API}/applications/{PKG}/edits/{edit_id}:commit"
            "?changesNotSentForReview=true",
            "edits.commit(changesNotSentForReview=true)")
        play.edit_id = None
        return out, False


def update_listing(play: Play, short: str, full: str,
                   lang: str | None = None) -> dict:
    """insert -> list -> patch -> commit -> get. Returns what is LIVE, re-read."""
    if len(short) > SHORT_MAX:
        raise SystemExit(f"shortDescription is {len(short)} chars; Play's limit is {SHORT_MAX}")
    if len(full) > FULL_MAX:
        raise SystemExit(f"fullDescription is {len(full)} chars; Play's limit is {FULL_MAX}")
    if not short.strip() or not full.strip():
        raise SystemExit("refusing to write an empty description to the Play listing")

    play.open_edit()
    edit_id = play.edit_id
    languages = [l.get("language") for l in list_listings(play)]
    lang = lang or default_language(play)
    before = get_listing(play, lang)
    patch_listing(play, lang, short, full)
    committed, sent_for_review = commit_listing(play)

    # Verify against a FRESH edit: the committed one is gone, and reading back
    # through a new edit is the only way to see what Play actually stored.
    play.open_edit()
    live = get_listing(play, lang)
    play.delete_edit()

    return {
        "ok": True,
        "package": PKG,
        "language": lang,
        "languages": languages,
        "edit_id": edit_id,
        "committed_edit": committed.get("id") or edit_id,
        "sent_for_review": sent_for_review,
        "before": {"shortDescription": before.get("shortDescription", ""),
                   "fullDescription": before.get("fullDescription", "")},
        "live": live,
        # Proof the write is the text we asked for, not merely a 200.
        "verified": (live.get("shortDescription") == short
                     and live.get("fullDescription") == full),
        # Untouched by this lane, echoed so a regression is visible.
        "title": live.get("title"),
        "video": live.get("video"),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["tracks", "promote", "listing"])
    ap.add_argument("--sa", required=True)
    ap.add_argument("--code", type=int)
    ap.add_argument("--to", dest="to_track", default="production")
    ap.add_argument("--from", dest="from_track", default=None)
    ap.add_argument("--notes-file")
    ap.add_argument("--fraction", type=float, default=None,
                    help="staged rollout fraction; omitted = full rollout")
    ap.add_argument("--short-file", help="listing: file holding the shortDescription")
    ap.add_argument("--full-file", help="listing: file holding the fullDescription")
    ap.add_argument("--language", default=None,
                    help="listing: override the language; default = Play's defaultLanguage")
    a = ap.parse_args()

    play = Play(a.sa)
    try:
        if a.cmd == "tracks":
            play.open_edit()
            out = read_tracks(play)
            play.delete_edit()
            print(json.dumps({"ok": True, "tracks": out}, indent=2, sort_keys=True))
            return 0

        if a.cmd == "listing":
            # No text given = read-only: report the languages and what is live.
            if not a.short_file and not a.full_file:
                play.open_edit()
                lang = a.language or default_language(play)
                out = {"ok": True, "package": PKG, "language": lang,
                       "languages": [l.get("language") for l in list_listings(play)],
                       "live": get_listing(play, lang)}
                play.delete_edit()
                print(json.dumps(out, indent=2, sort_keys=True))
                return 0
            if not (a.short_file and a.full_file):
                raise SystemExit("listing needs BOTH --short-file and --full-file")
            short = open(a.short_file, encoding="utf-8").read().strip()
            full = open(a.full_file, encoding="utf-8").read().strip()
            out = update_listing(play, short, full, a.language)
            print(json.dumps(out, indent=2, sort_keys=True))
            return 0 if out["verified"] else 1

        if not a.code or not a.notes_file:
            raise SystemExit("promote needs --code and --notes-file")
        notes = open(a.notes_file).read().strip()
        if not notes:
            raise SystemExit("release notes are empty — refusing to promote")
        if len(notes) > 500:
            raise SystemExit(f"release notes are {len(notes)} chars; Play's limit is 500")

        play.open_edit()
        out = promote(play, a.code, a.to_track, notes, a.fraction, a.from_track)
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0
    except PlayError as e:
        play.delete_edit()
        print(json.dumps({"ok": False, "error": "play_api",
                          "status": e.status, "body": e.body}, indent=2), file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001 — the pipeline needs the real reason
        play.delete_edit()
        print(json.dumps({"ok": False, "error": type(e).__name__, "message": str(e)},
                         indent=2), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

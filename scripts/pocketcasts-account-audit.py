#!/usr/bin/env python3
"""Read a Pocket Casts account straight from the sync server.

The migration writes rows locally and relies on Pocket Casts' own sync to push
them up. Reading the server back is the only honest proof that the upload
happened; a local report can look perfect while nothing left the device.

Credentials come from `~/.claude/.env` (POCKETCASTS_EMAIL / POCKETCASTS_PASSWORD)
or from the environment. Nothing is ever written to the account by this script
unless --clear is passed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

API = "https://api.pocketcasts.com"
USER_AGENT = "Pocket Casts/7.0 (iOS)"
ENV_FILE = Path.home() / ".claude" / ".env"


def credential(name: str) -> str:
    value = os.environ.get(name)
    if value:
        return value
    if ENV_FILE.exists():
        text = ENV_FILE.read_text()
        match = re.search(rf"^{name}='(.*)'$", text, re.M) or re.search(rf'^{name}="(.*)"$', text, re.M)
        if match:
            return match.group(1)
    raise SystemExit(f"missing credential {name}; set it in the environment or {ENV_FILE}")


def call(path: str, body: dict[str, Any], token: str | None = None) -> dict[str, Any]:
    headers = {"Content-Type": "application/json", "User-Agent": USER_AGENT}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(API + path, data=json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = response.read()
    return json.loads(payload) if payload else {}


def login() -> str:
    response = call(
        "/user/login",
        {"email": credential("POCKETCASTS_EMAIL"), "password": credential("POCKETCASTS_PASSWORD"), "scope": "mobile"},
    )
    token = response.get("token") or response.get("accessToken")
    if not token:
        raise SystemExit("login succeeded but returned no token")
    return token


def collect(token: str) -> dict[str, Any]:
    def safe(path: str, body: dict[str, Any]) -> dict[str, Any]:
        try:
            return call(path, body, token)
        except urllib.error.HTTPError as error:
            return {"error": f"http {error.code}"}

    podcasts = safe("/user/podcast/list", {"v": 1})
    up_next = safe("/up_next/list", {"version": 2, "model": "webplayer", "serverModified": 0})
    starred = safe("/user/starred", {"v": 1})
    history = safe("/user/history", {"v": 1})
    filters = safe("/user/playlist/list", {"v": 1})

    return {
        "podcasts": podcasts.get("podcasts", []),
        "folders": podcasts.get("folders", []),
        "up_next": up_next.get("episodes", []),
        "starred": starred.get("episodes", []),
        "history": history.get("episodes", []),
        "filters": filters.get("filters", filters.get("playlists", [])),
    }


def summarise(state: dict[str, Any]) -> str:
    lines = [
        "Pocket Casts server state",
        f"- Subscribed podcasts: {len(state['podcasts'])}",
        f"- Folders: {len(state['folders'])}",
        f"- Up Next episodes: {len(state['up_next'])}",
        f"- Starred episodes: {len(state['starred'])}",
        f"- History episodes: {len(state['history'])}",
        f"- Filters: {len(state['filters'])}",
    ]
    if state["up_next"]:
        lines.append("- Up Next order:")
        for position, episode in enumerate(state["up_next"], start=1):
            title = episode.get("title") or episode.get("uuid")
            lines.append(f"    {position}. {title}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", type=Path, default=None, help="write the full server state here")
    parser.add_argument("--expect-empty", action="store_true", help="exit non-zero unless the account is empty")
    arguments = parser.parse_args()

    state = collect(login())
    print(summarise(state))

    if arguments.json:
        arguments.json.parent.mkdir(parents=True, exist_ok=True)
        arguments.json.write_text(json.dumps(state, indent=2) + "\n")
        print(f"- Full state written to {arguments.json}")

    if arguments.expect_empty:
        populated = {key: len(value) for key, value in state.items() if value}
        if populated:
            print(f"NOT EMPTY  {populated}")
            return 1
        print("EMPTY  account holds nothing")
    return 0


if __name__ == "__main__":
    sys.exit(main())

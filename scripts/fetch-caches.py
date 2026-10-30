#!/usr/bin/env python3
"""Download RuneScape caches from the OpenRS2 archive.

Python 3 standard library only - this is the fallback used by
`install.sh --binary`, where Node.js is not available. `repo/scripts/fetch-cache.mjs`
is the original version used when the viewer source is checked out.

  scripts/fetch-caches.py                  # newest OSRS + the Feb-2005 cache
  scripts/fetch-caches.py --only rs2-295   # one cache, useful for testing
  scripts/fetch-caches.py --dir /tmp/c     # somewhere other than ./repo/caches

Layout written (same as the Node version):

  <dir>/caches.json
  <dir>/osrs-241_2026-10-28/main_file_cache.dat2, idx*, info.json, keys.json
  <dir>/rs2-295_2005-02-21/main_file_cache.dat, idx*, info.json, keys.json
"""

import argparse
import io
import json
import os
import shutil
import sys
import urllib.error
import urllib.request
import zipfile

ARCHIVE_URL = "https://archive.openrs2.org/caches.json"
DEFAULT_PREFIXES = ["osrs-", "rs2-295"]


def human_size(num):
    value = float(num)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} GiB"


def cache_dir_name(cache):
    """Archive directory name, identical to repo/scripts/fetch-cache.mjs."""
    major = cache["builds"][0]["major"]
    date = cache["timestamp"].split("T")[0]
    if cache["game"] == "oldschool":
        if cache.get("environment") == "beta":
            return f"osrs-beta-{major}_{date}"
        return f"osrs-{major}_{date}"
    language = cache.get("language") or "en"
    suffix = "" if language == "en" else f"-{language}"
    return f"rs2-{major}{suffix}_{date}"


def is_complete(cache):
    if not cache.get("indexes"):
        return False
    return cache["valid_indexes"] == cache["indexes"] and cache["valid_groups"] / cache["groups"] >= 0.9


def is_usable(cache):
    """Filter used when writing caches.json (mirrors createCacheList())."""
    if not cache.get("builds") or not is_complete(cache):
        return False
    if cache.get("language") != "en":
        return False
    revision = cache["builds"][0]["major"]
    if cache.get("game") == "runescape" and (revision < 186 or revision > 740):
        return False
    return revision != 311


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "osrs-map-screensaver"})
    with urllib.request.urlopen(request) as response:
        length = response.headers.get("Content-Length")
        return response.read(), int(length) if length else None


def fetch_with_progress(url, label):
    print(f"  downloading {label}…", flush=True)
    request = urllib.request.Request(url, headers={"User-Agent": "osrs-map-screensaver"})
    chunks = []
    with urllib.request.urlopen(request) as response:
        total = int(response.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            chunks.append(chunk)
            done += len(chunk)
            if total:
                percent = done * 100 // total
                print(f"\r    {percent:3d}%  {human_size(done)} / {human_size(total)}", end="", flush=True)
    print()
    return b"".join(chunks)


def extract_cache_zip(payload, destination):
    """The archive ships a `cache/` directory; the viewer wants its contents."""
    os.makedirs(destination, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        for name in archive.namelist():
            if not name.startswith("cache/") or name.endswith("/"):
                continue
            relative = name[len("cache/"):]
            target = os.path.join(destination, relative)
            parent = os.path.dirname(target)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with archive.open(name) as source, open(target, "wb") as out:
                shutil.copyfileobj(source, out)


def install_cache(cache, caches_dir):
    name = cache_dir_name(cache)
    directory = os.path.join(caches_dir, name)
    if os.path.exists(os.path.join(directory, "info.json")):
        print(f"  already have {name}")
        return

    url = f"https://archive.openrs2.org/caches/{cache['scope']}/{cache['id']}"
    extract_cache_zip(fetch_with_progress(f"{url}/disk.zip", name), directory)

    keys, _ = fetch(f"{url}/keys.json")
    xteas = {str(entry["group"]): entry["key"] for entry in json.loads(keys)}
    with open(os.path.join(directory, "keys.json"), "w", encoding="utf8") as handle:
        json.dump(xteas, handle)

    with open(os.path.join(directory, "info.json"), "w", encoding="utf8") as handle:
        json.dump(cache, handle)

    maps = os.path.join(directory, "maps")
    if os.path.isdir(maps):
        names = [n for n in os.listdir(maps) if n.startswith(("m", "l"))]
        with open(os.path.join(directory, "maps.json"), "w", encoding="utf8") as handle:
            json.dump(names, handle)

    print(f"  ok {name} ({cache['game']} rev {cache['builds'][0]['major']}, {human_size(cache['size'])})")


def write_cache_list(caches_dir):
    entries = []
    for name in sorted(os.listdir(caches_dir)) if os.path.isdir(caches_dir) else []:
        directory = os.path.join(caches_dir, name)
        info_path = os.path.join(directory, "info.json")
        if not os.path.isdir(directory) or not os.path.exists(info_path):
            continue
        with open(info_path, encoding="utf8") as handle:
            info = json.load(handle)
        if not is_usable(info):
            print(f"  skipping {name} (not usable by the viewer)")
            continue
        entries.append(
            {
                "name": name,
                "game": info["game"],
                "environment": info.get("environment"),
                "revision": info["builds"][0]["major"],
                "timestamp": info["timestamp"],
                "size": info["size"],
            }
        )

    with open(os.path.join(caches_dir, "caches.json"), "w", encoding="utf8") as handle:
        json.dump(entries, handle)

    print(f"  wrote {os.path.join(caches_dir, 'caches.json')} with {len(entries)} cache(s)")
    return entries


def main():
    parser = argparse.ArgumentParser(description="Download RuneScape caches from OpenRS2.")
    parser.add_argument("prefixes", nargs="*", default=None, help="archive name prefixes, e.g. osrs- rs2-295")
    parser.add_argument("--only", action="append", metavar="PREFIX")
    parser.add_argument("--dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "repo", "caches"))
    arguments = parser.parse_args()

    prefixes = arguments.only or arguments.prefixes or DEFAULT_PREFIXES
    caches_dir = os.path.abspath(arguments.dir)
    os.makedirs(caches_dir, exist_ok=True)

    print("Fetching archive index…")
    try:
        payload, _ = fetch(ARCHIVE_URL)
    except urllib.error.URLError as error:
        print(f"error: cannot reach {ARCHIVE_URL}: {error}", file=sys.stderr)
        return 1
    archive = json.loads(payload)

    candidates = [
        cache
        for cache in archive
        if cache.get("scope") == "runescape"
        and cache.get("language") == "en"
        and cache.get("builds")
        and cache.get("timestamp")
        and is_complete(cache)
    ]

    for prefix in prefixes:
        matches = sorted(
            (c for c in candidates if cache_dir_name(c).startswith(prefix)),
            key=lambda c: c["timestamp"],
            reverse=True,
        )
        if not matches:
            print(f"warning: no cache matches {prefix!r}", file=sys.stderr)
            continue
        install_cache(matches[0], caches_dir)

    write_cache_list(caches_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())

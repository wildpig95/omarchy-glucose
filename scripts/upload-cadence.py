#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# upload-cadence - watch how often the Libre cloud actually receives data.
#
# Reads the widget's own cache (~/.local/state/glucose/last.json) instead of
# calling Abbott, so running this costs nothing and cannot get an account
# rate-limited. Every time the newest reading advances it logs a line:
#
#   <wall clock>  newest=<reading time>  lag=<minutes behind>  +<minutes since last>
#
# A healthy feed shows lag under ~20 minutes. A lag that grows for hours while
# the app is running means the primary app is not uploading, not that the
# widget is broken.
#
# Usage: upload-cadence.py [--interval 60] [--log PATH] [--once]

import argparse
import json
import os
import sys
import time
from datetime import datetime

DEFAULT_CACHE = "~/.local/state/glucose/last.json"
DEFAULT_LOG = "~/.local/state/glucose/cadence.log"


def read_cache(path):
    try:
        with open(os.path.expanduser(path), "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def stamp(epoch):
    return datetime.fromtimestamp(int(epoch)).strftime("%H:%M")


def main(argv):
    parser = argparse.ArgumentParser(description="Log the Libre cloud upload cadence.")
    parser.add_argument("--cache", default=DEFAULT_CACHE)
    parser.add_argument("--log", default=DEFAULT_LOG)
    parser.add_argument("--interval", type=int, default=60)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args(argv)

    log_path = os.path.expanduser(args.log)
    os.makedirs(os.path.dirname(log_path), exist_ok=True)

    last_newest = None
    while True:
        payload = read_cache(args.cache)
        now = int(time.time())
        if payload and payload.get("series"):
            series = payload["series"]
            newest = int(series[-1]["t"])
            if newest != last_newest:
                previous_gap = ""
                if last_newest is not None:
                    previous_gap = "  +%dm since last" % round((newest - last_newest) / 60)
                lag = round((now - newest) / 60)
                line = "%s  newest=%s  lag=%4dm  points=%d%s" % (
                    datetime.now().strftime("%m-%d %H:%M"), stamp(newest), lag, len(series), previous_gap)
                print(line, flush=True)
                with open(log_path, "a", encoding="utf-8") as handle:
                    handle.write(line + "\n")
                last_newest = newest
        elif payload and payload.get("ok") is False:
            print("%s  fetch error: %s" % (datetime.now().strftime("%m-%d %H:%M"), payload.get("error")), flush=True)

        if args.once:
            return 0
        time.sleep(max(15, args.interval))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

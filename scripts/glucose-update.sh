#!/usr/bin/env bash
# glucose-update.sh — keep the omarchy-glucose plugin current.
#
# Fast-forward only (never rewrites or merges your local work), and reloads the
# shell only when HEAD actually moved. Point a systemd user timer or cron at it:
#
#   ~/.config/systemd/user/glucose-update.timer   (see README)
#
# Safe to run by hand too.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PLUGIN_DIR"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "glucose-update: $PLUGIN_DIR is not a git checkout, nothing to do" >&2
  exit 0
fi

before="$(git rev-parse HEAD)"

if ! git fetch --quiet origin 2>/dev/null; then
  echo "glucose-update: fetch failed (offline?), keeping $(git rev-parse --short HEAD)" >&2
  exit 0
fi

if ! git merge --ff-only '@{u}' --quiet 2>/dev/null; then
  echo "glucose-update: not a fast-forward (local changes or diverged); leaving as is" >&2
  exit 0
fi

after="$(git rev-parse HEAD)"
if [ "$before" = "$after" ]; then
  echo "glucose-update: already up to date ($(git rev-parse --short HEAD))"
  exit 0
fi

echo "glucose-update: $before -> $after"
# Hot-reload the plugin code. Harmless if the shell is not running.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

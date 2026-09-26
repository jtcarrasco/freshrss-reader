#!/bin/bash
# The DMS plugin (dms/) ships its own copies of the shell-independent files so
# it can be installed on its own. Run this after changing any of them; the
# test suite fails if the copies drift.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dms/scripts
for f in Model.js scripts/freshrss_backend.py; do
  cp "$f" "dms/$f"
done
echo "synced shared files into dms/"

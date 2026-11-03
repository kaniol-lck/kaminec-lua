#!/bin/sh
# Usage: ./start.sh [lua5.4] [launcher-root]
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LUA=${1:-lua5.4}
ROOT=${2:-.minecraft}
exec "$LUA" "$HERE/server.lua" --dir "$ROOT" --port 8766 --open

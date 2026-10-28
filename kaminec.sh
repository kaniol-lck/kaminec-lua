#!/bin/sh
# Kaminec-Lua launcher wrapper (POSIX).
# Requires Lua 5.4 as lua5.4 or lua on PATH, or set LUA.
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${LUA:-}" ]; then
    :
elif command -v lua5.4 >/dev/null 2>&1; then
    LUA=lua5.4
elif command -v lua >/dev/null 2>&1; then
    LUA=lua
else
    echo "[Kaminec] Lua 5.4 not found. Install lua5.4 or set LUA." >&2
    exit 1
fi

exec "$LUA" "$DIR/src/main.lua" "$@"

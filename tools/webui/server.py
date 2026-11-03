#!/usr/bin/env python3
"""Lightweight localhost WebUI for Kaminec-Lua.

Python 3 standard library only. The UI is static HTML/JS; all real work is
delegated to the Lua CLI via subprocess argv (never a shell).

    python tools/webui/server.py --dir D:/dev/kaminec-spike/.minecraft
    python tools/webui/server.py --dir .minecraft --port 8765 --open

The server binds 127.0.0.1 only and requires a per-run token for API calls.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import webbrowser
from collections import deque
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

WEB_DIR = Path(__file__).resolve().parent
REPO_ROOT = WEB_DIR.parent.parent
MAIN_LUA = REPO_ROOT / "src" / "main.lua"
PUBLIC_DIR = WEB_DIR / "public"

PROFILE_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
VERSION_RE = re.compile(r"^[A-Za-z0-9._+-]+$")

JOBS: dict[str, "Job"] = {}
JOBS_LOCK = threading.Lock()


def find_lua(explicit: str | None) -> str:
    if explicit:
        path = Path(explicit)
        if path.exists():
            return str(path)
        raise FileNotFoundError(f"Lua executable not found: {explicit}")
    env = os.environ.get("LUA")
    if env and Path(env).exists():
        return env
    for name in ("lua5.4", "lua54", "lua", "lua.exe"):
        found = shutil.which(name)
        if found:
            return found
    raise FileNotFoundError("Lua 5.4 not found; pass --lua <path>")


class Job:
    """A single CLI subprocess with a bounded output buffer."""

    def __init__(self, argv: list[str], cwd: Path):
        self.argv = argv
        self.started_at = time.time()
        self.returncode: int | None = None
        self.error: str | None = None
        self.output: deque[str] = deque(maxlen=500)
        self.lock = threading.Lock()
        try:
            self.proc = subprocess.Popen(
                argv,
                cwd=str(cwd),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )
        except OSError as exc:
            self.proc = None
            self.error = str(exc)
            self.returncode = -1
            return
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self) -> None:
        assert self.proc is not None and self.proc.stdout is not None
        for line in self.proc.stdout:
            with self.lock:
                self.output.append(line.rstrip("\r\n"))
        self.returncode = self.proc.wait()

    @property
    def status(self) -> str:
        if self.error:
            return "failed"
        if self.returncode is None:
            return "running"
        return "done" if self.returncode == 0 else "failed"

    def as_dict(self) -> dict[str, Any]:
        with self.lock:
            output = list(self.output)
        return {
            "status": self.status,
            "returncode": self.returncode,
            "error": self.error,
            "elapsed": round(time.time() - self.started_at, 1),
            "output": output,
        }


def load_profiles(root: Path) -> dict[str, Any]:
    path = root / "profiles.json"
    if not path.exists():
        return {"root": str(root), "profiles": [], "error": "profiles.json not found"}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return {"root": str(root), "profiles": [], "error": f"invalid profiles.json: {exc}"}
    profiles = []
    raw = data.get("profiles") or {}
    if isinstance(raw, dict):
        for pid, profile in raw.items():
            if not isinstance(profile, dict):
                continue
            profiles.append(
                {
                    "id": pid,
                    "name": profile.get("name") or pid,
                    "version": profile.get("version") or "",
                    "root": profile.get("root") or str(root),
                    "game_dir": profile.get("game_dir") or "",
                    "external": bool(profile.get("external")),
                    "settings": profile.get("settings") or {},
                }
            )
    profiles.sort(key=lambda p: str(p["name"]).lower())
    return {"root": str(root), "profiles": profiles}


class Handler(BaseHTTPRequestHandler):
    server_version = "KaminecWebUI/0.1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        if not self.server.quiet:  # type: ignore[attr-defined]
            sys.stderr.write("[webui] " + fmt % args + "\n")

    @property
    def root(self) -> Path:
        return self.server.launcher_root  # type: ignore[attr-defined]

    @property
    def token(self) -> str:
        return self.server.token  # type: ignore[attr-defined]

    @property
    def lua(self) -> str:
        return self.server.lua  # type: ignore[attr-defined]

    def _token_ok(self) -> bool:
        supplied = self.headers.get("X-WebUI-Token", "")
        if not supplied:
            query = urllib.parse.urlparse(self.path).query
            supplied = urllib.parse.parse_qs(query).get("token", [""])[0]
        return secrets.compare_digest(supplied, self.token)

    def _send_json(self, value: Any, status: int = 200) -> None:
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path: Path) -> None:
        try:
            path = path.resolve()
            path.relative_to(PUBLIC_DIR.resolve())
            data = path.read_bytes()
        except (OSError, ValueError):
            self._send_json({"error": "not found"}, 404)
            return
        ctype = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 64 * 1024:
            return {}
        raw = self.rfile.read(length)
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return {}
        return value if isinstance(value, dict) else {}

    def _cli(self, args: list[str]) -> Job:
        job = Job([self.lua, str(MAIN_LUA), *args], cwd=REPO_ROOT)
        job_id = secrets.token_hex(8)
        with JOBS_LOCK:
            JOBS[job_id] = job
            # keep only a small recent history
            if len(JOBS) > 50:
                for old in list(JOBS)[: len(JOBS) - 50]:
                    JOBS.pop(old, None)
        setattr(job, "job_id", job_id)
        return job

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path.startswith("/api/"):
            if not self._token_ok():
                self._send_json({"error": "invalid token"}, 401)
                return
        if parsed.path in ("/", "/index.html"):
            self._send_file(PUBLIC_DIR / "index.html")
            return
        if parsed.path == "/api/state":
            self._send_json(load_profiles(self.root))
            return
        if parsed.path == "/api/java":
            job = self._cli(["java", "list"])
            self._send_json({"job": getattr(job, "job_id", "")})
            return
        if parsed.path.startswith("/api/jobs/"):
            job_id = parsed.path.rsplit("/", 1)[-1]
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if not job:
                self._send_json({"error": "job not found"}, 404)
                return
            self._send_json(job.as_dict())
            return
        # static asset
        relative = parsed.path.lstrip("/")
        if relative and ".." not in Path(relative).parts:
            candidate = PUBLIC_DIR / relative
            if candidate.is_file():
                self._send_file(candidate)
                return
        self._send_json({"error": "not found"}, 404)

    def do_POST(self) -> None:
        if not self._token_ok():
            self._send_json({"error": "invalid token"}, 401)
            return
        parsed = urllib.parse.urlparse(self.path)
        body = self._read_json()
        if parsed.path == "/api/action":
            action = str(body.get("action", ""))
            profile_id = str(body.get("profile", ""))
            if action not in ("download", "launch"):
                self._send_json({"error": "action must be download or launch"}, 400)
                return
            if not PROFILE_ID_RE.match(profile_id):
                self._send_json({"error": "invalid profile id"}, 400)
                return
            state = load_profiles(self.root)
            known = {p["id"] for p in state["profiles"]}
            if profile_id not in known:
                self._send_json({"error": "unknown profile"}, 404)
                return
            job = self._cli([action, "--profile", profile_id, "--dir", str(self.root)])
            self._send_json({"job": getattr(job, "job_id", "")})
            return
        if parsed.path == "/api/profile":
            version = str(body.get("version", "")).strip()
            name = str(body.get("name", "")).strip()
            if not VERSION_RE.match(version):
                self._send_json({"error": "invalid version"}, 400)
                return
            args = ["profile", "create", version, "--dir", str(self.root)]
            if name:
                args.extend(["--name", name])
            args.append("--java-auto")
            job = self._cli(args)
            self._send_json({"job": getattr(job, "job_id", "")})
            return
        self._send_json({"error": "not found"}, 404)


def main() -> int:
    parser = argparse.ArgumentParser(description="Kaminec-Lua lightweight WebUI")
    parser.add_argument("--dir", default=".minecraft", help="launcher root containing profiles.json")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--lua", help="path to Lua 5.4 executable")
    parser.add_argument("--token", help="fixed API token (default: random)")
    parser.add_argument("--open", action="store_true", help="open the browser")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    if not MAIN_LUA.is_file():
        raise SystemExit(f"src/main.lua not found: {MAIN_LUA}")
    root = Path(args.dir).expanduser().resolve()
    if not root.is_dir():
        raise SystemExit(f"launcher root not found: {root}")
    lua = find_lua(args.lua)
    token = args.token or secrets.token_urlsafe(18)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.launcher_root = root  # type: ignore[attr-defined]
    server.token = token  # type: ignore[attr-defined]
    server.lua = lua  # type: ignore[attr-defined]
    server.quiet = args.quiet  # type: ignore[attr-defined]
    url = f"http://127.0.0.1:{args.port}/?token={urllib.parse.quote(token)}"

    print("Kaminec-Lua WebUI")
    print(f"  root:  {root}")
    print(f"  lua:   {lua}")
    print(f"  url:   {url}")
    print("  bind:  127.0.0.1 only; Ctrl+C to stop")
    if args.open:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        server.shutdown()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

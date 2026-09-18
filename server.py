#!/usr/bin/env python3
"""
EagleCraft web platform — pure stdlib (no pip installs needed).

What it does:
  * Serves the website + the Eaglercraft browser client.
  * Login / register system (PBKDF2-hashed passwords, signed session cookies).
  * Account-synced worlds: upload your .epk world export to your account and
    download it on any device after login.
  * "Host your own server" panel: create / start / stop SMP game servers.

Low-latency design:
  * Game traffic does NOT pass through this web app. Each game server listens on
    its OWN WebSocket port and gets its OWN dev tunnel, so player packets go
    straight to the Java server (no extra proxy hop).
  * Every socket we open sets TCP_NODELAY (Nagle off).

Run:  python3 server.py            (defaults to port 8080)
      PORT=9000 python3 server.py
"""

import http.server
import socketserver
import socket
import sqlite3
import json
import os
import sys
import re
import hmac
import hashlib
import secrets
import time
import uuid
import subprocess
import shutil
import threading
from collections import deque
import posixpath
from urllib.parse import urlparse, parse_qs, unquote

ROOT = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.join(ROOT, "web")
DATA = os.path.join(ROOT, "data")
WORLDS_DIR = os.path.join(DATA, "worlds")
SERVERS_DIR = os.path.join(DATA, "servers")
DB_PATH = os.path.join(DATA, "eaglecraft.db")
PORT = int(os.environ.get("PORT", "8080"))

# Per-install secret used to sign session cookies.
SECRET_PATH = os.path.join(DATA, "secret.key")
if os.path.exists(SECRET_PATH):
    with open(SECRET_PATH, "rb") as f:
        SECRET = f.read()
else:
    SECRET = secrets.token_bytes(32)
    os.makedirs(DATA, exist_ok=True)
    with open(SECRET_PATH, "wb") as f:
        f.write(SECRET)
    os.chmod(SECRET_PATH, 0o600)

# Eaglercraft players connect to the BungeeCord proxy on this port (its own
# dev tunnel). Bungee forwards to the Paper backend on 25565.
SMP_PORT = int(os.environ.get("SMP_PORT", "25577"))

# Per-student storage cap ("data stored up to a certain point").
QUOTA_BYTES = int(os.environ.get("QUOTA_MB", "150")) * 1024 * 1024

for d in (WORLDS_DIR, SERVERS_DIR):
    os.makedirs(d, exist_ok=True)


# --------------------------------------------------------------------------- #
# Database
# --------------------------------------------------------------------------- #
def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


ADMIN_CONF = os.path.join(DATA, "admin.conf")


def load_admin_conf():
    """Read (or create) the easily-editable admin login file."""
    if not os.path.isfile(ADMIN_CONF):
        with open(ADMIN_CONF, "w") as f:
            f.write("# EagleCraft admin login.\n")
            f.write("# Change these, then restart the server (python3 server.py).\n")
            f.write("username=admin\n")
            f.write("password=Learn2025\n")
        os.chmod(ADMIN_CONF, 0o600)
    username, password = "admin", "Learn2025"
    with open(ADMIN_CONF) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip().lower(), v.strip()
            if k == "username":
                username = v
            elif k == "password":
                password = v
    return username, password


def seed_admin():
    """Ensure the admin account from admin.conf exists with that password."""
    username, password = load_admin_conf()
    salt = secrets.token_hex(16)
    ph = hash_pw(password, salt)
    conn = db()
    row = conn.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
    if row:
        conn.execute(
            "UPDATE users SET pw_hash=?, salt=?, is_admin=1 WHERE id=?",
            (ph, salt, row["id"]),
        )
    else:
        conn.execute(
            "INSERT INTO users (username,pw_hash,salt,is_admin,created) VALUES (?,?,?,1,?)",
            (username, ph, salt, int(time.time())),
        )
    conn.commit()
    conn.close()
    return username


def init_db():
    conn = db()
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS users (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            username  TEXT UNIQUE NOT NULL,
            pw_hash   TEXT NOT NULL,
            salt      TEXT NOT NULL,
            is_admin  INTEGER NOT NULL DEFAULT 0,
            created   INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS worlds (
            id        TEXT PRIMARY KEY,
            user_id   INTEGER NOT NULL,
            name      TEXT NOT NULL,
            filename  TEXT NOT NULL,
            size      INTEGER NOT NULL,
            updated   INTEGER NOT NULL
        );
        """
    )
    conn.commit()
    conn.close()


# --------------------------------------------------------------------------- #
# Auth helpers
# --------------------------------------------------------------------------- #
def hash_pw(password, salt):
    return hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt.encode("utf-8"), 200_000
    ).hex()


def make_session(user_id):
    issued = str(int(time.time()))
    payload = f"{user_id}.{issued}"
    sig = hmac.new(SECRET, payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}.{sig}"


def read_session(token):
    if not token:
        return None
    try:
        user_id, issued, sig = token.split(".")
    except ValueError:
        return None
    payload = f"{user_id}.{issued}"
    expected = hmac.new(SECRET, payload.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, sig):
        return None
    # 30-day expiry
    if int(time.time()) - int(issued) > 30 * 24 * 3600:
        return None
    return int(user_id)


USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,20}$")


def resolve_web_path(url_path):
    """Map a URL path to a file inside web/, or None if it escapes.

    A URL is not a filesystem path. os.path.normpath() on Windows turns "/"
    into "\\", and a leading backslash makes os.path.join() drop the base
    directory, so the old normpath().lstrip("/") approach 403'd every nested
    asset on Windows while working fine on Linux.

    Here the URL is normalised with POSIX rules, then split into components
    with "", "." and ".." thrown away, so traversal cannot survive no matter
    what separator the platform prefers.
    """
    decoded = unquote(url_path)
    if "\x00" in decoded:
        return None
    rel = posixpath.normpath(decoded)
    parts = [p for p in rel.split("/") if p and p not in (".", "..")]
    full = os.path.abspath(os.path.join(WEB, *parts)) if parts else os.path.abspath(WEB)
    base = os.path.abspath(WEB)
    if full != base and not full.startswith(base + os.sep):
        return None
    if os.path.isdir(full):
        full = os.path.join(full, "index.html")
    return full


# --------------------------------------------------------------------------- #
# HTTP handler
# --------------------------------------------------------------------------- #
class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "EagleCraft/1.0"

    # ---- low level helpers ------------------------------------------------ #
    def _set_nodelay(self):
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

    def setup(self):
        super().setup()
        self._set_nodelay()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _json(self, obj, status=200, extra_headers=None):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _err(self, msg, status=400):
        self._json({"error": msg}, status=status)

    def _body(self, max_bytes=200 * 1024 * 1024):
        length = int(self.headers.get("Content-Length", "0"))
        if length > max_bytes:
            return None
        return self.rfile.read(length)

    def _json_body(self):
        raw = self._body(max_bytes=1024 * 1024)
        if raw is None:
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None

    def _cookie_token(self):
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            part = part.strip()
            if part.startswith("session="):
                return part[len("session="):]
        return None

    def _current_user(self):
        uid = read_session(self._cookie_token())
        if uid is None:
            return None
        conn = db()
        row = conn.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
        conn.close()
        return row

    # ---- routing ---------------------------------------------------------- #
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith("/api/"):
            return self.api_get(path, parse_qs(parsed.query))
        return self.serve_static(path)

    def do_HEAD(self):
        parsed = urlparse(self.path)
        path = parsed.path
        # HEAD is used by /play to detect whether the client is installed.
        if path.startswith("/api/"):
            self.send_response(405)
            self.end_headers()
            return
        routes = {"/": "loader.html", "/chooser": "welcome.html",
                  "/eaglecraft": "index.html", "/dashboard": "dashboard.html",
                  "/play": "play.html", "/browser": "browser.html"}
        if path in routes:
            full = os.path.join(WEB, routes[path])
        else:
            full = resolve_web_path(path)
            if full is None:
                self.send_response(403)
                self.end_headers()
                return
        if os.path.isfile(full):
            ext = os.path.splitext(full)[1].lower()
            self.send_response(200)
            self.send_header("Content-Type", self.CONTENT_TYPES.get(ext, "application/octet-stream"))
            self.send_header("Content-Length", str(os.path.getsize(full)))
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/"):
            return self.api_post(parsed.path, parse_qs(parsed.query))
        self._err("not found", 404)

    def do_DELETE(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/"):
            return self.api_delete(parsed.path)
        self._err("not found", 404)

    # ---- static files ----------------------------------------------------- #
    def serve_static(self, path):
        # Game collections use relative asset paths, so they must load under
        # their own base dir — send the short links to the entry page.
        if path in ("/games", "/games/"):
            self.send_response(302)
            self.send_header("Location", "/games/Gams.html")
            self.end_headers()
            return
        if path in ("/moregames", "/moregames/"):
            self.send_response(302)
            self.send_header("Location", "/moregames/index.html")
            self.end_headers()
            return
        routes = {
            "/": "loader.html",           # progress bar, then a "Launch into about:blank" button
            "/chooser": "welcome.html",   # the "Where do you want to go?" portal (runs in about:blank)
            "/eaglecraft": "index.html",  # the EagleCraft login/landing
            "/dashboard": "dashboard.html",
            "/play": "play.html",
            "/browser": "browser.html", # the in-page browser
        }
        if path in routes:
            return self._send_file(os.path.join(WEB, routes[path]))

        # Prevent path traversal (see resolve_web_path).
        full = resolve_web_path(path)
        if full is None:
            return self._err("forbidden", 403)
        if os.path.isfile(full):
            return self._send_file(full)
        return self._err("not found", 404)

    CONTENT_TYPES = {
        ".html": "text/html; charset=utf-8",
        ".css": "text/css; charset=utf-8",
        ".js": "application/javascript; charset=utf-8",
        ".json": "application/json",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".gif": "image/gif",
        ".svg": "image/svg+xml",
        ".wasm": "application/wasm",
        ".epk": "application/octet-stream",
        ".map": "application/json",
        ".ico": "image/x-icon",
        ".jpeg": "image/jpeg",
        ".webp": "image/webp",
        ".mjs": "application/javascript; charset=utf-8",
        ".txt": "text/plain; charset=utf-8",
        ".xml": "application/xml",
        # audio / video for the games
        ".mp3": "audio/mpeg", ".ogg": "audio/ogg", ".wav": "audio/wav",
        ".m4a": "audio/mp4", ".mp4": "video/mp4", ".webm": "video/webm",
        # fonts
        ".woff": "font/woff", ".woff2": "font/woff2",
        ".ttf": "font/ttf", ".otf": "font/otf", ".eot": "application/vnd.ms-fontobject",
        # misc game/data blobs
        ".data": "application/octet-stream", ".mem": "application/octet-stream",
        ".unityweb": "application/octet-stream", ".pck": "application/octet-stream",
        ".br": "application/octet-stream", ".gz": "application/octet-stream",
    }

    def _send_file(self, full):
        if not os.path.isfile(full):
            return self._err("not found", 404)
        ext = os.path.splitext(full)[1].lower()
        ctype = self.CONTENT_TYPES.get(ext, "application/octet-stream")
        size = os.path.getsize(full)
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(full, "rb") as f:
            shutil.copyfileobj(f, self.wfile)

    # ---- API GET ---------------------------------------------------------- #
    def api_get(self, path, query):
        if path == "/api/games":
            # Public: list the Gams games (self-contained html in games/g/).
            gdir = os.path.join(WEB, "games", "g")
            imgdir = os.path.join(WEB, "games", "img")
            games = []
            if os.path.isdir(gdir):
                for fn in sorted(os.listdir(gdir)):
                    if not fn.endswith(".html"):
                        continue
                    base = fn[:-5]
                    if base in ("about",):
                        continue
                    has_img = os.path.isfile(os.path.join(imgdir, base + ".png"))
                    games.append({
                        "file": f"/games/g/{fn}",
                        "name": base,
                        "img": f"/games/img/{base}.png" if has_img else None,
                    })
            return self._json({"games": games})

        if path == "/api/me":
            user = self._current_user()
            if not user:
                return self._err("not logged in", 401)
            return self._json({
                "username": user["username"],
                "id": user["id"],
                "is_admin": bool(user["is_admin"]),
            })

        if path == "/api/worlds":
            user = self._current_user()
            if not user:
                return self._err("not logged in", 401)
            conn = db()
            rows = conn.execute(
                "SELECT id,name,size,updated FROM worlds WHERE user_id=? ORDER BY updated DESC",
                (user["id"],),
            ).fetchall()
            conn.close()
            used = sum(r["size"] for r in rows)
            return self._json({
                "worlds": [dict(r) for r in rows],
                "used": used,
                "quota": QUOTA_BYTES,
            })

        m = re.match(r"^/api/worlds/([\w-]+)/download$", path)
        if m:
            return self.download_world(m.group(1))

        if path == "/api/smp":
            user = self._current_user()
            if not user:
                return self._err("not logged in", 401)
            return self._json({
                "running": smp_online(),
                "port": SMP_PORT,
                "is_admin": bool(user["is_admin"]),
                "java": _java_available(),
                "jar": os.path.isfile(SMP_JAR) and os.path.isfile(BUNGEE_JAR),
                "backend": {
                    "running": BACKEND.running,
                    "ready": BACKEND.ready,
                    "uptime": BACKEND.uptime(),
                    "heap_mb": BACKEND.heap_mb,
                },
                "proxy": {
                    "running": PROXY.running,
                    "ready": PROXY.ready,
                    "uptime": PROXY.uptime(),
                    "heap_mb": PROXY.heap_mb,
                },
                "players": online_players(),
                "ram_budget_mb": SMP_RAM_MB,
            })

        if path == "/api/smp/log":
            user = self._current_user()
            if not user or not user["is_admin"]:
                return self._err("forbidden", 403)
            target = (query.get("target") or ["paper"])[0]
            try:
                after = int((query.get("after") or ["0"])[0])
            except (TypeError, ValueError):
                after = 0
            rows, cursor = console_tail(target, after)
            return self._json({
                # legacy field: whole visible buffer as one blob
                "log": "\n".join(line for _id, line in rows),
                # incremental field: only what you have not seen yet
                "lines": [{"id": i, "line": t} for i, t in rows],
                "cursor": cursor,
                "running": is_server_running(target),
            })

        return self._err("not found", 404)

    # ---- API POST --------------------------------------------------------- #
    def api_post(self, path, query):
        if path == "/api/register":
            return self.register()
        if path == "/api/login":
            return self.login()
        if path == "/api/logout":
            return self.logout()
        if path == "/api/worlds":
            return self.upload_world()
        if path in ("/api/smp/start", "/api/smp/stop"):
            return self.control_smp("start" if path.endswith("start") else "stop")
        if path == "/api/smp/cmd":
            return self.smp_command()
        return self._err("not found", 404)

    def api_delete(self, path):
        m = re.match(r"^/api/worlds/([\w-]+)$", path)
        if m:
            return self.delete_world(m.group(1))
        return self._err("not found", 404)

    # ---- auth endpoints --------------------------------------------------- #
    def register(self):
        data = self._json_body()
        if not data:
            return self._err("bad request")
        username = (data.get("username") or "").strip()
        password = data.get("password") or ""
        if not USERNAME_RE.match(username):
            return self._err("username must be 3-20 chars, letters/numbers/underscore")
        if len(password) < 6:
            return self._err("password must be at least 6 characters")
        salt = secrets.token_hex(16)
        ph = hash_pw(password, salt)
        conn = db()
        # The very first account to register becomes the admin (runs the SMP).
        first = conn.execute("SELECT COUNT(*) c FROM users").fetchone()["c"] == 0
        try:
            cur = conn.execute(
                "INSERT INTO users (username,pw_hash,salt,is_admin,created) VALUES (?,?,?,?,?)",
                (username, ph, salt, 1 if first else 0, int(time.time())),
            )
            conn.commit()
            uid = cur.lastrowid
        except sqlite3.IntegrityError:
            conn.close()
            return self._err("username already taken", 409)
        conn.close()
        token = make_session(uid)
        self._json(
            {"username": username, "id": uid},
            extra_headers={
                "Set-Cookie": f"session={token}; HttpOnly; Path=/; SameSite=Lax; Max-Age={30*24*3600}"
            },
        )

    def login(self):
        data = self._json_body()
        if not data:
            return self._err("bad request")
        username = (data.get("username") or "").strip()
        password = data.get("password") or ""
        conn = db()
        row = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
        conn.close()
        if not row or not hmac.compare_digest(
            row["pw_hash"], hash_pw(password, row["salt"])
        ):
            return self._err("wrong username or password", 401)
        token = make_session(row["id"])
        self._json(
            {"username": row["username"], "id": row["id"]},
            extra_headers={
                "Set-Cookie": f"session={token}; HttpOnly; Path=/; SameSite=Lax; Max-Age={30*24*3600}"
            },
        )

    def logout(self):
        self._json(
            {"ok": True},
            extra_headers={"Set-Cookie": "session=; HttpOnly; Path=/; Max-Age=0"},
        )

    # ---- world sync ------------------------------------------------------- #
    def upload_world(self):
        user = self._current_user()
        if not user:
            return self._err("not logged in", 401)
        name = self.headers.get("X-World-Name", "Unnamed World")[:80]
        raw = self._body()
        if raw is None:
            return self._err("file too large (200MB max)", 413)
        if not raw:
            return self._err("empty upload")
        # Enforce the per-student storage quota.
        conn = db()
        used = conn.execute(
            "SELECT COALESCE(SUM(size),0) s FROM worlds WHERE user_id=?", (user["id"],)
        ).fetchone()["s"]
        conn.close()
        if used + len(raw) > QUOTA_BYTES:
            remaining = max(0, QUOTA_BYTES - used)
            return self._err(
                f"storage full: {remaining // (1024*1024)} MB left of "
                f"{QUOTA_BYTES // (1024*1024)} MB. Delete a world first.",
                413,
            )
        wid = uuid.uuid4().hex
        user_dir = os.path.join(WORLDS_DIR, str(user["id"]))
        os.makedirs(user_dir, exist_ok=True)
        filename = f"{wid}.epk"
        with open(os.path.join(user_dir, filename), "wb") as f:
            f.write(raw)
        conn = db()
        conn.execute(
            "INSERT INTO worlds (id,user_id,name,filename,size,updated) VALUES (?,?,?,?,?,?)",
            (wid, user["id"], name, filename, len(raw), int(time.time())),
        )
        conn.commit()
        conn.close()
        self._json({"id": wid, "name": name, "size": len(raw)})

    def download_world(self, wid):
        user = self._current_user()
        if not user:
            return self._err("not logged in", 401)
        conn = db()
        row = conn.execute(
            "SELECT * FROM worlds WHERE id=? AND user_id=?", (wid, user["id"])
        ).fetchone()
        conn.close()
        if not row:
            return self._err("not found", 404)
        full = os.path.join(WORLDS_DIR, str(user["id"]), row["filename"])
        if not os.path.isfile(full):
            return self._err("file missing", 404)
        safe_name = re.sub(r"[^\w.-]", "_", row["name"]) or "world"
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(os.path.getsize(full)))
        self.send_header(
            "Content-Disposition", f'attachment; filename="{safe_name}.epk"'
        )
        self.end_headers()
        with open(full, "rb") as f:
            shutil.copyfileobj(f, self.wfile)

    def delete_world(self, wid):
        user = self._current_user()
        if not user:
            return self._err("not logged in", 401)
        conn = db()
        row = conn.execute(
            "SELECT * FROM worlds WHERE id=? AND user_id=?", (wid, user["id"])
        ).fetchone()
        if not row:
            conn.close()
            return self._err("not found", 404)
        full = os.path.join(WORLDS_DIR, str(user["id"]), row["filename"])
        if os.path.isfile(full):
            os.remove(full)
        conn.execute("DELETE FROM worlds WHERE id=?", (wid,))
        conn.commit()
        conn.close()
        self._json({"ok": True})

    # ---- the SMP (the only server WE host; LANs are client-side) --------- #
    def control_smp(self, action):
        user = self._current_user()
        if not user:
            return self._err("not logged in", 401)
        if not user["is_admin"]:
            return self._err("only the admin can control the SMP", 403)
        if action == "start":
            ok, msg = start_game_server("smp", SMP_PORT)
            if not ok:
                return self._err(msg, 503)
            return self._json({"ok": True, "running": True, "note": msg})
        stop_game_server("smp")
        return self._json({"ok": True, "running": False})

    def smp_command(self):
        user = self._current_user()
        if not user:
            return self._err("not logged in", 401)
        if not user["is_admin"]:
            return self._err("only the admin can run server commands", 403)
        data = self._json_body()
        cmd = (data or {}).get("command", "").strip()
        target = ((data or {}).get("target") or "paper").strip()
        if not cmd:
            return self._err("empty command")
        ok, msg = send_smp_command(cmd, target)
        if not ok:
            return self._err(msg, 503)
        return self._json({"ok": True, "note": msg})


# --------------------------------------------------------------------------- #
# SMP game-server process management.
#
# The SMP runs on its own port (its own dev tunnel) so player traffic never
# passes through this web app. Needs Java + an Eaglercraft server jar at
# data/eaglercraftserver.jar; if either is missing we report it cleanly.
# --------------------------------------------------------------------------- #
SMP_DIR = os.path.join(DATA, "smp")            # Paper 1.20.4 backend
SMP_JAR = os.path.join(SMP_DIR, "paper.jar")
BUNGEE_DIR = os.path.join(DATA, "bungee")      # BungeeCord + EaglerXServer
BUNGEE_JAR = os.path.join(BUNGEE_DIR, "BungeeCord.jar")

# RAM. SMP_RAM_MB is the budget for the WHOLE network, not just the backend:
# the proxy takes a small fixed slice and Paper receives everything else. That
# keeps one knob for the operator and stops the two heaps from over-committing
# the host when the box only has 8 GB.
SMP_RAM_MB = int(os.environ.get("SMP_RAM_MB", "4096"))
PROXY_RAM_MB = int(os.environ.get("SMP_PROXY_RAM_MB", "512"))
BACKEND_RAM_MB = max(1024, SMP_RAM_MB - PROXY_RAM_MB)

# How many console lines we keep in RAM per process for the web console.
CONSOLE_LINES = int(os.environ.get("SMP_CONSOLE_LINES", "800"))

# How long start_game_server waits for "Done (x.xxxs)!" before it brings the
# proxy up anyway (the proxy tolerates a backend that is still booting).
BACKEND_READY_TIMEOUT = int(os.environ.get("SMP_READY_TIMEOUT", "180"))


# --------------------------------------------------------------------------- #
# Java 21 discovery
#
# Paper 1.20.4 requires Java 17+, and EaglerXServer/BungeeCord are compiled for
# 17+ as well, so BOTH children run on the same Java 21 runtime. (An earlier
# revision of this file launched the backend with Java 8 for a native 1.8.8
# jar; that combination cannot load a 1.20.4 Paper build -- it dies with
# UnsupportedClassVersionError before it ever prints a log line.)
# --------------------------------------------------------------------------- #
def _find_java21():
    import glob as _glob

    exe = "java.exe" if os.name == "nt" else "java"
    home = os.environ.get("JAVA21_HOME", "").strip()
    if home:
        cand = os.path.join(home, "bin", exe)
        if os.path.isfile(cand):
            return cand
    patterns = [
        os.path.join(ROOT, "runtime", "jdk-21*"),
        os.path.join(ROOT, "runtime", "jre-21*"),
        "/config/jdk-21*",
    ]
    for pat in patterns:
        for d in sorted(_glob.glob(pat)):
            for cand in (os.path.join(d, "bin", exe),
                         os.path.join(d, "Contents", "Home", "bin", exe)):
                if os.path.isfile(cand):
                    return cand
    return shutil.which("java")


_JAVA21 = _find_java21()


def _java_bin():
    """Re-resolve lazily so a setup.sh run does not require a web restart."""
    global _JAVA21
    if not _JAVA21 or not os.path.isfile(_JAVA21):
        _JAVA21 = _find_java21()
    return _JAVA21


def _java_available():
    return _java_bin() is not None


def aikar_flags(heap_mb):
    """Aikar's G1GC tuning -- removes the GC pauses that clients see as lag.

    The large-heap variant only makes sense at >=12 GB; using it on a 4 GB heap
    starves the old generation and makes pauses worse, so we scale it."""
    big = heap_mb >= 12288
    return [
        "-XX:+UseG1GC",
        "-XX:+ParallelRefProcEnabled",
        "-XX:MaxGCPauseMillis=200",
        "-XX:+UnlockExperimentalVMOptions",
        "-XX:+DisableExplicitGC",
        "-XX:+AlwaysPreTouch",
        "-XX:G1NewSizePercent=" + ("40" if big else "30"),
        "-XX:G1MaxNewSizePercent=" + ("50" if big else "40"),
        "-XX:G1HeapRegionSize=" + ("16M" if big else "8M"),
        "-XX:G1ReservePercent=" + ("15" if big else "20"),
        "-XX:G1HeapWastePercent=5",
        "-XX:G1MixedGCCountTarget=4",
        "-XX:InitiatingHeapOccupancyPercent=" + ("20" if big else "15"),
        "-XX:G1MixedGCLiveThresholdPercent=90",
        "-XX:G1RSetUpdatingPauseTimePercent=5",
        "-XX:SurvivorRatio=32",
        "-XX:+PerfDisableSharedMem",
        "-XX:MaxTenuringThreshold=1",
        "-Dusing.aikars.flags=https://mcflags.emc.gs",
        "-Daikars.new.flags=true",
    ]


# --------------------------------------------------------------------------- #
# A supervised Java child process.
#
# stdout/stderr are merged and drained by a dedicated daemon thread into
# (a) an in-memory ring buffer the web console reads, and (b) console.log on
# disk. stdin stays open on a pipe so the dashboard can type commands. Nothing
# here ever blocks an HTTP worker thread: the reader owns the pipe, the writer
# only takes a short lock around one write+flush.
# --------------------------------------------------------------------------- #
_JOIN_RE = re.compile(r"\]:\s+([A-Za-z0-9_]{1,16}) joined the game")
_QUIT_RE = re.compile(r"\]:\s+([A-Za-z0-9_]{1,16}) left the game")
_DONE_RE = re.compile(r"Done \([\d.]+s\)!")
_PROXY_READY_RE = re.compile(r"Listening on|Enabled .*EaglerXServer|Listening for eaglercraft")


class JavaProcess:
    def __init__(self, key, cwd, jar, heap_mb, stop_cmd,
                 jvm_extra=(), jar_args=(), aikar=True, ready_re=None):
        self.key = key
        self.cwd = cwd
        self.jar = jar
        self.heap_mb = heap_mb
        self.stop_cmd = stop_cmd
        self.jvm_extra = list(jvm_extra)
        self.jar_args = list(jar_args)
        self.aikar = aikar
        self.ready_re = ready_re

        self.proc = None
        self.started = 0.0
        self.ready = False
        self.players = set()
        self.lines = deque(maxlen=CONSOLE_LINES)   # (id, text)
        self._next_id = 1
        self._lock = threading.RLock()
        self._stdin_lock = threading.Lock()
        self._logf = None

    # -- state ------------------------------------------------------------ #
    @property
    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def uptime(self):
        return int(time.time() - self.started) if self.running else 0

    def argv(self):
        gc = aikar_flags(self.heap_mb) if self.aikar else [
            "-XX:+UseG1GC", "-XX:MaxGCPauseMillis=100", "-XX:+ParallelRefProcEnabled",
        ]
        return [_java_bin(), f"-Xms{self.heap_mb}M", f"-Xmx{self.heap_mb}M",
                *gc, *self.jvm_extra, "-Dfile.encoding=UTF-8",
                "-jar", self.jar, *self.jar_args]

    # -- console ---------------------------------------------------------- #
    def _emit(self, text):
        with self._lock:
            self.lines.append((self._next_id, text))
            self._next_id += 1
        if self._logf:
            try:
                self._logf.write(text + "\n")
                self._logf.flush()
            except (OSError, ValueError):
                pass

    def tail(self, after=0):
        """Return ((id, line), ...) newer than `after`, plus the new cursor."""
        with self._lock:
            rows = [(i, t) for i, t in self.lines if i > after]
            cursor = self._next_id - 1
        return rows, cursor

    # -- lifecycle -------------------------------------------------------- #
    def start(self):
        with self._lock:
            if self.running:
                return True, f"{self.key} already running"
            java = _java_bin()
            if not java:
                return False, "Java 21 not found -- run setup.sh"
            if not os.path.isfile(self.jar):
                return False, f"{os.path.basename(self.jar)} missing -- run setup.sh"
            os.makedirs(self.cwd, exist_ok=True)
            try:
                self._logf = open(os.path.join(self.cwd, "console.log"),
                                  "a", encoding="utf-8", errors="replace")
            except OSError:
                self._logf = None
            argv = self.argv()
            self._emit("$ " + " ".join(argv))
            creation = 0
            if os.name == "nt":
                creation = subprocess.CREATE_NEW_PROCESS_GROUP
            try:
                self.proc = subprocess.Popen(
                    argv,
                    cwd=self.cwd,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    bufsize=1,
                    universal_newlines=True,
                    encoding="utf-8",
                    errors="replace",
                    creationflags=creation,
                )
            except OSError as e:
                self._emit(f"!! failed to launch {self.key}: {e}")
                return False, f"failed to launch {self.key}: {e}"
            self.started = time.time()
            self.ready = False
            self.players.clear()
            threading.Thread(target=self._pump, name=f"{self.key}-stdout",
                             daemon=True).start()
            return True, (f"{self.key} starting (pid {self.proc.pid}, "
                          f"{self.heap_mb} MB heap)")

    def _pump(self):
        proc = self.proc
        if proc is None or proc.stdout is None:
            return
        try:
            for raw in iter(proc.stdout.readline, ""):
                line = raw.rstrip("\r\n")
                if not line:
                    continue
                if not self.ready:
                    if self.ready_re and self.ready_re.search(line):
                        self.ready = True
                m = _JOIN_RE.search(line)
                if m:
                    self.players.add(m.group(1))
                m = _QUIT_RE.search(line)
                if m:
                    self.players.discard(m.group(1))
                self._emit(line)
        except (OSError, ValueError):
            pass
        finally:
            code = proc.poll()
            self.ready = False
            self.players.clear()
            self._emit(f"-- {self.key} exited with code {code} --")
            if self._logf:
                try:
                    self._logf.close()
                except OSError:
                    pass
                self._logf = None

    def send(self, cmd):
        if not self.running or self.proc is None or self.proc.stdin is None:
            return False, f"{self.key} is not running"
        try:
            with self._stdin_lock:
                self.proc.stdin.write(cmd.rstrip("\n") + "\n")
                self.proc.stdin.flush()
        except (OSError, ValueError, BrokenPipeError) as e:
            return False, f"could not send to {self.key}: {e}"
        self._emit("> " + cmd)
        return True, f"sent to {self.key}: {cmd}"

    def stop(self, timeout=45):
        with self._lock:
            if not self.running:
                return
            self._emit(f"-- graceful shutdown: '{self.stop_cmd}' --")
            self.send(self.stop_cmd)
            deadline = time.time() + timeout
            while time.time() < deadline and self.running:
                time.sleep(0.25)
            if self.running:
                self._emit("-- grace period expired, terminating --")
                try:
                    self.proc.terminate()
                    self.proc.wait(timeout=10)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            if self.running:
                self._emit("-- still alive, killing --")
                try:
                    self.proc.kill()
                except OSError:
                    pass
            self.ready = False


# The two children. The backend binds 127.0.0.1 only (see server.properties):
# players never touch it directly, they always come through the proxy.
BACKEND = JavaProcess(
    "paper", SMP_DIR, SMP_JAR, BACKEND_RAM_MB, "stop",
    jvm_extra=("-Dcom.mojang.eula.agree=true",),
    jar_args=("--nogui",), aikar=True, ready_re=_DONE_RE,
)
PROXY = JavaProcess(
    "proxy", BUNGEE_DIR, BUNGEE_JAR, PROXY_RAM_MB, "end",
    jvm_extra=("-Djava.net.preferIPv4Stack=true",),
    jar_args=(), aikar=False, ready_re=_PROXY_READY_RE,
)

# Aliases so older call sites ("smp", "smp_proxy") keep working.
PROCS = {"paper": BACKEND, "backend": BACKEND, "smp": BACKEND,
         "proxy": PROXY, "bungee": PROXY, "smp_proxy": PROXY}


def is_server_running(sid):
    p = PROCS.get(sid)
    return bool(p and p.running)


def _port_listening(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.3)
    try:
        return s.connect_ex(("127.0.0.1", port)) == 0
    finally:
        s.close()


def smp_online():
    """Player-facing status: is the proxy port accepting connections? Port-based
    so it stays correct even if the web app restarted under a live network."""
    return PROXY.running or _port_listening(SMP_PORT)


def online_players():
    return sorted(BACKEND.players)


def console_tail(target="paper", after=0):
    p = PROCS.get(target, BACKEND)
    return p.tail(after)


def send_smp_command(cmd, target="paper"):
    p = PROCS.get(target)
    if p is None:
        return False, f"unknown console target '{target}'"
    return p.send(cmd)


def _start_proxy_when_ready():
    """Wait for the backend to finish generating spawn, then open the door."""
    deadline = time.time() + BACKEND_READY_TIMEOUT
    while time.time() < deadline and BACKEND.running and not BACKEND.ready:
        time.sleep(0.5)
    if not _port_listening(SMP_PORT):
        PROXY.start()


def start_game_server(sid="smp", port=None):
    """Start Paper, then BungeeCord once Paper is accepting connections.

    Returns immediately -- the proxy is launched from a background thread so an
    HTTP request never blocks for the length of a world load."""
    port = SMP_PORT if port is None else port
    if not _java_available():
        return False, "Java 21 is not installed -- run setup.sh."
    if not os.path.isfile(SMP_JAR) or not os.path.isfile(BUNGEE_JAR):
        return False, "SMP server not set up yet -- run setup.sh."
    if BACKEND.running and PROXY.running:
        return True, "already running"

    notes = []
    if not BACKEND.running and not _port_listening(25565):
        ok, msg = BACKEND.start()
        notes.append(msg)
        if not ok:
            return False, msg
    if not PROXY.running:
        threading.Thread(target=_start_proxy_when_ready,
                         name="proxy-starter", daemon=True).start()
        notes.append(f"proxy will open on :{port} once the world is loaded")
    return True, " | ".join(notes) or "starting"


def stop_game_server(sid="smp"):
    """Proxy first (clean disconnect), flush the world, then the backend."""
    PROXY.stop(timeout=20)
    if BACKEND.running:
        BACKEND.send("save-all flush")
        time.sleep(1.5)
    BACKEND.stop(timeout=60)


# --------------------------------------------------------------------------- #
# Threaded server with TCP_NODELAY
# --------------------------------------------------------------------------- #
class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        super().server_bind()


def check_bindings():
    """Verify nothing else already owns the ports we are about to bind."""
    clash = False
    for label, port in (("website", PORT), ("paper backend", 25565),
                        ("eagler proxy", SMP_PORT)):
        busy = _port_listening(port)
        print(f"  {label:<14} :{port:<6} {'IN USE' if busy else 'free'}")
        clash = clash or busy
    return not clash


def main():
    init_db()
    admin_name = seed_admin()

    if "--init-db" in sys.argv:
        print(f"  database ready:     {DB_PATH}")
        print(f"  admin account:      '{admin_name}'")
        return
    if "--check-ports" in sys.argv:
        raise SystemExit(0 if check_bindings() else 1)

    print(f"  admin account:      '{admin_name}' (edit data/admin.conf to change)")
    # AUTOSTART_SMP=1 boots the SMP on startup (so this process owns the
    # console pipe), letting one command bring up website + SMP together.
    if os.environ.get("AUTOSTART_SMP") == "1" and os.path.isfile(SMP_JAR):
        ok, msg = start_game_server("smp", SMP_PORT)
        print(f"  smp autostart:      {msg}")
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"EagleCraft platform running:  http://localhost:{PORT}")
    print(f"  accounts + worlds:  ready (quota {QUOTA_BYTES // (1024*1024)} MB/student)")
    print(f"  SMP game port:      {SMP_PORT} (own dev tunnel)")
    print(f"  java 21:            {_java_bin() or 'NOT FOUND - run setup.sh'}")
    print(f"  ram budget:         {SMP_RAM_MB} MB total "
          f"= paper {BACKEND_RAM_MB} MB + proxy {PROXY_RAM_MB} MB")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down…")
        stop_game_server("smp")


if __name__ == "__main__":
    main()

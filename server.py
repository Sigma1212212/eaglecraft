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
from urllib.parse import urlparse, parse_qs

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
                  "/play": "play.html", "/games": "games-hub.html"}
        if path in routes:
            full = os.path.join(WEB, routes[path])
        else:
            safe = os.path.normpath(path).lstrip("/")
            full = os.path.join(WEB, safe)
            if not os.path.abspath(full).startswith(os.path.abspath(WEB)):
                self.send_response(403)
                self.end_headers()
                return
            if os.path.isdir(full):
                full = os.path.join(full, "index.html")
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
        routes = {
            "/": "loader.html",           # progress bar, then a "Launch into about:blank" button
            "/chooser": "welcome.html",   # the "Where do you want to go?" portal (runs in about:blank)
            "/eaglecraft": "index.html",  # the EagleCraft login/landing
            "/dashboard": "dashboard.html",
            "/play": "play.html",
            "/games": "games-hub.html",   # our launcher (games open in about:blank)
        }
        if path in routes:
            return self._send_file(os.path.join(WEB, routes[path]))

        # Prevent path traversal.
        safe = os.path.normpath(path).lstrip("/")
        full = os.path.join(WEB, safe)
        if not os.path.abspath(full).startswith(os.path.abspath(WEB)):
            return self._err("forbidden", 403)
        if os.path.isdir(full):
            full = os.path.join(full, "index.html")
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
            })

        if path == "/api/smp/log":
            user = self._current_user()
            if not user or not user["is_admin"]:
                return self._err("forbidden", 403)
            logf = os.path.join(SMP_DIR, "logs", "latest.log")
            lines = []
            if os.path.isfile(logf):
                with open(logf, "rb") as f:
                    lines = f.read().decode("utf-8", "replace").splitlines()[-60:]
            return self._json({"log": "\n".join(lines)})

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
        if not cmd:
            return self._err("empty command")
        ok, msg = send_smp_command(cmd)
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
_running = {}  # sid -> Popen

# SMP stack: BungeeCord proxy (EaglerXServer) -> Paper 1.20.4 backend
# (ViaVersion/Backwards/Rewind so 1.8 Eaglercraft clients work + EssentialsX).
SMP_DIR = os.path.join(DATA, "smp")            # Paper backend
SMP_JAR = os.path.join(SMP_DIR, "paper.jar")
BUNGEE_DIR = os.path.join(DATA, "bungee")      # proxy (player-facing)
BUNGEE_JAR = os.path.join(BUNGEE_DIR, "BungeeCord.jar")
# RAM for the SMP (8 GB default; the box has ~30 GB). Editable via env.
SMP_RAM_MB = int(os.environ.get("SMP_RAM_MB", "8192"))
# Paper 1.20.4 needs Java 21. Look for a JRE in this order: $JAVA21_HOME,
# the repo-local runtime/ dir (created by setup.sh), /config, then PATH.
def _find_java():
    glob = __import__("glob")
    if os.environ.get("JAVA21_HOME"):
        cand = os.path.join(os.environ["JAVA21_HOME"], "bin", "java")
        if os.path.isfile(cand):
            return cand
    patterns = [
        os.path.join(ROOT, "runtime", "jdk-21*"),
        os.path.join(ROOT, "runtime", "jdk21*"),
        "/config/jdk-21*",
    ]
    for pat in patterns:
        for d in sorted(glob.glob(pat)):
            cand = os.path.join(d, "bin", "java")
            if os.path.isfile(cand):
                return cand
    return None


_BUNDLED_JAVA = _find_java()


def _java_bin():
    return _BUNDLED_JAVA or shutil.which("java")


def is_server_running(sid):
    p = _running.get(sid)
    return p is not None and p.poll() is None


def _port_listening(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.3)
    try:
        return s.connect_ex(("127.0.0.1", port)) == 0
    finally:
        s.close()


def smp_online():
    """Player-facing status: is the Bungee proxy port accepting connections?
    Port-based so it stays correct even if the web server restarted."""
    return is_server_running("smp_proxy") or _port_listening(SMP_PORT)


def _java_available():
    return _java_bin() is not None


def _launch(java, jar, cwd, xms, xmx, extra_args=("nogui",), stdin_pipe=False):
    return subprocess.Popen(
        [java, f"-Xms{xms}M", f"-Xmx{xmx}M", "-XX:+UseG1GC", "-jar", jar, *extra_args],
        cwd=cwd,
        stdin=subprocess.PIPE if stdin_pipe else subprocess.DEVNULL,
        stdout=open(os.path.join(cwd, "console.log"), "ab"),
        stderr=subprocess.STDOUT,
    )


def send_smp_command(cmd):
    """Write a console command to the running Paper backend (admin only)."""
    p = _running.get("smp")
    if not p or p.poll() is not None or not p.stdin:
        return False, "SMP backend is not running (or was started before this web session)."
    try:
        p.stdin.write((cmd.rstrip("\n") + "\n").encode("utf-8"))
        p.stdin.flush()
    except (OSError, ValueError) as e:
        return False, f"could not send: {e}"
    return True, f"sent: {cmd}"


def start_game_server(sid, port):
    """Start the Paper backend, then the BungeeCord proxy (player-facing)."""
    if is_server_running(sid) and is_server_running(sid + "_proxy"):
        return True, "already running"
    java = _java_bin()
    if not java:
        return False, "Java is not installed — run setup.sh."
    if not os.path.isfile(SMP_JAR) or not os.path.isfile(BUNGEE_JAR):
        return False, "SMP server not set up yet — run setup.sh."
    xmx = SMP_RAM_MB
    xms = min(2048, xmx)
    try:
        if not is_server_running(sid) and not _port_listening(25565):
            _running[sid] = _launch(java, SMP_JAR, SMP_DIR, xms, xmx, stdin_pipe=True)
        if not is_server_running(sid + "_proxy") and not _port_listening(SMP_PORT):
            # The proxy is light; cap its heap at 1 GB.
            _running[sid + "_proxy"] = _launch(
                java, BUNGEE_JAR, BUNGEE_DIR, 256, 1024, extra_args=())
    except OSError as e:
        return False, f"failed to launch: {e}"
    return True, (f"SMP starting — backend {xmx} MB RAM, proxy on port {port}. "
                  f"Give it ~30s to finish loading.")


def stop_game_server(sid):
    # Stop the proxy first, then the backend.
    for key in (sid + "_proxy", sid):
        p = _running.pop(key, None)
        if p and p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=8)
            except subprocess.TimeoutExpired:
                p.kill()


# --------------------------------------------------------------------------- #
# Threaded server with TCP_NODELAY
# --------------------------------------------------------------------------- #
class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        super().server_bind()


def main():
    init_db()
    admin_name = seed_admin()
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
    print(f"  java available:     {_java_available()}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down…")
        for sid in list(_running):
            stop_game_server(sid)


if __name__ == "__main__":
    main()

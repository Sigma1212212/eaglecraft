# 🟩 EagleCraft

A self-hosted **browser Minecraft** platform for a class/group:

- **Accounts** for every student (passwords hashed, sessions signed) — data persists in SQLite
- **Per-account worlds** — upload your world export, download it on any device (150 MB quota each)
- **about:blank launcher** — pops the game into a clean window
- **A real vanilla SMP** simulated server-side (Paper 1.20.4), tuned so low-end
  Chromebooks only have to draw — no economy, no shops, no plugins
- **Admin server console** built into the website
- **One-command install + boot**, and public hosting via **Microsoft Dev Tunnels**

Everything is pure Python standard library on the web side — no pip packages.

---

## Quick start

```bash
git clone <your-repo-url> eaglecraft
cd eaglecraft
bash setup.sh      # downloads Java 21, Paper, BungeeCord, plugins; lays down configs
bash start.sh      # boots the website + SMP (and the dev tunnel if logged in)
```

Open <http://localhost:8080>. Admin login: **`admin` / `Learn2025`** (change it in
`data/admin.conf`).

### Go public (Microsoft Dev Tunnels)

One-time interactive login (only you can do this):

```bash
/config/bin/devtunnel user login -e      # Microsoft account (or -g for GitHub)
bash start.sh                            # now it also starts the anonymous tunnel
grep devtunnels.ms logs/tunnel.log       # your public URLs
```

You get two URLs:

| URL | use |
|-----|-----|
| `https://<id>-8080.use.devtunnels.ms`  | the website |
| `wss://<id>-25577.use.devtunnels.ms`   | the SMP — paste into Eaglercraft **Direct Connect** |

`--allow-anonymous` is set, so anyone with the link can connect (no Microsoft sign-in).

---

## The SMP

Players join from inside the game: **Multiplayer → Direct Connect →** the `wss://…-25577…`
URL. Architecture (two Java 21 processes, started for you):

```
Eaglercraft 1.8 client  (Chromebook browser canvas)
      │  ws / wss
      ▼
BungeeCord + EaglerXServer + ViaVersion/ViaBackwards/ViaRewind
      │                       data/bungee/   0.0.0.0:25577   (player-facing)
      │  forwards, already translated to 1.20.4
      ▼
Paper 1.20.4            data/smp/      127.0.0.1:25565   (never exposed)
```

Both processes run on **Java 21** and are supervised by `server.py`: their
stdout is drained by a dedicated thread into a ring buffer the dashboard
streams, and their stdin stays on a pipe so the web console can type commands.

The **Via stack lives on the proxy**, so protocol translation is paid for once
by your host PC instead of by every Chromebook.

> **Why Paper 1.20.4?** EaglerXServer’s Bukkit module breaks on Paper ≥ 1.20.5
> (Mojang mappings). Running EaglerXServer on **BungeeCord** + a 1.20.4 backend,
> with Via to accept 1.8 clients, is the combination that actually works.

### Running the server (admin)

Log in as admin → dashboard → **Server Console**. It writes straight to Paper's
stdin, so every vanilla command works:

1. `op <yourEaglercraftName>`
2. In-game: stand where spawn should be → `/setworldspawn`
3. `whitelist add <name>` / `whitelist on` if you want it closed
4. `save-all flush` before you shut the PC down

There is no economy, no shop signs and no permissions plugin — operators come
from vanilla `ops.json` and everything else is plain survival Minecraft.

---

## Performance: where every setting lives

The clients are browser canvases on weak hardware, so the host absorbs the
simulation and the wire stays quiet.

| Setting | Value | File |
|---|---|---|
| `view-distance` | 5 | `server.properties` + `spigot.yml` |
| `simulation-distance` | 4 | `server.properties` + `spigot.yml` |
| `entity-broadcast-range-percentage` | 50 | `server.properties` |
| `entity-activation-range` | animals 16 / monsters 24 / misc 8 | `spigot.yml` |
| `entity-tracking-range` | animals 24 / monsters 32 / misc 16 | `spigot.yml` |
| `max-entity-collisions` | 2 | `spigot.yml` + `config/paper-world-defaults.yml` |
| `player-max-chunk-send-rate` | 12.0 | `config/paper-global.yml` |
| `chunk-system` threads | all cores | `config/paper-global.yml` |
| mob despawn ranges | soft 32 / hard 80 | `config/paper-world-defaults.yml` |

Two corrections worth knowing, because the internet still repeats both:

* **`async-chunks: true` does not exist any more.** It was removed after Paper
  1.16 — chunk load/gen/IO has been asynchronous ever since. The real controls
  are `chunk-system` and `chunk-loading-basic` in `paper-global.yml`.
* **`view-distance`/`simulation-distance` are not Paper keys.** They live in
  `server.properties` (global) and `spigot.yml` (per world). Putting them in
  `paper-world-defaults.yml` silently does nothing.

Player-side settings are in [CHROMEBOOK-CLIENT-SETTINGS.md](CHROMEBOOK-CLIENT-SETTINGS.md).

## Run it as a service (survives reboots)

`start.sh` and the tunnel both die with the shell that launched them. To keep
the SMP up across reboots, install both as Windows services from an
**elevated** PowerShell:

```powershell
cd "C:\path	o\eaglecraft"
.\service\install-services.ps1
```

That installs `eaglecraft` (the panel, which supervises Paper + the proxy) and
`cloudflared` (the tunnel). Remove them with `-Uninstall`.

Two details the installer handles that matter:

* **It refuses to use `python3`.** In Git Bash that name is a Microsoft Store
  app-execution alias under `WindowsApps` — a per-user reparse point a
  LocalSystem service cannot follow. It finds a real `python.exe` instead.
* **It never lets the service hard-kill the panel.** Stopping is wired to
  `server.py --shutdown`, which stops the proxy, flushes the world and then
  stops Paper, blocking until done. A plain kill gives Paper no chance to
  save: the world rolls back to the last autosave and a kill landing
  mid-region-write can corrupt chunks.

Don't run `start.sh` while the service is running — they fight over ports.

## Scripts

| Script | What it does |
|--------|--------------|
| `setup.sh` | Java 21 JRE, Paper 1.20.4 (sha256-verified), BungeeCord, EaglerXServer, Via stack, tuned configs. Re-runnable. |
| `start.sh` | Loads `.env`, creates DB tables, checks port bindings, boots panel + SMP + dev tunnel. |
| `stop.sh`  | Stops everything. |
| `tunnel.sh`| Just the dev tunnel (persistent, anonymous). |

## Layout

```
server.py            web app (stdlib HTTP, SQLite, auth, worlds, SMP control + console)
web/                 frontend (index, dashboard, play) + eaglercraft/index.html (client)
smp-config/          tuned Paper/Spigot/Bukkit configs (copied in by setup.sh)
  ├ server.properties         view 5, simulation 4, entity broadcast 50%
  ├ spigot.yml                activation + tracking ranges, collisions
  ├ bukkit.yml                spawn limits
  ├ paper-global.yml          chunk send rate, chunk-system threads, limiter
  └ paper-world-defaults.yml  despawn ranges, collisions, hopper/pathfinding
bungee-config/       known-good BungeeCord config
setup.sh start.sh stop.sh tunnel.sh
.env.example         RAM / port / behaviour knobs
data/                runtime: SQLite db, worlds, the server + proxy (git-ignored)
runtime/             the downloaded JRE (git-ignored)
```

## Config knobs

Copy `.env.example` to `.env` — `start.sh` loads it.

- `data/admin.conf` — admin username/password (re-applied on each boot)
- `SMP_RAM_MB` — budget for the **whole network** (default 4096). The proxy
  takes `SMP_PROXY_RAM_MB` (default 512) and Paper receives the remainder, so
  the two heaps can never over-commit the host.
- `PORT` — website port (default 8080)
- `SMP_PORT` — proxy/websocket port players connect to (default 25577)
- `JAVA21_HOME` — use a specific Java 21 instead of the bundled one.
  Java 17+ is mandatory: Paper 1.20.4 cannot start on Java 8 or 11.

## Security notes

Meant for friends/classroom hosting. Passwords use PBKDF2-HMAC-SHA256 (200k iters,
per-user salt); sessions are HMAC-signed `HttpOnly` cookies. The SMP runs in offline
mode (required for Eaglercraft) behind the proxy. If you expose it widely, keep the
dev tunnel’s HTTPS and consider rate-limiting.

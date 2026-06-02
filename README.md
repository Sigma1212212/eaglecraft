# 🟩 EagleCraft

A self-hosted **browser Minecraft** platform for a class/group:

- **Accounts** for every student (passwords hashed, sessions signed) — data persists in SQLite
- **Per-account worlds** — upload your world export, download it on any device (150 MB quota each)
- **about:blank launcher** — pops the game into a clean window
- **A real SMP** that renders server-side (Paper + 8 GB RAM) with **economy & shop signs** and **spawn**
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
Eaglercraft 1.8 client
      │  wss
      ▼
BungeeCord  +  EaglerXServer        data/bungee/   (port 25577, player-facing)
      │  forwards
      ▼
Paper 1.20.4  +  ViaVersion/Backwards/Rewind  +  EssentialsX   data/smp/  (port 25565)
```

> **Why Paper 1.20.4?** EaglerXServer’s Bukkit module breaks on Paper ≥ 1.20.5
> (Mojang mappings). Running EaglerXServer on **BungeeCord** + a 1.20.4 backend,
> with Via to accept 1.8 clients, is the combination that actually works.

### Spawn & shop (admin)

Log in as admin → dashboard → **Server Console**:

1. `op <yourEaglercraftName>`
2. In-game: stand where spawn should be → `/setspawn`
3. Build a shop: place a sign —
   ```
   [Buy]          [Sell]
   1              1
   diamond        cobblestone
   100            2
   ```
   Players start with **500** coins; `[Buy]`/`[Sell]`/`[Trade]` signs and `/sell hand` all work.

---

## Scripts

| Script | What it does |
|--------|--------------|
| `setup.sh` | Downloads Java/Paper/Bungee/plugins, installs configs. Re-runnable. |
| `start.sh` | Boots web server + SMP (`AUTOSTART_SMP=1`) + dev tunnel. |
| `stop.sh`  | Stops everything. |
| `tunnel.sh`| Just the dev tunnel (persistent, anonymous). |

## Layout

```
server.py            web app (stdlib HTTP, SQLite, auth, worlds, SMP control + console)
web/                 frontend (index, dashboard, play) + eaglercraft/index.html (client)
smp-config/          known-good Paper/Spigot/Essentials configs (copied in by setup.sh)
bungee-config/       known-good BungeeCord config
setup.sh start.sh stop.sh tunnel.sh
data/                runtime: SQLite db, worlds, the server + proxy (git-ignored)
runtime/             the downloaded JRE (git-ignored)
```

## Config knobs

- `data/admin.conf` — admin username/password (re-applied on each boot)
- `SMP_RAM_MB` env — backend heap in MB (default 8192)
- `PORT` env — website port (default 8080)
- `JAVA21_HOME` env — use a specific Java 21 instead of the bundled one

## Security notes

Meant for friends/classroom hosting. Passwords use PBKDF2-HMAC-SHA256 (200k iters,
per-user salt); sessions are HMAC-signed `HttpOnly` cookies. The SMP runs in offline
mode (required for Eaglercraft) behind the proxy. If you expose it widely, keep the
dev tunnel’s HTTPS and consider rate-limiting.

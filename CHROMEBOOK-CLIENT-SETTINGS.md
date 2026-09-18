# Chromebook client settings

Give this page to the players. The server is already doing everything it can —
these are the settings **inside the Eaglercraft game window** that keep the
browser's render thread alive on a low-end Chromebook.

Open in-game: **Options → Video Settings**

## Apply these exactly

| Setting | Set it to | Why it matters in a browser |
|---|---|---|
| **Render Distance** | **4 chunks** (max 5) | The single biggest one. Every chunk is a mesh the browser rebuilds on the main JS thread. The server only sends 5 anyway, so going higher just wastes memory. |
| **Graphics** | **Fast** | Removes transparent-leaf and fancy-water shading — large fill-rate saving on Intel UHD / Mali GPUs. |
| **Smooth Lighting** | **OFF** | Per-vertex light blending is recalculated on every chunk rebuild. Off = noticeably faster chunk loads. |
| **Particles** | **Minimal** | Particles are per-frame draw calls with no gameplay value. |
| **Clouds** | **OFF** | A full-screen transparent layer redrawn every frame. |
| **Max Framerate** | **30 fps** (or VSync) | Counter-intuitive but correct: capping frees CPU for chunk meshing and stops the fans/thermal throttling that causes the "it got slow after 10 minutes" complaint. |
| **Entity Shadows** | **OFF** | A second render pass per entity. |
| **View Bobbing** | **OFF** | Small win, and reduces motion sickness. |
| **Fullscreen** | **OFF** | Fullscreen forces the canvas to the panel's native resolution. A windowed canvas renders fewer pixels. |
| **Brightness** | Moody / default | Bright forces a lightmap recalculation. |
| **Mipmap Levels** | **0** | Saves texture memory on GPUs with tiny VRAM budgets. |

## Browser habits that matter as much as the settings

1. **Close every other tab.** Chromebook RAM is the real limit — the game tab
   wants ~1 GB on its own. Other tabs are what cause the "Aw, Snap!" crash.
2. **Keep the game tab in the foreground.** Chrome throttles background tabs;
   the game falls behind the server and gets disconnected.
3. **Plug in the charger.** ChromeOS on battery drops the CPU to a low power
   state and the game will stutter no matter what the server does.
4. **Don't cast/screen-share while playing.** Screen capture competes for the
   same GPU the canvas uses.
5. **If it stutters when you first join**, stand still for ten seconds. The
   server is deliberately feeding chunks slowly (12/second) so the browser can
   keep up — running away from spawn while it loads is what freezes the tab.

## Quick triage

| Symptom | Fix |
|---|---|
| Tab crashes on join | Render distance too high, or too many tabs open. Set 4, close everything else. |
| World loads in slow squares | Expected — that's the chunk send rate protecting you. It fills in. |
| Fine, then gets bad after ~10 min | Thermal throttling. Plug in, cap framerate at 30. |
| Teleporting / rubber-banding | Network, not video. Check wifi; this one is not fixed by video settings. |
| Black screen, audio still plays | GPU process died. Reload the tab (Ctrl+R) — the world is saved server-side. |

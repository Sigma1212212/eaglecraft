// Dashboard logic: guard auth, render worlds + storage + the SMP.

let ME = null;

(async function init() {
  const me = await api('/api/me');
  if (!me.ok) { location.href = '/'; return; }
  ME = me.data;
  document.getElementById('who').textContent =
    'Signed in as ' + ME.username + (ME.is_admin ? ' (admin)' : '');
  const wp = document.getElementById('webport');
  if (wp) wp.textContent = location.port || '8080';
  loadWorlds();
  loadSmp();
})();

// ---- about:blank launcher (shared) ---------------------------------------
function launchBlank() {
  const w = window.open('about:blank', '_blank');
  if (!w) { alert('Allow pop-ups for this site, then click Launch again.'); return; }
  const url = location.origin + '/eaglercraft/index.html';
  const d = w.document;
  d.open();
  d.write('<!DOCTYPE html><html><head><title>EagleCraft</title>' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">' +
    '<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}' +
    'iframe{position:fixed;inset:0;border:0;width:100vw;height:100vh}</style></head>' +
    '<body><iframe src="' + url + '" allow="fullscreen; autoplay; gamepad; ' +
    'pointer-lock; clipboard-write; microphone; camera"></iframe></body></html>');
  d.close();
}

// ---- worlds + storage ----------------------------------------------------
async function loadWorlds() {
  const el = document.getElementById('worlds');
  const res = await api('/api/worlds');
  const worlds = (res.data.worlds) || [];
  const used = res.data.used || 0, quota = res.data.quota || 1;
  const pct = Math.min(100, Math.round(used / quota * 100));
  const bar = document.getElementById('quota-bar');
  const txt = document.getElementById('quota-text');
  if (bar) bar.style.width = pct + '%';
  if (bar) bar.style.background = pct > 90 ? 'var(--red)' : 'var(--green)';
  if (txt) txt.textContent = `${fmtSize(used)} of ${fmtSize(quota)} used (${pct}%)`;

  if (!worlds.length) {
    el.innerHTML = '<div class="empty">No worlds yet — upload one below.</div>';
    return;
  }
  el.innerHTML = worlds.map(w => `
    <div class="item">
      <div class="grow">
        <div class="title">${esc(w.name)}</div>
        <div class="meta">${fmtSize(w.size)} · saved ${fmtTime(w.updated)}</div>
      </div>
      <a class="btn gray small" href="/api/worlds/${w.id}/download">⬇ Download</a>
      <button class="btn danger small" onclick="delWorld('${w.id}')">Delete</button>
    </div>`).join('');
}

async function uploadWorld() {
  const fileInput = document.getElementById('world-file');
  const msg = document.getElementById('world-msg');
  const file = fileInput.files[0];
  if (!file) return;
  let name = document.getElementById('world-name').value.trim() ||
             file.name.replace(/\.(epk|zip|bin)$/i, '');
  msg.className = 'msg'; msg.textContent = 'Uploading ' + file.name + '…';
  const buf = await file.arrayBuffer();
  const res = await api('/api/worlds', 'POST', null, buf,
    { 'X-World-Name': name, 'Content-Type': 'application/octet-stream' });
  fileInput.value = '';
  if (res.ok) {
    msg.className = 'msg ok'; msg.textContent = 'Uploaded “' + name + '”.';
    document.getElementById('world-name').value = '';
    loadWorlds();
  } else {
    msg.className = 'msg err'; msg.textContent = res.data.error || 'Upload failed';
  }
}

async function delWorld(id) {
  if (!confirm('Delete this world from your account?')) return;
  await api('/api/worlds/' + id, 'DELETE');
  loadWorlds();
}

// ---- the SMP -------------------------------------------------------------
async function loadSmp() {
  const res = await api('/api/smp');
  if (!res.ok) return;
  const s = res.data;
  document.getElementById('smp-status').innerHTML =
    `<span class="pill ${s.running ? 'on' : 'off'}">${s.running ? 'online' : 'offline'}</span>`;
  document.getElementById('smp-port').textContent = s.port;

  const ctrl = document.getElementById('smp-controls');
  const consoleBox = document.getElementById('smp-console');
  if (s.is_admin) {
    ctrl.innerHTML = s.running
      ? `<button class="btn gray small" onclick="ctrlSmp('stop')">Stop SMP</button>`
      : `<button class="btn small" onclick="ctrlSmp('start')">Start SMP</button>`;
    if (!s.java || !s.jar) {
      ctrl.innerHTML += `<div class="msg" style="color:var(--muted)">` +
        `Needs ${!s.java ? 'Java' : ''}${(!s.java && !s.jar) ? ' + ' : ''}` +
        `${!s.jar ? 'server jar' : ''} — run <code>setup_server.sh</code>.</div>`;
    }
    consoleBox.style.display = s.running ? '' : 'none';
    if (s.running && !window._consoleTimer) {
      refreshConsole();
      window._consoleTimer = setInterval(refreshConsole, 4000);
    }
  } else {
    ctrl.innerHTML = `<span class="meta">Only the admin can start/stop the SMP.</span>`;
  }
}

async function refreshConsole() {
  const out = document.getElementById('console-out');
  if (!out) return;
  const res = await api('/api/smp/log');
  if (res.ok) {
    const atBottom = out.scrollTop + out.clientHeight >= out.scrollHeight - 20;
    out.textContent = res.data.log || '(no output yet)';
    if (atBottom) out.scrollTop = out.scrollHeight;
  }
}

async function sendCmd() {
  const inp = document.getElementById('console-cmd');
  const cmd = inp.value.trim();
  if (!cmd) return;
  inp.value = '';
  const res = await api('/api/smp/cmd', 'POST', { command: cmd });
  const msg = document.getElementById('smp-msg');
  if (res.ok) { msg.className = 'msg ok'; msg.textContent = 'Ran: ' + cmd; }
  else { msg.className = 'msg err'; msg.textContent = res.data.error || 'Failed'; }
  setTimeout(refreshConsole, 500);
}

async function ctrlSmp(action) {
  const msg = document.getElementById('smp-msg');
  msg.className = 'msg'; msg.textContent = action === 'start' ? 'Starting…' : 'Stopping…';
  const res = await api('/api/smp/' + action, 'POST');
  if (res.ok) { msg.className = 'msg ok'; msg.textContent = res.data.note || 'Done.'; }
  else { msg.className = 'msg err'; msg.textContent = res.data.error || 'Failed'; }
  loadSmp();
}

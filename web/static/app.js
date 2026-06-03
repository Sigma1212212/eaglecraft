// Shared helpers for all pages.

async function api(path, method = 'GET', body = null, raw = null, headers = {}) {
  const opts = { method, headers: { ...headers }, credentials: 'same-origin' };
  if (raw !== null) {
    opts.body = raw;
  } else if (body !== null) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(path, opts);
  let data = {};
  const ct = res.headers.get('Content-Type') || '';
  if (ct.includes('application/json')) {
    try { data = await res.json(); } catch (e) { data = {}; }
  }
  return { ok: res.ok, status: res.status, data, res };
}

async function logout() {
  await api('/api/logout', 'POST');
  location.href = '/chooser';
}

function fmtSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / 1024 / 1024).toFixed(1) + ' MB';
}

function fmtTime(epoch) {
  return new Date(epoch * 1000).toLocaleString();
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

// Shared "launch into about:blank" helper.
//
// Opens a clean about:blank window and loads the target (game / EagleCraft /
// the chooser) inside a full-window iframe. The address bar stays about:blank.
// The iframe is same-origin, so content keeps using the browser's own
// localStorage / IndexedDB — the server never touches save data.
//
// We build the iframe with the DOM API (more reliable than document.write into
// a popup) and use an ABSOLUTE url (about:blank has no base url of its own).
function launchBlank(url, title) {
  const full = /^https?:\/\//.test(url) ? url : location.origin + url;
  let win;
  try { win = window.open('about:blank', '_blank'); } catch (e) { win = null; }
  if (!win) {
    alert('Please allow pop-ups for this site, then click again.');
    return false;
  }

  function inject() {
    try {
      const doc = win.document;
      doc.title = title || 'Play';
      if (doc.documentElement) doc.documentElement.style.cssText = 'margin:0;height:100%;background:#000';
      doc.body.style.cssText = 'margin:0;padding:0;height:100vh;background:#000;overflow:hidden';
      doc.body.innerHTML = '';
      const f = doc.createElement('iframe');
      f.src = full;
      f.setAttribute('allow', 'fullscreen; autoplay; gamepad; pointer-lock; clipboard-write; microphone; camera');
      f.style.cssText = 'position:fixed;top:0;left:0;border:0;width:100vw;height:100vh';
      doc.body.appendChild(f);
    } catch (e) {
      // Last resort: navigate the popup straight to the content.
      try { win.location.href = full; } catch (_) {}
    }
  }

  if (win.document && win.document.body) inject();
  else setTimeout(inject, 60);
  return false;
}

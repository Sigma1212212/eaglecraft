// Shared "launch into about:blank" helper.
//
// Opens a clean about:blank window and loads the target (game or EagleCraft)
// inside a full-window iframe. The iframe is same-origin, so the content keeps
// using the *browser's* own localStorage / IndexedDB for save data — the server
// never touches it.
//
// Key detail: an about:blank document has no base URL, so the iframe src MUST be
// an absolute URL (with origin), otherwise the content can't load.
function launchBlank(url, title) {
  const full = /^https?:\/\//.test(url) ? url : location.origin + url;
  let win;
  try { win = window.open('about:blank', '_blank'); } catch (e) { win = null; }
  if (!win) {
    alert('Please allow pop-ups for this site, then click again.');
    return false;
  }
  const html =
    '<!DOCTYPE html><html><head><meta charset="utf-8">' +
    '<title>' + (title || 'Play') + '</title>' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">' +
    '<style>html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden}' +
    'iframe{position:fixed;inset:0;border:0;width:100vw;height:100vh}</style></head>' +
    '<body><iframe src="' + full + '" allow="fullscreen; autoplay; gamepad; ' +
    'pointer-lock; clipboard-write; microphone; camera"></iframe></body></html>';
  try {
    win.document.open();
    win.document.write(html);
    win.document.close();
  } catch (e) {
    // Fallback for browsers that block document.write into the popup.
    win.location = full;
  }
  return false;
}

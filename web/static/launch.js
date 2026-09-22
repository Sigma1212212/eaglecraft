// Shared navigation helper.
//
// This used to open an about:blank pop-up and inject the target into a
// full-window iframe. That was removed: it required pop-up permission, showed
// a blank screen whenever the browser blocked it, and hid the real URL so the
// game could not be bookmarked, reloaded or shared.
//
// Navigating normally also means the browser can cache the page properly and
// the back button behaves.
function openApp(url) {
  const full = /^https?:\/\//.test(url) ? url : location.origin + url;
  location.href = full;
  return false;
}

// Old name, kept so any page still calling it keeps working.
function launchBlank(url, _title) {
  return openApp(url);
}

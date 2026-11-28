function linkify(text) {
  const esc = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return esc.replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" target="_blank" rel="noopener">$1</a>');
}

(async () => {
  const el = document.getElementById('content');
  try {
    const store = (chrome.storage.session || chrome.storage.local);
    const data = await store.get('herbertResult');
    const r = data && data.herbertResult;
    if (r) {
      document.getElementById('title').textContent = r.title || 'Herbert';
      document.getElementById('meta').textContent = new Date(r.ts || Date.now()).toLocaleString('de-DE');
      el.innerHTML = linkify(r.text || '');
      await store.remove('herbertResult');
    } else {
      el.textContent = 'Kein Ergebnis vorhanden.';
    }
  } catch (e) {
    el.textContent = 'Fehler: ' + ((e && e.message) ? e.message : String(e));
  }
})();

document.getElementById('btnBack').addEventListener('click', () => history.back());

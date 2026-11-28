// SysPilot Extension Manager - Popup-Logik
// chrome.management API: Liste, Enable/Disable, Entfernen, Detailseite.
// Export/Import: HTML mit eingebettetem JSON - Sync zwischen Browsern.

const $ = id => document.getElementById(id);
let allExts = [];

const STORE_URL = id => 'https://chromewebstore.google.com/detail/' + id;
const DETAIL_SCHEME = (() => {
  // chrome://extensions laesst sich intern oeffnen - wie der
  // Zahnrad-Button in Easy Extension Manager (chrome.tabs.create)
  return 'chrome://extensions/';
})();

async function load() {
  setStatus('Lade...');
  try {
    allExts = await chrome.management.getAll();
  } catch (e) {
    setStatus('Fehler: ' + e.message);
    return;
  }
  // eigene Extension aus der Liste filtern (kann sich nicht selbst entfernen)
  const self = await chrome.management.getSelf().catch(() => null);
  render();
  const en = allExts.filter(e => e.enabled).length;
  $('counts').textContent = allExts.length + ' gesamt, ' + en + ' aktiv';
  setStatus('');
}

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function iconUrl(e) {
  if (e.icons && e.icons.length) {
    // groesstes Icon >= 32px bevorzugen, sonst letztes
    const sorted = [...e.icons].sort((a, b) => b.size - a.size);
    const pick = sorted.find(i => i.size >= 32) || sorted[0];
    return pick.url;
  }
  return 'icon.png';
}

function render() {
  const q = ($('search').value || '').toLowerCase().trim();
  const onlyDisabled = $('chkDisabled').checked;
  const list = $('list');
  list.innerHTML = '';
  const shown = allExts.filter(e => {
    if (onlyDisabled && e.enabled) return false;
    if (!q) return true;
    return (e.name || '').toLowerCase().includes(q)
        || (e.id || '').toLowerCase().includes(q)
        || (e.description || '').toLowerCase().includes(q);
  });
  $('empty').hidden = shown.length > 0;
  for (const e of shown) {
    const li = document.createElement('li');
    li.className = 'ext' + (e.enabled ? '' : ' disabled');
    const ver = e.version ? ' v' + e.version : '';
    const installType = e.installType === 'development' ? ' [dev]' : '';
    const host = e.hostPermissions && e.hostPermissions.length ? ' · ' + e.hostPermissions.length + ' Hosts' : '';
    li.innerHTML =
      '<img src="' + esc(iconUrl(e)) + '" alt="">' +
      '<div class="info">' +
        '<div class="name">' + esc(e.name || e.id) + '</div>' +
        '<div class="meta">' + esc(e.shortName || '') + esc(ver) + esc(installType) + esc(host) + '</div>' +
      '</div>' +
      '<div class="actions">' +
        '<button class="tgl" data-act="toggle" title="' + (e.enabled ? 'Deaktivieren' : 'Aktivieren') + '"></button>' +
        '<button data-act="details" title="Detailseite im Browser oeffnen">&#x2699;</button>' +
        '<button class="danger" data-act="remove" title="Entfernen">&#x1F5D1;</button>' +
      '</div>';
    li.querySelector('[data-act="toggle"]').addEventListener('click', () => toggle(e));
    li.querySelector('[data-act="details"]').addEventListener('click', () => openDetails(e));
    li.querySelector('[data-act="remove"]').addEventListener('click', () => removeExt(e));
    list.appendChild(li);
  }
}

async function toggle(e) {
  setStatus((e.enabled ? 'Deaktiviere' : 'Aktiviere') + ': ' + e.name + ' ...');
  try {
    await chrome.management.setEnabled(e.id, !e.enabled);
    e.enabled = !e.enabled;
    render();
    const en = allExts.filter(x => x.enabled).length;
    $('counts').textContent = allExts.length + ' gesamt, ' + en + ' aktiv';
    setStatus('');
  } catch (err) {
    setStatus('Fehler: ' + (err.message || err));
  }
}

function openDetails(e) {
  // Laeuft INNEN im Browser - chrome.tabs.create funktioniert hier
  // zuverlaessig (das war der Vorteil von Easy Extension Manager)
  chrome.tabs.create({ url: 'chrome://extensions/?id=' + e.id });
}

async function removeExt(e) {
  // Chrome-eigener Bestaetigungsdialog (showConfirmDialog) - der kennt
  // die "aus Sync entfernen?"-Option und ist trusted, im Gegensatz zu
  // window.confirm() im Popup.
  setStatus('Entferne: ' + (e.name || e.id) + ' ...');
  try {
    await chrome.management.uninstall(e.id, { showConfirmDialog: true });
    allExts = allExts.filter(x => x.id !== e.id);
    render();
    $('counts').textContent = allExts.length + ' gesamt, ' + allExts.filter(x => x.enabled).length + ' aktiv';
    setStatus('Entfernt: ' + (e.name || e.id));
    setTimeout(() => setStatus(''), 4000);
  } catch (err) {
    const msg = (err && err.message) ? err.message : String(err);
    setStatus('Fehler: ' + msg + ' - versuche Detailseite ...');
    // Fallback: policy-installierte/geschuetzte Extensions kann
    // chrome.management nicht entfernen - Detailseite oeffnen
    setTimeout(() => { openDetails(e); setStatus(''); }, 1500);
  }
}

// ---------- Export / Import ----------
function exportHtml() {
  const data = {
    app: 'SysPilot Extension Manager',
    exported: new Date().toISOString(),
    count: allExts.length,
    extensions: allExts.map(e => ({
      id: e.id, name: e.name, version: e.version, enabled: e.enabled,
      description: e.description || '', installType: e.installType || '',
      hostPermissions: e.hostPermissions || [], permissions: e.permissions || []
    }))
  };
  const json = JSON.stringify(data, null, 1);
  const rows = data.extensions.map(e =>
    '<tr><td><img src="' + iconUrlSafe(e) + '" style="width:16px;height:16px;vertical-align:middle"></td>' +
    '<td>' + escHtml(e.name || e.id) + '</td><td>' + escHtml(e.version || '') + '</td>' +
    '<td>' + (e.enabled ? 'AN' : 'aus') + '</td><td><code>' + escHtml(e.id) + '</code></td>' +
    '<td><a href="' + STORE_URL(e.id) + '">Store</a></td></tr>').join('');
  const html = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>SysPilot Extension Export</title>' +
    '<style>body{font-family:Segoe UI,sans-serif;background:#1e1e2e;color:#e6e6f0;padding:24px}' +
    'h1{color:#ff8c00}table{border-collapse:collapse;width:100%}td,th{padding:6px 10px;border-bottom:1px solid #33334d;text-align:left;font-size:13px}' +
    'a{color:#7ab8ff}code{color:#9a9ab5;font-size:11px}</style></head><body>' +
    '<h1>SysPilot Extension Export</h1>' +
    '<p>' + escHtml(data.exported) + ' - ' + data.count + ' Extensions. ' +
    'Import in einem anderen Browser: Datei in der SysPilot Extension Manager Extension waehlen.</p>' +
    '<table><tr><th></th><th>Name</th><th>Version</th><th>Status</th><th>ID</th><th></th></tr>' + rows + '</table>' +
    '<script type="application/json" id="syspilot-ext-data">' + json.replace(/</g, '\\u003c') + '</scr' + 'ipt>' +
    '</body></html>';
  const blob = new Blob([html], { type: 'text/html' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'syspilot-extensions-' + new Date().toISOString().slice(0, 10) + '.html';
  document.body.appendChild(a);
  a.click();
  a.remove();
  setStatus('Export gespeichert: ' + a.download);
  setTimeout(() => setStatus(''), 4000);
}
function iconUrlSafe(e) { return 'icon.png'; }
function escHtml(s) { return esc(s); }

function parseImportFile(file) {
  const reader = new FileReader();
  reader.onload = () => {
    const txt = String(reader.result || '');
    let data = null;
    // eingebettetes JSON im HTML suchen
    const m = txt.match(/<script type="application\/json" id="syspilot-ext-data">([\s\S]*?)<\/script>/);
    const raw = m ? m[1] : txt;
    try { data = JSON.parse(raw); } catch (e) {
      // evtl. simpler Array-Export
      try { const j = JSON.parse(txt); data = { extensions: Array.isArray(j) ? j : (j.extensions || []) }; }
      catch (e2) { setStatus('Import fehlgeschlagen: keine SysPilot-Export-Daten gefunden'); return; }
    }
    const exts = (data.extensions || []).map(x => ({
      id: x.id, name: x.name || x.id, version: x.version || '', enabled: x.enabled !== false
    }));
    showImportPanel(exts, data.exported || '');
  };
  reader.readAsText(file);
}

async function showImportPanel(exts, exported) {
  const panel = $('importPanel');
  const installed = new Set(allExts.map(e => e.id));
  const missing = exts.filter(e => !installed.has(e.id));
  const present = exts.filter(e => installed.has(e.id));
  panel.hidden = false;
  panel.innerHTML = '<h4>Import: ' + exts.length + ' Eintraege' +
    (exported ? ' (Export vom ' + esc(exported) + ')' : '') + '</h4>' +
    present.slice(0, 10).map(e =>
      '<div class="imp-item"><span>' + esc(e.name) + '</span><span class="st">vorhanden</span></div>').join('') +
    (present.length > 10 ? '<div class="imp-item"><span>...+' + (present.length - 10) + ' weitere vorhanden</span></div>' : '') +
    missing.map(e =>
      '<div class="imp-item"><span>' + esc(e.name) + ' <code>' + esc(e.id) + '</code></span>' +
      '<span><span class="st missing">fehlt</span> <a href="' + STORE_URL(e.id) + '" target="_blank">Store</a></span></div>').join('') +
    (missing.length === 0 ? '<div class="imp-item"><span class="st">Alles bereits installiert.</span></div>' : '') +
    '<div style="margin-top:6px;color:#9a9ab5;font-size:11px">Chrome erlaubt keine Direktinstallation - „Store" oeffnet die Webstore-Seite. Sync zwischen Browsern: Export in Browser A, Import in Browser B.</div>';
}

// ---------- Events ----------
$('search').addEventListener('input', render);
$('chkDisabled').addEventListener('change', render);
$('btnRefresh').addEventListener('click', load);
$('btnExport').addEventListener('click', exportHtml);
$('btnImport').addEventListener('click', () => $('fileImport').click());
$('fileImport').addEventListener('change', e => {
  const f = e.target.files && e.target.files[0];
  if (f) parseImportFile(f);
  e.target.value = '';
});

function setStatus(t) { $('status').textContent = t; }

load();

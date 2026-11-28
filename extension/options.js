const $ = id => document.getElementById(id);
const statusEl = $('status');

async function load() {
  const c = await chrome.storage.local.get(['apiUrl', 'apiKey', 'model']);
  $('apiUrl').value = c.apiUrl || 'http://127.0.0.1:8377/v1';
  $('apiKey').value = c.apiKey || '';
  $('model').value = c.model || 'herbert';
}

$('btnSave').addEventListener('click', async () => {
  await chrome.storage.local.set({
    apiUrl: $('apiUrl').value.trim(),
    apiKey: $('apiKey').value.trim(),
    model: $('model').value.trim() || 'herbert'
  });
  statusEl.className = 'ok';
  statusEl.textContent = 'Gespeichert.';
});

$('btnTest').addEventListener('click', async () => {
  statusEl.className = ''; statusEl.textContent = 'Teste ...';
  try {
    const c = await chrome.storage.local.get(['apiUrl', 'apiKey']);
    const base = (c.apiUrl || 'http://127.0.0.1:8377/v1').replace(/\/+$/, '');
    const headers = {};
    if (c.apiKey) headers['Authorization'] = 'Bearer ' + c.apiKey;
    const r = await fetch(base.replace(/\/v1$/, '') + '/health', { headers });
    if (r.ok) {
      const j = await r.json().catch(() => ({}));
      statusEl.className = 'ok';
      statusEl.textContent = 'Verbunden: ' + (j.service || 'herbert') + ' v' + (j.version || '?');
    } else {
      statusEl.className = 'fail';
      statusEl.textContent = 'HTTP ' + r.status + (r.status === 401 ? ' - API-Key falsch' : '');
    }
  } catch (e) {
    statusEl.className = 'fail';
    statusEl.textContent = 'Nicht erreichbar - laeuft der Herbert-API-Server? (' + (e.message || e) + ')';
  }
});

document.addEventListener('DOMContentLoaded', load);

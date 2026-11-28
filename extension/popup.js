// Herbert Popup - sendet Aufgaben an den Background-Service-Worker.
const $ = id => document.getElementById(id);
const resultEl = $('result'), errEl = $('err'), inputEl = $('askInput');

function linkify(text) {
  const esc = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return esc.replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" target="_blank">$1</a>');
}

function showErr(msg) { errEl.textContent = msg; errEl.classList.remove('hidden'); }
function clearOut() { resultEl.classList.add('hidden'); errEl.classList.add('hidden'); }

async function run(task, arg) {
  clearOut();
  const btns = document.querySelectorAll('button[data-task]');
  btns.forEach(b => b.disabled = true);
  resultEl.classList.remove('hidden');
  resultEl.textContent = 'Herbert denkt nach ...';
  try {
    const withPage = $('withPage').checked;
    const r = await chrome.runtime.sendMessage({
      type: 'herbert:runTask', task, arg,
      withPage: withPage || ['summarize','translate','transcript'].includes(task)
    });
    if (!r || !r.ok) throw new Error((r && r.error) || 'Keine Antwort');
    resultEl.innerHTML = linkify(r.text || '');
  } catch (e) {
    resultEl.classList.add('hidden');
    showErr((e && e.message) ? e.message : String(e));
    if (/HTTP 401|403/.test(String(e))) showErr('API-Key fehlt oder falsch - in den Einstellungen (Zahnrad) eintragen.');
  } finally {
    btns.forEach(b => b.disabled = false);
  }
}

// Status-Punkt
document.addEventListener('DOMContentLoaded', async () => {
  try {
    const r = await chrome.runtime.sendMessage({ type: 'herbert:status' });
    $('statusDot').className = 'dot ' + (r && r.ok ? 'on' : 'off');
  } catch { $('statusDot').className = 'dot off'; }
});

document.querySelectorAll('button[data-task]').forEach(btn => {
  btn.addEventListener('click', () => {
    const task = btn.dataset.task;
    const arg = (task === 'ask' || task === 'assist') ? inputEl.value.trim() : undefined;
    const lang = $('langSel').value;
    if ((task === 'ask' || task === 'assist') && !arg && !$('withPage').checked) {
      showErr('Bitte eine Frage eingeben oder „mit Seite" aktivieren.'); return;
    }
    run(task, task === 'translate' ? lang : arg);
  });
});

inputEl.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    document.querySelector('button[data-task="ask"]').click();
  }
});

$('btnOptions').addEventListener('click', e => {
  e.preventDefault();
  chrome.runtime.openOptionsPage();
});

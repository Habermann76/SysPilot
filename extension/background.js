// Herbert Browser-Extension - Background Service Worker
// Verbindet sich mit der lokalen Herbert-API (OpenAI-kompatibel)
// und stellt Summarize/Translate/Transcript/Ask/Assist bereit.

const DEFAULTS = { apiUrl: 'http://127.0.0.1:8377/v1', apiKey: '', model: 'herbert' };

async function getCfg() {
  const c = await chrome.storage.local.get(['apiUrl', 'apiKey', 'model']);
  return { ...DEFAULTS, ...c };
}

async function herbertChat({ prompt, system = '', history = [] }) {
  const cfg = await getCfg();
  const base = (cfg.apiUrl || DEFAULTS.apiUrl).replace(/\/+$/, '');
  const headers = { 'Content-Type': 'application/json' };
  if (cfg.apiKey) headers['Authorization'] = 'Bearer ' + cfg.apiKey;
  const messages = [];
  if (system) messages.push({ role: 'system', content: system });
  for (const h of history) messages.push(h);
  messages.push({ role: 'user', content: prompt });
  const resp = await fetch(base + '/chat/completions', {
    method: 'POST', headers,
    body: JSON.stringify({ model: cfg.model || 'herbert', messages, stream: false })
  });
  if (!resp.ok) {
    const t = await resp.text().catch(() => '');
    throw new Error('Herbert-API HTTP ' + resp.status + (t ? ': ' + t.slice(0, 200) : ''));
  }
  const data = await resp.json();
  const txt = data && data.choices && data.choices[0] && data.choices[0].message
    ? data.choices[0].message.content : '';
  if (!txt) throw new Error('Leere Antwort von Herbert');
  return txt;
}

async function apiStatus() {
  const cfg = await getCfg();
  const base = (cfg.apiUrl || DEFAULTS.apiUrl).replace(/\/+$/, '');
  try {
    const r = await fetch(base.replace(/\/v1$/, '') + '/health', { method: 'GET' });
    return r.ok;
  } catch { return false; }
}

// --- Seiten-Text / Transkript-Tracks ueber Content-Script holen ---
async function getPageContext(tabId) {
  try {
    const r = await chrome.tabs.sendMessage(tabId, { type: 'herbert:getPageText' });
    return (r && r.text) ? r.text : '';
  } catch { return ''; }
}
async function getCaptionTracks(tabId) {
  try {
    const r = await chrome.tabs.sendMessage(tabId, { type: 'herbert:getCaptionTracks' });
    return (r && r.tracks) ? r.tracks : [];
  } catch { return []; }
}

// YouTube-Transkript: timedtext json3 vom Caption-Track (background = kein CORS-Problem)
async function fetchTranscript(tabId) {
  const tracks = await getCaptionTracks(tabId);
  if (!tracks.length) return '';
  // Bevorzugt: de > en > erstes
  const pick = tracks.find(t => /^(de|de-DE|de-DE-x)/i.test(t.languageCode || ''))
            || tracks.find(t => /^(en|en-US|en-GB)/i.test(t.languageCode || ''))
            || tracks[0];
  let url = pick.baseUrl;
  url += (url.includes('?') ? '&' : '?') + 'fmt=json3';
  try {
    const r = await fetch(url);
    if (!r.ok) return '';
    const j = await r.json();
    const parts = [];
    for (const ev of (j.events || [])) {
      for (const seg of (ev.segs || [])) { if (seg.utf8) parts.push(seg.utf8); }
    }
    return parts.join('').replace(/\n{3,}/g, '\n\n').trim();
  } catch { return ''; }
}

// --- Aufgaben ---
const TASKS = {
  async summarize(ctx) {
    const text = ctx.pageText.slice(0, 24000);
    if (!text) throw new Error('Kein Seitentext extrahierbar.');
    return herbertChat({
      system: 'Du bist Herbert, der KI-Assistent aus SysPilot. Fasse den folgenden Seitentext KURZ und KNADEIG in deutscher Sprache zusammen (Kernaussagen, Stichpunkte, keine Einleitung).',
      prompt: 'Titel: ' + ctx.title + '\nURL: ' + ctx.url + '\n\n' + text
    });
  },
  async translate(ctx, lang) {
    const text = ctx.pageText.slice(0, 20000);
    if (!text) throw new Error('Kein Seitentext extrahierbar.');
    const target = lang || 'Deutsch';
    return herbertChat({
      system: 'Du bist ein Uebersetzer. Uebersetze den folgenden Text nach ' + target + '. Gib NUR die Uebersetzung aus, ohne Anmerkungen, ohne Einleitung.',
      prompt: text
    });
  },
  async transcript(ctx) {
    if (!ctx.transcript) throw new Error('Kein Transkript gefunden (YouTube-Video mit Untertiteln noetig).');
    return herbertChat({
      system: 'Du bist Herbert. Erstellt eine knappe, strukturierte Zusammenfassung des Transkripts (Abschnitte mit Stichpunkten, Kernaussagen). Deutsch.',
      prompt: 'Video: ' + ctx.title + '\n\nTranskript:\n' + ctx.transcript.slice(0, 30000)
    });
  },
  async ask(ctx, question) {
    if (!question) throw new Error('Keine Frage angegeben.');
    const sys = 'Du bist Herbert, der KI-Assistent aus SysPilot (localhost). Antworte knapp und konkret auf Deutsch.';
    const prompt = ctx.pageText
      ? 'Seite: ' + ctx.title + ' (' + ctx.url + ')\n\nInhalt (Auszug):\n' + ctx.pageText.slice(0, 12000) + '\n\nFrage: ' + question
      : question;
    return herbertChat({ system: sys, prompt });
  },
  async assist(ctx, question) {
    return TASKS.ask(ctx, question || 'Was ist auf dieser Seite wichtig?');
  },
  async copyText(ctx) {
    return ctx.pageText ? ctx.pageText.slice(0, 50000) : '';
  }
};

async function runTask(tab, task, arg, opts) {
  const o = opts || {};
  const withPage = o.withPage !== false;
  const needsPage = withPage && ['summarize','translate','ask','assist','copyText'].includes(task);
  const needsTranscript = (task === 'transcript');
  const ctx = {
    title: (tab && tab.title) || '',
    url: (tab && tab.url) || '',
    pageText: needsPage ? await getPageContext(tab.id) : '',
    transcript: needsTranscript ? await fetchTranscript(tab.id) : ''
  };
  if (task === 'copyText') { return ctx.pageText; }
  return TASKS[task](ctx, arg);
}

// Ergebnis in eigenem Tab anzeigen (fuer Kontextmenue-Aufrufe)
async function showResult(title, text) {
  const store = (chrome.storage.session || chrome.storage.local);
  await store.set({ herbertResult: { title, text, ts: Date.now() } });
  await chrome.tabs.create({ url: chrome.runtime.getURL('result.html') });
}

// --- Nachrichten-Router (Popup/options/content) ---
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    try {
      if (msg.type === 'herbert:status') { sendResponse({ ok: await apiStatus() }); return; }
      if (msg.type === 'herbert:runTask') {
        const tab = sender.tab || (msg.tabId ? await chrome.tabs.get(msg.tabId) : null);
        if (!tab) { sendResponse({ ok: false, error: 'Kein aktiver Tab' }); return; }
        const out = await runTask(tab, msg.task, msg.arg, { withPage: msg.withPage });
        sendResponse({ ok: true, text: out });
        return;
      }
      if (msg.type === 'herbert:runTaskAndShow') {
        const tab = sender.tab || await chrome.tabs.get(msg.tabId);
        const out = await runTask(tab, msg.task, msg.arg);
        await showResult((tab && tab.title) || 'Herbert', out);
        sendResponse({ ok: true });
        return;
      }
      if (msg.type === 'herbert:rawChat') {
        const out = await herbertChat({ prompt: msg.prompt, system: msg.system || '' });
        sendResponse({ ok: true, text: out });
        return;
      }
      sendResponse({ ok: false, error: 'Unbekannte Nachricht: ' + msg.type });
    } catch (e) {
      sendResponse({ ok: false, error: (e && e.message) ? e.message : String(e) });
    }
  })();
  return true;
});

// --- Kontextmenue ---
chrome.runtime.onInstalled.addListener(() => {
  const mk = (id, title, contexts) => chrome.contextMenus.create({ id, title, contexts });
  mk('herbert-summarize', 'Mit Herbert zusammenfassen', ['page']);
  mk('herbert-ask', 'Mit Herbert besprechen', ['page', 'selection']);
  mk('herbert-assist', 'Herbert-Assistent (mit Seitenkontext)', ['page']);
  mk('herbert-transcript', 'Video/Transkript zusammenfassen (YouTube)', ['page']);
  mk('herbert-copy', 'Seiten-Text kopieren', ['page']);
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    if (info.menuItemId === 'herbert-copy') {
      chrome.tabs.sendMessage(tab.id, { type: 'herbert:copyPageText' }, () => void chrome.runtime.lastError);
      return;
    }
    const taskMap = {
      'herbert-summarize': 'summarize',
      'herbert-ask': 'ask',
      'herbert-assist': 'assist',
      'herbert-transcript': 'transcript'
    };
    const task = taskMap[info.menuItemId];
    if (!task) return;
    const arg = (task === 'ask') ? (info.selectionText || 'Was ist hier wichtig?') : undefined;
    const out = await runTask(tab, task, arg);
    await showResult((tab && tab.title) || 'Herbert', out);
  } catch (e) {
    await showResult('Herbert - Fehler', 'Fehler: ' + ((e && e.message) ? e.message : String(e)));
  }
});

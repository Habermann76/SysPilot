// Pilot Herbert - Browser-Waechter fuer SysPilot
// Erkennt auf GitHub-Repo-Seiten KI-/LLM-Begriffe und bietet einen
// Herbert-Badge: Klick -> 'syspilot://repo/Owner/Name' oeffnet den
// gefuehrten Installations-Assistenten in SysPilot.
(function () {
  'use strict';

  // KI-/LLM-Signale, die einen Installations-Vorschlag ausloesen
  const KEYWORDS = [
    'local llm', 'local-first', 'local ai', 'llm', 'gguf', 'ollama',
    'openai-compatible', 'ai assistant', 'personal ai', 'offline ai',
    'language model', 'inference', 'ai agent', 'mcp server',
    'uncensored', 'abliterated', 'heretic', 'chatbot', 'ai companion'
  ];

  const MAX_HITS = 3; // hoechstens N Badges pro Seite

  function repoSlug() {
    // github.com/Owner/Name[/...]
    const m = location.pathname.match(/^\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\/|$)/);
    if (!m) return null;
    const skip = new Set(['features','topics','trending','collections','orgs','users','settings','marketplace','pricing','login','signup','explore','about','apps','sponsors']);
    if (skip.has(m[1].toLowerCase()) || skip.has(m[2].toLowerCase())) return null;
    return m[1] + '/' + m[2];
  }

  function pageText() {
    // Titel + Repo-Beschreibung + Readme-Anfang + Topics (DOM, begrenzt)
    const parts = [];
    const title = document.querySelector('strong[itemprop="name"] a, [data-testid="repo-name"]')?.textContent;
    if (title) parts.push(title);
    const about = document.querySelector('[data-testid="repository-description"], .Layout-sidebar .f4.my-3, [itemprop="about"]');
    if (about) parts.push(about.textContent);
    const readme = document.querySelector('article.markdown-body, .markdown-body');
    if (readme) parts.push(readme.textContent.slice(0, 8000));
    document.querySelectorAll('a[href*="/topics/"]').forEach(a => parts.push(a.textContent));
    return parts.join(' ').toLowerCase();
  }

  function matchedKeywords(text) {
    return KEYWORDS.filter(k => text.includes(k));
  }

  function injectBadge(slug, hits) {
    if (document.getElementById('pilot-herbert-badge')) return;
    const btn = document.createElement('button');
    btn.id = 'pilot-herbert-badge';
    btn.textContent = 'Herbert: KI-Tool? (' + hits.slice(0, 3).join(', ') + ')';
    Object.assign(btn.style, {
      position: 'fixed', right: '16px', bottom: '16px', zIndex: 2147483647,
      padding: '8px 12px', borderRadius: '20px', border: 'none',
      background: 'linear-gradient(135deg,#0ea5e9,#6366f1)', color: '#fff',
      font: '600 12px/1.2 system-ui,sans-serif', cursor: 'pointer',
      boxShadow: '0 4px 14px rgba(0,0,0,.35)'
    });
    btn.title = 'Mit SysPilot Pilot Herbert installieren/einrichten';
    btn.onclick = () => {
      const url = 'syspilot://repo/' + slug;
      // Primaer: Protokoll-Handler (SysPilot muss installiert + Protokoll registriert sein)
      const a = document.createElement('a');
      a.href = url; a.style.display = 'none'; document.body.appendChild(a);
      try { a.click(); } catch (e) {}
      setTimeout(() => a.remove(), 500);
      // Fallback: Hinweis + Text in Zwischenablage
      const txt = 'SysPilot Installation: ' + 'https://github.com/' + slug;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(txt).catch(() => {});
      }
      btn.textContent = 'An SysPilot uebergeben - ggf. SysPilot installieren';
      setTimeout(() => { btn.textContent = 'Herbert: KI-Tool? (' + hits.slice(0, 3).join(', ') + ')'; }, 4000);
    };
    document.body.appendChild(btn);
  }

  function scan() {
    const slug = repoSlug();
    if (!slug) return;
    // Nur Repo-Hauptseiten (kein /blob/, /tree/, /issues ...)
    const sub = location.pathname.split('/').slice(3).join('/');
    if (sub && !/^(releases|actions|pulse|graphs|network|commits|branches|tags|stargazers|watchers|forks)?$/.test(sub)) return;
    const text = pageText();
    const hits = matchedKeywords(text);
    if (hits.length >= 2) injectBadge(slug, hits); // >=2 Keywords = echtes Signal, keine Single-Word-Zufalle
  }

  // GitHub ist SPA - spaet + bei Navigation erneut pruefen
  let lastUrl = location.href;
  setTimeout(scan, 1500);
  setInterval(() => {
    if (location.href !== lastUrl) { lastUrl = location.href; setTimeout(scan, 1200); }
  }, 1500);
})();

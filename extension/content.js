// Herbert Extension - Content Script
// Extrahiert Seiten-Text (lesbarer Artikel-Body), YouTube-Caption-Tracks
// und uebernimmt das Kopieren in die Zwischenablage.

function extractMainText() {
  // Grobe Readability: Skripte/Styles/Navs entfernen, groessten Textblock waehlen
  const clone = document.body ? document.body.cloneNode(true) : null;
  if (!clone) return '';
  clone.querySelectorAll('script,style,noscript,svg,canvas,iframe,form,nav,header,footer,aside,[role=navigation],[role=banner],[role=contentinfo],.advertisement,.ads,.cookie-banner,#cookie-banner').forEach(e => e.remove());
  const candidates = [clone.querySelector('article'), clone.querySelector('main'), clone.querySelector('[role=main]')].filter(Boolean);
  let best = clone;
  let bestLen = 0;
  const pool = candidates.length ? candidates : Array.from(clone.children);
  for (const el of pool) {
    const t = (el.innerText || '').trim();
    if (t.length > bestLen) { bestLen = t.length; best = el; }
  }
  let text = (best.innerText || '').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
  if (text.length > 60000) text = text.slice(0, 60000);
  return text;
}

function getYouTubeCaptionTracks() {
  try {
    const pr = window.ytInitialPlayerResponse;
    const tracks = pr && pr.captions && pr.captions.playerCaptionsTracklistRenderer
      && pr.captions.playerCaptionsTracklistRenderer.captionTracks;
    if (Array.isArray(tracks)) {
      return tracks.map(t => ({ baseUrl: t.baseUrl, languageCode: t.languageCode, name: t.name && t.name.simpleText }));
    }
  } catch (e) { }
  return [];
}

async function copyPageTextToClipboard() {
  const text = extractMainText();
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // Fallback: execCommand
    const ta = document.createElement('textarea');
    ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select();
    const ok = document.execCommand('copy');
    ta.remove();
    return ok;
  }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.type === 'herbert:getPageText') {
    sendResponse({ text: extractMainText() });
    return false;
  }
  if (msg.type === 'herbert:getCaptionTracks') {
    sendResponse({ tracks: getYouTubeCaptionTracks() });
    return false;
  }
  if (msg.type === 'herbert:copyPageText') {
    copyPageTextToClipboard().then(ok => sendResponse({ ok })).catch(() => sendResponse({ ok: false }));
    return true;
  }
  return false;
});

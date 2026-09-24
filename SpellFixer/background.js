// Service worker: בדיקה מקוונת מול LanguageTool, תפריט לחצן ימני וקיצורי מקלדת.
const API_URL = 'https://api.languagetool.org/v2/check';
const CHUNK_SIZE = 15000;   // השירות החינמי מגביל ל-20KB לבקשה
const MAX_CHUNKS = 4;       // ו-20 בקשות לדקה
const cache = new Map();
const CACHE_MAX = 60;

const DEFAULTS = {
  enabled: true,
  autoCheckFields: true,
  online: true,
  grammar: false,
  language: 'auto',
  custom: '',
  ignored: []
};

chrome.runtime.onInstalled.addListener(async () => {
  const current = await chrome.storage.local.get(null);
  await chrome.storage.local.set({ ...DEFAULTS, ...current });

  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: 'fix-field',
      title: 'תקן את כל שגיאות הכתיב בשדה',
      contexts: ['editable']
    });
    chrome.contextMenus.create({
      id: 'scan-page',
      title: 'סרוק את הדף לשגיאות כתיב',
      contexts: ['page', 'selection', 'link']
    });
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (tab && tab.id != null) {
    sendToTab(tab.id, { type: info.menuItemId === 'fix-field' ? 'FIX_FIELD' : 'SCAN_PAGE' }, info.frameId);
  }
});

chrome.commands.onCommand.addListener(async (command) => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return;
  // בקיצור מקלדת לא ידוע באיזו מסגרת נמצא השדה - שולחים לכולן, והמסגרת עם השדה הפעיל מגיבה
  sendToTab(tab.id, { type: command === 'fix-field' ? 'FIX_FIELD' : 'SCAN_PAGE', fromShortcut: true });
});

function sendToTab(tabId, message, frameId) {
  const opts = frameId != null ? { frameId } : undefined;
  chrome.tabs.sendMessage(tabId, message, opts).catch(() => {});
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === 'LT_CHECK') {
    checkOnline(msg.text, msg.language, msg.grammar)
      .then((result) => sendResponse({ ok: true, ...result }))
      .catch((err) => sendResponse({ ok: false, error: String(err && err.message || err) }));
    return true; // תשובה אסינכרונית
  }
  return false;
});

function splitChunks(text) {
  const chunks = [];
  let start = 0;
  while (start < text.length && chunks.length < MAX_CHUNKS) {
    let end = Math.min(start + CHUNK_SIZE, text.length);
    if (end < text.length) {
      // חיתוך בסוף שורה/משפט כדי לא לשבור מילה
      const nl = text.lastIndexOf('\n', end);
      const sp = text.lastIndexOf(' ', end);
      const cut = nl > start + CHUNK_SIZE / 2 ? nl : sp > start ? sp : end;
      end = cut;
    }
    chunks.push({ start, text: text.slice(start, end) });
    start = end;
  }
  return chunks;
}

const SPELLING_TYPES = new Set(['misspelling', 'typographical', 'duplication']);

async function checkOnline(text, language = 'auto', grammar = false) {
  const key = `${language}|${grammar}|${text}`;
  if (cache.has(key)) return cache.get(key);

  const matches = [];
  for (const chunk of splitChunks(text)) {
    if (!chunk.text.trim()) continue;
    const body = new URLSearchParams({ text: chunk.text, language });
    if (language === 'auto') body.set('preferredVariants', 'en-US,de-DE,pt-PT,ca-ES');

    const res = await fetch(API_URL, {
      method: 'POST',
      headers: { Accept: 'application/json' },
      body
    });
    if (res.status === 429) throw new Error('יותר מדי בקשות לשירות הבדיקה - נסו שוב בעוד דקה');
    if (!res.ok) throw new Error(`שגיאת שירות הבדיקה (${res.status})`);
    const data = await res.json();

    for (const m of data.matches || []) {
      const type = (m.rule && m.rule.issueType) || 'other';
      if (!grammar && !SPELLING_TYPES.has(type)) continue;
      matches.push({
        offset: chunk.start + m.offset,
        length: m.length,
        word: chunk.text.substr(m.offset, m.length),
        message: m.message || m.shortMessage || 'שגיאה אפשרית',
        replacements: (m.replacements || []).slice(0, 5).map((r) => r.value),
        type,
        ruleId: m.rule && m.rule.id,
        source: 'online'
      });
    }
  }

  const result = { matches };
  cache.set(key, result);
  if (cache.size > CACHE_MAX) cache.delete(cache.keys().next().value);
  return result;
}

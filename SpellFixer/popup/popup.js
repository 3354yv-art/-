const DEFAULTS = {
  enabled: true,
  autoCheckFields: true,
  online: true,
  grammar: false,
  language: 'auto',
  custom: '',
  ignored: []
};
const $ = (id) => document.getElementById(id);
const statusEl = $('status');

function setStatus(text, kind = '') {
  statusEl.textContent = text;
  statusEl.className = 'status' + (kind ? ' ' + kind : '');
}

async function load() {
  const s = { ...DEFAULTS, ...(await chrome.storage.local.get(null)) };
  for (const key of ['enabled', 'autoCheckFields', 'online', 'grammar']) $(key).checked = !!s[key];
  $('language').value = s.language;
  $('custom').value = s.custom;
  $('ignored').value = (s.ignored || []).join('\n');
}

for (const key of ['enabled', 'autoCheckFields', 'online', 'grammar']) {
  $(key).addEventListener('change', () => chrome.storage.local.set({ [key]: $(key).checked }));
}
$('language').addEventListener('change', () => chrome.storage.local.set({ language: $('language').value }));

$('save').addEventListener('click', async () => {
  const ignored = $('ignored').value.split(/\r?\n/).map((w) => w.trim()).filter(Boolean);
  await chrome.storage.local.set({ custom: $('custom').value, ignored });
  setStatus('המילון נשמר ✓', 'ok');
});

// שולח פקודה למסגרת הראשית של הלשונית; אם סקריפט התוכן עוד לא נטען (לשונית שנפתחה לפני ההתקנה) - מזריק אותו
async function sendToPage(message) {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !/^(https?|file):/.test(tab.url || '')) {
    throw new Error('לא ניתן לבדוק את הדף הזה (דפי מערכת של הדפדפן חסומים לתוספים)');
  }
  try {
    return await chrome.tabs.sendMessage(tab.id, message, { frameId: 0 });
  } catch (e) {
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      files: ['lib/dictionary.js', 'lib/checker.js', 'content.js']
    });
    return await chrome.tabs.sendMessage(tab.id, message, { frameId: 0 });
  }
}

async function run(message, describe) {
  setStatus('עובד…');
  try {
    const res = await sendToPage(message);
    const [text, kind] = describe(res || {});
    setStatus(text, kind);
  } catch (e) {
    setStatus(e.message || String(e), 'warn');
  }
}

$('scan').addEventListener('click', () => run({ type: 'SCAN_PAGE' }, (r) => {
  if (r.error && !r.count) return [`${r.error}`, 'warn'];
  return r.count ? [`נמצאו ${r.count} שגיאות. לחצו על מילה מסומנת בדף כדי לתקן.`, 'warn'] : ['לא נמצאו שגיאות ✓', 'ok'];
}));
$('fixPage').addEventListener('click', () => run({ type: 'FIX_PAGE' }, (r) =>
  r.count ? [`תוקנו ${r.count} שגיאות בדף`, 'ok'] : ['אין סימונים לתיקון - סרקו את הדף קודם', '']));
$('clear').addEventListener('click', () => run({ type: 'CLEAR_PAGE' }, () => ['הסימונים נוקו', '']));
$('fixField').addEventListener('click', () => run({ type: 'FIX_FIELD' }, (r) => {
  if (r.count == null) return ['לחצו קודם בתוך שדה טקסט בדף', 'warn'];
  return r.count ? [`תוקנו ${r.count} שגיאות בשדה`, 'ok'] : ['לא נמצאו שגיאות בשדה ✓', 'ok'];
}));

load();

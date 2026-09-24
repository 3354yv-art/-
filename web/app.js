'use strict';

/* ═══════════════════════ ADB סטודיו ═══════════════════════ */

const TOKEN = new URLSearchParams(location.search).get('token') || '';
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const content = $('#content');

const store = {
  get(key, fallback) { try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem(key, value); } catch { /* לא חשוב */ } },
  json(key, fallback) { try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; } },
};

/* ───────────── אייקונים ───────────── */

const ICONS = {
  phone: '<rect x="5" y="2" width="14" height="20" rx="2.5"/><path d="M12 18h.01"/>',
  grid: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  folder: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
  folderPlus: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/><path d="M12 10v6M9 13h6"/>',
  camera: '<path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3z"/><circle cx="12" cy="13" r="3"/>',
  cast: '<path d="M2 8V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-6"/><path d="M2 12a9 9 0 0 1 8 8M2 16a5 5 0 0 1 4 4M2 20h.01"/>',
  terminal: '<path d="m4 17 6-6-6-6"/><path d="M12 19h8"/>',
  moon: '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41"/>',
  chevron: '<path d="m6 9 6 6 6-6"/>',
  wifi: '<path d="M12 20h.01M2 8.82a15 15 0 0 1 20 0M5 12.86a10 10 0 0 1 14 0M8.5 16.43a5 5 0 0 1 7 0"/>',
  x: '<path d="M18 6 6 18M6 6l12 12"/>',
  upload: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m17 8-5-5-5 5"/><path d="M12 3v12"/>',
  download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/><path d="M12 15V3"/>',
  battery: '<rect x="2" y="7" width="16" height="10" rx="2"/><path d="M22 11v2"/>',
  charging: '<rect x="2" y="7" width="16" height="10" rx="2"/><path d="M22 11v2"/><path d="m11 9-2.5 3h3L9 15"/>',
  storage: '<path d="M22 12H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><path d="M6 16h.01M10 16h.01"/>',
  cpu: '<rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M15 2v2M15 20v2M2 15h2M2 9h2M20 15h2M20 9h2M9 2v2M9 20v2"/>',
  monitor: '<rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/>',
  refresh: '<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>',
  power: '<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.77.04"/>',
  play: '<path d="M7 4v16l13-8z"/>',
  stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
  trash: '<path d="M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M10 11v6M14 11v6"/>',
  search: '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
  file: '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>',
  image: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.09-3.09a2 2 0 0 0-2.82 0L6 21"/>',
  video: '<path d="m16 13 5.22 3.48a.5.5 0 0 0 .78-.42V7.94a.5.5 0 0 0-.76-.42L16 10.5"/><rect x="2" y="6" width="14" height="12" rx="2"/>',
  music: '<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>',
  package: '<path d="M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z"/><path d="M12 22V12M3.3 7l8.7 5 8.7-5"/>',
  up: '<path d="m5 12 7-7 7 7"/><path d="M12 19V5"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  alert: '<circle cx="12" cy="12" r="10"/><path d="M12 8v4M12 16h.01"/>',
  usb: '<path d="M12 2v14"/><path d="m8 6 4-4 4 4"/><path d="M7 11v2a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2v-2"/><circle cx="12" cy="19" r="3"/>',
  unlink: '<path d="m18.84 12.25 1.72-1.71a5 5 0 0 0-7.07-7.07l-1.72 1.71M5.17 11.75l-1.71 1.71a5 5 0 0 0 7.07 7.07l1.71-1.71M8 2v3M2 8h3M16 22v-3M22 16h-3"/>',
  sparkles: '<path d="M12 3 9.5 9.5 3 12l6.5 2.5L12 21l2.5-6.5L21 12l-6.5-2.5z"/>',
  eraser: '<path d="m7 21-4.3-4.3a1 1 0 0 1 0-1.4l10-10a1 1 0 0 1 1.4 0l5.6 5.6a1 1 0 0 1 0 1.4L11 21"/><path d="M22 21H7M5 11l9 9"/>',
  pause: '<rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/>',
  ban: '<circle cx="12" cy="12" r="10"/><path d="m4.9 4.9 14.2 14.2"/>',
  undo: '<path d="M3 7v6h6"/><path d="M21 17a9 9 0 0 0-9-9 9 9 0 0 0-6 2.3L3 13"/>',
  pencil: '<path d="M21.17 6.81a2.83 2.83 0 0 0-4-4L3.84 16.17a2 2 0 0 0-.5.83l-1.32 4.35a.5.5 0 0 0 .62.62l4.35-1.32a2 2 0 0 0 .83-.5z"/>',
  back: '<path d="m15 18-6-6 6-6"/>',
  home: '<circle cx="12" cy="12" r="8"/>',
  recents: '<rect x="5" y="5" width="14" height="14" rx="2"/>',
  volUp: '<path d="M11 5 6 9H2v6h4l5 4z"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07M19.07 4.93a10 10 0 0 1 0 14.14"/>',
  volDown: '<path d="M11 5 6 9H2v6h4l5 4z"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/>',
  mute: '<path d="M11 5 6 9H2v6h4l5 4z"/><path d="m22 9-6 6M16 9l6 6"/>',
  skipNext: '<path d="m5 4 10 8-10 8z"/><path d="M19 5v14"/>',
  skipPrev: '<path d="M19 20 9 12l10-8z"/><path d="M5 19V5"/>',
  qr: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M14 14h3v3h-3zM20 14v.01M14 20h.01M17 20h4v-3"/>',
  keyboard: '<rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/>',
  external: '<path d="M15 3h6v6M10 14 21 3M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>',
};

const svg = name =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${ICONS[name] || ''}</svg>`;
const icon = name => `<i data-icon="${name}">${svg(name)}</i>`;
const hydrateIcons = (root = document) =>
  $$('i[data-icon]', root).forEach(el => { if (!el.innerHTML) el.innerHTML = svg(el.dataset.icon); });

/* ───────────── עזרים ───────────── */

const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// עוטף טקסט לועזי/מספרי כדי שיוצג בסדר הנכון בתוך משפט בעברית
const ltr = s => `⁦${s}⁩`;

function fmtBytes(n) {
  if (n == null) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return ltr(`${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${units[i]}`);
}

function fmtUptime(sec) {
  if (sec == null) return '—';
  const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
  if (d) return `${d} ${d === 1 ? 'יום' : 'ימים'}, ${h} שע׳`;
  if (h) return `${h} שע׳, ${m} דק׳`;
  return `${m} דקות`;
}

const fmtDate = ts => ltr(new Date(ts * 1000).toLocaleString('he-IL', {
  day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit',
}));

function fmtPatch(p) {
  if (!p) return '';
  const d = new Date(p);
  return isNaN(d) ? p : d.toLocaleDateString('he-IL', { month: 'long', year: 'numeric' });
}

const joinPath = (dir, name) => (dir.endsWith('/') ? dir : dir + '/') + name;
const parentPath = p => p.replace(/\/+$/, '').replace(/\/[^/]*$/, '') || '/';

function hue(str) {
  let h = 0;
  for (const ch of str) h = (h * 31 + ch.charCodeAt(0)) % 360;
  return h;
}
const avatarStyle = pkg => {
  const h = hue(pkg);
  return `background:linear-gradient(135deg,hsl(${h} 70% 55%),hsl(${(h + 40) % 360} 70% 45%))`;
};

/* שמות ידידותיים לאפליקציות נפוצות (ADB לא חושף את שם האפליקציה) */
const APP_NAMES = {
  'com.whatsapp': 'WhatsApp', 'com.whatsapp.w4b': 'WhatsApp Business', 'org.telegram.messenger': 'Telegram',
  'com.facebook.katana': 'Facebook', 'com.facebook.orca': 'Messenger', 'com.instagram.android': 'Instagram',
  'com.facebook.appmanager': 'Facebook App Manager', 'com.facebook.services': 'Facebook Services',
  'com.facebook.system': 'Facebook App Installer', 'com.zhiliaoapp.musically': 'TikTok',
  'com.snapchat.android': 'Snapchat', 'com.twitter.android': 'X (Twitter)', 'com.linkedin.android': 'LinkedIn',
  'com.pinterest': 'Pinterest', 'com.reddit.frontpage': 'Reddit', 'com.discord': 'Discord',
  'com.viber.voip': 'Viber', 'com.skype.raider': 'Skype', 'us.zoom.videomeetings': 'Zoom',
  'com.microsoft.teams': 'Microsoft Teams', 'com.microsoft.office.outlook': 'Outlook',
  'com.microsoft.office.word': 'Word', 'com.microsoft.office.excel': 'Excel',
  'com.microsoft.office.powerpoint': 'PowerPoint', 'com.microsoft.skydrive': 'OneDrive',
  'com.spotify.music': 'Spotify', 'com.netflix.mediaclient': 'Netflix', 'com.shazam.android': 'Shazam',
  'com.duolingo': 'Duolingo', 'com.waze': 'Waze', 'com.tranzmate': 'Moovit', 'com.ubercab': 'Uber',
  'com.gettaxi.android': 'Gett', 'com.unicell.pangoandroid': 'פנגו', 'com.bnhp.payments.paymentsapp': 'ביט',
  'com.payboxapp': 'PayBox', 'com.ideomobile.hapoalim': 'בנק הפועלים', 'com.leumi.leumiwallet': 'לאומי',
  'com.amazon.mShop.android.shopping': 'Amazon', 'com.alibaba.aliexpresshd': 'AliExpress',
  'com.zzkko': 'SHEIN', 'com.ebay.mobile': 'eBay', 'com.booking': 'Booking.com', 'com.airbnb.android': 'Airbnb',
  'com.android.chrome': 'Chrome', 'com.google.android.youtube': 'YouTube',
  'com.google.android.apps.youtube.music': 'YouTube Music', 'com.google.android.gm': 'Gmail',
  'com.google.android.apps.maps': 'מפות Google', 'com.google.android.apps.photos': 'תמונות Google',
  'com.google.android.apps.docs': 'Google Drive', 'com.google.android.calendar': 'יומן Google',
  'com.google.android.keep': 'Google Keep', 'com.google.android.apps.translate': 'Google Translate',
  'com.google.android.apps.tachyon': 'Google Meet', 'com.google.android.googlequicksearchbox': 'Google',
  'com.google.android.gms': 'שירותי Google Play', 'com.android.vending': 'Google Play',
  'com.google.android.dialer': 'טלפון', 'com.google.android.apps.messaging': 'הודעות',
  'com.google.android.contacts': 'אנשי קשר', 'com.google.android.deskclock': 'שעון',
  'com.google.android.calculator': 'מחשבון', 'com.google.android.GoogleCamera': 'מצלמה',
  'com.google.android.apps.wellbeing': 'איזון דיגיטלי', 'com.google.android.apps.nbu.files': 'Files by Google',
  'com.google.android.apps.walletnfcrel': 'Google Wallet', 'com.google.android.tts': 'המרת טקסט לדיבור',
  'com.google.android.inputmethod.latin': 'מקלדת Gboard', 'com.android.settings': 'הגדרות',
  'com.samsung.android.bixby.agent': 'Bixby', 'com.samsung.android.app.spage': 'Samsung Free',
  'com.sec.android.app.camera': 'מצלמה', 'com.samsung.android.dialer': 'טלפון',
  'com.samsung.android.messaging': 'הודעות', 'com.sec.android.gallery3d': 'גלריה',
  'com.sec.android.app.myfiles': 'הקבצים שלי', 'com.samsung.android.calendar': 'יומן',
  'com.sec.android.app.popupcalculator': 'מחשבון', 'com.sec.android.app.sbrowser': 'Samsung Internet',
  'com.samsung.android.email.provider': 'אימייל', 'com.sec.android.app.samsungapps': 'Galaxy Store',
  'com.samsung.android.app.notes': 'Samsung Notes', 'com.samsung.android.oneconnect': 'SmartThings',
  'com.samsung.android.spay': 'Samsung Wallet', 'com.samsung.android.game.gamehome': 'Game Launcher',
  'com.sec.android.app.launcher': 'מסך הבית של סמסונג', 'com.android.systemui': 'ממשק המערכת',
  'com.miui.gallery': 'גלריה', 'com.miui.securitycenter': 'אבטחה',
};
const GENERIC = new Set(['com', 'org', 'net', 'io', 'co', 'il', 'android', 'app', 'apps', 'mobile', 'client',
  'main', 'google', 'lite', 'free', 'pro', 'phone', 'launcher', 'release', 'prod', 'sec', 'samsung', 'miui']);
function appName(pkg) {
  if (APP_NAMES[pkg]) return APP_NAMES[pkg];
  const parts = pkg.split('.');
  const pick = [...parts].reverse().find(p => !GENERIC.has(p.toLowerCase()) && p.length > 1) || parts.at(-1);
  return pick.charAt(0).toUpperCase() + pick.slice(1).replace(/_/g, ' ');
}

const IMAGE_EXT = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'];
const extOf = name => name.split('.').pop().toLowerCase();
const isImage = name => IMAGE_EXT.includes(extOf(name));
const INSTALLABLE = /\.(apk|apks|xapk)$/i;
function fileIcon(name) {
  const ext = extOf(name);
  if (IMAGE_EXT.includes(ext) || ext === 'heic') return 'image';
  if (['mp4', 'mkv', 'mov', 'webm', '3gp', 'avi'].includes(ext)) return 'video';
  if (['mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac', 'opus'].includes(ext)) return 'music';
  if (['apk', 'apks', 'xapk'].includes(ext)) return 'package';
  return 'file';
}

/* ───────────── תקשורת עם השרת ───────────── */

async function api(path, body = {}) {
  let res;
  try {
    res = await fetch('/api/' + path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Token': TOKEN },
      body: JSON.stringify(body),
    });
  } catch {
    throw new Error('אין תקשורת עם התוכנה — ייתכן שהיא נסגרה');
  }
  const data = await res.json().catch(() => ({ error: 'תגובה לא תקינה' }));
  if (!res.ok || data.error) throw new Error(data.error || 'הפעולה נכשלה');
  return data;
}

const apiUrl = (path, params) =>
  `/api/${path}?${new URLSearchParams({ ...params, token: TOKEN })}`;

async function fetchBlob(path, params) {
  const res = await fetch(apiUrl(path, params));
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data.error || 'ההורדה נכשלה');
  }
  return res.blob();
}

function saveBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = Object.assign(document.createElement('a'), { href: url, download: filename });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}

async function downloadWithToast(path, params, filename, label) {
  const t = toast(`מוריד ${label}…`, 'loading');
  try {
    saveBlob(await fetchBlob(path, params), filename);
    t.done(`${label} נשמר בתיקיית ההורדות`);
  } catch (e) {
    t.fail(e.message);
  }
}

function uploadFile(path, params, file, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('PUT', apiUrl(path, params));
    xhr.upload.onprogress = e => e.lengthComputable && onProgress(e.loaded / e.total);
    xhr.onload = () => {
      let data = {};
      try { data = JSON.parse(xhr.responseText); } catch { /* ריק */ }
      if (xhr.status >= 200 && xhr.status < 300 && !data.error) resolve(data);
      else reject(new Error(data.error || 'הפעולה נכשלה'));
    };
    xhr.onerror = () => reject(new Error('שגיאת תקשורת'));
    xhr.send(file);
  });
}

/* ───────────── הודעות וחלונות ───────────── */

function toast(message, type = 'ok', { progress = false } = {}) {
  const el = document.createElement('div');
  const iconFor = t => t === 'error' ? icon('alert') : t === 'loading' ? '<span class="spinner"></span>' : icon('check');
  el.className = `toast ${type}`;
  el.innerHTML = `${iconFor(type)}<div class="grow"><div class="msg">${esc(message)}</div>` +
    (progress ? '<div class="progress"><span></span></div>' : '') + '</div>';
  $('#toasts').append(el);
  let timer;
  const close = (delay = 0) => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      el.style.transition = 'opacity .25s, transform .25s';
      el.style.opacity = '0';
      el.style.transform = 'translateY(8px)';
      setTimeout(() => el.remove(), 250);
    }, delay);
  };
  const finish = (msg, kind) => {
    el.className = `toast ${kind}`;
    el.firstElementChild.outerHTML = iconFor(kind);
    $('.msg', el).textContent = msg;
    $('.progress', el)?.remove();
    close(kind === 'error' ? 6000 : 3500);
  };
  if (type !== 'loading') close(type === 'error' ? 6000 : 3500);
  return {
    text(msg) { $('.msg', el).textContent = msg; },
    progress(p) { const bar = $('.progress span', el); if (bar) bar.style.width = `${Math.round(p * 100)}%`; },
    done: msg => finish(msg, 'ok'),
    fail: msg => finish(msg, 'error'),
  };
}

const modal = $('#modal');
function openModal(title, html, { wide = false } = {}) {
  const prev = modal.onclose;
  modal.onclose = null;
  prev?.();
  $('#modalTitle').textContent = title;
  $('#modalBox').classList.toggle('wide', wide);
  $('#modalBody').innerHTML = html;
  hydrateIcons($('#modalBody'));
  modal.hidden = false;
  setTimeout(() => $('#modalBody input:not([type=checkbox])')?.focus(), 50);
  return $('#modalBody');
}
function closeModal() {
  modal.hidden = true;
  const cb = modal.onclose;
  modal.onclose = null;
  cb?.();
}
modal.addEventListener('click', e => {
  if (e.target === modal || e.target.closest('[data-close]')) closeModal();
});
document.addEventListener('keydown', e => { if (e.key === 'Escape' && !modal.hidden) closeModal(); });

function confirmDialog({ title, text, ok = 'אישור', danger = false }) {
  return new Promise(resolve => {
    const body = openModal(title, `<p>${text}</p>
      <div class="modal-foot">
        <button class="btn ${danger ? 'danger' : 'primary'}" data-ok>${esc(ok)}</button>
        <button class="btn ghost" data-close>ביטול</button>
      </div>`);
    let answer = false;
    modal.onclose = () => resolve(answer);
    $('[data-ok]', body).onclick = () => { answer = true; closeModal(); };
    $('[data-ok]', body).focus();
  });
}

function promptDialog({ title, label, value = '', ok = 'אישור' }) {
  return new Promise(resolve => {
    const body = openModal(title, `<form>
      <label class="field"><span>${esc(label)}</span><input name="v" value="${esc(value)}" class="rtl-input"></label>
      <div class="modal-foot"><button class="btn primary">${esc(ok)}</button><button type="button" class="btn ghost" data-close>ביטול</button></div>
    </form>`);
    let answer = null;
    modal.onclose = () => resolve(answer);
    const input = $('input', body);
    const dot = value.lastIndexOf('.');
    setTimeout(() => input.setSelectionRange(0, dot > 0 ? dot : value.length), 60);
    $('form', body).onsubmit = e => { e.preventDefault(); answer = e.target.v.value.trim() || null; closeModal(); };
  });
}

/* ───────────── מצב ───────────── */

const state = {
  adb: null,
  devices: [],
  serial: store.get('serial', null),
  view: 'overview',
  apps: null,
  appTab: 'user',
  appQuery: '',
  selected: new Set(),
  path: '/sdcard',
  files: null,
  shots: [],
  term: [],
  history: [],
  mirror: { quality: 'balanced', screenOff: false, stayAwake: true, audio: true, record: false, readOnly: false,
            ...store.json('mirror', {}) },
  mirrorRunning: false,
};

const current = () => state.devices.find(d => d.serial === state.serial) || null;
const ready = () => current()?.state === 'device';
const deviceLabel = d => d.model || d.serial;

/* ───────────── ערכת נושא ───────────── */

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  $('#themeBtn').innerHTML = icon(theme === 'dark' ? 'sun' : 'moon');
}
applyTheme(store.get('theme', matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));
$('#themeBtn').onclick = () => {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  store.set('theme', next);
  applyTheme(next);
};

/* ───────────── מכשירים ───────────── */

const STATE_TEXT = {
  device: 'מחובר',
  unauthorized: 'ממתין לאישור',
  offline: 'לא מקוון',
  authorizing: 'מאשר…',
  recovery: 'מצב שחזור',
  sideload: 'Sideload',
};

function renderPicker() {
  const dev = current();
  const btn = $('#deviceBtn');
  $('.dot', btn).className = 'dot ' + (!dev ? '' : dev.state === 'device' ? 'ok' : 'warn');
  $('.device-name', btn).textContent = dev ? deviceLabel(dev) : 'אין מכשיר מחובר';
  $('#quickShot').disabled = $('#quickMirror').disabled = !ready();
  const menu = $('#deviceMenu');
  menu.innerHTML = state.devices.length
    ? state.devices.map(d => `
      <button data-serial="${esc(d.serial)}">
        <span class="dot ${d.state === 'device' ? 'ok' : 'warn'}"></span>
        <span class="grow" style="flex:1">
          ${esc(deviceLabel(d))} <span class="mini-ico">${d.wireless ? icon('wifi') : icon('usb')}</span>
          <small>${esc(d.serial)} · ${esc(STATE_TEXT[d.state] || d.state)}</small>
        </span>
        ${d.serial === state.serial ? icon('check') : ''}
      </button>`).join('')
    : '<div class="empty">לא נמצאו מכשירים.<br>חברו טלפון בכבל או התחברו אלחוטית.</div>';
}

function resetDeviceState() {
  state.apps = null;
  state.files = null;
  state.selected.clear();
  state.mirrorRunning = false;
}

function selectDevice(serial) {
  if (serial === state.serial) return;
  state.serial = serial;
  store.set('serial', serial || '');
  resetDeviceState();
  renderPicker();
  render();
}

$('#deviceBtn').onclick = e => { e.stopPropagation(); $('#deviceMenu').classList.toggle('open'); };
$('#deviceMenu').onclick = e => {
  const b = e.target.closest('[data-serial]');
  if (b) selectDevice(b.dataset.serial);
  $('#deviceMenu').classList.remove('open');
};
document.addEventListener('click', () => $('#deviceMenu').classList.remove('open'));

let lastDevicesKey = '';
async function refreshDevices(force = false) {
  if (!state.adb?.adb) return force && render();
  let devices;
  try {
    devices = (await api('devices')).devices;
  } catch {
    return;
  }
  const key = JSON.stringify(devices);
  if (key === lastDevicesKey) return force && render();
  lastDevicesKey = key;
  const wasReady = ready();
  state.devices = devices;
  if (!current()) {
    const pick = devices.find(d => d.state === 'device') || devices[0];
    state.serial = pick?.serial || null;
    resetDeviceState();
    renderPicker();
    render();
    return;
  }
  renderPicker();
  if (force || wasReady !== ready()) render();
}

async function refreshStatus() {
  const had = state.adb && !!state.adb.adb && !state.adb.error;
  try {
    state.adb = await api('status');
  } catch (e) {
    state.adb = { adb: false, error: e.message };
  }
  const el = $('#adbStatus');
  $('.dot', el).className = 'dot ' + (state.adb.adb ? 'ok' : 'bad');
  el.lastElementChild.textContent = state.adb.adb
    ? `ADB ${state.adb.version || ''} פעיל`
    : state.adb.error ? 'התוכנה לא זמינה' : 'ADB לא מותקן';
  return had !== (!!state.adb.adb && !state.adb.error);
}

/* ───────────── ניווט ───────────── */

$('#nav').onclick = e => {
  const b = e.target.closest('[data-view]');
  if (b) go(b.dataset.view);
};

function go(view) {
  state.view = view;
  $$('#nav button').forEach(b => b.classList.toggle('active', b.dataset.view === view));
  render();
}

let renderId = 0;
function render() {
  renderId++;
  if (!state.adb) {
    content.innerHTML = '<div class="loading"><span class="spinner"></span>טוען…</div>';
    return;
  }
  if (!state.adb.adb) return renderSetup();
  const dev = current();
  if (!dev) return renderNoDevice();
  if (dev.state !== 'device') return renderNotReady(dev);
  ({ overview: renderOverview, mirror: renderMirror, apps: renderApps,
     files: renderFiles, terminal: renderTerminal })[state.view]();
}

function setContent(html) {
  content.innerHTML = html;
  hydrateIcons(content);
  content.scrollTop = 0;
}

/* ───────────── מסכי מצב ───────────── */

function renderSetup() {
  if (state.adb.error) {
    return setContent(`<div class="empty-state">
      <div class="big-ico">${icon('alert')}</div>
      <h2>אין חיבור לתוכנה</h2>
      <p>נראה שהתוכנה נסגרה. הפעילו מחדש את ADB סטודיו.</p></div>`);
  }
  setContent(`<div class="empty-state">
    <div class="big-ico">${icon('sparkles')}</div>
    <h2>בואו נתחיל</h2>
    <p>כדי לדבר עם הטלפון צריך את כלי ה-ADB הרשמי של גוגל.<br>אפשר להתקין אותו בלחיצה אחת — כ-10MB, ישירות מהאתר של גוגל.</p>
    <button class="btn primary lg" id="setupBtn">${icon('download')}<span>התקנה אוטומטית</span></button>
    <p class="hint" style="margin-top:18px">מעדיפים ידנית? הורידו את
      <a href="https://developer.android.com/tools/releases/platform-tools" target="_blank" rel="noopener">Platform Tools</a>
      וחלצו את התיקייה <code>platform-tools</code> ליד קובץ התוכנה.</p>
  </div>`);
  $('#setupBtn').onclick = async e => {
    const btn = e.currentTarget;
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span><span>מוריד ומתקין…</span>';
    try {
      state.adb = await api('setup');
      toast('ADB הותקן בהצלחה!');
      await refreshStatus();
      await refreshDevices(true);
    } catch (err) {
      toast(err.message, 'error');
      btn.disabled = false;
      btn.innerHTML = `${icon('refresh')}<span>נסו שוב</span>`;
    }
  };
}

function renderNoDevice() {
  setContent(`<div class="empty-state">
    <div class="big-ico">${icon('phone')}</div>
    <h2>חברו את הטלפון</h2>
    <p>שלושה צעדים קצרים ואתם בפנים. המכשיר יופיע כאן אוטומטית.</p>
    <div class="steps">
      <div class="card step"><b>1</b><div>הפעילו <strong>אפשרויות מפתחים</strong>
        <small>הגדרות ← אודות הטלפון ← הקישו 7 פעמים על "מספר Build"</small></div></div>
      <div class="card step"><b>2</b><div>הפעילו <strong>ניפוי באגים ב-USB</strong>
        <small>הגדרות ← מערכת ← אפשרויות מפתחים</small></div></div>
      <div class="card step"><b>3</b><div>חברו כבל ו<strong>אשרו את החלון</strong> שיקפוץ בטלפון
        <small>מומלץ לסמן "אפשר תמיד מהמחשב הזה"</small></div></div>
    </div>
    <div class="row-btns center">
      <button class="btn primary" id="goQr">${icon('qr')}<span>בלי כבל — סריקת QR</span></button>
      <button class="btn ghost" id="goWireless">${icon('wifi')}<span>חיבור לפי כתובת</span></button>
    </div>
  </div>`);
  $('#goQr').onclick = () => openWireless('qr');
  $('#goWireless').onclick = () => openWireless('ip');
}

function renderNotReady(dev) {
  const unauthorized = dev.state === 'unauthorized';
  setContent(`<div class="empty-state">
    <div class="big-ico warn">${icon(unauthorized ? 'phone' : 'alert')}</div>
    <h2>${unauthorized ? 'אשרו את החיבור בטלפון' : 'המכשיר לא זמין כרגע'}</h2>
    <p>${unauthorized
      ? 'במסך הטלפון מופיעה הודעה "לאשר ניפוי באגים ב-USB?" — לחצו <strong>אישור</strong>. לא רואים אותה? נתקו וחברו את הכבל מחדש.'
      : `מצב המכשיר: ${esc(STATE_TEXT[dev.state] || dev.state)}. נסו לנתק ולחבר מחדש.`}</p>
    <div class="loading" style="padding:0"><span class="spinner"></span>ממתין…</div>
  </div>`);
}

/* ───────────── סקירה ───────────── */

let liveTimer = null;
async function refreshLiveScreen() {
  const img = $('#liveScreen');
  if (!img || document.hidden) return;
  try {
    const blob = await fetchBlob('screenshot', { serial: state.serial });
    if (!img.isConnected) return;
    const old = img.src;
    img.src = URL.createObjectURL(blob);
    img.closest('.live-phone').classList.add('loaded');
    if (old.startsWith('blob:')) URL.revokeObjectURL(old);
  } catch { /* מסך מאובטח או מכשיר עסוק — מתעלמים */ }
}

async function renderOverview() {
  const id = renderId;
  const dev = current();
  setContent(`<div class="card hero">
      <div class="live-phone"><div class="skeleton" style="position:absolute;inset:0"></div></div>
      <div style="flex:1">
        <div class="skeleton" style="height:30px;width:240px"></div>
        <div class="skeleton" style="height:16px;width:160px;margin-top:12px"></div>
      </div></div>
    <div class="stats">${'<div class="card stat"><div class="skeleton" style="height:70px"></div></div>'.repeat(4)}</div>`);
  let info;
  try {
    info = await api('device/info', { serial: dev.serial });
  } catch (e) {
    if (id !== renderId) return;
    return setContent(`<div class="empty-state"><div class="big-ico">${icon('alert')}</div>
      <h2>לא הצלחנו לקרוא את פרטי המכשיר</h2><p>${esc(e.message)}</p>
      <button class="btn primary" onclick="render()">${icon('refresh')}<span>נסו שוב</span></button></div>`);
  }
  if (id !== renderId) return;

  const b = info.battery, s = info.storage, r = info.ram;
  const storagePct = s ? Math.round(s.used / s.total * 100) : 0;
  const ramPct = r ? Math.round((r.total - r.free) / r.total * 100) : 0;
  const stat = (ico, label, value, note = '', bar = null, low = false) => `
    <div class="card stat">
      <div class="stat-head"><span class="ico">${icon(ico)}</span>${label}</div>
      <div class="stat-value">${value}</div>
      ${note ? `<div class="stat-note">${note}</div>` : ''}
      ${bar != null ? `<div class="bar ${low ? 'low' : ''}"><span style="width:${bar}%"></span></div>` : ''}
    </div>`;
  const kv = (k, v) => v ? `<div class="kv"><span>${k}</span><b>${v}</b></div>` : '';

  setContent(`
    <div class="card hero">
      <button class="live-phone" id="livePhone" title="לחצו לרענון">
        <img id="liveScreen" alt="">
        <span class="live-badge"><span class="pulse"></span>מסך חי</span>
      </button>
      <div class="hero-body">
        <h2>${esc(info.model || deviceLabel(dev))}</h2>
        <div class="sub">${esc(info.brand || info.manufacturer)} · ${esc(info.codename)}</div>
        <div class="chips">
          <span class="chip accent">${ltr('Android ' + esc(info.android))}</span>
          <span class="chip">${dev.wireless ? icon('wifi') : icon('usb')} ${dev.wireless ? 'אלחוטי' : 'USB'}</span>
          ${info.ip ? `<span class="chip">${ltr(esc(info.ip))}</span>` : ''}
        </div>
        <div class="hero-actions">
          <button class="btn primary" data-act="mirror">${icon('cast')}<span>שיקוף מסך</span></button>
          <button class="btn ghost" data-act="shot">${icon('camera')}<span>צילום מסך</span></button>
          <button class="btn ghost" data-act="install">${icon('package')}<span>התקנת APK</span></button>
          ${dev.wireless
            ? `<button class="btn ghost" data-act="disconnect">${icon('unlink')}<span>ניתוק</span></button>`
            : `<button class="btn ghost" data-act="wifi">${icon('wifi')}<span>מעבר לאלחוטי</span></button>`}
          <button class="btn ghost" data-act="reboot">${icon('power')}<span>הפעלה מחדש</span></button>
        </div>
      </div>
    </div>

    <div class="stats">
      ${b ? stat(b.charging ? 'charging' : 'battery', 'סוללה', `<bdi dir="ltr">${b.level}<small>%</small></bdi>`,
        [b.full ? 'טעונה במלואה' : b.charging ? 'בטעינה' : 'לא בטעינה',
         b.temperature != null ? ltr(`${b.temperature}°C`) : ''].filter(Boolean).join(' · '),
        b.level, b.level <= 15) : ''}
      ${s ? stat('storage', 'אחסון', `${fmtBytes(s.free)} <small>פנויים</small>`,
        `${fmtBytes(s.used)} בשימוש מתוך ${fmtBytes(s.total)}`, storagePct, storagePct >= 90) : ''}
      ${r ? stat('cpu', 'זיכרון RAM', fmtBytes(r.total), `${ltr(ramPct + '%')} בשימוש כרגע`, ramPct) : ''}
      ${stat('monitor', 'מסך', `<span style="direction:ltr;display:inline-block">${esc(info.screen || '—')}</span>`,
        `פועל ${fmtUptime(info.uptime)}`)}
    </div>

    <div class="section-title">פרטי המכשיר</div>
    <div class="card kv-grid">
      ${kv('יצרן', esc(info.manufacturer))}
      ${kv('דגם', ltr(esc(info.model)))}
      ${kv('גרסת אנדרואיד', ltr(`${esc(info.android)} (API ${esc(info.sdk)})`))}
      ${kv('עדכון אבטחה', esc(fmtPatch(info.patch)))}
      ${kv('מעבד', ltr(esc([info.chipset, info.abi].filter(Boolean).join(' · '))))}
      ${kv('מספר סידורי', ltr(esc(dev.serial)))}
      ${kv('גרסת מערכת', ltr(esc(info.build)))}
      ${kv('כתובת IP', info.ip ? ltr(esc(info.ip)) : 'לא מחובר ל-Wi‑Fi')}
    </div>`);

  $$('[data-act]', content).forEach(el => el.onclick = () => overviewAction(el.dataset.act, el));
  $('#livePhone').onclick = refreshLiveScreen;
  refreshLiveScreen();
  clearInterval(liveTimer);
  liveTimer = setInterval(() => {
    if (state.view !== 'overview' || !$('#liveScreen')) return clearInterval(liveTimer);
    refreshLiveScreen();
  }, 12000);
}

async function overviewAction(act, el) {
  const dev = current();
  if (act === 'mirror') return startMirror();
  if (act === 'shot') return quickShot();
  if (act === 'install') return pickFiles('.apk,.apks,.xapk', true, installApks);
  if (act === 'reboot') return rebootDialog();
  el.disabled = true;
  try {
    if (act === 'wifi') {
      const t = toast('מעביר לחיבור אלחוטי…', 'loading');
      try {
        const res = await api('device/wifi', { serial: dev.serial });
        t.done(res.message);
        await refreshDevices();
        selectDevice(res.serial);
      } catch (e) { t.fail(e.message); }
    } else if (act === 'disconnect') {
      toast((await api('disconnect', { serial: dev.serial })).message);
      refreshDevices();
    }
  } catch (e) {
    toast(e.message, 'error');
  } finally {
    el.disabled = false;
  }
}

function rebootDialog() {
  const body = openModal('הפעלה מחדש', `
    <p>בחרו את מצב ההפעלה. המכשיר יתנתק לכמה רגעים.</p>
    <div class="actions-grid" style="grid-template-columns:1fr">
      <button class="action-tile" data-mode=""><span class="ico">${icon('refresh')}</span><span>הפעלה מחדש רגילה<small>כמו כיבוי והדלקה</small></span></button>
      <button class="action-tile" data-mode="recovery"><span class="ico">${icon('sparkles')}</span><span>מצב Recovery<small>תפריט שחזור מערכת</small></span></button>
      <button class="action-tile" data-mode="bootloader"><span class="ico">${icon('cpu')}</span><span>מצב Bootloader<small>למשתמשים מתקדמים</small></span></button>
    </div>`);
  $$('[data-mode]', body).forEach(b => b.onclick = async () => {
    closeModal();
    try {
      toast((await api('device/reboot', { serial: state.serial, mode: b.dataset.mode })).message);
    } catch (e) { toast(e.message, 'error'); }
  });
}

/* ───────────── שיקוף ושליטה ───────────── */

const QUALITY_TEXT = { high: 'איכות מרבית', balanced: 'מאוזן', saver: 'חסכוני' };
const KEY_GROUPS = [
  [['back', 'back', 'חזרה'], ['home', 'home', 'בית'], ['recents', 'recents', 'אחרונות']],
  [['voldown', 'volDown', 'עוצמה −'], ['mute', 'mute', 'השתקה'], ['volup', 'volUp', 'עוצמה +']],
  [['prev', 'skipPrev', 'הקודם'], ['play', 'pause', 'נגן/השהה'], ['next', 'skipNext', 'הבא']],
];

function renderMirror() {
  const o = state.mirror;
  const installed = state.adb.scrcpy;
  const toggle = (key, label, hint) => `
    <label class="option">
      <span class="grow"><b>${label}</b><small>${hint}</small></span>
      <span class="toggle"><input type="checkbox" data-opt="${key}" ${o[key] ? 'checked' : ''}><span class="track"></span></span>
    </label>`;
  setContent(`
    <div class="page-head">
      <div><h1>שיקוף ושליטה</h1><p>רואים את מסך הטלפון על המחשב ושולטים בו עם העכבר והמקלדת</p></div>
    </div>
    <div class="mirror-grid">
      <div class="card card-pad">
        ${installed ? `
        <div class="mirror-cta" id="mirrorCta"></div>
        <div class="section-title">איכות תמונה</div>
        <div class="segmented" id="quality">${Object.entries(QUALITY_TEXT).map(([k, v]) =>
          `<button data-q="${k}" class="${o.quality === k ? 'active' : ''}">${v}</button>`).join('')}</div>
        <div class="section-title">אפשרויות</div>
        <div class="options">
          ${toggle('screenOff', 'כיבוי מסך הטלפון', 'המסך בטלפון כבוי והשיקוף ממשיך — חוסך סוללה')}
          ${toggle('stayAwake', 'להשאיר ער', 'הטלפון לא ננעל כל עוד הוא מחובר')}
          ${toggle('audio', 'צליל במחשב', 'הצליל של הטלפון יוצא מהמחשב (אנדרואיד 11 ומעלה)')}
          ${toggle('record', 'הקלטת וידאו', 'השיקוף נשמר כסרטון בתיקיית הסרטונים')}
          ${toggle('readOnly', 'צפייה בלבד', 'רק רואים, בלי לשלוט — מתאים להצגה')}
        </div>
        <details class="shortcuts">
          <summary>${icon('keyboard')} קיצורי מקלדת בחלון השיקוף</summary>
          <div class="kv-grid compact">
            <div class="kv"><span>בית / חזרה</span><b>${ltr('Ctrl+H / Ctrl+B')}</b></div>
            <div class="kv"><span>אפליקציות אחרונות</span><b>${ltr('Ctrl+S')}</b></div>
            <div class="kv"><span>עוצמת שמע</span><b>${ltr('Ctrl+↑ / Ctrl+↓')}</b></div>
            <div class="kv"><span>הדבקת טקסט מהמחשב</span><b>${ltr('Ctrl+V')}</b></div>
            <div class="kv"><span>סיבוב מסך</span><b>${ltr('Ctrl+R')}</b></div>
            <div class="kv"><span>כיבוי מסך הטלפון</span><b>${ltr('Ctrl+O')}</b></div>
            <div class="kv"><span>מסך מלא</span><b>${ltr('Ctrl+F')}</b></div>
            <div class="kv"><span>התקנת APK / העברת קובץ</span><b>גרירה לחלון</b></div>
          </div>
        </details>` : `
        <div class="empty-state" style="padding:30px 10px">
          <div class="big-ico">${icon('cast')}</div>
          <h2>עוד רגע משקפים</h2>
          <p>לשיקוף המסך צריך רכיב קטן (scrcpy — קוד פתוח, כ-10MB).<br>התקנה חד-פעמית בלחיצה אחת.</p>
          <button class="btn primary lg" id="scrcpySetup">${icon('download')}<span>התקנת רכיב השיקוף</span></button>
        </div>`}
      </div>

      <div class="mirror-side">
        <div class="card card-pad">
          <div class="card-title">${icon('phone')} שלט רחוק</div>
          <div class="remote">
            ${KEY_GROUPS.map(g => `<div class="remote-row">${g.map(([k, ic, label]) =>
              `<button class="remote-key" data-key="${k}" title="${label}">${icon(ic)}<small>${label}</small></button>`).join('')}</div>`).join('')}
            <button class="btn ghost wide-btn" data-key="power">${icon('power')}<span>הדלקה / כיבוי מסך</span></button>
          </div>
        </div>
        <div class="card card-pad">
          <div class="card-title">${icon('camera')} צילום מסך</div>
          <div class="shot-preview" id="shotPreview"></div>
          <div class="row-btns">
            <button class="btn primary" id="shotBtn">${icon('camera')}<span>צלם</span></button>
            <button class="btn ghost" id="saveShot">${icon('download')}<span>שמירה</span></button>
          </div>
          <div class="gallery" id="gallery"></div>
        </div>
        <button class="btn ghost" id="openMedia">${icon('external')}<span>פתיחת תיקיית ההקלטות</span></button>
      </div>
    </div>`);

  if (installed) {
    drawMirrorCta();
    $('#quality').onclick = e => {
      const b = e.target.closest('[data-q]');
      if (!b) return;
      o.quality = b.dataset.q;
      $$('#quality button').forEach(x => x.classList.toggle('active', x === b));
      store.set('mirror', JSON.stringify(o));
    };
    $$('[data-opt]', content).forEach(c => c.onchange = () => {
      o[c.dataset.opt] = c.checked;
      store.set('mirror', JSON.stringify(o));
    });
    pollMirror();
  } else {
    $('#scrcpySetup').onclick = async e => {
      const btn = e.currentTarget;
      btn.disabled = true;
      btn.innerHTML = '<span class="spinner"></span><span>מוריד ומתקין…</span>';
      try {
        toast((await api('mirror/setup')).message);
        await refreshStatus();
        render();
      } catch (err) {
        toast(err.message, 'error');
        btn.disabled = false;
        btn.innerHTML = `${icon('refresh')}<span>נסו שוב</span>`;
      }
    };
  }
  $$('[data-key]', content).forEach(b => b.onclick = () => sendKey(b.dataset.key, b));
  $('#shotBtn').onclick = takeShot;
  $('#saveShot').onclick = () => saveShot(state.shots[0]);
  $('#openMedia').onclick = async () => {
    try { await api('open-media'); } catch (e) { toast(e.message, 'error'); }
  };
  drawShots();
}

function drawMirrorCta() {
  const el = $('#mirrorCta');
  if (!el) return;
  el.innerHTML = state.mirrorRunning
    ? `<div class="live-pill"><span class="pulse"></span>השיקוף פועל בחלון נפרד</div>
       <button class="btn danger lg" id="mirrorStop">${icon('stop')}<span>עצירת השיקוף</span></button>`
    : `<button class="btn primary xl" id="mirrorStart">${icon('cast')}<span>התחלת שיקוף</span></button>
       <p class="hint">החלון נפתח בנפרד — לוחצים, גוללים ומקלידים בו כמו בטלפון.</p>`;
  $('#mirrorStart')?.addEventListener('click', startMirror);
  $('#mirrorStop')?.addEventListener('click', stopMirror);
}

let mirrorPoll = null;
function pollMirror() {
  clearInterval(mirrorPoll);
  const tick = async () => {
    if (state.view !== 'mirror' || !ready()) return clearInterval(mirrorPoll);
    try {
      const res = await api('mirror/status', { serial: state.serial });
      if (res.running !== state.mirrorRunning) { state.mirrorRunning = res.running; drawMirrorCta(); }
    } catch { /* מתעלמים */ }
  };
  tick();
  mirrorPoll = setInterval(tick, 3000);
}

async function startMirror() {
  if (!ready()) return;
  if (!state.adb.scrcpy) {
    go('mirror');
    return toast('צריך להתקין קודם את רכיב השיקוף', 'error');
  }
  const t = toast('פותח שיקוף…', 'loading');
  try {
    const res = await api('mirror/start', {
      serial: state.serial,
      title: `${deviceLabel(current())} — ADB סטודיו`,
      options: state.mirror,
    });
    t.done(res.message);
    state.mirrorRunning = true;
    drawMirrorCta();
  } catch (e) {
    t.fail(e.message);
  }
}

async function stopMirror() {
  try {
    toast((await api('mirror/stop', { serial: state.serial })).message);
  } catch (e) { toast(e.message, 'error'); }
  state.mirrorRunning = false;
  drawMirrorCta();
}

async function sendKey(key, btn) {
  btn.classList.add('pressed');
  setTimeout(() => btn.classList.remove('pressed'), 180);
  try { await api('device/key', { serial: state.serial, key }); } catch (e) { toast(e.message, 'error'); }
}

function stampName() {
  const d = new Date();
  const p = n => String(n).padStart(2, '0');
  return `צילום מסך ${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}-${p(d.getMinutes())}-${p(d.getSeconds())}.png`;
}

let shooting = false;
async function captureShot() {
  const blob = await fetchBlob('screenshot', { serial: state.serial });
  const shot = { blob, url: URL.createObjectURL(blob), name: stampName() };
  state.shots.unshift(shot);
  state.shots.splice(12).forEach(s => URL.revokeObjectURL(s.url));
  return shot;
}

async function takeShot() {
  if (shooting) return;
  shooting = true;
  const btn = $('#shotBtn');
  if (btn) { btn.disabled = true; btn.innerHTML = '<span class="spinner"></span><span>מצלם…</span>'; }
  try {
    await captureShot();
    drawShots();
  } catch (e) {
    toast(e.message, 'error');
  } finally {
    shooting = false;
    const b = $('#shotBtn');
    if (b) { b.disabled = false; b.innerHTML = `${icon('camera')}<span>צלם</span>`; }
  }
}

async function quickShot() {
  if (!ready() || shooting) return;
  shooting = true;
  const t = toast('מצלם את המסך…', 'loading');
  try {
    const shot = await captureShot();
    saveShot(shot, false);
    t.done('צילום המסך נשמר בתיקיית ההורדות');
    drawShots();
  } catch (e) {
    t.fail(e.message);
  } finally {
    shooting = false;
  }
}

function saveShot(shot, notify = true) {
  if (!shot) return toast('עוד לא צילמתם מסך', 'error');
  saveBlob(shot.blob, shot.name);
  if (notify) toast('צילום המסך נשמר בתיקיית ההורדות');
}

function drawShots() {
  const preview = $('#shotPreview');
  if (!preview) return;
  const [first, ...rest] = state.shots;
  preview.innerHTML = first
    ? `<img src="${first.url}" alt="צילום מסך">`
    : `<div class="muted">${icon('image')}<span>הצילום יופיע כאן</span></div>`;
  $('#saveShot').disabled = !first;
  $('#gallery').innerHTML = rest.map((s, i) =>
    `<button data-i="${i + 1}" title="שמירה"><img src="${s.url}" alt=""></button>`).join('');
  $('#gallery').onclick = e => {
    const b = e.target.closest('[data-i]');
    if (b) saveShot(state.shots[+b.dataset.i]);
  };
}

$('#quickShot').onclick = quickShot;
$('#quickMirror').onclick = () => (state.mirrorRunning ? go('mirror') : startMirror());

/* ───────────── חיבור אלחוטי ───────────── */

function openWireless(tab = 'qr') {
  const body = openModal('חיבור אלחוטי', `
    <div class="tabs">
      <button data-tab="qr">סריקת QR</button>
      <button data-tab="code">קוד צימוד</button>
      <button data-tab="ip">כתובת IP</button>
    </div>

    <div data-pane="qr">
      <div class="qr-wrap">
        <div class="qr-box" id="qrBox"><span class="spinner"></span></div>
        <ol class="qr-steps">
          <li>בטלפון: <b>הגדרות ← אפשרויות מפתחים</b></li>
          <li>הפעילו <b>ניפוי באגים אלחוטי</b> ולחצו עליו</li>
          <li>בחרו <b>"צימוד מכשיר עם קוד QR"</b> וסרקו</li>
        </ol>
      </div>
      <div class="qr-status" id="qrStatus"><span class="spinner"></span>ממתין לסריקה…</div>
      <p class="hint">המחשב והטלפון צריכים להיות באותה רשת Wi‑Fi. אנדרואיד 11 ומעלה.</p>
    </div>

    <form data-pane="code">
      <div class="note">בטלפון: אפשרויות מפתחים ← <b>ניפוי באגים אלחוטי</b> ← "צימוד מכשיר עם קוד צימוד".
        הזינו את הכתובת והקוד שמופיעים שם.</div>
      <label class="field"><span>כתובת ופורט צימוד</span><input name="address" placeholder="192.168.1.20:37215" autocomplete="off"></label>
      <label class="field"><span>קוד צימוד</span><input name="code" placeholder="123456" inputmode="numeric" maxlength="6" autocomplete="off"></label>
      <div class="modal-foot"><button class="btn primary">${icon('check')}<span>צמד</span></button></div>
    </form>

    <form data-pane="ip">
      <div id="found"></div>
      <label class="field"><span>כתובת</span><input name="address" placeholder="192.168.1.20:5555" autocomplete="off"></label>
      <div class="note">מחוברים בכבל? "מעבר לאלחוטי" במסך הסקירה עושה את זה אוטומטית.</div>
      <div class="modal-foot"><button class="btn primary">${icon('wifi')}<span>התחבר</span></button></div>
    </form>`);

  let alive = true;
  modal.onclose = () => { alive = false; };

  const show = t => {
    $$('[data-tab]', body).forEach(b => b.classList.toggle('active', b.dataset.tab === t));
    $$('[data-pane]', body).forEach(p => { p.hidden = p.dataset.pane !== t; });
    $(`[data-pane="${t}"] input`, body)?.focus();
    if (t === 'qr') startQr();
    if (t === 'ip') loadFound();
  };
  $$('[data-tab]', body).forEach(b => b.onclick = () => show(b.dataset.tab));

  const submitting = async (btn, fn) => {
    const prev = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span><span>רגע…</span>';
    try { await fn(); } catch (e) { toast(e.message, 'error'); }
    if (btn.isConnected) { btn.disabled = false; btn.innerHTML = prev; }
  };

  const connected = async serial => {
    toast('מחובר! אפשר להתחיל');
    closeModal();
    await refreshDevices();
    selectDevice(serial);
  };

  let qrSession = null;
  async function startQr() {
    if (qrSession) return;
    const status = $('#qrStatus');
    const setStatus = (html, cls = '') => { status.className = 'qr-status ' + cls; status.innerHTML = html; };
    try {
      const res = await api('qr/start');
      qrSession = res.session;
      const qr = qrcode(0, 'M');
      qr.addData(res.qr);
      qr.make();
      $('#qrBox').innerHTML = qr.createSvgTag({ cellSize: 5, margin: 2, scalable: true });
    } catch (e) {
      return setStatus(`${icon('alert')} ${esc(e.message)}`, 'bad');
    }
    const started = Date.now();
    while (alive) {
      await new Promise(r => setTimeout(r, 1500));
      if (!alive) break;
      if ($('[data-pane="qr"]', body).hidden) continue;
      try {
        const res = await api('qr/poll', { session: qrSession });
        if (!alive) break;
        if (res.state === 'connected') return connected(res.serial);
        if (res.state === 'pairing') setStatus('<span class="spinner"></span>נסרק! מתחבר…', 'good');
        if (res.state === 'paired') {
          return setStatus(`${icon('check')} צומד בהצלחה — אם לא התחבר, עברו ללשונית "כתובת IP"`, 'good');
        }
        if (res.state === 'waiting' && Date.now() - started > 60000) {
          setStatus('<span class="spinner"></span>עדיין ממתין… לא עובד? נסו "קוד צימוד".');
        }
      } catch (e) {
        return setStatus(`${icon('alert')} ${esc(e.message)}`, 'bad');
      }
    }
  }

  async function loadFound() {
    const box = $('#found');
    box.innerHTML = '<div class="found-title"><span class="spinner"></span>מחפש מכשירים ברשת…</div>';
    try {
      const { devices } = await api('discover');
      if (!alive) return;
      box.innerHTML = devices.length
        ? `<div class="found-title">נמצאו ברשת</div>${devices.map(d => `
          <button type="button" class="found-item" data-addr="${esc(d.address)}">
            ${icon('phone')}<span class="grow"><b>${esc(d.label)}</b><small>${ltr(esc(d.address))}</small></span>
            <span class="chip accent">התחבר</span>
          </button>`).join('')}`
        : '';
      $$('[data-addr]', box).forEach(b => b.onclick = () => submitting(b, async () => {
        const res = await api('connect', { address: b.dataset.addr });
        await connected(res.serial);
      }));
    } catch { box.innerHTML = ''; }
  }

  $('[data-pane="ip"]', body).onsubmit = e => {
    e.preventDefault();
    submitting($('button.btn', e.target), async () => {
      const res = await api('connect', { address: e.target.address.value });
      await connected(res.serial);
    });
  };
  $('[data-pane="code"]', body).onsubmit = e => {
    e.preventDefault();
    submitting($('button.btn', e.target), async () => {
      const res = await api('pair', { address: e.target.address.value, code: e.target.code.value });
      toast(res.message);
      const ip = e.target.address.value.split(':')[0];
      show('ip');
      $('[data-pane="ip"] input', body).value = ip + ':';
    });
  };
  show(tab);
}
$('#wirelessBtn').onclick = () => openWireless('qr');

/* ───────────── אפליקציות ───────────── */

const APP_TABS = {
  user: ['האפליקציות שלי', a => !a.system && !a.removed],
  system: ['מערכת', a => a.system && !a.removed],
  disabled: ['מושבתות', a => a.disabled && !a.removed],
  removed: ['הוסרו', a => a.removed && a.system],
};

async function loadApps() {
  const id = renderId;
  state.apps = null;
  state.selected.clear();
  drawAppList();
  try {
    const { apps } = await api('apps', { serial: state.serial });
    if (id !== renderId) return;
    state.apps = apps;
  } catch (e) {
    if (id !== renderId) return;
    state.apps = [];
    toast(e.message, 'error');
  }
  drawAppList();
}

function renderApps() {
  setContent(`
    <div class="page-head">
      <div><h1>אפליקציות</h1><p>פתיחה, עצירה, השבתה, גיבוי והסרה — גם לכמה אפליקציות בבת אחת</p></div>
      <div class="actions"><button class="btn primary" id="installBtn">${icon('package')}<span>התקנת אפליקציה</span></button></div>
    </div>
    <div class="segmented tabs-line" id="appTabs"></div>
    <div class="toolbar">
      <label class="search">${icon('search')}<input id="appSearch" placeholder="חיפוש לפי שם…" value="${esc(state.appQuery)}"></label>
      <button class="icon-btn boxed" id="appsRefresh" title="רענון">${icon('refresh')}</button>
    </div>
    <div class="bulk" id="bulk" hidden></div>
    <div class="card list" id="appList"></div>
    <p class="hint center">טיפ: <b>השבתה</b> היא הדרך הבטוחה להיפטר מאפליקציות מערכת — אפשר תמיד להחזיר.</p>`);
  $('#installBtn').onclick = () => pickFiles('.apk,.apks,.xapk', true, installApks);
  $('#appSearch').oninput = e => { state.appQuery = e.target.value; drawAppList(); };
  $('#appsRefresh').onclick = loadApps;
  $('#appTabs').onclick = e => {
    const b = e.target.closest('[data-tab]');
    if (!b) return;
    state.appTab = b.dataset.tab;
    state.selected.clear();
    drawAppList();
  };
  $('#appList').onclick = onAppClick;
  $('#appList').onchange = onAppCheck;
  $('#bulk').onclick = onBulk;
  if (state.apps) drawAppList(); else loadApps();
}

function visibleApps() {
  const q = state.appQuery.trim().toLowerCase();
  return (state.apps || [])
    .filter(APP_TABS[state.appTab][1])
    .filter(a => !q || a.package.toLowerCase().includes(q) || appName(a.package).toLowerCase().includes(q))
    .sort((a, b) => appName(a.package).localeCompare(appName(b.package), 'he'));
}

function appActions(a) {
  const btn = (act, ico, title, cls = '') =>
    `<button class="icon-btn ${cls}" data-a="${act}" title="${title}">${icon(ico)}</button>`;
  if (a.removed) return btn('restore', 'undo', 'שחזור');
  return [
    a.disabled ? '' : btn('launch', 'play', 'פתיחה'),
    a.disabled ? '' : btn('stop', 'stop', 'עצירה בכוח'),
    btn('apk', 'download', 'גיבוי APK למחשב'),
    a.disabled ? btn('enable', 'check', 'הפעלה מחדש') : btn('disable', 'ban', 'השבתה'),
    btn('uninstall', 'trash', 'הסרה', 'danger'),
  ].join('');
}

function drawAppList() {
  const list = $('#appList');
  if (!list) return;
  $('#appTabs').innerHTML = Object.entries(APP_TABS).map(([k, [label, fn]]) =>
    `<button data-tab="${k}" class="${state.appTab === k ? 'active' : ''}">${label}` +
    (state.apps ? ` <span class="count-pill">${state.apps.filter(fn).length}</span>` : '') + '</button>').join('');
  drawBulk();
  if (!state.apps) {
    list.innerHTML = '<div class="loading"><span class="spinner"></span>טוען אפליקציות…</div>';
    return;
  }
  const apps = visibleApps();
  const allChecked = apps.length > 0 && apps.every(a => state.selected.has(a.package));
  list.innerHTML = apps.length ? `
    <div class="list-head">
      <label class="check"><input type="checkbox" data-all ${allChecked ? 'checked' : ''}><span></span></label>
      <span>${apps.length} אפליקציות</span>
    </div>` + apps.map(a => {
    const name = appName(a.package);
    const picked = state.selected.has(a.package);
    return `<div class="row clickable ${picked ? 'selected' : ''} ${a.disabled || a.removed ? 'dim' : ''}" data-pkg="${esc(a.package)}">
      <label class="check" data-stop><input type="checkbox" data-pick ${picked ? 'checked' : ''}><span></span></label>
      <div class="avatar" style="${avatarStyle(a.package)}">${esc([...name][0])}</div>
      <div class="grow">
        <div class="title">${esc(name)}${a.disabled && !a.removed ? '<span class="tag">מושבתת</span>' : ''}</div>
        <div class="meta">${esc(a.package)}</div>
      </div>
      <div class="row-actions">${appActions(a)}</div>
    </div>`;
  }).join('') : `<div class="empty-state" style="padding:40px"><p>${state.appQuery ? 'לא נמצאו תוצאות' : {
    user: 'אין אפליקציות שהותקנו', disabled: 'אין אפליקציות מושבתות', removed: 'לא הוסרו אפליקציות מערכת', system: 'אין',
  }[state.appTab]}</p></div>`;
}

function drawBulk() {
  const bar = $('#bulk');
  if (!bar) return;
  const n = state.selected.size;
  bar.hidden = !n;
  if (!n) return;
  const acts = state.appTab === 'removed'
    ? [['restore', 'undo', 'שחזור', 'primary']]
    : state.appTab === 'disabled'
      ? [['enable', 'check', 'הפעלה מחדש', 'primary'], ['uninstall', 'trash', 'הסרה', 'danger']]
      : [['disable', 'ban', 'השבתה', 'ghost'], ['stop', 'stop', 'עצירה', 'ghost'], ['uninstall', 'trash', 'הסרה', 'danger']];
  bar.innerHTML = `<b>נבחרו ${n}</b><span class="grow"></span>
    ${acts.map(([a, ic, label, cls]) => `<button class="btn ${cls}" data-bulk="${a}">${icon(ic)}<span>${label}</span></button>`).join('')}
    <button class="btn ghost" data-bulk="clear">${icon('x')}<span>ביטול</span></button>`;
}

function onAppCheck(e) {
  if (e.target.matches('[data-all]')) {
    visibleApps().forEach(a => e.target.checked ? state.selected.add(a.package) : state.selected.delete(a.package));
    return drawAppList();
  }
  if (e.target.matches('[data-pick]')) {
    const row = e.target.closest('[data-pkg]');
    e.target.checked ? state.selected.add(row.dataset.pkg) : state.selected.delete(row.dataset.pkg);
    row.classList.toggle('selected', e.target.checked);
    const all = $('[data-all]');
    if (all) all.checked = visibleApps().every(a => state.selected.has(a.package));
    drawBulk();
  }
}

const ACTION_TEXT = {
  uninstall: ['הסרה', 'הוסרו'], disable: ['השבתה', 'הושבתו'], enable: ['הפעלה', 'הופעלו'],
  restore: ['שחזור', 'שוחזרו'], stop: ['עצירה', 'נעצרו'],
};

async function confirmAppAction(action, apps) {
  const name = apps.length === 1 ? appName(apps[0].package) : `${apps.length} אפליקציות`;
  const anySystem = apps.some(a => a.system);
  if (action === 'uninstall') {
    return confirmDialog({
      title: `להסיר את ${name}?`,
      text: anySystem
        ? 'אפליקציות מערכת יוסרו רק למשתמש הנוכחי, ואפשר לשחזר אותן בלשונית "הוסרו".<br><b>מומלץ יותר: השבתה.</b> הסרה של רכיבי מערכת חשובים עלולה לפגוע בפעולת הטלפון.'
        : 'האפליקציה וכל הנתונים שלה יימחקו מהמכשיר.',
      ok: 'הסרה', danger: true,
    });
  }
  if (action === 'disable') {
    return confirmDialog({
      title: `להשבית את ${name}?`,
      text: 'האפליקציה תיעלם ולא תרוץ ברקע, אבל תישאר בטלפון — אפשר להחזיר אותה בכל רגע בלשונית "מושבתות".',
      ok: 'השבתה',
    });
  }
  if (action === 'clear') {
    return confirmDialog({
      title: `לנקות את הנתונים של ${name}?`,
      text: 'כל ההגדרות, החשבונות והקבצים של האפליקציה יימחקו — כאילו הותקנה עכשיו.',
      ok: 'ניקוי', danger: true,
    });
  }
  return true;
}

const runAppAction = (action, a) =>
  api('apps/action', { serial: state.serial, package: a.package, action, system: a.system });

async function onBulk(e) {
  const b = e.target.closest('[data-bulk]');
  if (!b) return;
  const action = b.dataset.bulk;
  if (action === 'clear') { state.selected.clear(); return drawAppList(); }
  const apps = state.apps.filter(a => state.selected.has(a.package));
  if (!await confirmAppAction(action, apps)) return;
  const t = toast(`מבצע ${ACTION_TEXT[action][0]}…`, 'loading', { progress: true });
  const failed = [];
  for (const [i, a] of apps.entries()) {
    t.text(`${ACTION_TEXT[action][0]}: ${appName(a.package)} (${i + 1}/${apps.length})`);
    try { await runAppAction(action, a); } catch (err) { failed.push(`${appName(a.package)}: ${err.message}`); }
    t.progress((i + 1) / apps.length);
  }
  const ok = apps.length - failed.length;
  if (failed.length) t.fail(`${ok} ${ACTION_TEXT[action][1]}, ${failed.length} נכשלו — ${failed[0]}`);
  else t.done(`${ok} אפליקציות ${ACTION_TEXT[action][1]}`);
  if (action === 'stop') { state.selected.clear(); drawAppList(); } else loadApps();
}

async function onAppClick(e) {
  if (e.target.closest('[data-stop]')) return;
  const row = e.target.closest('[data-pkg]');
  if (!row) return;
  const app = state.apps.find(a => a.package === row.dataset.pkg);
  const btn = e.target.closest('[data-a]');
  if (!btn) return openAppDetails(app);
  await doAppAction(btn.dataset.a, app, btn);
}

async function doAppAction(action, app, btn) {
  const name = appName(app.package);
  if (action === 'apk') {
    return downloadWithToast('apps/apk', { serial: state.serial, package: app.package }, `${name}.apk`, `APK של ${name}`);
  }
  if (!await confirmAppAction(action, [app])) return;
  const prev = btn?.innerHTML;
  if (btn) { btn.innerHTML = '<span class="spinner"></span>'; btn.disabled = true; }
  try {
    toast((await runAppAction(action, app)).message);
    if (['uninstall', 'disable', 'enable', 'restore'].includes(action)) {
      if (action === 'uninstall') {
        if (app.system) app.removed = true;
        else state.apps = state.apps.filter(a => a !== app);
      }
      if (action === 'disable') app.disabled = true;
      if (action === 'enable') app.disabled = false;
      if (action === 'restore') { app.removed = false; app.disabled = false; }
      state.selected.delete(app.package);
      drawAppList();
    }
  } catch (err) {
    toast(err.message, 'error');
  } finally {
    if (btn?.isConnected) { btn.innerHTML = prev; btn.disabled = false; }
  }
}

async function openAppDetails(app) {
  const name = appName(app.package);
  const body = openModal('פרטי אפליקציה', `
    <div class="app-head">
      <div class="avatar lg" style="${avatarStyle(app.package)}">${esc([...name][0])}</div>
      <div><h2>${esc(name)}</h2><div class="meta" dir="ltr">${esc(app.package)}</div>
        <div class="chips">${app.system ? '<span class="chip">מערכת</span>' : '<span class="chip accent">הותקנה על ידך</span>'}
          ${app.disabled ? '<span class="chip">מושבתת</span>' : ''}${app.removed ? '<span class="chip">הוסרה</span>' : ''}</div></div>
    </div>
    <div class="kv-grid compact" id="appKv"><div class="loading" style="padding:20px"><span class="spinner"></span></div></div>
    <div class="detail-actions">
      ${app.removed ? `<button class="btn primary" data-a="restore">${icon('undo')}<span>שחזור</span></button>` : `
        ${app.disabled ? '' : `<button class="btn primary" data-a="launch">${icon('play')}<span>פתיחה</span></button>
        <button class="btn ghost" data-a="stop">${icon('stop')}<span>עצירה</span></button>`}
        <button class="btn ghost" data-a="clear">${icon('eraser')}<span>ניקוי נתונים</span></button>
        <button class="btn ghost" data-a="apk">${icon('download')}<span>גיבוי APK</span></button>
        ${app.disabled
          ? `<button class="btn ghost" data-a="enable">${icon('check')}<span>הפעלה מחדש</span></button>`
          : `<button class="btn ghost" data-a="disable">${icon('ban')}<span>השבתה</span></button>`}
        <button class="btn danger" data-a="uninstall">${icon('trash')}<span>הסרה</span></button>`}
    </div>`);
  $$('[data-a]', body).forEach(b => b.onclick = async () => {
    const act = b.dataset.a;
    const closes = ['uninstall', 'disable', 'enable', 'restore', 'clear'].includes(act);
    if (closes) closeModal();
    await doAppAction(act, app, closes ? null : b);
  });
  if (app.removed) { $('#appKv').innerHTML = ''; return; }
  try {
    const i = await api('apps/info', { serial: state.serial, package: app.package });
    const kv = (k, v) => v ? `<div class="kv"><span>${k}</span><b>${v}</b></div>` : '';
    const date = s => s ? ltr(new Date(s.replace(' ', 'T')).toLocaleDateString('he-IL')) : '';
    if (!$('#appKv')) return;
    $('#appKv').innerHTML =
      kv('גרסה', i.version && ltr(esc(i.version))) +
      kv('גודל', i.size && fmtBytes(i.size)) +
      kv('הותקנה', date(i.installed)) +
      kv('עודכנה', date(i.updated)) +
      kv('מקור', esc(i.installer)) +
      kv('הרשאות שאושרו', i.permissions ? String(i.permissions) : '') +
      kv('מיועדת לאנדרואיד', i.targetSdk && ltr('API ' + esc(i.targetSdk)));
  } catch (e) {
    if ($('#appKv')) $('#appKv').innerHTML = `<p class="muted">${esc(e.message)}</p>`;
  }
}

async function installApks(files) {
  const apks = files.filter(f => INSTALLABLE.test(f.name));
  if (!apks.length) return toast('בחרו קובץ APK, APKS או XAPK', 'error');
  for (const file of apks) {
    const t = toast(`מעלה ${file.name}…`, 'loading', { progress: true });
    try {
      const res = await uploadFile('apps/install', { serial: state.serial, name: file.name }, file, p => {
        t.progress(p);
        if (p >= 1) t.text(`מתקין ${file.name}… (אם מופיעה בקשה בטלפון — אשרו)`);
      });
      t.done(res.message);
      state.apps = null;
      if (state.view === 'apps') loadApps();
    } catch (e) {
      t.fail(`${file.name}: ${e.message}`);
    }
  }
}

/* ───────────── קבצים ───────────── */

const PLACES = [
  ['אחסון פנימי', '/sdcard', 'storage'],
  ['הורדות', '/sdcard/Download', 'download'],
  ['מצלמה', '/sdcard/DCIM/Camera', 'camera'],
  ['תמונות', '/sdcard/Pictures', 'image'],
  ['סרטונים', '/sdcard/Movies', 'video'],
  ['מסמכים', '/sdcard/Documents', 'file'],
  ['WhatsApp', '/sdcard/Android/media/com.whatsapp/WhatsApp/Media', 'folder'],
];

function renderFiles() {
  setContent(`
    <div class="page-head">
      <div><h1>קבצים</h1><p>העברת קבצים בין המחשב לטלפון — אפשר גם לגרור קבצים לחלון</p></div>
      <div class="actions">
        <button class="btn ghost" id="mkdirBtn">${icon('folderPlus')}<span>תיקייה חדשה</span></button>
        <button class="btn primary" id="uploadBtn">${icon('upload')}<span>העלאה לטלפון</span></button>
      </div>
    </div>
    <div class="places">${PLACES.map(([n, p, ic]) =>
      `<button class="place" data-go="${esc(p)}">${icon(ic)}<span>${esc(n)}</span></button>`).join('')}</div>
    <div class="toolbar">
      <button class="icon-btn boxed" id="upBtn" title="תיקייה למעלה">${icon('up')}</button>
      <div class="breadcrumb" id="crumbs"></div>
      <button class="icon-btn boxed" id="filesRefresh" title="רענון">${icon('refresh')}</button>
    </div>
    <div class="card list" id="fileList"></div>`);
  $('#upBtn').onclick = () => openDir(parentPath(state.path));
  $('#filesRefresh').onclick = () => openDir(state.path);
  $('#uploadBtn').onclick = () => pickFiles('', true, uploadFiles);
  $('#mkdirBtn').onclick = makeDir;
  $$('[data-go]', content).forEach(b => b.onclick = () => openDir(b.dataset.go));
  $('#crumbs').onclick = e => { const b = e.target.closest('[data-path]'); if (b) openDir(b.dataset.path); };
  $('#fileList').onclick = onFileClick;
  if (state.files) drawFiles(); else openDir(state.path);
}

async function openDir(path) {
  const id = renderId;
  const list = $('#fileList');
  if (list) list.innerHTML = '<div class="loading"><span class="spinner"></span>טוען…</div>';
  try {
    const res = await api('files/list', { serial: state.serial, path });
    if (id !== renderId) return;
    state.path = res.path;
    state.files = res.entries;
  } catch (e) {
    if (id !== renderId) return;
    toast(e.message, 'error');
    if (!state.files) state.files = [];
  }
  drawFiles();
}

function drawFiles() {
  const list = $('#fileList');
  if (!list) return;
  const parts = state.path.split('/').filter(Boolean);
  $('#crumbs').innerHTML = `<button data-path="/">/</button>` + parts.map((p, i) =>
    `${i ? '<span class="sep">/</span>' : ''}<button data-path="/${esc(parts.slice(0, i + 1).join('/'))}">${esc(p)}</button>`).join('');
  $$('.place').forEach(b => b.classList.toggle('active', b.dataset.go === state.path));
  list.innerHTML = state.files.length ? state.files.map(f => `
    <div class="row clickable" data-name="${esc(f.name)}" data-dir="${f.dir ? 1 : ''}">
      <div class="file-ico ${f.dir ? 'dir' : ''}">${icon(f.dir ? 'folder' : fileIcon(f.name))}</div>
      <div class="grow"><div class="title filename">${esc(f.name)}</div></div>
      <div class="date">${fmtDate(f.mtime)}</div>
      <div class="size">${f.dir ? '' : fmtBytes(f.size)}</div>
      <div class="row-actions">
        <button class="icon-btn" data-a="download" title="${f.dir ? 'הורדת התיקייה כ-ZIP' : 'הורדה למחשב'}">${icon('download')}</button>
        <button class="icon-btn" data-a="rename" title="שינוי שם">${icon('pencil')}</button>
        <button class="icon-btn danger" data-a="delete" title="מחיקה">${icon('trash')}</button>
      </div>
    </div>`).join('')
    : `<div class="empty-state" style="padding:50px"><div class="big-ico sm">${icon('folder')}</div><p>התיקייה ריקה — גררו לכאן קבצים כדי להעלות</p></div>`;
}

async function onFileClick(e) {
  const row = e.target.closest('[data-name]');
  if (!row) return;
  const name = row.dataset.name;
  const path = joinPath(state.path, name);
  const isDir = !!row.dataset.dir;
  const action = e.target.closest('[data-a]')?.dataset.a;
  if (!action) {
    if (isDir) return openDir(path);
    if (isImage(name)) return previewImage(path, name);
    return;
  }
  if (action === 'download') {
    return downloadWithToast('files/pull', { serial: state.serial, path }, isDir ? `${name}.zip` : name, name);
  }
  if (action === 'rename') {
    const newName = await promptDialog({ title: 'שינוי שם', label: 'שם חדש', value: name, ok: 'שמירה' });
    if (!newName || newName === name) return;
    try {
      await api('files/rename', { serial: state.serial, path, name: newName });
      toast('השם שונה');
      openDir(state.path);
    } catch (err) { toast(err.message, 'error'); }
  }
  if (action === 'delete') {
    const ok = await confirmDialog({
      title: 'למחוק לצמיתות?',
      text: `<strong dir="auto">${esc(name)}</strong>${isDir ? ' וכל התוכן שבתוכה' : ''} יימחק מהמכשיר. אין סל מחזור.`,
      ok: 'מחיקה', danger: true,
    });
    if (!ok) return;
    try {
      await api('files/delete', { serial: state.serial, path });
      toast('נמחק');
      openDir(state.path);
    } catch (err) { toast(err.message, 'error'); }
  }
}

async function previewImage(path, name) {
  const body = openModal(name, `<div class="preview"><span class="spinner"></span></div>
    <div class="modal-foot"><button class="btn primary" data-save disabled>${icon('download')}<span>הורדה למחשב</span></button>
    <button class="btn ghost" data-close>סגירה</button></div>`, { wide: true });
  let url = null;
  modal.onclose = () => url && URL.revokeObjectURL(url);
  try {
    const blob = await fetchBlob('files/pull', { serial: state.serial, path, inline: 1 });
    if (!body.isConnected || modal.hidden) return;
    url = URL.createObjectURL(blob);
    $('.preview', body).innerHTML = `<img src="${url}" alt="">`;
    const save = $('[data-save]', body);
    save.disabled = false;
    save.onclick = () => saveBlob(blob, name);
  } catch (e) {
    $('.preview', body).innerHTML = `<p class="muted">${esc(e.message)}</p>`;
  }
}

async function makeDir() {
  const name = await promptDialog({ title: 'תיקייה חדשה', label: 'שם התיקייה', ok: 'יצירה' });
  if (!name) return;
  if (name.includes('/')) return toast('השם לא יכול להכיל /', 'error');
  try {
    await api('files/mkdir', { serial: state.serial, path: joinPath(state.path, name) });
    toast('התיקייה נוצרה');
    openDir(state.path);
  } catch (e) { toast(e.message, 'error'); }
}

async function uploadFiles(files) {
  const dir = state.path;
  for (const file of files) {
    const t = toast(`מעלה ${file.name}…`, 'loading', { progress: true });
    try {
      await uploadFile('files/upload', { serial: state.serial, dir, name: file.name }, file, p => {
        t.progress(p);
        if (p >= 1) t.text(`מעביר לטלפון: ${file.name}…`);
      });
      t.done(`${file.name} הועלה`);
    } catch (e) {
      t.fail(`${file.name}: ${e.message}`);
    }
  }
  if (state.view === 'files' && state.path === dir) openDir(dir);
}

/* ───────────── טרמינל ───────────── */

const QUICK = ['getprop ro.product.model', 'dumpsys battery', 'pm list packages -3', 'ls /sdcard', 'df -h', 'top -n 1 -m 10'];

function renderTerminal() {
  const dev = current();
  setContent(`
    <div class="page-head">
      <div><h1>טרמינל</h1><p>הרצת פקודות <span dir="ltr">adb shell</span> ישירות על המכשיר — למשתמשים מתקדמים</p></div>
      <div class="actions"><button class="btn ghost" id="termClear">${icon('eraser')}<span>ניקוי</span></button></div>
    </div>
    <div class="quick">${QUICK.map(q => `<button class="chip" data-q="${esc(q)}">${esc(q)}</button>`).join('')}</div>
    <div class="term">
      <div class="term-bar"><span style="background:#ff5f57"></span><span style="background:#febc2e"></span><span style="background:#28c840"></span><em>${esc(deviceLabel(dev))}</em></div>
      <div class="term-out" id="termOut"></div>
      <form class="term-in" id="termForm"><b>$</b><input id="termInput" autocomplete="off" spellcheck="false" placeholder="הקלידו פקודה ולחצו Enter"></form>
    </div>`);
  const input = $('#termInput');
  let pos = state.history.length;
  drawTerm();
  input.focus();

  $$('[data-q]', content).forEach(b => b.onclick = () => runCommand(b.dataset.q));
  $('#termClear').onclick = () => { state.term = []; drawTerm(); input.focus(); };
  $('#termForm').onsubmit = e => { e.preventDefault(); const v = input.value; input.value = ''; pos = state.history.length + 1; runCommand(v); };
  input.onkeydown = e => {
    if (e.key === 'ArrowUp' && pos > 0) { pos--; input.value = state.history[pos] || ''; e.preventDefault(); }
    if (e.key === 'ArrowDown') { pos = Math.min(pos + 1, state.history.length); input.value = state.history[pos] || ''; e.preventDefault(); }
  };
}

function drawTerm() {
  const out = $('#termOut');
  if (!out) return;
  out.innerHTML = state.term.length
    ? state.term.map(l => `<div class="${l.cls}">${esc(l.text)}</div>`).join('')
    : '<div class="info">מוכן. נסו אחת מהפקודות המהירות למעלה.</div>';
  out.scrollTop = out.scrollHeight;
}

async function runCommand(cmd) {
  cmd = cmd.trim();
  if (!cmd) return;
  if (state.history.at(-1) !== cmd) state.history.push(cmd);
  if (cmd.startsWith('adb shell ')) cmd = cmd.slice(10);
  state.term.push({ cls: 'cmd', text: `$ ${cmd}` });
  const pending = { cls: 'info', text: '…' };
  state.term.push(pending);
  drawTerm();
  try {
    const res = await api('shell', { serial: state.serial, command: cmd });
    pending.text = res.output || '(אין פלט)';
    pending.cls = res.code ? 'err' : '';
  } catch (e) {
    pending.text = e.message;
    pending.cls = 'err';
  }
  if (state.term.length > 400) state.term.splice(0, state.term.length - 400);
  drawTerm();
  $('#termInput')?.focus();
}

/* ───────────── בחירת קבצים וגרירה ───────────── */

function pickFiles(accept, multiple, handler) {
  if (!ready()) return toast('אין מכשיר מחובר', 'error');
  const input = Object.assign(document.createElement('input'), { type: 'file', accept, multiple });
  input.onchange = () => input.files.length && handler([...input.files]);
  input.click();
}

let dragDepth = 0;
const overlay = $('#dropOverlay');
const hasFiles = e => [...(e.dataTransfer?.types || [])].includes('Files');

window.addEventListener('dragenter', e => {
  if (!hasFiles(e) || !ready()) return;
  e.preventDefault();
  dragDepth++;
  $('#dropText').textContent = state.view === 'files'
    ? `שחררו כדי להעלות ל-${state.path}`
    : 'שחררו אפליקציה (APK) כדי להתקין';
  overlay.hidden = false;
});
window.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; overlay.hidden = true; } });
window.addEventListener('dragover', e => { if (hasFiles(e)) e.preventDefault(); });
window.addEventListener('drop', e => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  dragDepth = 0;
  overlay.hidden = true;
  if (!ready()) return;
  const files = [...e.dataTransfer.files];
  if (state.view === 'files') uploadFiles(files);
  else installApks(files);
});

/* ───────────── הפעלה ───────────── */

hydrateIcons();
render();
(async () => {
  await refreshStatus();
  await refreshDevices(true);
  setInterval(refreshDevices, 2500);
  setInterval(async () => { if (await refreshStatus()) refreshDevices(true); }, 15000);
})();

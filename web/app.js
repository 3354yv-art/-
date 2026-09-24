'use strict';

/* ═══════════════════════ ADB סטודיו ═══════════════════════ */

const TOKEN = new URLSearchParams(location.search).get('token') || '';
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const content = $('#content');

const store = {
  get(key, fallback) { try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem(key, value); } catch { /* לא חשוב */ } },
};

/* ───────────── אייקונים ───────────── */

const ICONS = {
  phone: '<rect x="5" y="2" width="14" height="20" rx="2.5"/><path d="M12 18h.01"/>',
  grid: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  folder: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
  folderPlus: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/><path d="M12 10v6M9 13h6"/>',
  camera: '<path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3z"/><circle cx="12" cy="13" r="3"/>',
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
  clock: '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
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
const ltr = s => `\u2066${s}\u2069`;

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

const joinPath = (dir, name) => (dir.endsWith('/') ? dir : dir + '/') + name;
const parentPath = p => p.replace(/\/+$/, '').replace(/\/[^/]*$/, '') || '/';

function hue(str) {
  let h = 0;
  for (const ch of str) h = (h * 31 + ch.charCodeAt(0)) % 360;
  return h;
}

const GENERIC = new Set(['com', 'org', 'net', 'io', 'co', 'android', 'app', 'apps', 'mobile', 'client',
  'main', 'google', 'lite', 'free', 'pro', 'phone', 'launcher', 'release', 'prod']);
function appName(pkg) {
  const parts = pkg.split('.');
  const pick = [...parts].reverse().find(p => !GENERIC.has(p.toLowerCase()) && p.length > 1) || parts.at(-1);
  return pick.charAt(0).toUpperCase() + pick.slice(1).replace(/_/g, ' ');
}

function fileIcon(name) {
  const ext = name.split('.').pop().toLowerCase();
  if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp'].includes(ext)) return 'image';
  if (['mp4', 'mkv', 'mov', 'webm', '3gp', 'avi'].includes(ext)) return 'video';
  if (['mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac', 'opus'].includes(ext)) return 'music';
  if (ext === 'apk') return 'package';
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
function openModal(title, html) {
  $('#modalTitle').textContent = title;
  $('#modalBody').innerHTML = html;
  hydrateIcons($('#modalBody'));
  modal.hidden = false;
  setTimeout(() => $('#modalBody input')?.focus(), 50);
  return $('#modalBody');
}
function closeModal() { modal.hidden = true; modal.onclose?.(); modal.onclose = null; }
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

function promptDialog({ title, label, placeholder = '', ok = 'אישור' }) {
  return new Promise(resolve => {
    const body = openModal(title, `<form>
      <label class="field"><span>${esc(label)}</span><input name="v" placeholder="${esc(placeholder)}" style="direction:rtl;text-align:right;font-family:var(--font)"></label>
      <div class="modal-foot"><button class="btn primary">${esc(ok)}</button><button type="button" class="btn ghost" data-close>ביטול</button></div>
    </form>`);
    let answer = null;
    modal.onclose = () => resolve(answer);
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
  showSystem: false,
  appQuery: '',
  path: '/sdcard',
  files: null,
  shot: null,
  term: [],
  history: [],
};

const current = () => state.devices.find(d => d.serial === state.serial) || null;
const ready = () => current()?.state === 'device';
const deviceLabel = d => d.model || d.serial;

/* ───────────── ערכת נושא ───────────── */

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  const btn = $('#themeBtn');
  btn.innerHTML = icon(theme === 'dark' ? 'sun' : 'moon');
}
const systemDark = matchMedia('(prefers-color-scheme: dark)').matches;
applyTheme(store.get('theme', systemDark ? 'dark' : 'light'));
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
  const menu = $('#deviceMenu');
  menu.innerHTML = state.devices.length
    ? state.devices.map(d => `
      <button data-serial="${esc(d.serial)}">
        <span class="dot ${d.state === 'device' ? 'ok' : 'warn'}"></span>
        <span class="grow" style="flex:1">
          ${esc(deviceLabel(d))} ${d.wireless ? icon('wifi') : icon('usb')}
          <small>${esc(d.serial)} · ${esc(STATE_TEXT[d.state] || d.state)}</small>
        </span>
        ${d.serial === state.serial ? icon('check') : ''}
      </button>`).join('')
    : '<div class="empty">לא נמצאו מכשירים.<br>חברו טלפון בכבל או התחברו אלחוטית.</div>';
  $$('button i', menu).forEach(i => { i.style.width = '15px'; i.style.height = '15px'; i.style.verticalAlign = 'middle'; });
}

function selectDevice(serial) {
  if (serial === state.serial) return;
  state.serial = serial;
  store.set('serial', serial || '');
  state.apps = null;
  state.files = null;
  state.shot = null;
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
    state.apps = state.files = state.shot = null;
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
  ({ overview: renderOverview, apps: renderApps, files: renderFiles,
     screen: renderScreen, terminal: renderTerminal })[state.view]();
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
      <p>נראה שחלון השרת נסגר. הפעילו מחדש את ADB סטודיו.</p></div>`);
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
    <button class="btn ghost" id="goWireless">${icon('wifi')}<span>או התחברו אלחוטית</span></button>
  </div>`);
  $('#goWireless').onclick = openWireless;
}

function renderNotReady(dev) {
  const unauthorized = dev.state === 'unauthorized';
  setContent(`<div class="empty-state">
    <div class="big-ico" style="background:rgba(245,158,11,.14);color:var(--warn)">${icon(unauthorized ? 'phone' : 'alert')}</div>
    <h2>${unauthorized ? 'אשרו את החיבור בטלפון' : 'המכשיר לא זמין כרגע'}</h2>
    <p>${unauthorized
      ? 'במסך הטלפון מופיעה הודעה "לאשר ניפוי באגים ב-USB?" — לחצו <strong>אישור</strong>. לא רואים אותה? נתקו וחברו את הכבל מחדש.'
      : `מצב המכשיר: ${esc(STATE_TEXT[dev.state] || dev.state)}. נסו לנתק ולחבר מחדש.`}</p>
    <div class="loading" style="padding:0"><span class="spinner"></span>ממתין…</div>
  </div>`);
}

/* ───────────── סקירה ───────────── */

async function renderOverview() {
  const id = renderId;
  const dev = current();
  setContent(`<div class="card hero">
      <div class="phone-art"></div>
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

  setContent(`
    <div class="card hero">
      <div class="phone-art"></div>
      <div style="flex:1;position:relative">
        <h2>${esc(info.model || deviceLabel(dev))}</h2>
        <div class="sub">${esc(info.manufacturer)} · ${esc(info.codename)}</div>
        <div class="chips">
          <span class="chip accent">${ltr('Android ' + esc(info.android))}</span>
          <span class="chip">${ltr('API ' + esc(info.sdk))}</span>
          <span class="chip">${dev.wireless ? icon('wifi') : icon('usb')} ${dev.wireless ? 'אלחוטי' : 'USB'}</span>
          ${info.ip ? `<span class="chip" style="direction:ltr">${esc(info.ip)}</span>` : ''}
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

    <div class="section-title">פעולות מהירות</div>
    <div class="actions-grid">
      <button class="action-tile" data-act="shot"><span class="ico">${icon('camera')}</span><span>צילום מסך<small>שמירה למחשב</small></span></button>
      <button class="action-tile" data-act="install"><span class="ico">${icon('package')}</span><span>התקנת APK<small>או גררו קובץ לחלון</small></span></button>
      ${dev.wireless
        ? `<button class="action-tile" data-act="disconnect"><span class="ico">${icon('unlink')}</span><span>ניתוק אלחוטי<small>${esc(dev.serial)}</small></span></button>`
        : `<button class="action-tile" data-act="wifi"><span class="ico">${icon('wifi')}</span><span>מעבר לאלחוטי<small>ולנתק את הכבל</small></span></button>`}
      <button class="action-tile danger" data-act="reboot"><span class="ico">${icon('power')}</span><span>הפעלה מחדש<small>כולל Recovery ו-Bootloader</small></span></button>
    </div>`);

  $$('[data-act]', content).forEach(el => el.onclick = () => overviewAction(el.dataset.act, el));
}

async function overviewAction(act, el) {
  const dev = current();
  if (act === 'shot') { go('screen'); takeShot(); return; }
  if (act === 'install') { pickFiles('.apk', true, installApks); return; }
  if (act === 'reboot') return rebootDialog();
  const busy = el.querySelector('.ico');
  const prev = busy.innerHTML;
  busy.innerHTML = '<span class="spinner"></span>';
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
      const res = await api('disconnect', { serial: dev.serial });
      toast(res.message);
      refreshDevices();
    }
  } catch (e) {
    toast(e.message, 'error');
  } finally {
    if (busy.isConnected) busy.innerHTML = prev;
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

/* ───────────── אלחוטי ───────────── */

function openWireless() {
  const body = openModal('חיבור אלחוטי', `
    <div class="tabs"><button class="active" data-tab="connect">התחברות</button><button data-tab="pair">צימוד בקוד</button></div>
    <form data-pane="connect">
      <div class="note">הזינו את כתובת ה-IP של הטלפון (אותה רשת Wi‑Fi).<br>
        טיפ: מחוברים בכבל? בחרו "מעבר לאלחוטי" במסך הסקירה — זה אוטומטי.</div>
      <label class="field"><span>כתובת</span><input name="address" placeholder="192.168.1.20:5555" autocomplete="off"></label>
      <div class="modal-foot"><button class="btn primary">${icon('wifi')}<span>התחבר</span></button></div>
    </form>
    <form data-pane="pair" hidden>
      <div class="note">לאנדרואיד 11 ומעלה, בלי כבל בכלל. בטלפון: אפשרויות מפתחים ← <strong>ניפוי באגים אלחוטי</strong> ← "צימוד מכשיר עם קוד צימוד".
        הזינו את הכתובת והקוד שמופיעים שם.</div>
      <label class="field"><span>כתובת ופורט צימוד</span><input name="address" placeholder="192.168.1.20:37215" autocomplete="off"></label>
      <label class="field"><span>קוד צימוד</span><input name="code" placeholder="123456" inputmode="numeric" maxlength="6" autocomplete="off"></label>
      <div class="modal-foot"><button class="btn primary">${icon('check')}<span>צמד</span></button></div>
    </form>`);
  const show = tab => {
    $$('[data-tab]', body).forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
    $$('[data-pane]', body).forEach(p => { p.hidden = p.dataset.pane !== tab; });
    $(`[data-pane="${tab}"] input`, body).focus();
  };
  $$('[data-tab]', body).forEach(b => b.onclick = () => show(b.dataset.tab));

  const submitting = async (form, fn) => {
    const btn = $('button.btn', form);
    const prev = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span><span>רגע…</span>';
    try { await fn(); } catch (e) { toast(e.message, 'error'); }
    btn.disabled = false;
    btn.innerHTML = prev;
  };

  $('[data-pane="connect"]', body).onsubmit = e => {
    e.preventDefault();
    submitting(e.target, async () => {
      const res = await api('connect', { address: e.target.address.value });
      toast(res.message);
      closeModal();
      await refreshDevices();
      selectDevice(res.serial);
    });
  };
  $('[data-pane="pair"]', body).onsubmit = e => {
    e.preventDefault();
    submitting(e.target, async () => {
      const res = await api('pair', { address: e.target.address.value, code: e.target.code.value });
      toast(res.message);
      const ip = e.target.address.value.split(':')[0];
      show('connect');
      $('[data-pane="connect"] input', body).value = ip + ':';
    });
  };
}
$('#wirelessBtn').onclick = openWireless;

/* ───────────── אפליקציות ───────────── */

async function loadApps() {
  const id = renderId;
  state.apps = null;
  drawAppList();
  try {
    const { apps } = await api('apps', { serial: state.serial, system: state.showSystem });
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
      <div><h1>אפליקציות</h1><p>פתיחה, עצירה, גיבוי והסרה של אפליקציות</p></div>
      <div class="actions"><button class="btn primary" id="installBtn">${icon('package')}<span>התקנת APK</span></button></div>
    </div>
    <div class="toolbar">
      <label class="search">${icon('search')}<input id="appSearch" placeholder="חיפוש אפליקציה…" value="${esc(state.appQuery)}"></label>
      <label class="toggle"><input type="checkbox" id="sysToggle" ${state.showSystem ? 'checked' : ''}><span class="track"></span>אפליקציות מערכת</label>
      <button class="icon-btn" id="appsRefresh" title="רענון">${icon('refresh')}</button>
    </div>
    <div class="count" id="appCount"></div>
    <div class="card list" id="appList"></div>`);
  $('#installBtn').onclick = () => pickFiles('.apk', true, installApks);
  $('#appSearch').oninput = e => { state.appQuery = e.target.value; drawAppList(); };
  $('#sysToggle').onchange = e => { state.showSystem = e.target.checked; loadApps(); };
  $('#appsRefresh').onclick = loadApps;
  $('#appList').onclick = onAppClick;
  if (state.apps) drawAppList(); else loadApps();
}

function drawAppList() {
  const list = $('#appList');
  if (!list) return;
  if (!state.apps) {
    list.innerHTML = '<div class="loading"><span class="spinner"></span>טוען אפליקציות…</div>';
    $('#appCount').textContent = '';
    return;
  }
  const q = state.appQuery.trim().toLowerCase();
  const apps = state.apps.filter(a => !q || a.package.toLowerCase().includes(q) || appName(a.package).toLowerCase().includes(q));
  $('#appCount').textContent = `${apps.length} אפליקציות`;
  list.innerHTML = apps.length ? apps.map(a => {
    const name = appName(a.package);
    return `<div class="row" data-pkg="${esc(a.package)}" data-system="${a.system ? 1 : ''}">
      <div class="avatar" style="background:linear-gradient(135deg,hsl(${hue(a.package)} 70% 55%),hsl(${(hue(a.package) + 40) % 360} 70% 45%))">${esc(name[0])}</div>
      <div class="grow">
        <div class="title">${esc(name)}${a.system ? '<span class="tag">מערכת</span>' : ''}</div>
        <div class="meta">${esc(a.package)}</div>
      </div>
      <div class="row-actions">
        <button class="icon-btn" data-a="launch" title="פתיחה">${icon('play')}</button>
        <button class="icon-btn" data-a="stop" title="עצירה בכוח">${icon('stop')}</button>
        <button class="icon-btn" data-a="clear" title="ניקוי נתונים">${icon('eraser')}</button>
        <button class="icon-btn" data-a="apk" title="גיבוי APK למחשב">${icon('download')}</button>
        <button class="icon-btn danger" data-a="uninstall" title="הסרה">${icon('trash')}</button>
      </div>
    </div>`;
  }).join('') : `<div class="empty-state" style="padding:40px"><p>${q ? 'לא נמצאו תוצאות' : 'אין אפליקציות'}</p></div>`;
}

async function onAppClick(e) {
  const btn = e.target.closest('[data-a]');
  if (!btn) return;
  const row = btn.closest('[data-pkg]');
  const pkg = row.dataset.pkg;
  const system = !!row.dataset.system;
  const action = btn.dataset.a;
  const name = appName(pkg);

  if (action === 'apk') return downloadWithToast('apps/apk', { serial: state.serial, package: pkg }, `${pkg}.apk`, `APK של ${name}`);
  if (action === 'uninstall') {
    const ok = await confirmDialog({
      title: `להסיר את ${name}?`,
      text: system
        ? `זו אפליקציית מערכת. היא תוסר עבור המשתמש הנוכחי בלבד וניתן יהיה לשחזר אותה.<br><code dir="ltr">${esc(pkg)}</code>`
        : `האפליקציה וכל הנתונים שלה יימחקו מהמכשיר.<br><code dir="ltr">${esc(pkg)}</code>`,
      ok: 'הסרה', danger: true,
    });
    if (!ok) return;
  }
  if (action === 'clear') {
    const ok = await confirmDialog({
      title: `לנקות את הנתונים של ${name}?`,
      text: 'כל ההגדרות, החשבונות והקבצים של האפליקציה יימחקו — כאילו הותקנה עכשיו.',
      ok: 'ניקוי', danger: true,
    });
    if (!ok) return;
  }
  const prev = btn.innerHTML;
  btn.innerHTML = '<span class="spinner"></span>';
  btn.disabled = true;
  try {
    const res = await api('apps/action', { serial: state.serial, package: pkg, action, system });
    toast(res.message);
    if (action === 'uninstall') {
      state.apps = state.apps.filter(a => a.package !== pkg);
      row.style.transition = 'opacity .25s';
      row.style.opacity = '0';
      setTimeout(drawAppList, 250);
    }
  } catch (err) {
    toast(err.message, 'error');
  } finally {
    btn.innerHTML = prev;
    btn.disabled = false;
  }
}

async function installApks(files) {
  const apks = files.filter(f => f.name.toLowerCase().endsWith('.apk'));
  if (!apks.length) return toast('בחרו קובץ APK', 'error');
  for (const file of apks) {
    const t = toast(`מעלה ${file.name}…`, 'loading', { progress: true });
    try {
      const res = await uploadFile('apps/install', { serial: state.serial, name: file.name }, file, p => {
        t.progress(p);
        if (p >= 1) t.text(`מתקין ${file.name}…`);
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
  ['אחסון פנימי', '/sdcard'],
  ['הורדות', '/sdcard/Download'],
  ['מצלמה', '/sdcard/DCIM/Camera'],
  ['תמונות', '/sdcard/Pictures'],
  ['מסמכים', '/sdcard/Documents'],
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
    <div class="chips" style="margin:0 0 14px">${PLACES.map(([n, p]) =>
      `<button class="chip" data-go="${p}">${esc(n)}</button>`).join('')}</div>
    <div class="toolbar">
      <button class="icon-btn" id="upBtn" title="תיקייה למעלה">${icon('up')}</button>
      <div class="breadcrumb" id="crumbs"></div>
      <button class="icon-btn" id="filesRefresh" title="רענון">${icon('refresh')}</button>
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
    if (!state.files) { state.files = []; }
  }
  drawFiles();
}

function drawFiles() {
  const list = $('#fileList');
  if (!list) return;
  const parts = state.path.split('/').filter(Boolean);
  $('#crumbs').innerHTML = `<button data-path="/">/</button>` + parts.map((p, i) =>
    `${i ? '<span class="sep">/</span>' : ''}<button data-path="/${esc(parts.slice(0, i + 1).join('/'))}">${esc(p)}</button>`).join('');
  list.innerHTML = state.files.length ? state.files.map(f => `
    <div class="row ${f.dir ? 'clickable' : ''}" data-name="${esc(f.name)}" data-dir="${f.dir ? 1 : ''}">
      <div class="file-ico ${f.dir ? 'dir' : ''}">${icon(f.dir ? 'folder' : fileIcon(f.name))}</div>
      <div class="grow"><div class="title filename">${esc(f.name)}</div></div>
      <div class="date">${fmtDate(f.mtime)}</div>
      <div class="size">${f.dir ? '' : fmtBytes(f.size)}</div>
      <div class="row-actions">
        ${f.dir ? '' : `<button class="icon-btn" data-a="download" title="הורדה למחשב">${icon('download')}</button>`}
        <button class="icon-btn danger" data-a="delete" title="מחיקה">${icon('trash')}</button>
      </div>
    </div>`).join('')
    : `<div class="empty-state" style="padding:50px"><div class="big-ico" style="width:64px;height:64px">${icon('folder')}</div><p>התיקייה ריקה</p></div>`;
}

async function onFileClick(e) {
  const row = e.target.closest('[data-name]');
  if (!row) return;
  const path = joinPath(state.path, row.dataset.name);
  const action = e.target.closest('[data-a]')?.dataset.a;
  if (!action) {
    if (row.dataset.dir) openDir(path);
    return;
  }
  if (action === 'download') {
    return downloadWithToast('files/pull', { serial: state.serial, path }, row.dataset.name, row.dataset.name);
  }
  if (action === 'delete') {
    const ok = await confirmDialog({
      title: 'למחוק לצמיתות?',
      text: `<strong dir="auto">${esc(row.dataset.name)}</strong>${row.dataset.dir ? ' וכל התוכן שבתוכה' : ''} יימחק מהמכשיר. אין סל מחזור.`,
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

/* ───────────── צילום מסך ───────────── */

function renderScreen() {
  setContent(`
    <div class="page-head"><div><h1>צילום מסך</h1><p>צילום של מה שמוצג עכשיו על מסך הטלפון</p></div></div>
    <div class="shot-wrap">
      <div class="card shot-stage" id="shotStage"></div>
      <div class="card card-pad shot-side">
        <button class="btn primary lg" id="shotBtn">${icon('camera')}<span>צלם עכשיו</span></button>
        <button class="btn ghost" id="saveShot" disabled>${icon('download')}<span>שמירה במחשב</span></button>
        <p class="hint">קיצור מקלדת: <strong>רווח</strong> לצילום, <strong>Ctrl+S</strong> לשמירה.</p>
      </div>
    </div>`);
  $('#shotBtn').onclick = takeShot;
  $('#saveShot').onclick = saveShot;
  drawShot();
}

function drawShot() {
  const stage = $('#shotStage');
  if (!stage) return;
  stage.innerHTML = state.shot
    ? `<img src="${state.shot.url}" alt="צילום מסך">`
    : `<div class="empty-state" style="padding:0"><div class="big-ico">${icon('camera')}</div><p>לחצו "צלם עכשיו"</p></div>`;
  $('#saveShot').disabled = !state.shot;
}

let shooting = false;
async function takeShot() {
  if (shooting) return;
  shooting = true;
  const btn = $('#shotBtn');
  if (btn) { btn.disabled = true; btn.innerHTML = '<span class="spinner"></span><span>מצלם…</span>'; }
  try {
    const blob = await fetchBlob('screenshot', { serial: state.serial });
    if (state.shot) URL.revokeObjectURL(state.shot.url);
    const stamp = new Date().toISOString().slice(0, 19).replace('T', '_').replace(/:/g, '-');
    state.shot = { blob, url: URL.createObjectURL(blob), name: `screenshot_${stamp}.png` };
    drawShot();
  } catch (e) {
    toast(e.message, 'error');
  } finally {
    shooting = false;
    const b = $('#shotBtn');
    if (b) { b.disabled = false; b.innerHTML = `${icon('camera')}<span>צלם עכשיו</span>`; }
  }
}

function saveShot() {
  if (!state.shot) return;
  saveBlob(state.shot.blob, state.shot.name);
  toast('צילום המסך נשמר בתיקיית ההורדות');
}

/* ───────────── טרמינל ───────────── */

const QUICK = ['getprop ro.product.model', 'dumpsys battery', 'pm list packages -3', 'ls /sdcard', 'df -h', 'top -n 1 -m 10'];

function renderTerminal() {
  const dev = current();
  setContent(`
    <div class="page-head">
      <div><h1>טרמינל</h1><p>הרצת פקודות <span dir="ltr">adb shell</span> ישירות על המכשיר</p></div>
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
    : 'שחררו קובץ APK כדי להתקין';
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

/* ───────────── קיצורי מקלדת ───────────── */

document.addEventListener('keydown', e => {
  if (!modal.hidden || state.view !== 'screen' || !ready()) return;
  if (e.code === 'Space' && e.target.tagName !== 'INPUT') { e.preventDefault(); takeShot(); }
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); saveShot(); }
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

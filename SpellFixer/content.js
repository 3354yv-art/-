// סקריפט התוכן: בודק שדות טקסט בזמן הקלדה, סורק את תוכן הדף ומחיל תיקונים.
(() => {
  if (window.__spellFixerLoaded) return;
  window.__spellFixerLoaded = true;

  const C = self.SpellFixerChecker;
  const BUILTIN = self.SpellFixerDictionary;
  const DEFAULTS = {
    enabled: true,
    autoCheckFields: true,
    online: true,
    grammar: false,
    language: 'auto',
    custom: '',
    ignored: []
  };

  let settings = { ...DEFAULTS };
  let dict = C.buildDictionary(BUILTIN, '');
  let ignored = new Set();

  function applySettings(stored) {
    settings = { ...DEFAULTS, ...stored };
    dict = C.buildDictionary(BUILTIN, settings.custom);
    ignored = new Set((settings.ignored || []).map((w) => w.toLowerCase()));
  }

  function reloadSettings() {
    return chrome.storage.local.get(null).then((s) => {
      applySettings(s);
      if (!settings.enabled || !settings.autoCheckFields) hideFieldUI();
      else if (field.el) scheduleFieldCheck(0);
    }).catch(() => {});
  }
  chrome.storage.onChanged.addListener((_c, area) => { if (area === 'local') reloadSettings(); });

  // ---------------------------------------------------------------- בדיקה
  async function checkText(text, { page = false } = {}) {
    const local = C.localCheck(text, dict, ignored, { whitespace: !page });
    let online = [];
    let error = null;
    const portion = C.onlinePortion(text, settings.language);
    if (settings.online && portion.text.trim()) {
      try {
        const res = await chrome.runtime.sendMessage({
          type: 'LT_CHECK', text: portion.text, language: settings.language, grammar: settings.grammar
        });
        if (res && res.ok) {
          online = C.mapOnlineMatches(res.matches, portion.parts)
            .filter((m) => !ignored.has(m.word.toLowerCase()));
        } else {
          error = (res && res.error) || 'אין תשובה משירות הבדיקה';
        }
      } catch (e) {
        error = 'הבדיקה המקוונת לא זמינה (נסו לרענן את הדף)';
      }
    }
    return { matches: C.mergeMatches(local, online), error };
  }

  // ------------------------------------------------- מיפוי טקסט <-> צמתי DOM
  const BLOCK_TAGS = new Set(['ADDRESS', 'ARTICLE', 'ASIDE', 'BLOCKQUOTE', 'BODY', 'BUTTON', 'DD', 'DETAILS',
    'DIV', 'DL', 'DT', 'FIELDSET', 'FIGCAPTION', 'FIGURE', 'FOOTER', 'FORM', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6',
    'HEADER', 'HR', 'LABEL', 'LI', 'MAIN', 'NAV', 'OL', 'OPTION', 'P', 'PRE', 'SECTION', 'SUMMARY', 'TABLE',
    'TD', 'TH', 'TR', 'UL']);
  const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'INPUT', 'SELECT', 'CODE', 'PRE', 'KBD',
    'SAMP', 'SVG', 'MATH', 'IFRAME', 'CANVAS', 'TEMPLATE', 'OBJECT', 'VIDEO', 'AUDIO']);

  function blockOf(node, root) {
    let el = node.parentElement;
    while (el && el !== root && !BLOCK_TAGS.has(el.tagName)) el = el.parentElement;
    return el || root;
  }

  // מחבר את כל צמתי הטקסט תחת root למחרוזת אחת (עם "\n" בין בלוקים) ושומר היכן כל צומת מתחיל
  function buildTextMap(root, { page = false, maxChars = Infinity } = {}) {
    const segs = [];
    let text = '';
    let lastBlock = null;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
      acceptNode(n) {
        if (n.nodeType === Node.ELEMENT_NODE) {
          if (n === uiHost) return NodeFilter.FILTER_REJECT;
          if (n.tagName === 'BR') return NodeFilter.FILTER_ACCEPT;
          if (page) {
            if (SKIP_TAGS.has(n.tagName) || n.isContentEditable) return NodeFilter.FILTER_REJECT;
            if (n.checkVisibility && !n.checkVisibility()) return NodeFilter.FILTER_REJECT;
          }
          return NodeFilter.FILTER_SKIP;
        }
        return n.nodeValue ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      }
    });
    let n;
    while ((n = walker.nextNode())) {
      if (n.nodeType === Node.ELEMENT_NODE) { // <br>
        text += '\n';
        lastBlock = null;
        continue;
      }
      const block = blockOf(n, root);
      if (lastBlock && block !== lastBlock && !text.endsWith('\n')) text += '\n';
      lastBlock = block;
      segs.push({ node: n, start: text.length });
      text += n.nodeValue;
      if (text.length > maxChars) break;
    }
    return { text, segs };
  }

  function pointAt(map, pos, isEnd) {
    const { segs } = map;
    let lo = 0, hi = segs.length - 1, idx = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (segs[mid].start <= pos) { idx = mid; lo = mid + 1; } else hi = mid - 1;
    }
    if (idx < 0) return null;
    let seg = segs[idx];
    if (isEnd && pos === seg.start && idx > 0) {
      const prev = segs[idx - 1];
      if (prev.start + prev.node.nodeValue.length === pos) seg = prev;
    }
    const offset = pos - seg.start;
    if (offset > seg.node.nodeValue.length) return null;
    return { node: seg.node, offset };
  }

  function rangeFor(map, start, end) {
    const a = pointAt(map, start, false);
    const b = pointAt(map, end, true);
    if (!a || !b) return null;
    try {
      const r = document.createRange();
      r.setStart(a.node, a.offset);
      r.setEnd(b.node, b.offset);
      return r;
    } catch (e) {
      return null;
    }
  }

  // ------------------------------------------------------------- ממשק (Shadow DOM)
  const CSS = `
    :host { all: initial; }
    [hidden] { display: none !important; }
    * { box-sizing: border-box; font-family: system-ui, -apple-system, "Segoe UI", Arial, sans-serif; }
    .badge { position: fixed; width: 22px; height: 22px; border-radius: 11px; border: none; padding: 0;
      font-size: 12px; font-weight: 700; color: #fff; background: #e53935; cursor: pointer;
      box-shadow: 0 1px 4px rgba(0,0,0,.35); display: flex; align-items: center; justify-content: center;
      line-height: 1; transition: opacity .15s; }
    .badge.ok { background: #43a047; opacity: .5; }
    .badge.ok:hover { opacity: 1; }
    .badge.busy { background: #757575; opacity: .7; }
    .badge.warn { background: #fb8c00; }
    .panel { position: fixed; width: 330px; max-width: calc(100vw - 16px); max-height: 380px; display: flex;
      flex-direction: column; background: #fff; color: #1f1f1f; border-radius: 10px; border: 1px solid #ddd;
      box-shadow: 0 8px 28px rgba(0,0,0,.25); font-size: 14px; direction: rtl; overflow: hidden; }
    .head { display: flex; align-items: center; gap: 8px; padding: 10px 12px; border-bottom: 1px solid #eee; }
    .title { flex: 1; font-weight: 600; }
    .list { overflow: auto; }
    .item { padding: 9px 12px; border-bottom: 1px solid #f0f0f0; }
    .item:last-child { border-bottom: none; }
    .ctx { color: #555; font-size: 13px; margin-bottom: 4px; unicode-bidi: plaintext; word-break: break-word; }
    .bad { color: #d32f2f; text-decoration: line-through; font-weight: 600; }
    .msg { font-size: 12px; color: #777; margin-bottom: 6px; unicode-bidi: plaintext; }
    .sugs { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
    button { font: inherit; }
    .sug { background: #e8f0fe; color: #1a56db; border: 1px solid #c6d8fb; border-radius: 14px;
      padding: 3px 11px; font-size: 13px; cursor: pointer; unicode-bidi: plaintext; }
    .sug:hover { background: #d2e3fc; }
    .ign { background: none; border: none; color: #888; font-size: 12px; cursor: pointer; text-decoration: underline; }
    .all { background: #1a73e8; color: #fff; border: none; border-radius: 6px; padding: 5px 10px; cursor: pointer; font-size: 12px; }
    .all:hover { background: #1765cc; }
    .x { background: none; border: none; font-size: 18px; cursor: pointer; color: #666; line-height: 1; padding: 0 2px; }
    .empty { padding: 18px; text-align: center; color: #2e7d32; }
    .err { padding: 6px 12px; font-size: 12px; color: #b35300; background: #fff3e0; }
    .toast { position: fixed; bottom: 22px; left: 50%; transform: translateX(-50%); background: #323232; color: #fff;
      padding: 10px 18px; border-radius: 8px; font-size: 14px; direction: rtl; box-shadow: 0 4px 12px rgba(0,0,0,.3);
      max-width: calc(100vw - 32px); }
    @media (prefers-color-scheme: dark) {
      .panel { background: #2b2c2f; color: #e8e8e8; border-color: #45464a; }
      .head, .item { border-color: #3a3b3e; }
      .ctx { color: #c4c4c4; } .msg { color: #9a9a9a; }
      .bad { color: #ff6b6b; }
      .sug { background: #1f3a66; color: #cfe0ff; border-color: #2d5291; }
      .sug:hover { background: #274a80; }
      .x { color: #bbb; } .empty { color: #81c784; }
      .err { background: #3d2a12; color: #ffb74d; }
    }`;

  let uiHost = null;
  let ui = null;
  let panelMode = null; // 'field' | 'page'
  let panelAnchor = null;

  function ensureUI() {
    if (uiHost && uiHost.isConnected) return ui;
    uiHost = document.createElement('spellfixer-ui');
    uiHost.style.cssText = 'all:initial;position:absolute;top:0;left:0;width:0;height:0;z-index:2147483647;';
    const shadow = uiHost.attachShadow({ mode: 'closed' });
    const style = document.createElement('style');
    style.textContent = CSS;
    const badge = h('button', 'badge');
    const panel = h('div', 'panel');
    const toast = h('div', 'toast');
    badge.hidden = panel.hidden = toast.hidden = true;
    shadow.append(style, badge, panel, toast);
    // לחיצה על הממשק לא תגנוב את הפוקוס מהשדה שעורכים
    shadow.addEventListener('mousedown', (e) => e.preventDefault());
    badge.addEventListener('click', () => {
      if (!panel.hidden && panelMode === 'field') hidePanel();
      else openFieldPanel();
    });
    document.documentElement.appendChild(uiHost);
    ui = { shadow, badge, panel, toast };
    return ui;
  }

  function h(tag, className, text) {
    const e = document.createElement(tag);
    if (className) e.className = className;
    if (text != null) e.textContent = text;
    return e;
  }

  let toastTimer = 0;
  function showToast(message, ms = 3500) {
    const { toast } = ensureUI();
    toast.textContent = message;
    toast.hidden = false;
    clearTimeout(toastTimer);
    if (ms) toastTimer = setTimeout(() => { toast.hidden = true; }, ms);
  }

  function hidePanel() {
    if (ui) ui.panel.hidden = true;
    panelMode = null;
    panelAnchor = null;
  }

  function placePanel() {
    if (!ui || ui.panel.hidden || !panelAnchor) return;
    const rect = typeof panelAnchor === 'function' ? panelAnchor() : panelAnchor.getBoundingClientRect();
    if (!rect) return hidePanel();
    const p = ui.panel;
    const w = p.offsetWidth, ph = p.offsetHeight;
    const vw = document.documentElement.clientWidth, vh = window.innerHeight;
    let left = Math.min(Math.max(8, rect.right - w), vw - w - 8);
    let top = rect.bottom + 6;
    if (top + ph > vh - 8 && rect.top - ph - 6 > 8) top = rect.top - ph - 6;
    p.style.left = `${Math.max(8, left)}px`;
    p.style.top = `${Math.max(8, Math.min(top, vh - ph - 8))}px`;
  }

  function suggestionLabel(rep) {
    if (rep === ' ') return 'רווח יחיד';
    if (rep === '') return '(מחיקה)';
    return rep;
  }

  function contextNode(text, m) {
    const ctx = h('div', 'ctx');
    const before = text.slice(Math.max(0, m.offset - 30), m.offset).replace(/\s+/g, ' ');
    const after = text.slice(m.offset + m.length, m.offset + m.length + 30).replace(/\s+/g, ' ');
    ctx.append(
      (m.offset > 30 ? '…' : '') + before,
      h('span', 'bad', m.type === 'whitespace' ? '␣'.repeat(m.length) : m.word),
      after + (m.offset + m.length + 30 < text.length ? '…' : '')
    );
    return ctx;
  }

  // מציג את חלון השגיאות. options: { title, text, matches, error, onFix, onIgnore, onFixAll }
  function renderPanel({ title, text, matches, error, onFix, onIgnore, onFixAll }) {
    const { panel } = ensureUI();
    panel.textContent = '';
    const head = h('div', 'head');
    head.append(h('span', 'title', title));
    if (onFixAll && matches.some((m) => m.replacements.length)) {
      const all = h('button', 'all', 'תקן הכל');
      all.addEventListener('click', onFixAll);
      head.append(all);
    }
    const close = h('button', 'x', '×');
    close.title = 'סגור';
    close.addEventListener('click', hidePanel);
    head.append(close);
    panel.append(head);
    if (error) panel.append(h('div', 'err', error));

    const list = h('div', 'list');
    if (!matches.length) list.append(h('div', 'empty', 'לא נמצאו שגיאות ✓'));
    for (const m of matches) {
      const item = h('div', 'item');
      item.append(contextNode(text, m), h('div', 'msg', m.message));
      const sugs = h('div', 'sugs');
      for (const rep of m.replacements) {
        const b = h('button', 'sug', suggestionLabel(rep));
        b.addEventListener('click', () => onFix(m, rep));
        sugs.append(b);
      }
      if (!m.replacements.length) sugs.append(h('span', 'msg', 'אין הצעות תיקון'));
      const ign = h('button', 'ign', 'התעלם');
      ign.title = m.type === 'misspelling' ? 'הוסף למילון האישי ואל תסמן יותר' : 'התעלם הפעם';
      ign.addEventListener('click', () => onIgnore(m));
      sugs.append(ign);
      item.append(sugs);
      list.append(item);
    }
    panel.append(list);
    panel.hidden = false;
    placePanel();
  }

  function ignoreWord(word) {
    const w = word.toLowerCase();
    ignored.add(w);
    const list = Array.from(new Set([...(settings.ignored || []), w]));
    settings.ignored = list;
    chrome.storage.local.set({ ignored: list }).catch(() => {});
  }

  // ------------------------------------------------------------ שדות עריכה
  const field = { el: null, timer: 0, seq: 0, matches: [], text: '', busy: false, error: null };

  function editableRoot(t) {
    if (!t || t.nodeType !== Node.ELEMENT_NODE) return null;
    if (t.getAttribute('spellcheck') === 'false') return null;
    if (t.tagName === 'TEXTAREA') return t.readOnly || t.disabled ? null : t;
    if (t.tagName === 'INPUT') {
      return (t.type === 'text' || t.type === 'search') && !t.readOnly && !t.disabled ? t : null;
    }
    if (t.isContentEditable) {
      let r = t;
      while (r.parentElement && r.parentElement.isContentEditable) r = r.parentElement;
      return r.getAttribute('spellcheck') === 'false' ? null : r;
    }
    return null;
  }

  const isTextControl = (el) => el.tagName === 'TEXTAREA' || el.tagName === 'INPUT';
  const getFieldText = (el) => (isTextControl(el) ? el.value : buildTextMap(el).text);

  function deepActiveElement() {
    let a = document.activeElement;
    while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
    return a;
  }

  function isFocused(el) {
    const a = deepActiveElement();
    return !!a && (a === el || el.contains(a));
  }

  function attachField(el) {
    field.el = el;
    field.matches = [];
    field.text = '';
    field.error = null;
    clearTimeout(field.timer);
    if (panelMode === 'field') hidePanel();
    if (settings.enabled && settings.autoCheckFields) scheduleFieldCheck(250);
    else hideFieldUI();
  }

  function detachField() {
    field.el = null;
    clearTimeout(field.timer);
    field.seq++;
    hideFieldUI();
  }

  function hideFieldUI() {
    if (ui) ui.badge.hidden = true;
    if (panelMode === 'field') hidePanel();
  }

  function scheduleFieldCheck(delay) {
    clearTimeout(field.timer);
    field.timer = setTimeout(runFieldCheck, delay);
  }

  async function runFieldCheck() {
    const el = field.el;
    if (!el) return;
    const text = getFieldText(el);
    const seq = ++field.seq;
    if (!text.trim()) {
      field.matches = [];
      field.text = text;
      field.error = null;
      updateBadge();
      return;
    }
    field.busy = true;
    updateBadge();
    const { matches, error } = await checkText(text);
    if (seq !== field.seq || el !== field.el) return;
    field.busy = false;
    if (getFieldText(el) !== text) return; // הטקסט השתנה בינתיים - בדיקה חדשה כבר מתוזמנת
    field.matches = matches;
    field.text = text;
    field.error = error;
    updateBadge();
    if (panelMode === 'field') openFieldPanel();
  }

  function updateBadge() {
    const el = field.el;
    if (!el || !settings.enabled || !settings.autoCheckFields) return hideFieldUI();
    const { badge } = ensureUI();
    const rect = el.getBoundingClientRect();
    const vh = window.innerHeight, vw = document.documentElement.clientWidth;
    const visible = rect.width > 30 && rect.height > 14 && rect.bottom > 0 && rect.top < vh && rect.right > 0 && rect.left < vw;
    if (!visible || (!field.text.trim() && !field.busy)) {
      badge.hidden = true;
      return;
    }
    const count = field.matches.length;
    badge.className = 'badge' + (field.busy ? ' busy' : count ? '' : field.error ? ' warn' : ' ok');
    badge.textContent = field.busy ? '…' : count ? String(Math.min(count, 99)) : field.error ? '!' : '✓';
    badge.title = field.busy ? 'בודק…' : count ? `נמצאו ${count} שגיאות - לחצו לתיקון` : field.error || 'לא נמצאו שגיאות';
    const rtl = getComputedStyle(el).direction === 'rtl';
    const size = 22, pad = 4;
    const bottom = Math.min(rect.bottom, vh) - size - pad;
    const x = rtl ? rect.left + pad : rect.right - size - pad;
    badge.style.top = `${Math.max(rect.top + pad, bottom)}px`;
    badge.style.left = `${x}px`;
    badge.hidden = false;
  }

  function openFieldPanel() {
    if (!field.el) return;
    ensureUI();
    panelMode = 'field';
    panelAnchor = ui.badge;
    const count = field.matches.length;
    renderPanel({
      title: field.busy && !count ? 'בודק…' : count ? `נמצאו ${count} שגיאות` : 'בדיקת כתיב',
      text: field.text,
      matches: field.matches,
      error: field.error,
      onFix: (m, rep) => {
        if (applyFieldFix(field.el, m, rep)) {
          const delta = rep.length - m.length;
          field.matches = field.matches
            .filter((x) => x !== m)
            .map((x) => (x.offset > m.offset ? { ...x, offset: x.offset + delta } : x));
          field.text = getFieldText(field.el);
        }
        updateBadge();
        field.matches.length ? openFieldPanel() : hidePanel();
        scheduleFieldCheck(700);
      },
      onIgnore: (m) => {
        if (m.type === 'misspelling') ignoreWord(m.word);
        field.matches = field.matches.filter((x) => x !== m &&
          !(m.type === 'misspelling' && x.word.toLowerCase() === m.word.toLowerCase()));
        updateBadge();
        field.matches.length ? openFieldPanel() : hidePanel();
      },
      onFixAll: () => {
        fixAllMatchesInField(field.el, field.matches);
        field.matches = field.matches.filter((m) => !m.replacements.length);
        field.text = getFieldText(field.el);
        updateBadge();
        hidePanel();
        scheduleFieldCheck(500);
      }
    });
  }

  function replaceInField(el, start, end, rep) {
    if (isTextControl(el)) {
      el.focus();
      el.setSelectionRange(start, end);
      // execCommand שומר על היסטוריית ביטול (Ctrl+Z) ומעדכן אתרים שמבוססים על React וכד'
      const ok = document.execCommand('insertText', false, rep);
      if (!ok || el.value.slice(start, start + rep.length) !== rep) {
        el.setRangeText(rep, start, end, 'end');
        el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: rep }));
      }
      return true;
    }
    const range = rangeFor(buildTextMap(el), start, end);
    if (!range) return false;
    el.focus();
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    if (!document.execCommand('insertText', false, rep)) {
      range.deleteContents();
      if (rep) range.insertNode(document.createTextNode(rep));
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: rep }));
    }
    return true;
  }

  function applyFieldFix(el, m, rep) {
    if (!el) return false;
    const text = getFieldText(el);
    if (text.substr(m.offset, m.length) !== m.word) return false; // הטקסט השתנה
    return replaceInField(el, m.offset, m.offset + m.length, rep);
  }

  function fixAllMatchesInField(el, matches) {
    let fixed = 0;
    const sorted = matches.filter((m) => m.replacements.length).sort((a, b) => b.offset - a.offset);
    for (const m of sorted) if (applyFieldFix(el, m, m.replacements[0])) fixed++;
    if (isTextControl(el)) el.setSelectionRange(el.value.length, el.value.length);
    return fixed;
  }

  async function fixFocusedField() {
    const el = editableRoot(deepActiveElement());
    if (!el) return null;
    const text = getFieldText(el);
    const { matches } = await checkText(text);
    if (getFieldText(el) !== text) return null;
    const count = fixAllMatchesInField(el, matches);
    showToast(count ? `תוקנו ${count} שגיאות` : 'לא נמצאו שגיאות לתיקון');
    if (el === field.el) scheduleFieldCheck(300);
    return count;
  }

  document.addEventListener('focusin', (e) => {
    const target = e.composedPath()[0];
    if (target === uiHost) return;
    const el = editableRoot(target);
    if (el === field.el) return;
    if (el) attachField(el); else detachField();
  }, true);

  document.addEventListener('focusout', () => {
    setTimeout(() => { if (field.el && !isFocused(field.el)) detachField(); }, 200);
  }, true);

  document.addEventListener('input', (e) => {
    if (!field.el || !settings.enabled || !settings.autoCheckFields) return;
    const t = e.composedPath()[0];
    if (t === field.el || field.el.contains(t)) scheduleFieldCheck(900);
  }, true);

  let rafPending = false;
  function onViewportChange() {
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(() => {
      rafPending = false;
      if (field.el) updateBadge();
      placePanel();
    });
  }
  window.addEventListener('scroll', onViewportChange, { capture: true, passive: true });
  window.addEventListener('resize', onViewportChange, { passive: true });

  // ---------------------------------------------------------- סריקת הדף
  const pageMarks = new Map();
  let markSeq = 0;

  function ensurePageStyle() {
    if (document.getElementById('spellfixer-style')) return;
    const s = document.createElement('style');
    s.id = 'spellfixer-style';
    s.textContent = `
      .sf-mark { text-decoration: underline wavy #e53935 !important; text-decoration-skip-ink: none !important;
        text-underline-offset: 3px; background: rgba(229,57,53,.10) !important; cursor: pointer !important;
        border-radius: 2px; }
      .sf-mark.sf-other { text-decoration-color: #1e88e5 !important; background: rgba(30,136,229,.10) !important; }
      .sf-mark.sf-fixed { text-decoration: none !important; background: rgba(67,160,71,.18) !important; }`;
    (document.head || document.documentElement).appendChild(s);
  }

  async function scanPage() {
    clearPageMarks();
    if (!document.body) return { count: 0 };
    showToast('סורק את הדף…', 0);
    const map = buildTextMap(document.body, { page: true, maxChars: 60000 });
    const { matches, error } = await checkText(map.text, { page: true });

    const found = [];
    for (const m of matches) {
      const r = rangeFor(map, m.offset, m.offset + m.length);
      if (r && r.toString() === m.word) found.push({ m, r });
    }
    ensurePageStyle();
    // עוטפים מהסוף להתחלה כדי שהטווחים המוקדמים יישארו תקפים
    for (let i = found.length - 1; i >= 0; i--) {
      const { m, r } = found[i];
      try {
        const span = document.createElement('span');
        span.className = 'sf-mark' + (m.type === 'misspelling' ? '' : ' sf-other');
        const id = String(++markSeq);
        span.dataset.sfId = id;
        span.title = m.message;
        span.appendChild(r.extractContents());
        r.insertNode(span);
        pageMarks.set(id, m);
      } catch (e) { /* טווח שלא ניתן לעטוף */ }
    }
    const count = pageMarks.size;
    let msg = count ? `נמצאו ${count} שגיאות בדף - לחצו על מילה מסומנת לתיקון` : 'לא נמצאו שגיאות בדף ✓';
    if (error) msg += ` (${error})`;
    showToast(msg, 5000);
    return { count, error };
  }

  function unwrap(span) {
    const parent = span.parentNode;
    if (!parent) return;
    while (span.firstChild) parent.insertBefore(span.firstChild, span);
    parent.removeChild(span);
    parent.normalize();
  }

  function clearPageMarks() {
    document.querySelectorAll('.sf-mark').forEach(unwrap);
    pageMarks.clear();
    if (panelMode === 'page') hidePanel();
  }

  function replaceMark(span, rep) {
    const parent = span.parentNode;
    if (!parent) return;
    parent.replaceChild(document.createTextNode(rep), span);
    parent.normalize();
    pageMarks.delete(span.dataset.sfId);
  }

  function fixAllPage() {
    let count = 0;
    document.querySelectorAll('.sf-mark').forEach((span) => {
      const m = pageMarks.get(span.dataset.sfId);
      if (m && m.replacements.length) { replaceMark(span, m.replacements[0]); count++; }
    });
    if (panelMode === 'page') hidePanel();
    showToast(count ? `תוקנו ${count} שגיאות בדף` : 'אין שגיאות לתיקון');
    return count;
  }

  function openMarkPanel(span) {
    const m = pageMarks.get(span.dataset.sfId);
    if (!m) return;
    ensureUI();
    panelMode = 'page';
    panelAnchor = () => (span.isConnected ? span.getBoundingClientRect() : null);
    // הקשר: האלמנט הקרוב שמכיל מספיק טקסט, בלי לעלות מעבר לבלוק שמכיל את המילה
    let ctxEl = span.parentElement;
    while (ctxEl !== document.body && !BLOCK_TAGS.has(ctxEl.tagName) &&
           ctxEl.textContent.length < 60 && ctxEl.parentElement !== document.body) {
      ctxEl = ctxEl.parentElement;
    }
    let text = span.textContent;
    let offset = 0;
    if (ctxEl !== document.body) {
      const before = document.createRange();
      before.setStart(ctxEl, 0);
      before.setEndBefore(span);
      offset = before.toString().length;
      text = ctxEl.textContent;
    }
    renderPanel({
      title: 'שגיאה בדף',
      text,
      matches: [{ ...m, offset, word: span.textContent }],
      onFix: (_m, rep) => { replaceMark(span, rep); hidePanel(); },
      onIgnore: () => {
        if (m.type === 'misspelling') {
          ignoreWord(m.word);
          document.querySelectorAll('.sf-mark').forEach((s) => {
            const other = pageMarks.get(s.dataset.sfId);
            if (other && other.word.toLowerCase() === m.word.toLowerCase()) { pageMarks.delete(s.dataset.sfId); unwrap(s); }
          });
        } else {
          pageMarks.delete(span.dataset.sfId);
          unwrap(span);
        }
        hidePanel();
      },
      onFixAll: pageMarks.size > 1 ? () => fixAllPage() : null
    });
  }

  document.addEventListener('click', (e) => {
    if (e.target === uiHost) return;
    const mark = e.target.closest && e.target.closest('.sf-mark');
    if (mark && pageMarks.has(mark.dataset.sfId)) {
      e.preventDefault();
      e.stopPropagation();
      openMarkPanel(mark);
    } else if (panelMode === 'page') {
      hidePanel();
    }
  }, true);

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && ui && !ui.panel.hidden) hidePanel();
  }, true);

  // ---------------------------------------------------------- הודעות מהרקע / מהחלון הקופץ
  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    const isTop = window === window.top;
    switch (msg && msg.type) {
      case 'SCAN_PAGE':
        if (!isTop && msg.fromShortcut) return false;
        scanPage().then(sendResponse, (e) => sendResponse({ error: String(e) }));
        return true;
      case 'FIX_FIELD':
        if (msg.fromShortcut && !document.hasFocus()) return false;
        fixFocusedField().then((count) => {
          if (count == null && isTop && !msg.fromShortcut) showToast('לחצו קודם בתוך שדה טקסט');
          sendResponse({ count });
        });
        return true;
      case 'FIX_PAGE':
        sendResponse({ count: fixAllPage() });
        return false;
      case 'CLEAR_PAGE':
        clearPageMarks();
        sendResponse({ ok: true });
        return false;
      case 'PING':
        sendResponse({ ok: true, marks: pageMarks.size });
        return false;
    }
    return false;
  });

  reloadSettings();
})();

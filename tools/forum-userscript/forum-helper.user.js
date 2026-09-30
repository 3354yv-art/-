// ==UserScript==
// @name         Forum Helper
// @namespace    https://github.com/3354yv-art
// @version      1.0.0
// @description  כלי עזר לפורומים: מצב כהה, כפתור חזרה למעלה, כיווץ ציטוטים ארוכים והדגשת מילות מפתח
// @author       3354yv-art
// @match        *://*/*forum*
// @match        *://*/*thread*
// @match        *://*/*topic*
// @match        *://*/viewtopic.php*
// @match        *://*/showthread.php*
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_registerMenuCommand
// @run-at       document-end
// @downloadURL  https://raw.githubusercontent.com/3354yv-art/-/main/tools/forum-userscript/forum-helper.user.js
// @updateURL    https://raw.githubusercontent.com/3354yv-art/-/main/tools/forum-userscript/forum-helper.user.js
// ==/UserScript==

(function () {
  'use strict';

  const settings = {
    dark: GM_getValue('dark', false),
    keywords: GM_getValue('keywords', ''),
  };

  // Dark mode
  const darkStyle = document.createElement('style');
  darkStyle.textContent =
    'html{filter:invert(.92) hue-rotate(180deg);background:#fff}' +
    'img,video,iframe,picture{filter:invert(1) hue-rotate(180deg)}';
  function applyDark() {
    if (settings.dark) document.head.appendChild(darkStyle);
    else darkStyle.remove();
  }
  applyDark();

  // Back-to-top button
  const topBtn = document.createElement('button');
  topBtn.textContent = '▲';
  topBtn.title = 'חזרה למעלה';
  Object.assign(topBtn.style, {
    position: 'fixed', bottom: '20px', left: '20px', zIndex: 99999,
    width: '44px', height: '44px', borderRadius: '50%', border: 'none',
    background: '#2563eb', color: '#fff', fontSize: '18px', cursor: 'pointer',
    boxShadow: '0 2px 8px rgba(0,0,0,.3)', display: 'none',
  });
  topBtn.onclick = () => window.scrollTo({ top: 0, behavior: 'smooth' });
  document.body.appendChild(topBtn);
  window.addEventListener('scroll', () => {
    topBtn.style.display = window.scrollY > 400 ? 'block' : 'none';
  });

  // Collapse long quotes
  function collapseQuotes(root) {
    root.querySelectorAll('blockquote, .quote, .bbcode_quote').forEach((q) => {
      if (q.dataset.fhDone || q.scrollHeight < 200) return;
      q.dataset.fhDone = '1';
      q.style.maxHeight = '120px';
      q.style.overflow = 'hidden';
      const toggle = document.createElement('a');
      toggle.href = '#';
      toggle.textContent = '▼ הצג ציטוט מלא';
      toggle.style.display = 'block';
      toggle.onclick = (e) => {
        e.preventDefault();
        const open = q.style.maxHeight === 'none';
        q.style.maxHeight = open ? '120px' : 'none';
        toggle.textContent = open ? '▼ הצג ציטוט מלא' : '▲ כווץ ציטוט';
      };
      q.after(toggle);
    });
  }

  // Keyword highlighting
  function highlight(root) {
    const words = settings.keywords.split(',').map((w) => w.trim()).filter(Boolean);
    if (!words.length) return;
    const re = new RegExp('(' + words.map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|') + ')', 'gi');
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) =>
        n.parentElement.closest('script,style,textarea,input,mark') || !re.test(n.nodeValue)
          ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach((n) => {
      const span = document.createElement('span');
      span.innerHTML = n.nodeValue
        .replace(/&/g, '&amp;').replace(/</g, '&lt;')
        .replace(re, '<mark style="background:#fde047;color:#000">$1</mark>');
      n.replaceWith(span);
    });
  }

  function run(root) {
    collapseQuotes(root);
    highlight(root);
  }
  run(document.body);

  // Handle posts loaded dynamically
  new MutationObserver((muts) => {
    muts.forEach((m) => m.addedNodes.forEach((n) => n.nodeType === 1 && run(n)));
  }).observe(document.body, { childList: true, subtree: true });

  // Tampermonkey menu
  GM_registerMenuCommand('🌙 הפעל/כבה מצב כהה', () => {
    settings.dark = !settings.dark;
    GM_setValue('dark', settings.dark);
    applyDark();
  });
  GM_registerMenuCommand('🔍 מילות מפתח להדגשה', () => {
    const v = prompt('מילים להדגשה, מופרדות בפסיק:', settings.keywords);
    if (v === null) return;
    settings.keywords = v;
    GM_setValue('keywords', v);
    location.reload();
  });
})();

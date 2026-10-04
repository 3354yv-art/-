// ==UserScript==
// @name         הסתרת צ'אטים ריקים - מתמחים
// @namespace    mitmachim-hide-empty-chats
// @version      1.0
// @description  מסתיר מרשימת הצ'אטים בפורום מתמחים צ'אטים שאין בהם הודעות
// @match        https://mitmachim.top/*
// @grant        none
// @run-at       document-idle
// ==/UserScript==

(function () {
    'use strict';

    // רשימות צ'אט (עמוד /chats, והתפריט הנפתח בכותרת) - NodeBB
    const ITEM_SELECTOR = '[component="chat/recent"] [data-roomid], [component="chat/list"] [data-roomid], .chat-room-list [data-roomid], .chats-list [data-roomid]';
    // אלמנטים שמכילים את תקציר ההודעה האחרונה
    const TEASER_SELECTOR = '[component="chat/room/teaser"], [component="chat/teaser"], .teaser-content, .teaser, .chat-room-teaser';

    function isEmpty(item) {
        const teaser = item.querySelector(TEASER_SELECTOR);
        if (teaser) {
            return teaser.textContent.trim() === '';
        }
        // אין אלמנט תקציר בכלל - נחשב ריק רק אם אין אף טקסט מעבר לשם
        return false;
    }

    function run() {
        document.querySelectorAll(ITEM_SELECTOR).forEach(function (item) {
            const empty = isEmpty(item);
            item.style.display = empty ? 'none' : '';
            item.dataset.hiddenEmptyChat = empty ? '1' : '';
        });
    }

    let timer = null;
    new MutationObserver(function () {
        clearTimeout(timer);
        timer = setTimeout(run, 150);
    }).observe(document.body, { childList: true, subtree: true });

    run();
})();

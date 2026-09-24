// לוגיקת בדיקה מקומית: מילון שגיאות נפוצות, מילים כפולות ורווחים כפולים,
// ומיזוג התוצאות עם תוצאות שירות LanguageTool.
(function (global) {
  const HEB_PREFIX_LETTERS = 'ושהבכלמ';
  const WORD_RE = /[\p{L}\p{M}]+(?:[׳״'’"][\p{L}\p{M}]+)*/gu;
  const HEBREW_LETTER = /[א-ת]/;
  // מילות יחס שחזרה עליהן כמעט תמיד שגויה (לעומת "לאט לאט", "יום יום" שהן תקינות)
  const HEB_NO_REPEAT = new Set(['של', 'את', 'על', 'עם', 'אל', 'כי', 'אם', 'או', 'גם', 'רק', 'אבל', 'לא', 'זה', 'הוא', 'היא']);

  function buildDictionary(builtin, customText) {
    const dict = new Map();
    for (const [wrong, right] of Object.entries(builtin || {})) dict.set(wrong.toLowerCase(), right);
    for (const line of String(customText || '').split(/\r?\n/)) {
      const m = line.match(/^\s*(.+?)\s*(?:=|->|=>|→)\s*(.+?)\s*$/);
      if (m && m[1] !== m[2]) dict.set(m[1].toLowerCase(), m[2]);
    }
    return dict;
  }

  function matchCase(original, fix) {
    if (original.length > 1 && original === original.toUpperCase() && original !== original.toLowerCase()) {
      return fix.toUpperCase();
    }
    const first = original[0];
    if (first !== first.toLowerCase()) return fix[0].toUpperCase() + fix.slice(1);
    return fix;
  }

  function lookup(word, dict) {
    const lower = word.toLowerCase();
    if (dict.has(lower)) return matchCase(word, dict.get(lower));
    // בעברית אותיות השימוש (ו, ש, ה, ב, כ, ל, מ) נצמדות למילה: "ובעיקבות" -> "ו" + "בעקבות"
    if (HEBREW_LETTER.test(word[0])) {
      for (let i = 1; i <= 3 && i < word.length - 1; i++) {
        if (!HEB_PREFIX_LETTERS.includes(word[i - 1])) break;
        const rest = word.slice(i);
        if (dict.has(rest)) return word.slice(0, i) + dict.get(rest);
      }
    }
    return null;
  }

  // options.whitespace: לבדוק גם רווחים כפולים (רק בשדות עריכה, לא בתוכן הדף)
  function localCheck(text, dict, ignored, options = {}) {
    const matches = [];
    let prev = null;
    for (const m of text.matchAll(WORD_RE)) {
      const word = m[0];
      const offset = m.index;
      if (!ignored || !ignored.has(word.toLowerCase())) {
        const fix = lookup(word, dict);
        if (fix) {
          matches.push({
            offset, length: word.length, word,
            message: 'שגיאת כתיב נפוצה',
            replacements: [fix],
            type: 'misspelling',
            source: 'local'
          });
        }
      }
      // מילה כפולה: "של של"
      if (prev && prev.word === word && HEB_NO_REPEAT.has(word) &&
          /^[^\S\n]+$/.test(text.slice(prev.offset + prev.word.length, offset))) {
        matches.push({
          offset: prev.offset,
          length: offset + word.length - prev.offset,
          word: text.slice(prev.offset, offset + word.length),
          message: 'מילה כפולה',
          replacements: [word],
          type: 'duplication',
          source: 'local'
        });
      }
      prev = { word, offset };
    }
    if (options.whitespace) {
      for (const m of text.matchAll(/(?<=\S) {2,}(?=\S)/g)) {
        matches.push({
          offset: m.index, length: m[0].length, word: m[0],
          message: 'רווח כפול',
          replacements: [' '],
          type: 'whitespace',
          source: 'local'
        });
      }
    }
    return matches;
  }

  // האם כדאי לשלוח לבדיקה מקוונת: LanguageTool לא תומך בעברית,
  // לכן בטקסט שרובו עברית מסתפקים בבדיקה המקומית.
  function shouldCheckOnline(text, language) {
    if (language && language !== 'auto') return true;
    const letters = text.match(/\p{L}/gu);
    if (!letters || letters.length < 3) return false;
    const hebrew = letters.filter((c) => HEBREW_LETTER.test(c)).length;
    return (letters.length - hebrew) / letters.length >= 0.5;
  }

  // בוחר את השורות שמתאימות לבדיקה מקוונת (לא עבריות) ומחזיר טקסט מקוצר + טבלת מיפוי מיקומים
  function onlinePortion(text, language) {
    if (language && language !== 'auto') return { text, parts: [{ from: 0, to: 0, len: text.length }] };
    const parts = [];
    let out = '';
    let pos = 0;
    for (const line of text.split('\n')) {
      if (shouldCheckOnline(line, 'auto')) {
        parts.push({ from: out.length, to: pos, len: line.length });
        out += line + '\n';
      }
      pos += line.length + 1;
    }
    return { text: out, parts };
  }

  // ממפה שגיאות שהתקבלו על הטקסט המקוצר חזרה למיקומים בטקסט המקורי
  function mapOnlineMatches(matches, parts) {
    const result = [];
    for (const m of matches) {
      const part = parts.find((p) => m.offset >= p.from && m.offset + m.length <= p.from + p.len);
      if (part) result.push({ ...m, offset: m.offset - part.from + part.to });
    }
    return result;
  }

  // מיזוג: מיון לפי מיקום והסרת חפיפות (עדיפות לתוצאה עם הצעות תיקון)
  function mergeMatches(...lists) {
    const all = lists.flat().filter(Boolean).sort((a, b) => a.offset - b.offset || b.length - a.length);
    const out = [];
    for (const m of all) {
      const last = out[out.length - 1];
      if (last && m.offset < last.offset + last.length) {
        if (!last.replacements.length && m.replacements.length) out[out.length - 1] = m;
        continue;
      }
      out.push(m);
    }
    return out;
  }

  // החלת התיקון הראשון של כל שגיאה על מחרוזת (מהסוף להתחלה כדי שהמיקומים יישארו נכונים)
  function applyAll(text, matches) {
    const sorted = matches.filter((m) => m.replacements.length).sort((a, b) => b.offset - a.offset);
    for (const m of sorted) {
      text = text.slice(0, m.offset) + m.replacements[0] + text.slice(m.offset + m.length);
    }
    return text;
  }

  global.SpellFixerChecker = {
    buildDictionary, lookup, localCheck, shouldCheckOnline, onlinePortion, mapOnlineMatches, mergeMatches, applyAll, matchCase
  };
})(typeof self !== 'undefined' ? self : this);

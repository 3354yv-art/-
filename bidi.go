package main

import "unicode"

// Bidi reordering: a simplified subset of the Unicode Bidirectional Algorithm,
// enough to display Hebrew (and Arabic) correctly in a terminal that has no
// bidi support of its own.

type class int

const (
	cN  class = iota // neutral: spaces, punctuation, symbols
	cR               // right-to-left letter
	cL               // left-to-right letter
	cD               // digit
	cM               // combining mark (niqqud)
	cES              // number sign: + -
	cET              // number terminator: % $ ₪ ...
	cCS              // number separator: , . / :
)

var mirror = map[rune]rune{
	'(': ')', ')': '(', '[': ']', ']': '[', '{': '}', '}': '{',
	'<': '>', '>': '<', '«': '»', '»': '«', '‹': '›', '›': '‹',
}

// Characters that frame a line (indentation, box borders, bullets). They stay
// in place when a Hebrew line is reversed so boxes and lists keep their shape.
var frameChars = map[rune]bool{}

func init() {
	for _, r := range " \t|•●○◦▪▫■□-*+>⎿⏺✻✶✳·" {
		frameChars[r] = true
	}
}

func isFrame(r rune) bool {
	return frameChars[r] || unicode.IsSpace(r) || (r >= 0x2500 && r <= 0x259F)
}

func isRTL(r rune) bool {
	return (r >= 0x0590 && r <= 0x08FF) || (r >= 0xFB1D && r <= 0xFDFF) ||
		(r >= 0xFE70 && r <= 0xFEFF) || (r >= 0x10800 && r <= 0x10FFF) ||
		(r >= 0x1E800 && r <= 0x1EFFF)
}

func classify(r rune) class {
	switch {
	case unicode.In(r, unicode.Mn, unicode.Me):
		return cM
	case unicode.IsDigit(r):
		return cD
	case isRTL(r):
		return cR
	case unicode.IsLetter(r):
		return cL
	}
	switch r {
	case '+', '-':
		return cES
	case '#', '$', '%', '°', '¢', '£', '¤', '¥', '€', '‰', '₪', '±':
		return cET
	case ',', '.', '/', ':', 0xA0:
		return cCS
	}
	return cN
}

func hasRTL(rs []rune) bool {
	for _, r := range rs {
		if classify(r) == cR {
			return true
		}
	}
	return false
}

type unit struct {
	t   class
	idx []int
}

// makeUnits groups runes into units: a base char with its combining marks, or
// a whole number such as 3.14, 1,000 or 50% (numbers always stay LTR).
func makeUnits(rs []rune) []unit {
	var raw []unit
	for i, r := range rs {
		t := classify(r)
		if t == cM && len(raw) > 0 {
			raw[len(raw)-1].idx = append(raw[len(raw)-1].idx, i)
			continue
		}
		if t == cM {
			t = cN
		}
		raw = append(raw, unit{t, []int{i}})
	}

	var units []unit
	n := len(raw)
	for k := 0; k < n; {
		if raw[k].t != cD {
			units = append(units, raw[k])
			k++
			continue
		}
		idx := append([]int{}, raw[k].idx...)
		if len(units) > 0 && units[len(units)-1].t == cET { // leading $ / #
			idx = append(units[len(units)-1].idx, idx...)
			units = units[:len(units)-1]
		}
		k++
		for k < n {
			t := raw[k].t
			if t == cD || t == cET {
				idx = append(idx, raw[k].idx...)
				k++
			} else if (t == cCS || t == cES) && k+1 < n && raw[k+1].t == cD {
				idx = append(idx, raw[k].idx...)
				idx = append(idx, raw[k+1].idx...)
				k += 2
			} else {
				break
			}
		}
		units = append(units, unit{cD, idx})
	}
	for i := range units {
		if units[i].t == cES || units[i].t == cET || units[i].t == cCS {
			units[i].t = cN
		}
	}
	return units
}

// placed is one rune in display order: its logical index and displayed rune.
type placed struct {
	i int
	r rune
}

func plainUnit(rs []rune, u unit, out []placed) []placed {
	for _, i := range u.idx {
		out = append(out, placed{i, rs[i]})
	}
	return out
}

func rtlUnit(rs []rune, u unit, out []placed) []placed {
	for _, i := range u.idx {
		r := rs[i]
		if m, ok := mirror[r]; ok && u.t == cN {
			r = m
		}
		out = append(out, placed{i, r})
	}
	return out
}

func firstStrong(units []unit) class {
	for _, u := range units {
		if u.t == cR || u.t == cL {
			return u.t
		}
	}
	return cN
}

// visualLTR: left-to-right paragraph, reverse each right-to-left run in place.
func visualLTR(rs []rune, units []unit) []placed {
	out := make([]placed, 0, len(rs))
	n := len(units)
	for pos := 0; pos < n; {
		if units[pos].t != cR {
			out = plainUnit(rs, units[pos], out)
			pos++
			continue
		}
		last := pos
		for k := pos + 1; k < n && units[k].t != cL; k++ {
			if units[k].t == cR || units[k].t == cD {
				last = k
			}
		}
		for k := last; k >= pos; k-- {
			out = rtlUnit(rs, units[k], out)
		}
		pos = last + 1
	}
	return out
}

func allFrame(rs []rune, u unit) bool {
	for _, i := range u.idx {
		if !isFrame(rs[i]) {
			return false
		}
	}
	return true
}

// visualRTL: right-to-left paragraph, reverse the line while keeping LTR
// islands (English, numbers) and the line frame in place.
func visualRTL(rs []rune, units []unit) []placed {
	n := len(units)
	start := 0
	for start < n && units[start].t == cN && allFrame(rs, units[start]) {
		start++
	}
	// Numbered list marker such as "1. " or "2) " stays at the start too.
	if start+2 < n && units[start].t == cD && units[start+1].t == cN &&
		(rs[units[start+1].idx[0]] == '.' || rs[units[start+1].idx[0]] == ')') &&
		unicode.IsSpace(rs[units[start+2].idx[0]]) {
		start += 3
	}
	end := n
	for end > start && units[end-1].t == cN && allFrame(rs, units[end-1]) {
		end--
	}

	type block struct {
		ltr   bool
		units []unit
	}
	var blocks []block
	for k := start; k < end; {
		if units[k].t == cL || units[k].t == cD {
			last := k
			for j := k + 1; j < end && units[j].t != cR; j++ {
				if units[j].t == cL || units[j].t == cD {
					last = j
				}
			}
			blocks = append(blocks, block{true, units[k : last+1]})
			k = last + 1
		} else {
			blocks = append(blocks, block{false, units[k : k+1]})
			k++
		}
	}

	out := make([]placed, 0, len(rs))
	for _, u := range units[:start] {
		out = plainUnit(rs, u, out)
	}
	for b := len(blocks) - 1; b >= 0; b-- {
		for _, u := range blocks[b].units {
			if blocks[b].ltr {
				out = plainUnit(rs, u, out)
			} else {
				out = rtlUnit(rs, u, out)
			}
		}
	}
	for _, u := range units[end:] {
		out = plainUnit(rs, u, out)
	}
	return out
}

// visualOrder returns the runes of a line in display order.
// base is "auto" (direction of the first strong letter), "ltr" or "rtl".
func visualOrder(rs []rune, base string) []placed {
	units := makeUnits(rs)
	if base == "rtl" || (base == "auto" && firstStrong(units) == cR) {
		return visualRTL(rs, units)
	}
	return visualLTR(rs, units)
}

// ReorderLine reorders one line of plain text (no escape sequences).
func ReorderLine(s, base string) string {
	rs := []rune(s)
	if !hasRTL(rs) {
		return s
	}
	out := make([]rune, 0, len(rs))
	for _, p := range visualOrder(rs, base) {
		out = append(out, p.r)
	}
	return string(out)
}

// runeWidth approximates how many terminal cells a rune takes.
func runeWidth(r rune) int {
	if unicode.In(r, unicode.Mn, unicode.Me, unicode.Cf) {
		return 0
	}
	if (r >= 0x1100 && r <= 0x115F) || (r >= 0x2E80 && r <= 0xA4CF) ||
		(r >= 0xAC00 && r <= 0xD7A3) || (r >= 0xF900 && r <= 0xFAFF) ||
		(r >= 0xFE30 && r <= 0xFE4F) || (r >= 0xFF00 && r <= 0xFF60) ||
		(r >= 0xFFE0 && r <= 0xFFE6) || (r >= 0x1F300 && r <= 0x1FAFF) ||
		(r >= 0x20000 && r <= 0x3FFFD) {
		return 2
	}
	return 1
}

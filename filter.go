package main

import (
	"strings"
	"unicode/utf8"
)

const maxEsc = 1 << 16

type pchar struct {
	r     rune
	style string
}

// Filter is a streaming filter over raw terminal output.
//
// Plain text between control characters / escape sequences is collected into
// a segment; color (SGR) sequences stay inside the segment attached to the
// characters they style. When a segment contains RTL text it is reordered for
// display. The number of cells never changes, so cursor positioning done by
// full-screen programs (AI CLIs, editors) stays correct.
type Filter struct {
	Enabled bool
	Base    string
	Columns int

	partial []byte // incomplete UTF-8 sequence from the previous chunk
	state   int
	esc     strings.Builder
	sgr     []string
	pend    []pchar
	pendRaw strings.Builder
	pendRTL bool
	segCol0 bool // current segment starts at column 0
	col0    bool
	prev    rune // previous rune inside an escape sequence
	out     []byte
}

const (
	stText = iota
	stEsc
	stEscI
	stCSI
	stStr
)

func NewFilter(base string, columns int) *Filter {
	return &Filter{Enabled: true, Base: base, Columns: columns, col0: true}
}

// HasPendingRTL reports whether Hebrew text is buffered waiting for more data.
func (f *Filter) HasPendingRTL() bool { return f.pendRTL }

func (f *Filter) Feed(data []byte) []byte {
	if !f.Enabled {
		return data
	}
	f.out = f.out[:0]
	if len(f.partial) > 0 {
		data = append(f.partial, data...)
		f.partial = nil
	}
	for len(data) > 0 {
		r, size := utf8.DecodeRune(data)
		if r == utf8.RuneError && size <= 1 {
			if !utf8.FullRune(data) {
				f.partial = append([]byte{}, data...)
				break
			}
			// Invalid byte: pass it through untouched.
			f.flush()
			f.out = append(f.out, data[0])
			data = data[1:]
			continue
		}
		f.step(r)
		data = data[size:]
	}
	if len(f.pend) > 0 && !f.pendRTL {
		f.flush()
	}
	return f.take()
}

// Flush emits whatever is buffered (called after a short idle timeout).
func (f *Filter) Flush() []byte {
	f.out = f.out[:0]
	f.flush()
	return f.take()
}

func (f *Filter) Finish() []byte {
	f.out = f.out[:0]
	f.flush()
	f.out = append(f.out, f.esc.String()...)
	f.esc.Reset()
	f.out = append(f.out, f.partial...)
	f.partial = nil
	f.state = stText
	return f.take()
}

func (f *Filter) SetEnabled(on bool) []byte {
	var pending []byte
	if !on && f.Enabled {
		pending = f.Finish()
	}
	f.Enabled = on
	return pending
}

func (f *Filter) take() []byte {
	b := append([]byte{}, f.out...)
	f.out = f.out[:0]
	return b
}

func (f *Filter) step(r rune) {
	if f.state == stText {
		switch {
		case r == 0x1b:
			f.state = stEsc
			f.esc.WriteRune(r)
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0):
			f.flush()
			f.out = utf8.AppendRune(f.out, r)
			if r == '\r' || r == '\n' {
				f.col0 = true
			}
		default:
			if len(f.pend) == 0 {
				f.segCol0 = f.col0
			}
			f.pend = append(f.pend, pchar{r, strings.Join(f.sgr, "")})
			f.pendRaw.WriteRune(r)
			if !f.pendRTL && classify(r) == cR {
				f.pendRTL = true
			}
			f.col0 = false
		}
		return
	}

	f.esc.WriteRune(r)
	prev := f.prev
	f.prev = r
	switch f.state {
	case stEsc:
		switch {
		case r == '[':
			f.state = stCSI
		case strings.ContainsRune("]PX^_", r):
			f.state = stStr
		case r >= 0x20 && r <= 0x2f:
			f.state = stEscI
		default:
			f.endEscape()
		}
	case stEscI:
		if r >= 0x30 && r <= 0x7e {
			f.endEscape()
		}
	case stCSI:
		if r >= 0x40 && r <= 0x7e {
			f.endEscape()
		}
	case stStr:
		if r == 0x07 || (r == '\\' && prev == 0x1b) {
			f.endEscape()
		}
	}
	if f.esc.Len() > maxEsc {
		f.endEscape()
	}
}

func isSGR(esc string) bool {
	if !strings.HasPrefix(esc, "\x1b[") || !strings.HasSuffix(esc, "m") {
		return false
	}
	for _, c := range esc[2 : len(esc)-1] {
		if !(c >= '0' && c <= '9') && c != ';' && c != ':' {
			return false
		}
	}
	return true
}

func (f *Filter) endEscape() {
	esc := f.esc.String()
	f.esc.Reset()
	f.state = stText
	if isSGR(esc) {
		f.applySGR(esc)
		if len(f.pend) > 0 {
			f.pendRaw.WriteString(esc)
		} else {
			f.out = append(f.out, esc...)
		}
		return
	}
	f.flush()
	f.out = append(f.out, esc...)
	// Cursor may have moved: we no longer know that we're at column 0.
	f.col0 = false
}

func (f *Filter) applySGR(esc string) {
	params := esc[2 : len(esc)-1]
	parts := strings.Split(params, ";")
	if parts[0] == "" || parts[0] == "0" {
		f.sgr = f.sgr[:0]
		if rest := strings.Join(parts[1:], ";"); rest != "" {
			f.sgr = append(f.sgr, "\x1b["+rest+"m")
		}
		return
	}
	f.sgr = append(f.sgr, esc)
	if len(f.sgr) > 32 {
		f.sgr = append([]string{}, f.sgr[len(f.sgr)-32:]...)
	}
}

func (f *Filter) flush() {
	if len(f.pend) == 0 {
		return
	}
	if f.pendRTL {
		f.emitReordered()
	} else {
		f.out = append(f.out, f.pendRaw.String()...)
	}
	f.pend = f.pend[:0]
	f.pendRaw.Reset()
	f.pendRTL = false
}

// rows splits a segment into terminal rows so wrapped lines reorder per row.
func (f *Filter) rows(rs []rune) [][2]int {
	if !f.segCol0 || f.Columns <= 0 {
		return [][2]int{{0, len(rs)}}
	}
	var rows [][2]int
	start, width := 0, 0
	for i, r := range rs {
		w := runeWidth(r)
		if width+w > f.Columns {
			rows = append(rows, [2]int{start, i})
			start, width = i, 0
		}
		width += w
	}
	return append(rows, [2]int{start, len(rs)})
}

func (f *Filter) emitReordered() {
	rs := make([]rune, len(f.pend))
	for i, p := range f.pend {
		rs[i] = p.r
	}
	current := f.pend[0].style
	for _, row := range f.rows(rs) {
		a, b := row[0], row[1]
		for _, p := range visualOrder(rs[a:b], f.Base) {
			if style := f.pend[a+p.i].style; style != current {
				f.out = append(f.out, "\x1b[0m"+style...)
				current = style
			}
			f.out = utf8.AppendRune(f.out, p.r)
		}
	}
	if final := strings.Join(f.sgr, ""); current != final {
		f.out = append(f.out, "\x1b[0m"+final...)
	}
}

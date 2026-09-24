package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/creack/pty"
)

func TestReorderLine(t *testing.T) {
	cases := []struct{ base, in, want string }{
		{"auto", "שלום עולם", "םלוע םולש"},
		{"auto", "hello world (1, 2)", "hello world (1, 2)"},
		{"auto", "hello שלום עולם world", "hello םלוע םולש world"},
		{"auto", "שלום 123 עולם", "םלוע 123 םולש"},
		{"auto", "גרסה 3.14 של Python", "Python לש 3.14 הסרג"},
		{"auto", "מחיר: 50% הנחה", "החנה 50% :ריחמ"},
		{"auto", "שלום, מה שלומך?", "?ךמולש המ ,םולש"},
		{"auto", "(שלום) עולם", "םלוע (םולש)"},
		{"auto", "● שלום עולם", "● םלוע םולש"},
		{"auto", "  1. שלום עולם", "  1. םלוע םולש"},
		{"auto", "│ שלום עולם   │", "│ םלוע םולש   │"},
		{"auto", "שָׁלוֹם", "םוֹלשָׁ"},
		{"ltr", "שלום, מה שלומך?", "ךמולש המ ,םולש?"},
	}
	for _, c := range cases {
		if got := ReorderLine(c.in, c.base); got != c.want {
			t.Errorf("ReorderLine(%q, %s) = %q, want %q", c.in, c.base, got, c.want)
		}
	}
}

func runFilter(f *Filter, chunks ...string) string {
	var out []byte
	for _, c := range chunks {
		out = append(out, f.Feed([]byte(c))...)
	}
	return string(append(out, f.Finish()...))
}

func TestFilter(t *testing.T) {
	cases := []struct {
		name, in, want string
		cols           int
	}{
		{"escapes preserved", "\x1b[2J\x1b[1;1Hשלום עולם\r\n", "\x1b[2J\x1b[1;1Hםלוע םולש\r\n", 0},
		{"non-hebrew identical", "\x1b[31mred\x1b[0m text \x1b]0;title\x07 ok\r\n", "\x1b[31mred\x1b[0m text \x1b]0;title\x07 ok\r\n", 0},
		// "עולם" is unstyled, "שלום" stays bold after reordering.
		{"colors follow words", "\x1b[1mשלום\x1b[0m עולם\n", "\x1b[1m\x1b[0mםלוע \x1b[0m\x1b[1mםולש\x1b[0m\n", 0},
		// At width 4 the terminal shows "אבג " on row 1 and "דהו" on row 2;
		// each row must be reversed on its own.
		{"wrapped rows", "\nאבג דהו\n", "\nגבא והד\n", 4},
	}
	for _, c := range cases {
		if got := runFilter(NewFilter("auto", c.cols), c.in); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestFilterByteByByte(t *testing.T) {
	f := NewFilter("auto", 0)
	data := []byte("שלום עולם\n")
	var out []byte
	for i := range data {
		out = append(out, f.Feed(data[i:i+1])...)
	}
	out = append(out, f.Finish()...)
	if string(out) != "םלוע םולש\n" {
		t.Errorf("got %q", out)
	}
}

func TestFilterDisabled(t *testing.T) {
	f := NewFilter("auto", 0)
	f.Enabled = false
	if got := runFilter(f, "שלום\n"); got != "שלום\n" {
		t.Errorf("got %q", got)
	}
}

func TestPTY(t *testing.T) {
	bin := t.TempDir() + "/hebfix"
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	cmd := exec.Command(bin, "printf", `\033[32mשלום עולם\033[0m\n`)
	ptmx, err := pty.Start(cmd)
	if err != nil {
		t.Fatal(err)
	}
	var sb strings.Builder
	buf := make([]byte, 4096)
	for {
		n, err := ptmx.Read(buf)
		sb.Write(buf[:n])
		if err != nil {
			break
		}
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("exit: %v", err)
	}
	if !strings.Contains(sb.String(), "\x1b[32mםלוע םולש\x1b[0m") {
		t.Errorf("output %q", sb.String())
	}
	_ = os.Remove(bin)
}

import os
import pty
import select
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import hebfix  # noqa: E402

HEBFIX = os.path.join(os.path.dirname(__file__), "..", "hebfix.py")


class ReorderTest(unittest.TestCase):
    def check(self, logical, visual, base="auto"):
        self.assertEqual(hebfix.reorder_line(logical, base), visual)

    def test_plain_hebrew(self):
        self.check("שלום עולם", "םלוע םולש")

    def test_ascii_untouched(self):
        self.check("hello world (1, 2)", "hello world (1, 2)")

    def test_hebrew_inside_english(self):
        self.check("hello שלום עולם world", "hello םלוע םולש world")

    def test_numbers_keep_order(self):
        self.check("שלום 123 עולם", "םלוע 123 םולש")
        self.check("גרסה 3.14 של Python", "Python לש 3.14 הסרג")
        self.check("מחיר: 50% הנחה", "החנה 50% :ריחמ")

    def test_sentence_punctuation(self):
        self.check("שלום, מה שלומך?", "?ךמולש המ ,םולש")

    def test_brackets_mirrored(self):
        self.check("(שלום) עולם", "םלוע (םולש)")

    def test_frame_kept(self):
        self.check("● שלום עולם", "● םלוע םולש")
        self.check("  1. שלום עולם", "  1. םלוע םולש")
        self.check("│ שלום עולם   │", "│ םלוע םולש   │")

    def test_niqqud_stays_on_letter(self):
        self.check("שָׁלוֹם", "םוֹלשָׁ")

    def test_ltr_base(self):
        self.check("שלום, מה שלומך?", "ךמולש המ ,םולש?", base="ltr")


class FilterTest(unittest.TestCase):
    def run_filter(self, chunks, **kw):
        f = hebfix.Filter(**kw)
        out = b"".join(f.feed(c.encode()) for c in chunks)
        return (out + f.finish()).decode()

    def test_escape_sequences_preserved(self):
        out = self.run_filter(["\x1b[2J\x1b[1;1Hשלום עולם\r\n"])
        self.assertEqual(out, "\x1b[2J\x1b[1;1Hםלוע םולש\r\n")

    def test_non_hebrew_is_byte_identical(self):
        s = "\x1b[31mred\x1b[0m text \x1b]0;title\x07 ok\r\n"
        self.assertEqual(self.run_filter([s]), s)

    def test_colors_follow_words(self):
        out = self.run_filter(["\x1b[1mשלום\x1b[0m עולם\n"])
        # "עולם" is unstyled, "שלום" stays bold after reordering.
        self.assertEqual(out, "\x1b[1m\x1b[0mםלוע \x1b[0m\x1b[1mםולש\x1b[0m\n")

    def test_split_utf8_and_chunks(self):
        data = "שלום עולם\n".encode()
        f = hebfix.Filter()
        out = b"".join(f.feed(data[i:i + 1]) for i in range(len(data)))
        self.assertEqual((out + f.finish()).decode(), "םלוע םולש\n")

    def test_wrapped_line_reordered_per_row(self):
        # At width 4 the terminal shows "אבג " on row 1 and "דהו" on row 2;
        # each row must be reversed on its own.
        out = self.run_filter(["\nאבג דהו\n"], columns=4)
        self.assertEqual(out, "\nגבא והד\n")

    def test_disabled(self):
        self.assertEqual(self.run_filter(["שלום\n"], enabled=False), "שלום\n")


class PtyTest(unittest.TestCase):
    def test_wraps_command(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.execvp(sys.executable, [sys.executable, HEBFIX, "printf",
                                       "\\033[32mשלום עולם\\033[0m\\n"])
        out = b""
        while True:
            r, _, _ = select.select([fd], [], [], 5)
            if not r:
                break
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            out += data
        _, status = os.waitpid(pid, 0)
        self.assertEqual(os.WEXITSTATUS(status), 0)
        self.assertIn("\x1b[32mםלוע םולש\x1b[0m", out.decode())


if __name__ == "__main__":
    unittest.main()

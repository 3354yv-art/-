#!/usr/bin/env python3
"""hebfix - fixes reversed Hebrew (RTL) text in terminals without bidi support.

Runs your shell (or any command, e.g. an AI CLI) inside a pseudo-terminal and
reorders right-to-left text in its output so Hebrew reads correctly, while
leaving escape sequences, colors and cursor movement intact.

Usage:
    hebfix                   wrap $SHELL
    hebfix CMD [ARGS...]     wrap a single command (e.g. `hebfix claude`)
    hebfix --pipe            filter stdin to stdout (`cmd | hebfix --pipe`)
    hebfix toggle|on|off     control the hebfix session you are running inside
    hebfix status            show whether the current terminal is wrapped
"""

import codecs
import os
import select
import signal
import sys
import unicodedata

VERSION = "1.0.0"

# Exit code meaning "could not start" - the shell rc hook falls back to a
# plain shell when it sees it, so a broken install never locks you out.
EXIT_STARTUP_FAILED = 213

MIRROR = {
    "(": ")", ")": "(", "[": "]", "]": "[", "{": "}", "}": "{",
    "<": ">", ">": "<", "«": "»", "»": "«", "‹": "›", "›": "‹",
}

# Characters that frame a line (indentation, box borders, bullets). They stay
# in place when a Hebrew line is reversed so boxes and lists keep their shape.
FRAME_CHARS = set(" \t|•●○◦▪▫■□-*+>⎿⏺✻✶✳·─│┃╭╮╰╯┌┐└┘├┤")


def _is_frame(ch):
    return ch in FRAME_CHARS or ch.isspace() or 0x2500 <= ord(ch) <= 0x259F


# ---------------------------------------------------------------------------
# Bidi reordering (a simplified subset of the Unicode Bidirectional Algorithm)
# ---------------------------------------------------------------------------

def _classify(ch):
    b = unicodedata.bidirectional(ch)
    if b in ("R", "AL"):
        return "R"
    if b == "L":
        return "L"
    if b in ("EN", "AN"):
        return "D"
    if b == "NSM":
        return "M"
    if b in ("ES", "ET", "CS"):
        return b
    return "N"


def _units(chars):
    """Group chars into units: [type, [indices]].

    A unit is a base char with its combining marks (niqqud), or a whole number
    such as 3.14, 1,000 or 50% - numbers always stay left-to-right.
    """
    raw = []
    for i, ch in enumerate(chars):
        t = _classify(ch)
        if t == "M" and raw:
            raw[-1][1].append(i)
        else:
            raw.append(["N" if t == "M" else t, [i]])

    units = []
    k = 0
    n = len(raw)
    while k < n:
        t, idx = raw[k]
        if t == "D":
            idx = list(idx)
            if units and units[-1][0] == "ET":  # leading $ / # etc.
                idx = units.pop()[1] + idx
            k += 1
            while k < n:
                t2 = raw[k][0]
                if t2 == "D":
                    idx += raw[k][1]
                    k += 1
                elif t2 in ("CS", "ES") and k + 1 < n and raw[k + 1][0] == "D":
                    idx += raw[k][1] + raw[k + 1][1]
                    k += 2
                elif t2 == "ET":
                    idx += raw[k][1]
                    k += 1
                else:
                    break
            units.append(["D", idx])
        else:
            units.append([t, list(idx)])
            k += 1
    for u in units:
        if u[0] in ("ES", "ET", "CS"):
            u[0] = "N"
    return units


def _mirror_unit(chars, unit):
    """Return [(index, char)] for a unit displayed right-to-left."""
    t, idx = unit
    if t == "N":
        return [(i, MIRROR.get(chars[i], chars[i])) for i in idx]
    return [(i, chars[i]) for i in idx]


def _plain_unit(chars, unit):
    return [(i, chars[i]) for i in unit[1]]


def _first_strong(units):
    for t, _ in units:
        if t in ("R", "L"):
            return t
    return None


def _visual_ltr(chars, units):
    """LTR paragraph: reverse each right-to-left run in place."""
    out = []
    n = len(units)
    pos = 0
    while pos < n:
        if units[pos][0] != "R":
            out += _plain_unit(chars, units[pos])
            pos += 1
            continue
        last = pos
        k = pos + 1
        while k < n and units[k][0] != "L":
            if units[k][0] in ("R", "D"):
                last = k
            k += 1
        for u in reversed(units[pos:last + 1]):
            out += _mirror_unit(chars, u)
        pos = last + 1
    return out


def _visual_rtl(chars, units):
    """RTL paragraph: reverse the line, keeping LTR islands and the frame."""
    n = len(units)
    start = 0
    while start < n and units[start][0] == "N" and all(
            _is_frame(chars[i]) for i in units[start][1]):
        start += 1
    # Numbered list marker such as "1. " or "2) " stays at the start too.
    if (start < n and units[start][0] == "D" and start + 2 < n
            and units[start + 1][0] == "N"
            and chars[units[start + 1][1][0]] in ".)"
            and chars[units[start + 2][1][0]].isspace()):
        start += 3
    end = n
    while end > start and units[end - 1][0] == "N" and all(
            _is_frame(chars[i]) for i in units[end - 1][1]):
        end -= 1

    blocks = []  # (is_ltr_island, [units])
    k = start
    while k < end:
        if units[k][0] in ("L", "D"):
            last = k
            j = k + 1
            while j < end and units[j][0] != "R":
                if units[j][0] in ("L", "D"):
                    last = j
                j += 1
            blocks.append((True, units[k:last + 1]))
            k = last + 1
        else:
            blocks.append((False, [units[k]]))
            k += 1

    out = []
    for u in units[:start]:
        out += _plain_unit(chars, u)
    for is_ltr, us in reversed(blocks):
        for u in us:
            out += _plain_unit(chars, u) if is_ltr else _mirror_unit(chars, u)
    for u in units[end:]:
        out += _plain_unit(chars, u)
    return out


def visual_order(chars, base="auto"):
    """Return [(logical_index, display_char)] in display order."""
    units = _units(chars)
    if base == "rtl" or (base == "auto" and _first_strong(units) == "R"):
        return _visual_rtl(chars, units)
    return _visual_ltr(chars, units)


def has_rtl(text):
    return any(_classify(ch) == "R" for ch in text)


def reorder_line(text, base="auto"):
    """Reorder a single line of plain text (no escape sequences)."""
    if not has_rtl(text):
        return text
    return "".join(ch for _, ch in visual_order(list(text), base))


def char_width(ch):
    if unicodedata.combining(ch) or unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


# ---------------------------------------------------------------------------
# Streaming terminal filter
# ---------------------------------------------------------------------------

class Filter:
    """Streaming filter over raw terminal output bytes.

    Plain text between control characters / escape sequences is collected into
    a segment; color (SGR) sequences stay inside the segment attached to the
    characters they style. When a segment contains RTL text it is reordered
    for display. The number of cells never changes, so cursor positioning done
    by full-screen programs (AI CLIs, editors) stays correct.
    """

    MAX_ESC = 1 << 16

    def __init__(self, enabled=True, base="auto", columns=0):
        self.enabled = enabled
        self.base = base
        self.columns = columns
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self._state = "text"
        self._esc = ""
        self._sgr = []
        self._pend = []       # [(char, sgr_tuple)]
        self._pend_raw = []   # original text of the segment
        self._pend_rtl = False
        self._seg_col0 = True  # segment starts at column 0
        self._col0 = True
        self._out = []

    @property
    def has_pending_rtl(self):
        return self._pend_rtl

    def feed(self, data):
        if not self.enabled:
            return data
        text = self._decoder.decode(data)
        self._out = []
        for ch in text:
            self._step(ch)
        if self._pend and not self._pend_rtl:
            self._flush()
        return self._take()

    def flush(self):
        """Emit whatever is buffered (called after a short idle timeout)."""
        self._out = []
        self._flush()
        return self._take()

    def finish(self):
        self._out = []
        tail = self._decoder.decode(b"", final=True)
        for ch in tail:
            self._step(ch)
        self._flush()
        if self._esc:
            self._out.append(self._esc)
            self._esc = ""
            self._state = "text"
        return self._take()

    def set_enabled(self, enabled):
        if not enabled and self.enabled:
            pending = self.finish()
            self.enabled = False
            return pending
        self.enabled = enabled
        return b""

    def _take(self):
        s = "".join(self._out)
        self._out = []
        return s.encode("utf-8", "surrogateescape")

    # -- parser -------------------------------------------------------------

    def _step(self, ch):
        st = self._state
        if st == "text":
            o = ord(ch)
            if ch == "\x1b":
                self._state = "esc"
                self._esc = ch
            elif o < 0x20 or o == 0x7F or 0x80 <= o < 0xA0:
                self._flush()
                self._out.append(ch)
                if ch in "\r\n":
                    self._col0 = True
            else:
                if not self._pend:
                    self._seg_col0 = self._col0
                self._pend.append((ch, tuple(self._sgr)))
                self._pend_raw.append(ch)
                if not self._pend_rtl and _classify(ch) == "R":
                    self._pend_rtl = True
                self._col0 = False
            return

        self._esc += ch
        o = ord(ch)
        if st == "esc":
            if ch == "[":
                self._state = "csi"
            elif ch in "]PX^_":
                self._state = "str"
            elif 0x20 <= o <= 0x2F:
                self._state = "esci"
            else:
                self._end_escape()
        elif st == "esci":
            if 0x30 <= o <= 0x7E:
                self._end_escape()
        elif st == "csi":
            if 0x40 <= o <= 0x7E:
                self._end_escape()
        elif st == "str":
            if ch == "\x07" or self._esc.endswith("\x1b\\"):
                self._end_escape()
        if len(self._esc) > self.MAX_ESC:
            self._end_escape()

    def _end_escape(self):
        esc = self._esc
        self._esc = ""
        self._state = "text"
        params = esc[2:-1]
        if esc.startswith("\x1b[") and esc.endswith("m") and all(
                c in "0123456789;:" for c in params):
            self._apply_sgr(esc, params)
            if self._pend:
                self._pend_raw.append(esc)
            else:
                self._out.append(esc)
            return
        self._flush()
        self._out.append(esc)
        # Cursor movement: we no longer know that we're at column 0.
        self._col0 = False

    def _apply_sgr(self, esc, params):
        parts = params.split(";") if params else [""]
        if parts[0] in ("", "0"):
            self._sgr = []
            rest = ";".join(parts[1:])
            if rest:
                self._sgr.append("\x1b[" + rest + "m")
        else:
            self._sgr.append(esc)
            if len(self._sgr) > 32:
                self._sgr = self._sgr[-32:]

    # -- output -------------------------------------------------------------

    def _flush(self):
        if not self._pend:
            return
        if not self._pend_rtl:
            self._out.append("".join(self._pend_raw))
        else:
            self._emit_reordered()
        self._pend = []
        self._pend_raw = []
        self._pend_rtl = False

    def _rows(self, chars):
        """Split a segment into terminal rows so wrapped lines reorder per row."""
        if not (self._seg_col0 and self.columns > 0):
            return [(0, len(chars))]
        rows = []
        start = 0
        width = 0
        for i, ch in enumerate(chars):
            w = char_width(ch)
            if width + w > self.columns:
                rows.append((start, i))
                start = i
                width = 0
            width += w
        rows.append((start, len(chars)))
        return rows

    def _emit_reordered(self):
        chars = [c for c, _ in self._pend]
        styles = [s for _, s in self._pend]
        current = styles[0]
        out = self._out
        for a, b in self._rows(chars):
            for i, ch in visual_order(chars[a:b], self.base):
                style = styles[a + i]
                if style != current:
                    out.append("\x1b[0m" + "".join(style))
                    current = style
                out.append(ch)
        final = tuple(self._sgr)
        if current != final:
            out.append("\x1b[0m" + "".join(final))


# ---------------------------------------------------------------------------
# PTY wrapper
# ---------------------------------------------------------------------------

def _get_winsize(fd):
    import fcntl
    import struct
    import termios
    try:
        return fcntl.ioctl(fd, termios.TIOCGWINSZ, struct.pack("HHHH", 0, 0, 0, 0))
    except OSError:
        return None


def _columns(winsize):
    import struct
    if not winsize:
        return 0
    return struct.unpack("HHHH", winsize)[1]


def _write_all(fd, data):
    while data:
        try:
            n = os.write(fd, data)
        except InterruptedError:
            continue
        data = data[n:]


def run_pty(argv, base):
    import fcntl
    import pty
    import termios
    import tty

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()

    parent_pid = os.getpid()
    os.environ["HEBFIX_ACTIVE"] = "1"
    os.environ["HEBFIX_PID"] = str(parent_pid)

    winsize = _get_winsize(stdout_fd) or _get_winsize(stdin_fd)
    try:
        pid, master = pty.fork()
    except OSError as e:
        sys.stderr.write("hebfix: לא ניתן לפתוח מסוף וירטואלי: %s\n" % e)
        return EXIT_STARTUP_FAILED

    if pid == 0:
        try:
            os.execvp(argv[0], argv)
        except OSError as e:
            sys.stderr.write("hebfix: %s: %s\n" % (argv[0], e.strerror))
        os._exit(127)

    if winsize:
        fcntl.ioctl(master, termios.TIOCSWINSZ, winsize)

    filt = Filter(base=base, columns=_columns(winsize))
    if os.environ.get("HEBFIX_DISABLE"):
        filt.enabled = False
    toggles = []

    def on_winch(signum, frame):
        ws = _get_winsize(stdout_fd)
        if ws:
            filt.columns = _columns(ws)
            try:
                fcntl.ioctl(master, termios.TIOCSWINSZ, ws)
            except OSError:
                pass

    def on_usr(signum, frame):
        toggles.append(signum)

    signal.signal(signal.SIGWINCH, on_winch)
    signal.signal(signal.SIGUSR1, on_usr)   # toggle
    signal.signal(signal.SIGUSR2, on_usr)   # force on/off via file flag

    old_attrs = None
    try:
        old_attrs = termios.tcgetattr(stdin_fd)
        tty.setraw(stdin_fd)
    except termios.error:
        pass

    fds = [master, stdin_fd]
    try:
        while True:
            while toggles:
                sig = toggles.pop()
                if sig == signal.SIGUSR1:
                    want = not filt.enabled
                else:
                    want = _read_wanted_state(parent_pid, filt.enabled)
                _write_all(stdout_fd, filt.set_enabled(want))
            timeout = 0.03 if filt.has_pending_rtl else None
            try:
                ready, _, _ = select.select(fds, [], [], timeout)
            except InterruptedError:
                continue
            if not ready:
                _write_all(stdout_fd, filt.flush())
                continue
            if master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    data = b""
                if not data:
                    break
                _write_all(stdout_fd, filt.feed(data))
            if stdin_fd in ready:
                try:
                    data = os.read(stdin_fd, 65536)
                except OSError:
                    data = b""
                if not data:
                    fds.remove(stdin_fd)
                else:
                    _write_all(master, data)
    finally:
        try:
            _write_all(stdout_fd, filt.finish())
        except OSError:
            pass
        if old_attrs is not None:
            termios.tcsetattr(stdin_fd, termios.TCSAFLUSH, old_attrs)
        os.close(master)

    _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    return 128 + os.WTERMSIG(status)


def _state_file(pid):
    runtime = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(runtime, "hebfix-%d-%d.state" % (os.getuid(), pid))


def _read_wanted_state(pid, default):
    path = _state_file(pid)
    try:
        with open(path) as f:
            value = f.read().strip()
        os.unlink(path)
    except OSError:
        return default
    return value == "on"


def control(cmd):
    pid = os.environ.get("HEBFIX_PID")
    if cmd == "status":
        if pid:
            print("hebfix פעיל במסוף הזה (pid %s)" % pid)
            return 0
        print("hebfix לא פעיל במסוף הזה")
        return 1
    if not pid:
        sys.stderr.write("hebfix: המסוף הזה לא רץ דרך hebfix\n")
        return 1
    pid = int(pid)
    try:
        if cmd == "toggle":
            os.kill(pid, signal.SIGUSR1)
        else:
            with open(_state_file(pid), "w") as f:
                f.write(cmd)
            os.kill(pid, signal.SIGUSR2)
    except OSError as e:
        sys.stderr.write("hebfix: %s\n" % e)
        return 1
    return 0


def run_pipe(base):
    filt = Filter(base=base)
    out = sys.stdout.buffer
    inp = sys.stdin.buffer
    while True:
        data = inp.read1(65536) if hasattr(inp, "read1") else inp.read(65536)
        if not data:
            break
        out.write(filt.feed(data))
        out.flush()
    out.write(filt.finish())
    out.flush()
    return 0


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    base = os.environ.get("HEBFIX_BASE", "auto")
    pipe = False
    while args and args[0].startswith("-"):
        a = args.pop(0)
        if a == "--":
            break
        if a in ("-h", "--help"):
            print(__doc__.strip())
            print("\nOptions:\n  --base auto|ltr|rtl   paragraph direction (default: auto)")
            return 0
        if a in ("-V", "--version"):
            print("hebfix " + VERSION)
            return 0
        if a == "--pipe":
            pipe = True
        elif a == "--base" and args:
            base = args.pop(0)
        elif a.startswith("--base="):
            base = a.split("=", 1)[1]
        else:
            sys.stderr.write("hebfix: אפשרות לא מוכרת: %s\n" % a)
            return 2
    if base not in ("auto", "ltr", "rtl"):
        sys.stderr.write("hebfix: --base חייב להיות auto, ltr או rtl\n")
        return 2

    if len(args) == 1 and args[0] in ("toggle", "on", "off", "status"):
        return control(args[0])
    if pipe:
        return run_pipe(base)

    if not args:
        args = [os.environ.get("SHELL") or "/bin/sh"]

    if os.name != "posix" or not (sys.stdin.isatty() and sys.stdout.isatty()):
        # Not interactive: nothing to fix on screen, just run the command.
        try:
            os.execvp(args[0], args)
        except OSError as e:
            sys.stderr.write("hebfix: %s: %s\n" % (args[0], e.strerror))
            return 127
    return run_pty(args, base)


if __name__ == "__main__":
    sys.exit(main())

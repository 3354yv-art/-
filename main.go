// hebfix fixes reversed Hebrew (RTL) text in terminals without bidi support.
//
// It runs your shell (or any command, e.g. an AI CLI) inside a pseudo-terminal
// and reorders right-to-left text in its output so Hebrew reads correctly,
// while leaving escape sequences, colors and cursor movement intact.
package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/creack/pty"
	"golang.org/x/term"
)

const version = "2.0.0"

// exitStartupFailed means "could not start": the shell rc hook falls back to
// a plain shell when it sees it, so a broken install never locks you out.
const exitStartupFailed = 213

const usage = `hebfix - מיישר עברית הפוכה בטרמינל

שימוש:
  hebfix                   עוטף את ה-shell ($SHELL)
  hebfix CMD [ARGS...]     עוטף פקודה אחת (למשל: hebfix claude)
  hebfix --pipe            מסנן stdin ל-stdout (cmd | hebfix --pipe)
  hebfix toggle|on|off     כיבוי/הדלקה במסוף הנוכחי
  hebfix status            האם המסוף הנוכחי עובר דרך hebfix

אפשרויות:
  --base auto|ltr|rtl      כיוון הפסקה (ברירת מחדל: auto)
`

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	base := os.Getenv("HEBFIX_BASE")
	if base == "" {
		base = "auto"
	}
	pipe := false
	for len(args) > 0 && strings.HasPrefix(args[0], "-") {
		a := args[0]
		args = args[1:]
		switch {
		case a == "--":
			goto done
		case a == "-h" || a == "--help":
			fmt.Print(usage)
			return 0
		case a == "-V" || a == "--version":
			fmt.Println("hebfix " + version)
			return 0
		case a == "--pipe":
			pipe = true
		case a == "--base" && len(args) > 0:
			base = args[0]
			args = args[1:]
		case strings.HasPrefix(a, "--base="):
			base = strings.TrimPrefix(a, "--base=")
		default:
			fmt.Fprintf(os.Stderr, "hebfix: אפשרות לא מוכרת: %s\n", a)
			return 2
		}
	}
done:
	if base != "auto" && base != "ltr" && base != "rtl" {
		fmt.Fprintln(os.Stderr, "hebfix: --base חייב להיות auto, ltr או rtl")
		return 2
	}
	if len(args) == 1 {
		switch args[0] {
		case "toggle", "on", "off", "status":
			return control(args[0])
		}
	}
	if pipe {
		return runPipe(base)
	}
	if len(args) == 0 {
		sh := os.Getenv("SHELL")
		if sh == "" {
			sh = "/bin/sh"
		}
		args = []string{sh}
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) || !term.IsTerminal(int(os.Stdout.Fd())) {
		// Not interactive: nothing to fix on screen, just run the command.
		path, err := exec.LookPath(args[0])
		if err == nil {
			err = syscall.Exec(path, args, os.Environ())
		}
		fmt.Fprintf(os.Stderr, "hebfix: %s: %v\n", args[0], err)
		return 127
	}
	return runPTY(args, base)
}

func writeAll(w io.Writer, b []byte) {
	if len(b) > 0 {
		w.Write(b)
	}
}

func runPTY(args []string, base string) int {
	parentPID := os.Getpid()
	os.Setenv("HEBFIX_ACTIVE", "1")
	os.Setenv("HEBFIX_PID", strconv.Itoa(parentPID))

	cmd := exec.Command(args[0], args[1:]...)
	size, _ := pty.GetsizeFull(os.Stdout)
	var ptmx *os.File
	var err error
	if size != nil {
		ptmx, err = pty.StartWithSize(cmd, size)
	} else {
		ptmx, err = pty.Start(cmd)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "hebfix: %s: %v\n", args[0], err)
		if errors.Is(err, exec.ErrNotFound) || errors.Is(err, os.ErrNotExist) {
			return 127
		}
		return exitStartupFailed
	}
	defer ptmx.Close()

	cols := 0
	if size != nil {
		cols = int(size.Cols)
	}
	filt := NewFilter(base, cols)
	if os.Getenv("HEBFIX_DISABLE") != "" {
		filt.Enabled = false
	}

	sigs := make(chan os.Signal, 8)
	signal.Notify(sigs, syscall.SIGWINCH, syscall.SIGUSR1, syscall.SIGUSR2)
	defer signal.Stop(sigs)

	stdinFd := int(os.Stdin.Fd())
	if old, err := term.MakeRaw(stdinFd); err == nil {
		defer term.Restore(stdinFd, old)
	}

	go func() { io.Copy(ptmx, os.Stdin) }()

	output := make(chan []byte, 16)
	go func() {
		buf := make([]byte, 65536)
		for {
			n, err := ptmx.Read(buf)
			if n > 0 {
				output <- append([]byte{}, buf[:n]...)
			}
			if err != nil {
				close(output)
				return
			}
		}
	}()

	stdout := os.Stdout
	idle := time.NewTimer(time.Hour)
	idle.Stop()
loop:
	for {
		if filt.HasPendingRTL() {
			idle.Reset(30 * time.Millisecond)
		}
		select {
		case data, ok := <-output:
			idle.Stop()
			if !ok {
				break loop
			}
			writeAll(stdout, filt.Feed(data))
		case <-idle.C:
			writeAll(stdout, filt.Flush())
		case sig := <-sigs:
			switch sig {
			case syscall.SIGWINCH:
				if sz, err := pty.GetsizeFull(os.Stdout); err == nil {
					filt.Columns = int(sz.Cols)
					pty.Setsize(ptmx, sz)
				}
			case syscall.SIGUSR1:
				writeAll(stdout, filt.SetEnabled(!filt.Enabled))
			case syscall.SIGUSR2:
				writeAll(stdout, filt.SetEnabled(readWantedState(parentPID, filt.Enabled)))
			}
		}
	}
	writeAll(stdout, filt.Finish())

	if err := cmd.Wait(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
				return 128 + int(ws.Signal())
			}
			return ee.ExitCode()
		}
		return 1
	}
	return 0
}

func stateFile(pid int) string {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		dir = os.TempDir()
	}
	return filepath.Join(dir, fmt.Sprintf("hebfix-%d-%d.state", os.Getuid(), pid))
}

func readWantedState(pid int, def bool) bool {
	path := stateFile(pid)
	b, err := os.ReadFile(path)
	if err != nil {
		return def
	}
	os.Remove(path)
	return strings.TrimSpace(string(b)) == "on"
}

func control(cmd string) int {
	pidStr := os.Getenv("HEBFIX_PID")
	if cmd == "status" {
		if pidStr != "" {
			fmt.Printf("hebfix פעיל במסוף הזה (pid %s)\n", pidStr)
			return 0
		}
		fmt.Println("hebfix לא פעיל במסוף הזה")
		return 1
	}
	pid, err := strconv.Atoi(pidStr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "hebfix: המסוף הזה לא רץ דרך hebfix")
		return 1
	}
	sig := syscall.SIGUSR1
	if cmd != "toggle" {
		if err := os.WriteFile(stateFile(pid), []byte(cmd), 0o600); err != nil {
			fmt.Fprintf(os.Stderr, "hebfix: %v\n", err)
			return 1
		}
		sig = syscall.SIGUSR2
	}
	if err := syscall.Kill(pid, sig); err != nil {
		fmt.Fprintf(os.Stderr, "hebfix: %v\n", err)
		return 1
	}
	return 0
}

func runPipe(base string) int {
	filt := NewFilter(base, 0)
	buf := make([]byte, 65536)
	for {
		n, err := os.Stdin.Read(buf)
		if n > 0 {
			writeAll(os.Stdout, filt.Feed(buf[:n]))
		}
		if err != nil {
			break
		}
	}
	writeAll(os.Stdout, filt.Finish())
	return 0
}

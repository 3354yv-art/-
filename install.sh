#!/usr/bin/env bash
# Installs hebfix and hooks it into bash/zsh so every new terminal is fixed.
#
#   ./install.sh            wrap the whole shell (default)
#   ./install.sh --ai-only  wrap only AI command-line tools (claude, gemini, ...)
set -e

MODE=shell
case "$1" in
  --ai-only) MODE=ai ;;
  ""|--shell) ;;
  *) echo "שימוש: $0 [--shell | --ai-only]"; exit 2 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "hebfix צריך python3. התקן אותו ונסה שוב." >&2
  exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)/hebfix.py"
DEST_DIR="$HOME/.local/share/hebfix"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$DEST_DIR" "$BIN_DIR"
cp "$SRC" "$DEST_DIR/hebfix.py"
chmod +x "$DEST_DIR/hebfix.py"
ln -sf "$DEST_DIR/hebfix.py" "$BIN_DIR/hebfix"

AI_TOOLS="claude gemini codex aider ollama sgpt llm chatgpt copilot cursor-agent qwen opencode"

hook() {
  local shell_name="$1"
  echo "# >>> hebfix >>>"
  echo "# Fixes reversed Hebrew in the terminal. Remove with: ~/.local/share/hebfix/uninstall.sh"
  echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
  if [ "$MODE" = shell ]; then
    cat <<HOOK
if [ -z "\$HEBFIX_ACTIVE" ] && [ -z "\$HEBFIX_DISABLE" ] && [ -t 0 ] && [ -t 1 ] \\
   && [ -f "\$HOME/.local/share/hebfix/hebfix.py" ] && command -v python3 >/dev/null 2>&1; then
  python3 "\$HOME/.local/share/hebfix/hebfix.py" -- "$shell_name"
  __hebfix_rc=\$?
  [ \$__hebfix_rc -ne 213 ] && exit \$__hebfix_rc
  unset __hebfix_rc
fi
HOOK
  else
    for t in $AI_TOOLS; do
      echo "$t() { if [ -n \"\$HEBFIX_ACTIVE\" ]; then command $t \"\$@\"; else python3 \"\$HOME/.local/share/hebfix/hebfix.py\" $t \"\$@\"; fi; }"
    done
  fi
  echo "# <<< hebfix <<<"
}

install_rc() {
  local rc="$1" shell_name="$2"
  [ -f "$rc" ] || [ "$3" = force ] || return 0
  touch "$rc"
  # Replace an older hebfix block if one exists.
  if grep -q '# >>> hebfix >>>' "$rc"; then
    sed -i.hebfix-bak '/# >>> hebfix >>>/,/# <<< hebfix <<</d' "$rc"
    rm -f "$rc.hebfix-bak"
  fi
  hook "$shell_name" >> "$rc"
  echo "  ✔ $rc"
}

cp "$(dirname "$0")/uninstall.sh" "$DEST_DIR/uninstall.sh" 2>/dev/null || true

echo "מתקין את hebfix (מצב: $MODE)..."
case "$(basename "${SHELL:-bash}")" in
  zsh) install_rc "$HOME/.zshrc" zsh force; install_rc "$HOME/.bashrc" bash ;;
  *)   install_rc "$HOME/.bashrc" bash force; install_rc "$HOME/.zshrc" zsh ;;
esac

echo
echo "✅ הותקן! פתח חלון מסוף חדש והעברית תוצג בכיוון הנכון."
echo "   hebfix toggle  - כיבוי/הדלקה זמנית במסוף הנוכחי"
echo "   hebfix status  - בדיקה האם פעיל"

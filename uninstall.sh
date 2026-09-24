#!/usr/bin/env bash
# Removes hebfix and its shell hooks.
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ -f "$rc" ] && grep -q '# >>> hebfix >>>' "$rc"; then
    sed -i.hebfix-bak '/# >>> hebfix >>>/,/# <<< hebfix <<</d' "$rc"
    rm -f "$rc.hebfix-bak"
    echo "  ✔ הוסר מ-$rc"
  fi
done
rm -f "$HOME/.local/bin/hebfix"
rm -rf "$HOME/.local/share/hebfix"
echo "hebfix הוסר. פתח מסוף חדש."

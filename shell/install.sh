#!/bin/sh
# Append a line sourcing neodiff's shell launchers (gshow / gdiff) to the user's
# shell rc file(s), so the aliases are defined in new shells without a manual
# edit. Idempotent: a marked block is written once and refreshed in place on
# re-run.
#
# Intended as a plugin-manager post-install hook, e.g. vim-plug:
#   Plug 'justinnuwin/neodiff', { 'do': './shell/install.sh' }
#
# Args:
#   [rc-file...] - rc files to update; defaults to whichever of ~/.bashrc and
#                  ~/.zshrc exist (or $NEODIFF_RC, a space-separated list).
set -eu

unset CDPATH
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
source_line="source \"$script_dir/neodiff.sh\""

begin='# >>> neodiff >>>'
end='# <<< neodiff <<<'

# Choose target rc files: explicit args, then $NEODIFF_RC, then the existing
# default rc files.
if [ "$#" -gt 0 ]; then
    targets="$*"
elif [ -n "${NEODIFF_RC:-}" ]; then
    targets="$NEODIFF_RC"
else
    targets=""
    if [ -f "$HOME/.bashrc" ]; then targets="$targets $HOME/.bashrc"; fi
    if [ -f "$HOME/.zshrc" ]; then targets="$targets $HOME/.zshrc"; fi
fi

if [ -z "$targets" ]; then
    echo "neodiff: no ~/.bashrc or ~/.zshrc found; add this line to your shell rc:"
    echo "  $source_line"
    exit 0
fi

block="$begin
$source_line
$end"

for rc in $targets; do
    if [ -f "$rc" ] && grep -qF "$begin" "$rc"; then
        # Strip any existing block, then re-append the fresh one, so repeated
        # runs converge on a single up-to-date block.
        tmp=$(mktemp)
        awk -v b="$begin" -v e="$end" '
            $0 == b { skip = 1 }
            skip && $0 == e { skip = 0; next }
            !skip { print }
        ' "$rc" > "$tmp"
        printf '%s\n' "$block" >> "$tmp"
        cat "$tmp" > "$rc"
        rm -f "$tmp"
        echo "neodiff: refreshed source block in $rc"
    else
        printf '\n%s\n' "$block" >> "$rc"
        echo "neodiff: added source block to $rc"
    fi
done

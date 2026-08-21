#!/usr/bin/env bash
# Widen the Claude Code VS Code extension chat box to fill the sidebar.
#
# The webview lives in an iframe, so workbench CSS (custom-ui-style et al.)
# cannot reach it -- the extension's own stylesheet has to be patched.
# Extension updates ship a fresh CSS, so this re-runs via claude-code-width.path.
#
# Targets rules that are centred fixed-width containers, i.e. any block
# containing both "margin:0 auto" and "max-width:<N>px". In 2.1.238 that is
# exactly the chat input wrapper and the permissions container. Matching on
# the pattern rather than the class names survives their per-build hashes.

set -euo pipefail

EXT_GLOB="${HOME}/.vscode/extensions/anthropic.claude-code-*"
patched=0
found=0

shopt -s nullglob
for ext in $EXT_GLOB; do
    css="$ext/webview/index.css"
    [ -f "$css" ] || continue
    found=$((found + 1))

    if ! grep -qE 'margin:0 auto' "$css"; then
        continue
    fi

    # Already done?
    if ! perl -0777 -ne 'exit(1) unless /\{[^{}]*margin:0 auto[^{}]*\}/ && do {
            my $hit = 0;
            while (/(\{[^{}]*\})/g) { my $b = $1; $hit = 1 if $b =~ /margin:0 auto/ && $b =~ /max-width:\s*\d+px/ }
            $hit }' "$css"; then
        echo "already widened: $css"
        continue
    fi

    [ -f "$css.orig" ] || cp -p "$css" "$css.orig"

    perl -0777 -pi -e '
        s{\{[^{}]*\}}{
            my $b = $&;
            $b =~ s|max-width:\s*\d+px|max-width:100%|g if $b =~ m|margin:0 auto|;
            $b
        }ge
    ' "$css"

    echo "patched: $css  (backup at ${css##*/}.orig)"
    patched=$((patched + 1))
done

if [ "$found" -eq 0 ]; then
    echo "no anthropic.claude-code-* extension found under ~/.vscode/extensions" >&2
    exit 1
fi

if [ "$patched" -gt 0 ]; then
    echo "Done -- reload VS Code (Ctrl+Shift+P -> Developer: Reload Window)."
fi

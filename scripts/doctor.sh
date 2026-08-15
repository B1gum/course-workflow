#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FAIL=0
WARN=0

ok()   { printf 'OK   %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; WARN=$((WARN+1)); }
fail() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }

printf 'Course Workflow doctor\nRepository: %s\n\n' "$REPO_ROOT"

for cmd in nvim latexmk lualatex osascript; do
    if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd: $(command -v "$cmd")"; else fail "missing command: $cmd"; fi
done

for app in Hammerspoon iTerm Skim Zotero Safari MATLAB; do
    if [ -d "/Applications/$app.app" ] || [ -d "$HOME/Applications/$app.app" ]; then
        ok "$app application found"
    else
        warn "$app application not found in /Applications or ~/Applications"
    fi
done

if [ -f "$REPO_ROOT/config.json" ]; then ok "config.json exists"; else fail "config.json missing"; fi

HS="$HOME/.hammerspoon/course"
if [ -L "$HS" ]; then
    TARGET="$(readlink "$HS")"
    if [ "$TARGET" = "$REPO_ROOT/hammerspoon/course" ]; then
        ok "$HS points at this repository"
    else
        warn "$HS points at $TARGET (expected $REPO_ROOT/hammerspoon/course)"
    fi
else
    fail "$HS is not a symlink; run scripts/install-hammerspoon.sh"
fi

for pair in \
    "$HOME/.config/nvim/lua/course_context.lua|$REPO_ROOT/nvim/course_context.lua" \
    "$HOME/.config/nvim/lua/course-references|$REPO_ROOT/nvim/lua/course-references"; do
    LINK=${pair%%|*}; EXPECTED=${pair#*|}
    if [ -L "$LINK" ]; then
        ACTUAL=$(readlink "$LINK")
        [ "$ACTUAL" = "$EXPECTED" ] && ok "$LINK -> $EXPECTED" || warn "$LINK -> $ACTUAL (expected $EXPECTED)"
    else
        fail "$LINK missing/not symlink; run scripts/install-reference-nvim.sh"
    fi
done

if [ -f "$HOME/.hammerspoon/init.lua" ] && grep -q 'BEGIN NOAH COURSE WORKFLOW' "$HOME/.hammerspoon/init.lua"; then
    ok "Hammerspoon startup block installed"
else
    fail "Hammerspoon startup block missing; run scripts/install-hammerspoon.sh"
fi

DEBRIS=$(find "$REPO_ROOT/semesters" -mindepth 1 \( -iname '*semtest*' -o -iname '*test-semester*' -o -iname '*test-course*' -o -iname '*dynamics-test*' \) -print 2>/dev/null || true)
if [ -n "$DEBRIS" ]; then
    fail "test semester/course debris found:\n$DEBRIS"
else
    ok "no known test-semester/test-course debris"
fi

printf '\nResult: %d failure(s), %d warning(s).\n' "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ]

#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NVIM_LUA="$HOME/.config/nvim/lua"
CONTEXT_SOURCE="$REPO_ROOT/nvim/course_context.lua"
REFERENCES_SOURCE="$REPO_ROOT/nvim/lua/course-references"
CONTEXT_TARGET="$NVIM_LUA/course_context.lua"
REFERENCES_TARGET="$NVIM_LUA/course-references"

mkdir -p "$NVIM_LUA"

link_one() {
    local source="$1"
    local target="$2"

    if [ -L "$target" ]; then
        ln -sfn "$source" "$target"
        return
    fi

    if [ -e "$target" ]; then
        echo "ERROR: $target already exists and is not a symlink." >&2
        echo "Move it aside or merge it manually; nothing was overwritten." >&2
        exit 1
    fi

    ln -s "$source" "$target"
}

link_one "$CONTEXT_SOURCE" "$CONTEXT_TARGET"
link_one "$REFERENCES_SOURCE" "$REFERENCES_TARGET"

echo "Neovim reference integration installed."
echo "  $CONTEXT_TARGET -> $CONTEXT_SOURCE"
echo "  $REFERENCES_TARGET -> $REFERENCES_SOURCE"
echo
echo 'Keep your existing require("course_context") bootstrap; it now loads course-references automatically.'
echo "Reload Hammerspoon and restart Neovim before testing :References."

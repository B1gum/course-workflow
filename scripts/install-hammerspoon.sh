#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/hammerspoon/course"
HAMMERSPOON_DIR="$HOME/.hammerspoon"
TARGET_DIR="$HAMMERSPOON_DIR/course"
INIT_FILE="$HAMMERSPOON_DIR/init.lua"
BEGIN_MARKER="-- BEGIN NOAH COURSE WORKFLOW"
END_MARKER="-- END NOAH COURSE WORKFLOW"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

if [ ! -f "$SOURCE_DIR/init.lua" ]; then
    echo "ERROR: Could not find $SOURCE_DIR/init.lua" >&2
    exit 1
fi

mkdir -p "$HAMMERSPOON_DIR"

# Keep the repository as the single source of truth. If an older copied course
# directory exists in ~/.hammerspoon, preserve it and replace it with a symlink
# to the current repository checkout.
if [ -L "$TARGET_DIR" ]; then
    CURRENT_TARGET="$(readlink "$TARGET_DIR")"
    if [ "$CURRENT_TARGET" != "$SOURCE_DIR" ]; then
        BACKUP="$HAMMERSPOON_DIR/course.backup-$TIMESTAMP"
        echo "Preserving existing course symlink as: $BACKUP"
        mv "$TARGET_DIR" "$BACKUP"
        ln -s "$SOURCE_DIR" "$TARGET_DIR"
        echo "Linked $TARGET_DIR -> $SOURCE_DIR"
    else
        echo "Course module already linked to this repository."
    fi
elif [ -e "$TARGET_DIR" ]; then
    BACKUP="$HAMMERSPOON_DIR/course.backup-$TIMESTAMP"
    echo "Preserving existing course module as: $BACKUP"
    mv "$TARGET_DIR" "$BACKUP"
    ln -s "$SOURCE_DIR" "$TARGET_DIR"
    echo "Linked $TARGET_DIR -> $SOURCE_DIR"
else
    ln -s "$SOURCE_DIR" "$TARGET_DIR"
    echo "Linked $TARGET_DIR -> $SOURCE_DIR"
fi

if [ ! -e "$INIT_FILE" ]; then
    : > "$INIT_FILE"
fi

BLOCK_FILE="$(mktemp)"
NEW_INIT="$(mktemp)"
cleanup() {
    rm -f "$BLOCK_FILE" "$NEW_INIT"
}
trap cleanup EXIT

cat > "$BLOCK_FILE" <<'LUA'
-- BEGIN NOAH COURSE WORKFLOW
local courseOk, courseOrErr = pcall(require, "course")
if courseOk then
    Course = courseOrErr
else
    local message = "Course workflow failed to load: " .. tostring(courseOrErr)
    print(message)

    if hs and hs.notify and type(hs.notify.new) == "function" then
        pcall(function()
            hs.notify.new({
                title = "AU Course Workflow",
                informativeText = tostring(courseOrErr),
            }):send()
        end)
    end
end
-- END NOAH COURSE WORKFLOW
LUA

START_LINE="$(grep -nF -- "$BEGIN_MARKER" "$INIT_FILE" | head -n 1 | cut -d: -f1 || true)"
END_LINE="$(grep -nF -- "$END_MARKER" "$INIT_FILE" | head -n 1 | cut -d: -f1 || true)"

if [ -n "$START_LINE" ] || [ -n "$END_LINE" ]; then
    if [ -z "$START_LINE" ] || [ -z "$END_LINE" ] || [ "$END_LINE" -lt "$START_LINE" ]; then
        echo "ERROR: Found an incomplete course-workflow block in $INIT_FILE." >&2
        echo "Fix/remove the marker lines, then run this installer again." >&2
        exit 1
    fi

    EXISTING_BLOCK="$(mktemp)"
    sed -n "${START_LINE},${END_LINE}p" "$INIT_FILE" > "$EXISTING_BLOCK"

    if cmp -s "$EXISTING_BLOCK" "$BLOCK_FILE"; then
        echo "Hammerspoon startup block already installed."
        rm -f "$EXISTING_BLOCK"
    else
        BACKUP="$INIT_FILE.backup-$TIMESTAMP"
        cp "$INIT_FILE" "$BACKUP"

        if [ "$START_LINE" -gt 1 ]; then
            head -n "$((START_LINE - 1))" "$INIT_FILE" > "$NEW_INIT"
        else
            : > "$NEW_INIT"
        fi

        cat "$BLOCK_FILE" >> "$NEW_INIT"
        tail -n "+$((END_LINE + 1))" "$INIT_FILE" >> "$NEW_INIT"
        mv "$NEW_INIT" "$INIT_FILE"
        echo "Updated startup block in $INIT_FILE"
        echo "Backup: $BACKUP"
        rm -f "$EXISTING_BLOCK"
    fi
else
    BACKUP="$INIT_FILE.backup-$TIMESTAMP"
    cp "$INIT_FILE" "$BACKUP"

    if [ -s "$INIT_FILE" ] && [ -n "$(tail -c 1 "$INIT_FILE" 2>/dev/null || true)" ]; then
        printf '\n' >> "$INIT_FILE"
    fi

    if [ -s "$INIT_FILE" ]; then
        printf '\n' >> "$INIT_FILE"
    fi
    cat "$BLOCK_FILE" >> "$INIT_FILE"

    echo "Installed startup block in $INIT_FILE"
    echo "Backup: $BACKUP"
fi

# Verify the two conditions that make automatic startup possible.
if [ ! -L "$TARGET_DIR" ] || [ ! -f "$TARGET_DIR/init.lua" ]; then
    echo "ERROR: Hammerspoon course module is not reachable at $TARGET_DIR/init.lua" >&2
    exit 1
fi

if ! grep -qF -- "$BEGIN_MARKER" "$INIT_FILE"; then
    echo "ERROR: Hammerspoon init.lua does not contain the startup block." >&2
    exit 1
fi

echo
echo "Course workflow installation is ready."
echo "Hammerspoon module: $TARGET_DIR -> $SOURCE_DIR"
echo "Startup file:       $INIT_FILE"
echo
echo "Reload Hammerspoon once. From then on, the course workflow starts automatically."

#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$SCRIPT_DIR/course-workflow-helper"
OUTPUT="$SCRIPT_DIR/course-workflow-zotero-helper.xpi"

rm -f "$OUTPUT"
(
  cd "$SOURCE"
  zip -q -r "$OUTPUT" manifest.json bootstrap.js README.md
)
printf 'Built %s\n' "$OUTPUT"

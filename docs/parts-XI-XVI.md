# Parts XI–XVI — verification and reference-search setup

This layer keeps Zotero canonical and keeps course/context logic in Hammerspoon.
Neovim does **not** maintain a second reference index. It talks to the
loopback-only Hammerspoon reference service at `127.0.0.1:23120`, and that
service reads Zotero + Better BibTeX live.

## Install after applying the patch

From the `course-workflow` repository:

```sh
./scripts/install-hammerspoon.sh
./scripts/install-reference-nvim.sh
```

Then reload Hammerspoon and restart Neovim.

The Neovim installer preserves the existing architecture: your ordinary
Neovim config still only needs its existing:

```lua
require("course_context")
```

`course_context.lua` now bootstraps `course-references` from the repository.

## Part XI — SyncTeX acceptance test

No custom inverse-search implementation is added. Keep the native
VimTeX/Skim SyncTeX path.

### Forward search

For each of these source locations:

- `notes/master.tex`
- `notes/lectures/lec_01.tex`
- `notes/lectures/lec_02.tex`

place the cursor on distinctive text and run:

```vim
:VimtexView
```

Skim must focus the corresponding PDF location.

### Inverse search

Use Skim's configured SyncTeX inverse-search gesture on text originating from
both `master.tex` and a lecture file. Verify that the existing Skim/VimTeX
integration returns to the correct `.tex` file and line and focuses the
terminal/Neovim window.

### Selective builds

Repeat forward/inverse search after each of the existing build actions:

- Compile All
- Compile Current / one selected lecture
- Compile Range
- Compile Selected

Inspect `notes/.build/selected.tex` only as generated build state. The
source-side SyncTeX target should remain the real lecture file included by the
selection wrapper. Undefined references to omitted material are acceptable.

## Part XII — reference-service smoke test

With Zotero + Better BibTeX installed and local API access enabled:

```sh
curl --silent \
  --header 'Content-Type: application/json' \
  --data '{"command":"search","all":true}' \
  http://127.0.0.1:23120/v1/reference
```

The response should have `"ok":true` and normalized items containing stable
`itemKey` and `citationKey` values. If the connection is refused, reload
Hammerspoon and check its Console for startup errors.

`Open Reference` resolves the local PDF only at the moment it is opened. The
filesystem path is never stored as reference identity. If the PDF is absent on
this Mac, the Zotero item is opened instead and DOI/URL metadata is returned as
fallback information.

## Part XIII — Hammerspoon semantics

The launcher/menu now distinguish:

- **Search References** — current course Zotero collection
- **Open References** — exact current course Zotero collection
- **Search All References** — complete Zotero library
- **Open References Folder** — `course/references/` in Finder

Course-scoped search uses the existing A → B → C → D resolver and never asks
which course to use.

## Parts XIV–XV — Neovim/Telescope

Commands:

```vim
:References
:ReferencesAll
:ReferencesOpen
```

The Telescope picker searches author, year, title, and citation key.

Bindings inside the picker:

- `<CR>` — insert one `\\cite{...}` command (or open the item in Open mode)
- `<Tab>` — toggle multi-select
- `<C-o>` — open PDF in Skim, with Zotero fallback when unavailable
- `<C-z>` — select the bibliographic item in Zotero
- `<C-y>` — copy citation key

Multi-select inserts exactly one command such as:

```tex
\cite{key1,key2,key3}
```

in deterministic Zotero result order.

## Part XVI — reference namespace

With leader `,` the module registers:

```text
,rr  Search References
,rR  Search All References
,ro  Open Reference
,rp  Open Cited Page
```

`,rp` is deliberately reserved but does not yet implement page extraction or
Skim page navigation; those semantics belong to Part XVII. Invoking it now
shows an explicit informational message rather than guessing or adding a
partial implementation early.

## Minimum acceptance test

1. `:References` from a course `.tex` buffer shows only that course collection.
2. Searching author, year, title, and citation key all find the same item.
3. `<CR>` inserts `\cite{key}` at the original cursor.
4. Select two items with `<Tab>` and press `<CR>`; one multi-key citation is inserted.
5. `<C-o>` opens a local PDF in Skim.
6. For an item whose PDF is absent locally, `<C-o>` opens the Zotero item instead.
7. `<C-z>` selects the item in Zotero.
8. `<C-y>` copies the key.
9. `:ReferencesAll` includes items outside the current course collection.
10. Launcher/menu **Open References** opens the exact collection identified by `collectionKey`.
11. **Open References Folder** still opens only the generated `references/` directory.
12. Complete the Part XI forward/inverse SyncTeX matrix above.

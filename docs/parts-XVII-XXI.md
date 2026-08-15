# Research workflow — Parts XVII–XXI

This layer completes page navigation, browser capture, source ownership rules,
Git/reproducibility rules, and the final New Semester reference provisioning
checks.

## Part XVII — page-specific navigation

Portable LaTeX stays exactly as document markup:

```tex
\citepage{johnson1985contactmechanics}{42}
\citepage{johnson1985contactmechanics}{42--45}
```

In Neovim, put the cursor anywhere on the `\citepage{...}{...}` command and use:

```text
,rp
```

or:

```vim
:ReferencesOpenPage
```

The Neovim module extracts the citation key and the first numeric page in the
page/range. Hammerspoon then resolves:

```text
citation key → Zotero item → local PDF attachment → Skim
```

The Skim deep link is constructed only at invocation time. No Zotero storage
path, `file://` URI, or machine-specific Skim URI is written into the `.tex`
file. Numeric PDF position is the reliable V1 fallback.

If the PDF is absent on this Mac, the normal reference fallback opens the
Zotero item/DOI/source instead and reports that page navigation could not be
performed.

## Part XVIII — Safari capture

Use the normal **Zotero Safari Connector**. The workflow does not contain a
custom arXiv button, publisher userscript, or webpage translator.

The two Hammerspoon actions are:

```text
Save Reference
Save Reference Unfiled
```

`Save Reference` performs this sequence:

```text
Safari current page
  → normal Zotero Connector save
  → detect the newly created top-level Zotero item(s)
  → reliable A → B → C → D course context?
       yes → add to that exact stable course collection
       no  → leave Unfiled
```

`Save Reference Unfiled` always clears course collection membership for the
newly captured item(s), even when a course is active. It is the deliberate
"sort later" path.

The Connector button is invoked semantically through macOS Accessibility
(`AXPress` on the Zotero toolbar button), never by mouse coordinates. Zotero's
Connector still owns metadata translation, authentication/cookies, snapshot/PDF
capture, and attachment storage. The Course Workflow helper only performs the
post-capture collection assignment that Zotero's current local read API cannot
perform.

### One-time Safari prerequisites

- Enable the Zotero extension in Safari Settings → Extensions.
- Keep the Zotero Connector button visible in Safari's toolbar.
- Allow Hammerspoon under System Settings → Privacy & Security → Accessibility.
- Install Course Workflow Zotero Helper **1.1.0 or newer**.

A multi-item Connector save may leave the Connector's own selection UI open.
The workflow waits (bounded to 90 seconds) until the newly created Zotero item
set settles, then assigns the resulting top-level items.

## Part XIX — source ownership

Use these rules consistently:

### External paper/report/standard/thesis

```text
Safari/import → Zotero item → Zotero-managed PDF → course collection
```

Never copy the external research PDF into the course filesystem.

### Lecturer-provided paper

The supplied file remains, for example:

```text
course/literature/paper.pdf
```

If citation-worthy, create/reuse its bibliographic Zotero item and add the item
to the course collection. Do not copy the PDF into `references/`.

### Official textbook

Course access remains:

```text
course/literature/book.pdf
```

The New Semester wizard creates/reuses the Zotero Book identity and uses the
course book as a linked attachment rather than creating another managed PDF
copy.

### Transient webpage

Keep it in Safari bookmarks/Reading List unless it is genuinely worth citing or
intentionally finding again.

## Part XX — Git and reproducibility

`references/references.bib` is a generated interface, but it should be committed
when the course itself is Git-versioned. This lets a clean checkout compile
without first requiring Zotero/Better BibTeX to regenerate the bibliography.

Each newly scaffolded `references/` directory receives:

```gitignore
# External research PDFs are owned by Zotero, not the course repository.
*.pdf
*.PDF
```

This deliberately does **not** ignore `references.bib`.

Do not place Zotero-managed research PDFs in `references/` at all; the ignore
file is a guard rail, not an alternative storage design.

No unique research information may exist only in Hammerspoon/Neovim/Telescope
caches. The reference layer performs live reads and keeps only disposable
runtime state. It must be rebuildable from:

```text
Zotero library + course JSON + generated/reproducible configuration
```

## Part XXI — final New Semester reference provisioning

For each course, the wizard now treats Zotero/reference provisioning as part of
course creation rather than a follow-up procedure:

```text
course metadata
→ filesystem + course JSON
→ Zotero semester/course collection
→ persist stable collectionKey
→ Better BibLaTeX auto-export
→ wait for references/references.bib
→ optional literature/book.pdf symlink
→ optional Book item + stable bookItemKey + linked PDF
→ final validation
```

The stable `collectionKey` is persisted **before** the bibliography wait. This
matters for safe recovery: if Better BibTeX is temporarily unavailable after a
collection was created, rerunning the wizard resumes from that exact collection
instead of trying to infer identity from a same-named collection.

Final validation verifies the stable collection, the bibliography export, and,
when a textbook exists, the Book identity, course membership, and local linked
PDF. Existing stable IDs remain the basis for idempotent reruns.

## Quick acceptance checks

1. In a `.tex` buffer put the cursor on `\citepage{key}{42--45}` and run `,rp`.
   Skim should open the reference at PDF page 42.
2. With Safari frontmost and a course reliably active, run **Save Reference**.
   The normal Connector saves it and the item appears in the course collection.
3. Run **Save Reference Unfiled** with the same course active. The new item must
   remain outside course collections.
4. Outside resolvable course context, **Save Reference** must save Unfiled and
   never ask which course to use.
5. Create/rerun a test semester. `references/references.bib` must exist before
   successful completion, stable Zotero IDs must be persisted, and rerunning
   must not duplicate the collection/export/book/attachment.
6. In a Git-versioned test course, `git status` should allow
   `references/references.bib` to be committed while `references/*.pdf` is
   ignored.

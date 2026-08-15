# Course Workflow

A macOS course workflow built around Hammerspoon, Neovim, LaTeX, Skim, Zotero, Better BibTeX, Safari, and iTerm2.

The repository is the source of truth for workflow code and templates. The runtime expects the canonical checkout at `~/.config/course-workflow`; course documents live separately under the configured university root.

## Architecture

Course context resolves deterministically in this order:

1. explicit action/course context;
2. exact path-derived context from the active application;
3. manually selected/launched course context;
4. timetable-derived context.

If none of these resolves, the action fails safely instead of prompting for a course.

The central Hammerspoon action layer owns course actions. The launcher, menubar, hotkeys, Neovim bridge, LaTeX build flow, figure integration, and reference integration all delegate to that shared state/context layer.

### Global Hammerspoon key layer

The global course layer uses **Command+Shift (`⌘⇧`)** as its Hyper modifier.

| Shortcut | Action |
|---|---|
| `⌘⇧Space` | Open course launcher |
| `⌘⇧N` | Open notes |
| `⌘⇧A` | Open assignments |
| `⌘⇧F` | Figures (find/open/create) |
| `⌘⇧R` | Search course references |
| `⌘⇧M` | Open MATLAB |
| `⌘⇧L` | Open literature |
| `⌘⇧C` | Compile current |

`⌘⇧F` deliberately uses the figure picker as the single figure entry point; the picker also exposes creation, so a separate global “new figure” shortcut is unnecessary.

## Repository layout

```text
course-workflow/
├── config.json                     # machine/application configuration
├── hammerspoon/course/             # core workflow
├── nvim/                            # Neovim context + reference integration
├── scripts/
│   ├── install-hammerspoon.sh
│   ├── install-reference-nvim.sh
│   └── semester-wizard.lua
├── templates/notes/master.tex      # notes scaffold template
└── zotero/                          # Zotero helper plugin + build script
```

Semester/course metadata created by the workflow lives under `semesters/` in the canonical checkout. A course filesystem is created under the university root and follows the standard structure:

```text
course/
├── notes/
│   ├── lectures/
│   ├── figures/
│   └── .build/
├── assignments/
│   └── figures/
├── matlab/
├── literature/
│   └── book.pdf                    # optional symlink
└── references/
    └── references.bib              # Better BibTeX auto-export
```

External research PDFs belong to Zotero, not `references/`.

## Installation

Run the installers from the repository root:

```sh
./scripts/install-hammerspoon.sh
./scripts/install-reference-nvim.sh
```

The Hammerspoon installer:

- links `hammerspoon/course` to `~/.hammerspoon/course`;
- installs a guarded `require("course")` startup block in `~/.hammerspoon/init.lua`;
- preserves an existing module or startup block before replacing it.

Reload Hammerspoon once after installation. The workflow then starts automatically whenever Hammerspoon loads its configuration.

The Neovim installer links:

```text
nvim/course_context.lua            -> ~/.config/nvim/lua/course_context.lua
nvim/lua/course-references/        -> ~/.config/nvim/lua/course-references/
```

Keep the existing Neovim bootstrap:

```lua
require("course_context")
```

## Semester setup

Create a semester through the workflow's **New Semester** action. The wizard creates the course filesystem and metadata, provisions reference collections/exports, and validates the resulting setup.

Course timetable slots are stored in course metadata. Supported teaching periods use the fixed 08/10/12/14/16 boundaries and 2-hour or 4-hour durations.

Semester selection is manual and persistent. Course context inside the active semester can then be inferred automatically from paths, manual selection, or timetable state.

## Notes and LaTeX

Lecture files use zero-padded names such as:

```text
notes/lectures/lec_01.tex
notes/lectures/lec_02.tex
```

Selective compilation never mutates `master.tex`. It generates disposable build state under:

```text
notes/.build/selected.tex
```

and compiles from there. Partial builds may naturally contain undefined references to omitted material.

SyncTeX is intentionally left to the native VimTeX/Skim integration; the workflow does not implement a second inverse-search mechanism.

## References

Zotero is the canonical database for external academic/research sources. Better BibTeX provides stable citation keys and per-course BibLaTeX exports.

The Hammerspoon reference service listens only on loopback at:

```text
127.0.0.1:23120
```

Neovim commands:

```vim
:References
:ReferencesAll
:ReferencesOpen
:ReferencesOpenPage
```

The Telescope picker searches author, year, title, and citation key. Its main actions are:

- `<CR>` — insert `\\cite{...}` or open the selected item in Open mode;
- `<Tab>` — toggle multi-select;
- `<C-o>` — open the PDF in Skim, with Zotero fallback;
- `<C-z>` — select the bibliographic item in Zotero;
- `<C-y>` — copy the citation key.

For page-specific references, put the cursor on a command such as:

```tex
\citepage{johnson1985contactmechanics}{42--45}
```

and use `,rp` / `:ReferencesOpenPage` to resolve the citation key to the local Zotero attachment and open the first numeric PDF page in Skim.

## Safari capture

Use the normal Zotero Safari Connector. The workflow does not replace Zotero's translators or PDF handling.

Two Hammerspoon actions are provided:

- **Save Reference** — save with the Zotero Connector and assign newly created items to the reliably resolved course collection;
- **Save Reference Unfiled** — save deliberately outside course collections.

If course context cannot be resolved, normal Save Reference falls back to Unfiled rather than prompting.

Safari prerequisites:

- enable the Zotero extension in Safari;
- keep the Zotero Connector button visible in Safari's toolbar;
- allow Hammerspoon under macOS Accessibility permissions;
- install the Course Workflow Zotero Helper when local write operations are needed.

## Zotero helper

The helper plugin is intentionally narrow. It performs the local Zotero mutations that the workflow needs for course provisioning and post-capture collection assignment.

Build it with:

```sh
./zotero/build-helper.sh
```

Then install the resulting XPI from Zotero's plugin manager and restart Zotero. See `zotero/README.md` for helper-specific details.

## Source ownership rules

Use these rules consistently:

- external paper/report/standard/thesis → Zotero item + Zotero-managed PDF;
- lecturer-provided material → keep under `literature/`; create a Zotero bibliographic item too when citation-worthy;
- official textbook → keep course access at `literature/book.pdf`; use a Zotero bibliographic identity when cited;
- transient webpage → Safari bookmark/Reading List unless it is worth citing or deliberately finding again.

`references/references.bib` is generated, but should be committed when the course itself is version-controlled so a clean checkout can compile without first regenerating the bibliography.

## Runtime dependencies

The workflow assumes the configured macOS applications and integrations are installed and working, notably:

- Hammerspoon;
- iTerm2;
- Neovim;
- LaTeX/`latexmk` with LuaLaTeX;
- Skim;
- Safari;
- Zotero + Better BibTeX;
- the separate Inkscape figure workflow for figure actions.

Application bundle IDs and the university root are configured in `config.json`.

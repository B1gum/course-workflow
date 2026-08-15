# Course Workflow Zotero Helper

Zotero 9's local Web API is read-only. This tiny helper exposes only the narrow local write operations the course workflow needs:

- create a Zotero `Book` item when no existing item has been matched;
- add that Book item to the stable course collection;
- create/reuse a **linked-file** attachment pointing at `course/literature/book.pdf`;
- assign newly captured Zotero items to one stable course collection, or deliberately leave them Unfiled.

It does not handle ordinary research-paper capture or PDF storage.

## Build

From the repository root:

```sh
./zotero/build-helper.sh
```

This creates `zotero/course-workflow-zotero-helper.xpi`.

## Install

In Zotero 9, open **Tools → Plugins** and drag `course-workflow-zotero-helper.xpi` into the Plugins window. Restart Zotero once.

The semester wizard preflight checks `http://localhost:23119/course-workflow/ready` only when at least one configured course has a textbook, and fails before textbook provisioning if the helper is absent.

## Browser capture assignment

The `/course-workflow/assign-capture` endpoint receives only the stable item keys created by the normal Zotero Safari Connector. It either adds those top-level items to the requested stable course collection or clears collection membership for the explicit **Save Reference Unfiled** path. It never performs webpage translation itself.

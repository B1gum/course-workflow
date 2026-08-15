# Course Workflow Zotero helper

The course workflow uses Zotero's local read API and Better BibTeX JSON-RPC for normal reference work. Current Zotero 9 local API writes are read-only, so the tiny helper plugin in `course-workflow-helper/` is used only for the local mutations that cannot go through the read API:

- create/reuse a Zotero Book item and add it to the course collection;
- attach `course/literature/book.pdf` as a **linked file**, without copying it into Zotero storage;
- post-assign items created by the normal Zotero Safari Connector to one stable course collection, or deliberately leave them Unfiled.

## Build

```sh
./zotero/build-helper.sh
```

This creates `zotero/course-workflow-zotero-helper.xpi`.

## Install

In Zotero, open **Tools → Plugins**, choose **Install Plugin From File…**, select the XPI, and restart Zotero. The semester wizard checks `/course-workflow/ready` when at least one new course has a textbook and fails before provisioning if the helper is missing. Browser **Save Reference** actions also require helper 1.1.0 or newer for post-capture collection assignment.

The helper is intentionally version-bounded to Zotero 7–9. When Zotero local API writes are generally available, this bridge should be retired in favor of the supported local write API.

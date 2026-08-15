var endpoints = {};
var HELPER_VERSION = "1.1.0";

function log(message) {
  Zotero.debug("[course-workflow-helper] " + message);
}

function register(path, methods, handler) {
  endpoints[path] = function () {};
  endpoints[path].prototype = {
    supportedMethods: methods,
    supportedDataTypes: ["application/json"],
    permitBookmarklet: false,
    init: async function (request) {
      try {
        var result = await handler((request && request.data) || {}, request || {});
        return [200, "application/json", JSON.stringify(result)];
      }
      catch (error) {
        log("error on " + path + ": " + (error && error.stack ? error.stack : error));
        return [500, "text/plain", String((error && error.message) || error)];
      }
    },
  };
  Zotero.Server.Endpoints[path] = endpoints[path];
}

function requireString(value, name) {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error("'" + name + "' must be a non-empty string");
  }
  return value.trim();
}

function userCollection(key) {
  key = requireString(key, "collectionKey");
  var collection = Zotero.Collections.getByLibraryAndKey(
    Zotero.Libraries.userLibraryID,
    key
  );
  if (!collection) {
    throw new Error("Zotero collection '" + key + "' does not exist in My Library");
  }
  return collection;
}

function userItem(key, fieldName) {
  fieldName = fieldName || "itemKey";
  key = requireString(key, fieldName);
  var item = Zotero.Items.getByLibraryAndKey(Zotero.Libraries.userLibraryID, key);
  if (!item) {
    throw new Error("Zotero item '" + key + "' does not exist in My Library");
  }
  return item;
}

function isBook(item) {
  return Zotero.ItemTypes.getName(item.itemTypeID) === "book";
}

function normalizeAuthors(value) {
  if (Array.isArray(value)) {
    return value.map(String).map(function (name) { return name.trim(); }).filter(Boolean);
  }
  if (typeof value === "string") {
    return value.split(";").map(function (name) { return name.trim(); }).filter(Boolean);
  }
  return [];
}

function authorCreator(name) {
  name = String(name || "").trim();
  if (!name) return null;

  var comma = name.match(/^\s*([^,]+),\s*(.+?)\s*$/);
  if (comma) {
    return {
      creatorType: "author",
      firstName: comma[2],
      lastName: comma[1].trim(),
    };
  }

  var parts = name.split(/\s+/);
  if (parts.length === 1) {
    return { creatorType: "author", name: name };
  }

  return {
    creatorType: "author",
    firstName: parts.slice(0, -1).join(" "),
    lastName: parts[parts.length - 1],
  };
}

async function lookupBookByISBN(isbn, collection) {
  if (typeof isbn !== "string" || !isbn.trim()) return null;

  var identifiers = Zotero.Utilities.extractIdentifiers(isbn.trim());
  var identifier = identifiers.find(function (value) {
    return value && value.ISBN;
  });
  if (!identifier) return null;

  var translate = new Zotero.Translate.Search();
  translate.setIdentifier(identifier);
  var translators = await translate.getTranslators();
  if (!translators || !translators.length) return null;
  translate.setTranslator(translators);

  try {
    var items = await translate.translate({
      libraryID: Zotero.Libraries.userLibraryID,
      collections: [collection.id],
      saveAttachments: false,
    });
    for (var i = 0; i < items.length; i++) {
      if (isBook(items[i])) return items[i];
    }
  }
  catch (error) {
    log("ISBN lookup failed: " + error);
  }
  return null;
}

async function createBook(metadata, collection) {
  metadata = metadata || {};
  var title = requireString(metadata.title, "metadata.title");
  var authors = normalizeAuthors(metadata.authors);
  if (!authors.length) {
    throw new Error("'metadata.authors' must contain at least one author");
  }

  var item = new Zotero.Item("book");
  item.libraryID = Zotero.Libraries.userLibraryID;
  item.fromJSON({
    itemType: "book",
    title: title,
    creators: authors.map(authorCreator).filter(Boolean),
    date: typeof metadata.year === "string" ? metadata.year.trim() : "",
    ISBN: typeof metadata.isbn === "string" ? metadata.isbn.trim() : "",
  });
  item.setCollections([collection.id]);
  await item.saveTx();
  return item;
}

async function ensureCollectionMembership(item, collection) {
  var ids = item.getCollections();
  if (ids.includes(collection.id)) {
    return false;
  }
  ids.push(collection.id);
  item.setCollections(ids);
  await item.saveTx();
  return true;
}

function requireItemKeys(value) {
  if (!Array.isArray(value) || !value.length) {
    throw new Error("'itemKeys' must contain at least one Zotero item key");
  }

  var seen = new Set();
  return value.map(function (key) {
    return requireString(key, "itemKeys[]");
  }).filter(function (key) {
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function isChildItem(item) {
  // Bibliographic parent items and standalone PDF attachments have no parentID.
  // Connector-created child attachments/notes are deliberately not assignable.
  return !!item.parentID;
}

async function assignCapturedItems(data) {
  data = data || {};
  var itemKeys = requireItemKeys(data.itemKeys);
  var unfiled = data.unfiled === true;
  var collection = unfiled ? null : userCollection(data.collectionKey);
  var changed = [];

  for (var i = 0; i < itemKeys.length; i++) {
    var item = userItem(itemKeys[i], "itemKeys[]");

    if (isChildItem(item)) {
      throw new Error(
        "Captured item '" + item.key + "' is a child item; refusing to change collection membership"
      );
    }

    var ids = item.getCollections();
    var nextIDs;

    if (unfiled) {
      nextIDs = [];
    }
    else if (ids.includes(collection.id)) {
      nextIDs = ids;
    }
    else {
      nextIDs = ids.slice();
      nextIDs.push(collection.id);
    }

    var didChange = nextIDs.length !== ids.length
      || nextIDs.some(function (id, index) { return id !== ids[index]; });

    if (didChange) {
      item.setCollections(nextIDs);
      await item.saveTx();
      changed.push(item.key);
    }
  }

  return {
    count: itemKeys.length,
    itemKeys: itemKeys,
    changed: changed,
    unfiled: unfiled,
    collectionKey: collection ? collection.key : null,
  };
}

function canonicalPath(path) {
  return Zotero.File.pathToFile(path).path;
}

async function findLinkedAttachment(item, bookPath) {
  var wanted = canonicalPath(bookPath);
  var ids = item.getAttachments();
  for (var i = 0; i < ids.length; i++) {
    var attachment = Zotero.Items.get(ids[i]);
    if (!attachment) continue;
    if (attachment.attachmentLinkMode !== Zotero.Attachments.LINK_MODE_LINKED_FILE) continue;
    var path = await attachment.getFilePath();
    if (path && canonicalPath(path) === wanted) {
      return attachment;
    }
  }
  return null;
}

async function ensureLinkedAttachment(item, bookPath) {
  bookPath = requireString(bookPath, "bookPath");
  var file = Zotero.File.pathToFile(bookPath);
  if (!file.exists() || file.isDirectory()) {
    throw new Error("Textbook path is not a readable file: " + bookPath);
  }

  var existing = await findLinkedAttachment(item, bookPath);
  if (existing) {
    return { attachment: existing, reused: true };
  }

  var attachment = await Zotero.Attachments.linkFromFile({
    file: bookPath,
    parentItemID: item.id,
    title: "Course textbook PDF",
    contentType: "application/pdf",
  });
  return { attachment: attachment, reused: false };
}

function install() {}
function uninstall() {}

function startup() {
  register("/course-workflow/ready", ["GET", "POST"], async function () {
    return {
      ready: true,
      version: HELPER_VERSION,
      zotero: Zotero.version,
    };
  });

  register("/course-workflow/assign-capture", ["POST"], async function (data) {
    return assignCapturedItems(data);
  });

  register("/course-workflow/provision-textbook", ["POST"], async function (data) {
    var collection = userCollection(data.collectionKey);
    var item;
    var reused = false;

    if (data.bookItemKey) {
      item = userItem(data.bookItemKey, "bookItemKey");
      if (!isBook(item)) {
        throw new Error("Configured bookItemKey does not refer to a Book item");
      }
      reused = true;
    }
    else {
      var metadata = data.metadata || {};
      if (metadata.isbn) {
        item = await lookupBookByISBN(metadata.isbn, collection);
      }
      if (!item) {
        var fallbackAuthors = normalizeAuthors(metadata.authors);
        if (metadata.isbn && (!metadata.title || !fallbackAuthors.length)) {
          throw new Error(
            "ISBN lookup did not identify the textbook. Supply title and author metadata so the Book item can be created manually."
          );
        }
        item = await createBook(metadata, collection);
      }
    }

    var membershipChanged = await ensureCollectionMembership(item, collection);
    var linked = await ensureLinkedAttachment(item, data.bookPath);

    return {
      bookItemKey: item.key,
      reused: reused,
      collectionMembershipChanged: membershipChanged,
      attachmentKey: linked.attachment.key,
      attachmentReused: linked.reused,
    };
  });

  log("endpoints registered");
}

function shutdown() {
  for (var path in endpoints) {
    delete Zotero.Server.Endpoints[path];
  }
  endpoints = {};
}

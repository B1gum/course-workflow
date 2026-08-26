local References = {}

local Util = require("course.util")

References.BBT_RPC_URL = "http://localhost:23119/better-bibtex/json-rpc"
References.ZOTERO_LOCAL_BASE = "http://localhost:23119"
References.ZOTERO_API_BASE = References.ZOTERO_LOCAL_BASE .. "/api/users/0"
References.BIBLATEX_TRANSLATOR = "Better BibLaTeX"
References.ZOTERO_HELPER_BASE = References.ZOTERO_LOCAL_BASE .. "/course-workflow"
References.PAGE_SIZE = 100
References.CAPTURE_RECENT_LIMIT = 100
References.EXPORT_VERIFY_RETRIES = 120
References.CITATION_KEY_VERIFY_RETRIES = 40
References.ASYNC_VERIFY_DELAY = 0.25

local JSON_HEADERS = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
}

local API_HEADERS = {
    ["Accept"] = "application/json",
    ["Zotero-API-Version"] = "3",
}


local function runtimeFunction(runtime, name, fallback)
    if type(runtime) == "table" and type(runtime[name]) == "function" then
        return runtime[name]
    end

    return fallback
end

local function httpPost(url, body, headers)
    return hs.http.post(url, body, headers)
end

local function httpGet(url, headers)
    return hs.http.get(url, headers)
end

local function openURLWithBundle(url, bundleId)
    if Util.isNonEmptyString(bundleId) then
        hs.urlevent.openURLWithBundle(url, Util.trim(bundleId))
    else
        hs.urlevent.openURL(url)
    end

    return true
end

local function openFileWithBundle(path, bundleId)
    local command = "/usr/bin/open"

    if Util.isNonEmptyString(bundleId) then
        command = command
            .. " -b " .. Util.shellQuote(Util.trim(bundleId))
    end

    command = command .. " " .. Util.shellQuote(path)
    local _, ok = hs.execute(command)
    if not ok then
        return nil, "The macOS open command failed."
    end

    return true
end

local function fileMode(path)
    return hs.fs.attributes(path, "mode")
end


local function launchBundle(bundleId)
    if hs.application.launchOrFocusByBundleID(bundleId) then
        return true
    end

    return nil, "Could not launch application bundle " .. tostring(bundleId) .. "."
end

local function sleepSeconds(seconds)
    hs.timer.usleep(math.floor((seconds or 0) * 1000000))
end

local function decodeJson(body, label)
    local ok, value = pcall(hs.json.decode, body or "")

    if not ok or type(value) ~= "table" then
        return nil, (label or "Response") .. " was not valid JSON."
    end

    return value
end


local function percentEncode(value)
    value = tostring(value or "")

    return (value:gsub("([^%w%-_%.~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function percentEncodePath(value)
    value = tostring(value or "")

    return (value:gsub("([^%w%-_%.~/])", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function normalizeText(value)
    if not Util.isNonEmptyString(value) then
        return ""
    end

    return Util.trim(value):lower():gsub("%s+", " ")
end

local function normalizeIsbn(value)
    if not Util.isNonEmptyString(value) then
        return ""
    end

    return Util.trim(value):upper():gsub("[^0-9X]", "")
end

local function publicationYear(value)
    if not Util.isNonEmptyString(value) then
        return ""
    end

    return tostring(value):match("(%d%d%d%d)") or ""
end


function References.rpc(method, params, runtime)
    if not Util.isNonEmptyString(method) then
        return nil, "Better BibTeX RPC method must be a non-empty string."
    end

    local payload = hs.json.encode({
        jsonrpc = "2.0",
        id = 1,
        method = Util.trim(method),
        params = params or {},
    })

    local post = runtimeFunction(runtime, "httpPost", httpPost)
    local ok, status, body = pcall(
        post,
        References.BBT_RPC_URL,
        payload,
        JSON_HEADERS
    )

    if not ok then
        return nil, "Could not contact Better BibTeX: " .. tostring(status)
    end

    if status ~= 200 then
        return nil,
            string.format(
                "Better BibTeX JSON-RPC returned HTTP %s. Is Zotero running with Better BibTeX installed?",
                tostring(status)
            )
    end

    local response, decodeErr = decodeJson(body, "Better BibTeX response")

    if not response then
        return nil, decodeErr
    end

    if response.error ~= nil then
        local message = type(response.error) == "table"
            and response.error.message
            or response.error

        return nil, "Better BibTeX error: " .. tostring(message or "unknown JSON-RPC error")
    end

    return response.result
end

function References.ready(runtime)
    local result, err = References.rpc("api.ready", {}, runtime)

    if not result then
        return nil, err
    end

    if not Util.isNonEmptyString(result.betterbibtex)
        or not Util.isNonEmptyString(result.zotero) then

        return nil, "Better BibTeX answered, but its readiness response was incomplete."
    end

    return {
        betterbibtex = Util.trim(result.betterbibtex),
        zotero = Util.trim(result.zotero),
    }
end

function References.ensureReady(options, runtime)
    options = options or {}

    local ready, firstErr = References.ready(runtime)

    if ready then
        return ready
    end

    local bundleId = options.zoteroBundleId

    if not Util.isNonEmptyString(bundleId) then
        return nil,
            "Zotero/Better BibTeX is unavailable and no zoteroBundleId was supplied: "
                .. tostring(firstErr)
    end

    local launch = runtimeFunction(runtime, "launchBundle", launchBundle)
    local ok, launched, launchErr = pcall(launch, Util.trim(bundleId))

    if not ok or not launched then
        return nil,
            "Could not launch Zotero: " .. tostring(ok and launchErr or launched)
    end

    local retries = tonumber(options.retries) or 40
    local retryDelay = tonumber(options.retryDelay) or 0.25
    local sleeper = runtimeFunction(runtime, "sleep", sleepSeconds)
    local lastErr = firstErr

    for _ = 1, math.max(1, retries) do
        sleeper(retryDelay)
        ready, lastErr = References.ready(runtime)

        if ready then
            return ready
        end
    end

    return nil,
        "Zotero launched, but Better BibTeX/local integration did not become ready: "
            .. tostring(lastErr)
end

local function getJson(url, label, runtime)
    local get = runtimeFunction(runtime, "httpGet", httpGet)
    local ok, status, body, headers = pcall(get, url, API_HEADERS)

    if not ok then
        return nil, "Could not read " .. tostring(label) .. ": " .. tostring(status)
    end

    if status == 403 then
        return nil,
            "Zotero local API access is disabled. Enable Settings → Advanced → “Allow other applications on this computer to communicate with Zotero”."
    end

    if status ~= 200 then
        return nil,
            string.format(
                "Zotero local API returned HTTP %s while reading %s.",
                tostring(status),
                tostring(label)
            )
    end

    local value, decodeErr = decodeJson(body, "Zotero " .. tostring(label) .. " response")

    if not value then
        return nil, decodeErr
    end

    return value, headers
end

local function getText(url, label, runtime)
    local get = runtimeFunction(runtime, "httpGet", httpGet)
    local ok, status, body = pcall(get, url, API_HEADERS)

    if not ok then
        return nil, "Could not read " .. tostring(label) .. ": " .. tostring(status)
    end

    if status == 403 then
        return nil,
            "Zotero local API access is disabled. Enable Settings → Advanced → “Allow other applications on this computer to communicate with Zotero”."
    end

    if status ~= 200 then
        return nil,
            string.format(
                "Zotero local API returned HTTP %s while reading %s.",
                tostring(status),
                tostring(label)
            )
    end

    return tostring(body or "")
end

local function paginatedUrl(url, start)
    local separator = url:find("?", 1, true) and "&" or "?"
    return url
        .. separator
        .. "limit=" .. tostring(References.PAGE_SIZE)
        .. "&start=" .. tostring(start)
end

local function getAllJson(url, label, runtime)
    local result = {}
    local start = 0

    for pageNumber = 1, 1000 do
        local page, err = getJson(
            paginatedUrl(url, start),
            string.format("%s page %d", label, pageNumber),
            runtime
        )

        if not page then
            return nil, err
        end

        if #page == 0 then
            return result
        end

        for _, entry in ipairs(page) do
            table.insert(result, entry)
        end

        if #page < References.PAGE_SIZE then
            return result
        end

        start = start + #page
    end

    return nil, "Zotero pagination exceeded the safety limit while reading " .. tostring(label) .. "."
end

function References.collections(runtime)
    return getJson(
        References.ZOTERO_API_BASE .. "/collections?v=3",
        "collections",
        runtime
    )
end

function References.helperReady(runtime)
    local get = runtimeFunction(runtime, "httpGet", httpGet)
    local ok, status, body = pcall(
        get,
        References.ZOTERO_HELPER_BASE .. "/ready",
        JSON_HEADERS
    )

    if not ok then
        return nil, "Could not contact the Course Workflow Zotero helper: " .. tostring(status)
    end

    if status ~= 200 then
        return nil,
            "Course Workflow Zotero helper is not available. Install zotero/course-workflow-zotero-helper.xpi from the course-workflow repository, then restart Zotero."
    end

    local result, decodeErr = decodeJson(body, "Course Workflow Zotero helper readiness response")

    if not result then
        return nil, decodeErr
    end

    if result.ready ~= true then
        return nil, "Course Workflow Zotero helper answered but did not report ready=true."
    end

    return result
end

local function helperPost(endpoint, payload, label, runtime)
    local post = runtimeFunction(runtime, "httpPost", httpPost)
    local ok, status, body = pcall(
        post,
        References.ZOTERO_HELPER_BASE .. endpoint,
        hs.json.encode(payload or {}),
        JSON_HEADERS
    )

    if not ok then
        return nil, "Could not contact the Course Workflow Zotero helper: " .. tostring(status)
    end

    if status ~= 200 then
        if status == 404 then
            return nil,
                "Course Workflow Zotero helper does not support "
                    .. tostring(label)
                    .. ". Install/update the helper XPI bundled with the current course-workflow version."
        end

        return nil,
            string.format(
                "Course Workflow Zotero helper returned HTTP %s while %s: %s",
                tostring(status),
                tostring(label),
                tostring(body or "")
            )
    end

    local result, decodeErr = decodeJson(body, "Course Workflow Zotero helper " .. tostring(label) .. " response")
    if not result then
        return nil, decodeErr
    end

    return result
end

function References.assignCapturedItems(itemKeys, options, runtime)
    options = options or {}

    if type(itemKeys) ~= "table" or #itemKeys == 0 then
        return nil, "Capture assignment requires at least one Zotero item key."
    end

    local normalized = {}
    local seen = {}

    for _, value in ipairs(itemKeys) do
        if not Util.isNonEmptyString(value) then
            return nil, "Capture assignment item keys must be non-empty strings."
        end

        local key = Util.trim(value)
        if not seen[key] then
            seen[key] = true
            table.insert(normalized, key)
        end
    end

    local unfiled = options.unfiled == true
    local collectionKey = options.collectionKey

    if not unfiled and not Util.isNonEmptyString(collectionKey) then
        return nil, "Course-aware capture requires a stable collectionKey."
    end

    if Util.isNonEmptyString(collectionKey) then
        collectionKey = Util.trim(collectionKey)
    else
        collectionKey = nil
    end

    return helperPost(
        "/assign-capture",
        {
            itemKeys = normalized,
            collectionKey = collectionKey,
            unfiled = unfiled,
        },
        "assigning captured references",
        runtime
    )
end

function References.preflight(options, runtime)
    options = options or {}

    local ready, readyErr = References.ensureReady(options, runtime)

    if not ready then
        return nil, readyErr
    end

    local collections, collectionsErr = References.collections(runtime)

    if not collections then
        return nil, collectionsErr
    end

    local helper
    if options.requireTextbookHelper == true then
        local helperErr
        helper, helperErr = References.helperReady(runtime)
        if not helper then
            return nil, helperErr
        end
    end

    return {
        betterbibtex = ready.betterbibtex,
        zotero = ready.zotero,
        collectionCount = #collections,
        textbookHelper = helper and helper.version or nil,
    }
end

local function entryData(entry)
    if type(entry) ~= "table" then
        return {}
    end

    return type(entry.data) == "table" and entry.data or entry
end

local function entryKey(entry)
    local data = entryData(entry)
    return entry.key or data.key
end

local function entryName(entry)
    return entryData(entry).name
end

local function entryParent(entry)
    return entryData(entry).parentCollection
end

local function isTopLevel(entry)
    local parent = entryParent(entry)
    return parent == false or parent == nil or parent == ""
end

local function indexByKey(collections)
    local result = {}

    for _, entry in ipairs(collections or {}) do
        local key = entryKey(entry)

        if Util.isNonEmptyString(key) then
            result[Util.trim(key)] = entry
        end
    end

    return result
end

local function topLevelNamed(collections, name)
    local matches = {}

    for _, entry in ipairs(collections or {}) do
        if entryName(entry) == name and isTopLevel(entry) then
            table.insert(matches, entry)
        end
    end

    return matches
end

local function childrenNamed(collections, parentKey, name)
    local matches = {}

    for _, entry in ipairs(collections or {}) do
        if entryName(entry) == name and entryParent(entry) == parentKey then
            table.insert(matches, entry)
        end
    end

    return matches
end

function References.personalLibraryID(runtime)
    local libraries, err = References.rpc(
        "user.groups",
        { false },
        runtime
    )

    if type(libraries) ~= "table" then
        return nil,
            "Better BibTeX could not enumerate Zotero libraries: "
                .. tostring(err or "invalid user.groups response")
    end

    -- Better BibTeX implements user.groups() by mapping Zotero.Libraries.getAll().
    -- Zotero orders that list with the personal library first, followed by the
    -- remaining libraries by name. Use the first valid entry rather than
    -- assuming that a specific numeric library ID is globally fixed.
    for _, library in ipairs(libraries) do
        local id = type(library) == "table" and tonumber(library.id) or nil

        if id and id > 0 and id % 1 == 0 then
            return id
        end
    end

    return nil, "Better BibTeX returned no usable personal Zotero library ID."
end

local function collectionPath(semesterName, courseName, libraryID)
    if semesterName:find("/", 1, true) or courseName:find("/", 1, true) then
        return nil,
            "Zotero collection names used by the wizard may not contain '/'. Rename the semester/course display name or create the collection manually."
    end

    libraryID = tonumber(libraryID)

    if not libraryID or libraryID < 1 or libraryID % 1 ~= 0 then
        return nil, "Zotero provisioning requires a valid personal library ID."
    end

    -- Better BibTeX documents // as the personal-library shorthand, but recent
    -- releases resolve the empty library segment as a literal empty lookup and
    -- can fail with "Library  not found". An explicit library ID is stable
    -- across locales and avoids that resolver ambiguity.
    return "/" .. tostring(libraryID) .. "/" .. semesterName .. "/" .. courseName
end

local function verifyConfiguredCollection(collections, collectionKey, semesterName, courseName)
    local byKey = indexByKey(collections)
    local courseCollection = byKey[collectionKey]

    if not courseCollection then
        return nil,
            string.format(
                "Configured Zotero collection key %s does not exist locally. Refusing to repair by collection name.",
                collectionKey
            )
    end

    if entryName(courseCollection) ~= courseName then
        return nil,
            string.format(
                "Configured Zotero collection key %s resolves to %q, not %q.",
                collectionKey,
                tostring(entryName(courseCollection)),
                courseName
            )
    end

    local parentKey = entryParent(courseCollection)
    local semesterCollection = Util.isNonEmptyString(parentKey)
        and byKey[Util.trim(parentKey)]
        or nil

    if not semesterCollection
        or entryName(semesterCollection) ~= semesterName
        or not isTopLevel(semesterCollection) then

        return nil,
            string.format(
                "Configured Zotero collection key %s is not located at %s/%s.",
                collectionKey,
                semesterName,
                courseName
            )
    end

    return true
end

local function assertConfiguredPathUnambiguous(collections, collectionKey, semesterName, courseName)
    local semesters = topLevelNamed(collections, semesterName)

    if #semesters ~= 1 then
        return nil,
            string.format(
                "Configured Zotero path %s/%s is ambiguous because %d top-level semester collections have that name.",
                semesterName,
                courseName,
                #semesters
            )
    end

    local semesterKey = entryKey(semesters[1])
    local courses = childrenNamed(collections, semesterKey, courseName)

    if #courses ~= 1 or entryKey(courses[1]) ~= collectionKey then
        return nil,
            string.format(
                "Configured Zotero path %s/%s is ambiguous or no longer points uniquely to collection key %s.",
                semesterName,
                courseName,
                collectionKey
            )
    end

    return true
end

local function assertNoUnboundCollision(collections, semesterName, courseName)
    local semesters = topLevelNamed(collections, semesterName)

    if #semesters > 1 then
        return nil,
            string.format(
                "More than one top-level Zotero collection is named %q. Refusing ambiguous provisioning.",
                semesterName
            )
    end

    if #semesters == 0 then
        return true
    end

    local semesterKey = entryKey(semesters[1])
    local courses = childrenNamed(collections, semesterKey, courseName)

    if #courses > 0 then
        return nil,
            string.format(
                "Zotero collection %s/%s already exists, but this course has no configured collectionKey. Refusing to bind by name alone. Add the verified key to the course JSON or remove/rename the orphan collection.",
                semesterName,
                courseName
            )
    end

    return true
end

function References.provisionCourse(options, runtime)
    options = options or {}

    local semesterName = options.semesterName
    local courseName = options.courseName
    local exportPath = options.exportPath
    local configuredKey = options.collectionKey

    if not Util.isNonEmptyString(semesterName)
        or not Util.isNonEmptyString(courseName)
        or not Util.isNonEmptyString(exportPath) then

        return nil, "Zotero provisioning requires semesterName, courseName, and exportPath."
    end

    semesterName = Util.trim(semesterName)
    courseName = Util.trim(courseName)
    exportPath = Util.normalizePath(exportPath) or Util.trim(exportPath)

    local exportParent = exportPath:match("^(.*)/[^/]+$")

    if not exportParent or hs.fs.attributes(exportParent, "mode") ~= "directory" then
        return nil, "Bibliography export directory does not exist: " .. tostring(exportParent)
    end

    local _, readyErr = References.ensureReady({
        zoteroBundleId = options.zoteroBundleId,
    }, runtime)

    if readyErr then
        return nil, readyErr
    end

    local libraryID, libraryErr = References.personalLibraryID(runtime)

    if not libraryID then
        return nil, libraryErr
    end

    local path, pathErr = collectionPath(semesterName, courseName, libraryID)

    if not path then
        return nil, pathErr
    end

    local collections, collectionsErr = References.collections(runtime)

    if not collections then
        return nil, collectionsErr
    end

    local replace = false

    if configuredKey ~= nil then
        if not Util.isNonEmptyString(configuredKey) then
            return nil, "Configured Zotero collectionKey is empty."
        end

        configuredKey = Util.trim(configuredKey)

        local verified, verifyErr = verifyConfiguredCollection(
            collections,
            configuredKey,
            semesterName,
            courseName
        )

        if not verified then
            return nil, verifyErr
        end

        local unambiguous, ambiguityErr = assertConfiguredPathUnambiguous(
            collections,
            configuredKey,
            semesterName,
            courseName
        )

        if not unambiguous then
            return nil, ambiguityErr
        end

        replace = true
    else
        local collisionFree, collisionErr = assertNoUnboundCollision(
            collections,
            semesterName,
            courseName
        )

        if not collisionFree then
            return nil, collisionErr
        end
    end

    local result, exportErr = References.rpc(
        "autoexport.add",
        {
            path,
            References.BIBLATEX_TRANSLATOR,
            exportPath,
            {
                exportNotes = false,
                useJournalAbbreviation = false,
            },
            replace,
        },
        runtime
    )

    if not result then
        return nil, exportErr
    end

    if not Util.isNonEmptyString(result.key) then
        return nil, "Better BibTeX created the auto-export but returned no Zotero collection key."
    end

    local returnedKey = Util.trim(result.key)

    if configuredKey and returnedKey ~= configuredKey then
        return nil,
            string.format(
                "Better BibTeX returned collection key %s, but the course is configured for %s.",
                returnedKey,
                configuredKey
            )
    end

    return {
        collectionKey = returnedKey,
        libraryID = result.libraryID,
        autoexportID = result.id,
        collectionPath = path,
        exportPath = exportPath,
        reused = configuredKey ~= nil,
    }
end

local function fetchItem(itemKey, runtime)
    if not Util.isNonEmptyString(itemKey) then
        return nil, "Zotero item key must be a non-empty string."
    end

    return getJson(
        References.ZOTERO_API_BASE .. "/items/" .. percentEncode(Util.trim(itemKey)),
        "item " .. Util.trim(itemKey),
        runtime
    )
end

local function fetchTopBooks(runtime)
    return getJson(
        References.ZOTERO_API_BASE .. "/items/top?itemType=book",
        "book items",
        runtime
    )
end

local function creatorSearchText(creators)
    local parts = {}

    for _, creator in ipairs(creators or {}) do
        if type(creator) == "table" then
            if Util.isNonEmptyString(creator.name) then
                table.insert(parts, creator.name)
            else
                local combined = table.concat({
                    creator.firstName or "",
                    creator.lastName or "",
                }, " ")
                if Util.isNonEmptyString(combined) then
                    table.insert(parts, combined)
                end
            end
        end
    end

    return normalizeText(table.concat(parts, "; "))
end

local function metadataAuthors(metadata)
    if type(metadata.authors) == "table" then
        return metadata.authors
    end

    if not Util.isNonEmptyString(metadata.authors) then
        return {}
    end

    local result = {}

    for author in tostring(metadata.authors):gmatch("[^;]+") do
        author = Util.trim(author)
        if author ~= "" then
            table.insert(result, author)
        end
    end

    return result
end

local function bookMatches(entry, metadata)
    local data = entryData(entry)

    if data.itemType ~= "book" then
        return false
    end

    local wantedIsbn = normalizeIsbn(metadata.isbn)
    local itemIsbn = normalizeIsbn(data.ISBN)

    if wantedIsbn ~= "" and itemIsbn ~= "" and wantedIsbn == itemIsbn then
        return true
    end

    if normalizeText(data.title) ~= normalizeText(metadata.title) then
        return false
    end

    local wantedYear = publicationYear(metadata.date or metadata.year)
    local itemYear = publicationYear(data.date)

    if wantedYear ~= "" and itemYear ~= "" and wantedYear ~= itemYear then
        return false
    end

    local authors = metadataAuthors(metadata)

    if #authors > 0 then
        local wantedAuthor = normalizeText(authors[1])
        local itemAuthors = creatorSearchText(data.creators)

        if wantedAuthor ~= "" and not itemAuthors:find(wantedAuthor, 1, true) then
            return false
        end
    end

    return true
end

local function findExistingBook(metadata, runtime)
    local books, booksErr = fetchTopBooks(runtime)

    if not books then
        return nil, booksErr
    end

    local matches = {}

    for _, entry in ipairs(books) do
        if bookMatches(entry, metadata) then
            table.insert(matches, entry)
        end
    end

    if #matches > 1 then
        return nil,
            string.format(
                "More than one Zotero Book item matches %q. Refusing to guess; merge/fix duplicates or configure bookItemKey explicitly.",
                tostring(metadata.title)
            )
    end

    return matches[1]
end

local function provisionTextbookViaHelper(options, runtime)
    local result, err = helperPost(
        "/provision-textbook",
        options,
        "provisioning the textbook",
        runtime
    )

    if not result then
        return nil, err
    end

    if not Util.isNonEmptyString(result.bookItemKey) then
        return nil, "Course Workflow Zotero helper returned no bookItemKey."
    end

    return result
end

local function citationKeyForItem(itemKey, runtime)
    local result, err = References.rpc("item.citationkey", { { itemKey } }, runtime)

    if not result then
        return nil, err
    end

    for _, key in pairs(result) do
        if Util.isNonEmptyString(key) then
            return Util.trim(key)
        end
    end

    return nil, "Better BibTeX returned no citation key for Zotero item " .. itemKey .. "."
end

local function waitForCitationKey(itemKey, runtime)
    local sleeper = runtimeFunction(runtime, "sleep", sleepSeconds)
    local lastErr

    for _ = 1, References.CITATION_KEY_VERIFY_RETRIES do
        local key, err = citationKeyForItem(itemKey, runtime)

        if key then
            return key
        end

        lastErr = err
        sleeper(References.ASYNC_VERIFY_DELAY)
    end

    return nil, lastErr
end

function References.waitForExportFile(exportPath, runtime)
    if not Util.isNonEmptyString(exportPath) then
        return nil, "Bibliography verification requires exportPath."
    end

    local mode = runtimeFunction(runtime, "fileMode", fileMode)
    local sleeper = runtimeFunction(runtime, "sleep", sleepSeconds)
    exportPath = Util.normalizePath(exportPath) or Util.trim(exportPath)

    -- Better BibTeX auto-export is deliberately debounced. Keep verification
    -- bounded, but allow enough time for the normal delay and a busy Zotero
    -- event loop instead of racing a derived file immediately after mutation.
    for _ = 1, References.EXPORT_VERIFY_RETRIES do
        if mode(exportPath) == "file" then
            return true
        end
        sleeper(References.ASYNC_VERIFY_DELAY)
    end

    return nil,
        "Better BibLaTeX auto-export did not create "
            .. exportPath
            .. " within the bounded verification window."
end

function References.waitForBibKey(exportPath, citationKey, runtime)
    if not Util.isNonEmptyString(exportPath) or not Util.isNonEmptyString(citationKey) then
        return nil, "Bibliography verification requires exportPath and citationKey."
    end

    local sleeper = runtimeFunction(runtime, "sleep", sleepSeconds)
    local wanted = "{" .. Util.trim(citationKey) .. ","

    -- Collection membership changes are durable before Better BibTeX rewrites
    -- the generated .bib file. Give that asynchronous export a realistic,
    -- bounded window rather than treating its debounce delay as a failure.
    for _ = 1, References.EXPORT_VERIFY_RETRIES do
        local contents = Util.readFile(exportPath)

        if type(contents) == "string" and contents:find(wanted, 1, true) then
            return true
        end

        sleeper(References.ASYNC_VERIFY_DELAY)
    end

    return nil,
        string.format(
            "Better BibLaTeX auto-export did not expose citation key %s in %s within the bounded verification window.",
            citationKey,
            exportPath
        )
end


local SKIP_ITEM_TYPES = {
    attachment = true,
    note = true,
    annotation = true,
}

local function firstCreator(data)
    local creators = type(data.creators) == "table" and data.creators or {}
    local selected

    for _, creator in ipairs(creators) do
        if type(creator) == "table" and creator.creatorType == "author" then
            selected = creator
            break
        end
    end

    if not selected then
        for _, creator in ipairs(creators) do
            if type(creator) == "table" then
                selected = creator
                break
            end
        end
    end

    if type(selected) ~= "table" then
        return "Unknown"
    end

    if Util.isNonEmptyString(selected.lastName) then
        return Util.trim(selected.lastName)
    end

    if Util.isNonEmptyString(selected.name) then
        return Util.trim(selected.name)
    end

    if Util.isNonEmptyString(selected.firstName) then
        return Util.trim(selected.firstName)
    end

    return "Unknown"
end

local function citationKeysForItems(itemKeys, runtime)
    if type(itemKeys) ~= "table" or #itemKeys == 0 then
        return {}
    end

    local result, err = References.rpc("item.citationkey", { itemKeys }, runtime)

    if not result then
        return nil, err
    end

    local mapped = {}

    for _, itemKey in ipairs(itemKeys) do
        local value = result[itemKey]

        if not Util.isNonEmptyString(value) then
            for returnedKey, returnedValue in pairs(result) do
                if Util.isNonEmptyString(returnedValue)
                    and tostring(returnedKey):sub(-#itemKey - 1) == ":" .. itemKey then

                    value = returnedValue
                    break
                end
            end
        end

        if Util.isNonEmptyString(value) then
            mapped[itemKey] = Util.trim(value)
        end
    end

    return mapped
end

local function normalizedReferenceRows(entries, collectionKey, runtime)
    local rawByKey = {}
    local orderedKeys = {}

    for _, entry in ipairs(entries or {}) do
        local data = entryData(entry)
        local itemKey = entryKey(entry)
        local itemType = data.itemType

        if Util.isNonEmptyString(itemKey)
            and not SKIP_ITEM_TYPES[itemType] then

            itemKey = Util.trim(itemKey)
            rawByKey[itemKey] = data
            table.insert(orderedKeys, itemKey)
        end
    end

    local citationKeys, citationErr = citationKeysForItems(orderedKeys, runtime)

    if not citationKeys then
        return nil, citationErr
    end

    local rows = {}

    for index, itemKey in ipairs(orderedKeys) do
        local data = rawByKey[itemKey]
        local citationKey = citationKeys[itemKey]

        -- A picker result without a stable BBT key cannot safely be inserted
        -- into a LaTeX document, so omit it rather than inventing another
        -- identity layer.
        if Util.isNonEmptyString(citationKey) then
            local title = Util.isNonEmptyString(data.title)
                and Util.trim(data.title)
                or "Untitled"
            local year = publicationYear(data.date)

            table.insert(rows, {
                index = index,
                itemKey = itemKey,
                citationKey = citationKey,
                title = title,
                author = firstCreator(data),
                year = year ~= "" and year or "n.d.",
                collectionKey = collectionKey,
                doi = Util.isNonEmptyString(data.DOI) and Util.trim(data.DOI) or nil,
                url = Util.isNonEmptyString(data.url) and Util.trim(data.url) or nil,
                itemType = data.itemType,
            })
        end
    end

    return rows
end

local function configuredCollectionKey(course)
    if type(course) ~= "table" then
        return nil, "Reference operation requires a course object."
    end

    local zotero = type(course.zotero) == "table" and course.zotero or nil
    local collectionKey = zotero and zotero.collectionKey or nil

    if not Util.isNonEmptyString(collectionKey) then
        return nil,
            string.format(
                'Course "%s" has no Zotero collectionKey.',
                tostring(course.shortName or course.name or course.id or "?")
            )
    end

    return Util.trim(collectionKey)
end

function References.collectionKey(course)
    return configuredCollectionKey(course)
end

function References.topLevelItemKeys(runtime)
    -- Browser capture only needs a bounded before/after window. Limiting the
    -- baseline avoids scanning an entire long-lived Zotero library on every
    -- save while still safely covering ordinary Connector captures.
    local entries, err = References.recentTopLevelItems(
        References.CAPTURE_RECENT_LIMIT,
        runtime
    )

    if not entries then
        return nil, err
    end

    local keys = {}

    for _, entry in ipairs(entries) do
        local key = entryKey(entry)
        if Util.isNonEmptyString(key) then
            keys[Util.trim(key)] = true
        end
    end

    return keys
end

function References.recentTopLevelItems(limit, runtime)
    limit = tonumber(limit) or References.CAPTURE_RECENT_LIMIT
    limit = math.max(1, math.min(1000, math.floor(limit)))

    return getJson(
        References.ZOTERO_API_BASE
            .. "/items/top?sort=dateAdded&direction=desc&limit="
            .. tostring(limit)
            .. "&v=3",
        "recent top-level references",
        runtime
    )
end

function References.newTopLevelItemsSince(baseline, limit, runtime)
    if type(baseline) ~= "table" then
        return nil, "Reference capture baseline must be a table of Zotero item keys."
    end

    local entries, err = References.recentTopLevelItems(limit, runtime)
    if not entries then
        return nil, err
    end

    local result = {}

    for _, entry in ipairs(entries) do
        local key = entryKey(entry)
        if Util.isNonEmptyString(key) and baseline[Util.trim(key)] ~= true then
            table.insert(result, entry)
        end
    end

    table.sort(result, function(a, b)
        local ad = entryData(a)
        local bd = entryData(b)
        local aDate = tostring(ad.dateAdded or "")
        local bDate = tostring(bd.dateAdded or "")

        if aDate == bDate then
            return tostring(entryKey(a) or "") < tostring(entryKey(b) or "")
        end

        return aDate < bDate
    end)

    return result
end

function References.collection(course, runtime)
    local collectionKey, keyErr = configuredCollectionKey(course)

    if not collectionKey then
        return nil, keyErr
    end

    local collection, err = getJson(
        References.ZOTERO_API_BASE
            .. "/collections/" .. percentEncode(collectionKey)
            .. "?v=3",
        "course collection " .. collectionKey,
        runtime
    )

    if not collection then
        return nil,
            "Configured Zotero collectionKey "
                .. collectionKey
                .. " could not be resolved: "
                .. tostring(err)
    end

    return collection
end

function References.openCollection(course, options, runtime)
    options = options or {}

    local collectionKey, keyErr = configuredCollectionKey(course)

    if not collectionKey then
        return nil, keyErr
    end

    local ready, readyErr = References.ensureReady(options, runtime)

    if not ready then
        return nil, readyErr
    end

    local collection, collectionErr = References.collection(course, runtime)

    if not collection then
        return nil, collectionErr
    end

    local uri = "zotero://select/library/collections/" .. percentEncode(collectionKey)
    local opener = runtimeFunction(runtime, "openURLWithBundle", openURLWithBundle)
    local ok, opened, openErr = pcall(opener, uri, options.zoteroBundleId)

    if not ok or not opened then
        return nil, "Could not open Zotero collection: " .. tostring(ok and openErr or opened)
    end

    return {
        collectionKey = collectionKey,
        collection = collection,
        uri = uri,
    }
end

function References.itemsForCollection(collectionKey, options, runtime)
    options = options or {}

    if not Util.isNonEmptyString(collectionKey) then
        return nil, "Reference retrieval requires a stable collectionKey."
    end

    collectionKey = Util.trim(collectionKey)

    local ready, readyErr = References.ensureReady(options, runtime)

    if not ready then
        return nil, readyErr
    end

    local entries, entriesErr = getAllJson(
        References.ZOTERO_API_BASE
            .. "/collections/" .. percentEncode(collectionKey)
            .. "/items/top?sort=title&direction=asc&v=3",
        "course references",
        runtime
    )

    if not entries then
        return nil, entriesErr
    end

    return normalizedReferenceRows(entries, collectionKey, runtime)
end

function References.itemsForCourse(course, options, runtime)
    local collectionKey, keyErr = configuredCollectionKey(course)

    if not collectionKey then
        return nil, keyErr
    end

    return References.itemsForCollection(collectionKey, options, runtime)
end

function References.allItems(options, runtime)
    options = options or {}

    local ready, readyErr = References.ensureReady(options, runtime)

    if not ready then
        return nil, readyErr
    end

    local entries, entriesErr = getAllJson(
        References.ZOTERO_API_BASE .. "/items/top?sort=title&direction=asc&v=3",
        "all references",
        runtime
    )

    if not entries then
        return nil, entriesErr
    end

    return normalizedReferenceRows(entries, nil, runtime)
end

function References.item(itemKey, runtime)
    if not Util.isNonEmptyString(itemKey) then
        return nil, "Reference itemKey must be a non-empty string."
    end

    itemKey = Util.trim(itemKey)

    return getJson(
        References.ZOTERO_API_BASE
            .. "/items/" .. percentEncode(itemKey)
            .. "?v=3",
        "reference item " .. itemKey,
        runtime
    )
end

function References.resolveCitationKey(citationKey, options, runtime)
    if not Util.isNonEmptyString(citationKey) then
        return nil, "Citation key must be a non-empty string."
    end

    citationKey = Util.trim(citationKey)
    local items, err = References.allItems(options, runtime)

    if not items then
        return nil, err
    end

    local match

    for _, item in ipairs(items) do
        if item.citationKey == citationKey then
            if match then
                return nil,
                    'Citation key "' .. citationKey .. '" resolves to more than one Zotero item.'
            end

            match = item
        end
    end

    if not match then
        return nil, 'No Zotero item uses citation key "' .. citationKey .. '".'
    end

    return match
end

local function pdfAttachmentEntries(itemKey, runtime)
    local children, err = getAllJson(
        References.ZOTERO_API_BASE
            .. "/items/" .. percentEncode(itemKey)
            .. "/children?v=3",
        "reference attachments",
        runtime
    )

    if not children then
        return nil, err
    end

    local attachments = {}

    for _, entry in ipairs(children) do
        local data = entryData(entry)
        local key = entryKey(entry)
        local filename = Util.isNonEmptyString(data.filename) and data.filename or ""
        local contentType = Util.isNonEmptyString(data.contentType) and data.contentType or ""

        if Util.isNonEmptyString(key)
            and data.itemType == "attachment"
            and (
                contentType:lower() == "application/pdf"
                or filename:lower():match("%.pdf$") ~= nil
            ) then

            table.insert(attachments, {
                key = Util.trim(key),
                data = data,
            })
        end
    end

    return attachments
end

local function percentDecodePath(value)
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function fileUrlToPath(url)
    if not Util.isNonEmptyString(url) then
        return nil
    end

    url = Util.trim(url):gsub('^"(.*)"$', "%1")

    local path = url:match("^file://localhost(.*)$")
        or url:match("^file://(.*)$")

    if not path then
        return nil
    end

    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    return percentDecodePath(path)
end

function References.resolvePdfAttachment(itemKey, runtime)
    if not Util.isNonEmptyString(itemKey) then
        return nil, "PDF resolution requires a Zotero itemKey."
    end

    itemKey = Util.trim(itemKey)
    local attachments, err = pdfAttachmentEntries(itemKey, runtime)

    if not attachments then
        return nil, err
    end

    local mode = runtimeFunction(runtime, "fileMode", fileMode)

    for _, attachment in ipairs(attachments) do
        local body = getText(
            References.ZOTERO_API_BASE
                .. "/items/" .. percentEncode(attachment.key)
                .. "/file/view/url",
            "local PDF attachment",
            runtime
        )

        if body then
            local path = fileUrlToPath(body)

            if path and mode(path) == "file" then
                return {
                    itemKey = itemKey,
                    attachmentKey = attachment.key,
                    path = path,
                }
            end
        end
    end

    return nil, "No local PDF attachment is available for Zotero item " .. itemKey .. "."
end

function References.openItem(itemKey, options, runtime)
    options = options or {}

    if not Util.isNonEmptyString(itemKey) then
        return nil, "Opening a Zotero item requires itemKey."
    end

    local ready, readyErr = References.ensureReady(options, runtime)

    if not ready then
        return nil, readyErr
    end

    itemKey = Util.trim(itemKey)

    local item, itemErr = References.item(itemKey, runtime)

    if not item then
        return nil, itemErr
    end

    local uri = "zotero://select/library/items/" .. percentEncode(itemKey)
    local opener = runtimeFunction(runtime, "openURLWithBundle", openURLWithBundle)
    local ok, opened, openErr = pcall(opener, uri, options.zoteroBundleId)

    if not ok or not opened then
        return nil, "Could not open Zotero item: " .. tostring(ok and openErr or opened)
    end

    return {
        itemKey = itemKey,
        item = item,
        uri = uri,
        opened = "zotero",
    }
end

function References.openReference(reference, options, runtime)
    options = options or {}

    local normalized

    if type(reference) == "string" then
        if options.identity == "citationKey" then
            local resolved, resolveErr = References.resolveCitationKey(reference, options, runtime)

            if not resolved then
                return nil, resolveErr
            end

            normalized = resolved
        else
            normalized = { itemKey = reference }
        end
    elseif type(reference) == "table" then
        normalized = reference
    else
        return nil, "Open Reference requires a normalized reference or Zotero itemKey."
    end

    if not Util.isNonEmptyString(normalized.itemKey) then
        return nil, "Open Reference requires a stable Zotero itemKey."
    end

    local ready, readyErr = References.ensureReady(options, runtime)

    if not ready then
        return nil, readyErr
    end

    local itemKey = Util.trim(normalized.itemKey)
    local itemEntry, itemErr = References.item(itemKey, runtime)

    if not itemEntry then
        return nil, itemErr
    end

    local data = entryData(itemEntry)
    local pdf = References.resolvePdfAttachment(itemKey, runtime)

    if pdf then
        local opener = runtimeFunction(runtime, "openFileWithBundle", openFileWithBundle)
        local ok, opened, openErr = pcall(
            opener,
            pdf.path,
            options.skimBundleId
        )

        if not ok or not opened then
            return nil, "Could not open reference PDF in Skim: " .. tostring(ok and openErr or opened)
        end

        return {
            itemKey = itemKey,
            attachmentKey = pdf.attachmentKey,
            opened = "skim",
            path = pdf.path,
        }
    end

    local fallback, fallbackErr = References.openItem(itemKey, options, runtime)

    if not fallback then
        return nil, fallbackErr
    end

    local doi = Util.isNonEmptyString(data.DOI) and Util.trim(data.DOI) or nil
    local url = Util.isNonEmptyString(data.url) and Util.trim(data.url) or nil

    fallback.reason = "Reference PDF is not available locally on this Mac."
    fallback.doi = doi
    fallback.url = url
    fallback.fallbackUrl = doi and ("https://doi.org/" .. doi) or url

    return fallback
end

function References.openCitedPage(citationKey, page, options, runtime)
    options = options or {}

    if not Util.isNonEmptyString(citationKey) then
        return nil, "Open Cited Page requires a citation key."
    end

    page = tonumber(page)

    if not page or page < 1 or page % 1 ~= 0 then
        return nil, "Open Cited Page requires a positive integer page number."
    end

    local reference, resolveErr = References.resolveCitationKey(
        Util.trim(citationKey),
        options,
        runtime
    )

    if not reference then
        return nil, resolveErr
    end

    local pdf, pdfErr = References.resolvePdfAttachment(reference.itemKey, runtime)

    if not pdf then
        local fallback, fallbackErr = References.openReference(reference, options, runtime)
        if not fallback then
            return nil, fallbackErr or pdfErr
        end

        fallback.page = page
        fallback.reason = (fallback.reason or "Reference PDF is not available locally on this Mac.")
            .. " Page navigation therefore could not be performed."
        return fallback
    end

    -- Skim's documented deep-link format uses a one-based physical PDF page.
    -- We do not persist this machine-specific URI; it is constructed only at
    -- the moment the user invokes Open Cited Page.
    local uri = "skim://" .. percentEncodePath(pdf.path) .. "#page=" .. tostring(page)
    local opener = runtimeFunction(runtime, "openURLWithBundle", openURLWithBundle)
    local ok, opened, openErr = pcall(opener, uri, options.skimBundleId)

    if not ok or not opened then
        return nil, "Could not open cited page in Skim: " .. tostring(ok and openErr or opened)
    end

    return {
        itemKey = reference.itemKey,
        citationKey = reference.citationKey,
        attachmentKey = pdf.attachmentKey,
        path = pdf.path,
        page = page,
        pageMode = "numeric-pdf-position",
        uri = uri,
        opened = "skim",
    }
end

function References.provisionTextbook(options, runtime)
    options = options or {}

    local collectionKey = options.collectionKey
    local bookPath = options.bookPath
    local metadata = options.metadata or {}
    local configuredBookItemKey = options.bookItemKey

    if not Util.isNonEmptyString(collectionKey)
        or not Util.isNonEmptyString(bookPath) then

        return nil, "Textbook provisioning requires collectionKey and bookPath."
    end

    collectionKey = Util.trim(collectionKey)
    bookPath = Util.normalizePath(bookPath) or Util.trim(bookPath)

    if hs.fs.attributes(bookPath, "mode") ~= "file" then
        return nil, "Course textbook path is not a readable file: " .. tostring(bookPath)
    end

    local helper, helperErr = References.helperReady(runtime)
    if not helper then
        return nil, helperErr
    end

    local bookItemKey
    local reused = false

    if configuredBookItemKey ~= nil then
        if not Util.isNonEmptyString(configuredBookItemKey) then
            return nil, "Configured Zotero bookItemKey is empty."
        end

        configuredBookItemKey = Util.trim(configuredBookItemKey)
        local bookItem, fetchErr = fetchItem(configuredBookItemKey, runtime)

        if not bookItem then
            return nil,
                "Configured Zotero bookItemKey "
                    .. configuredBookItemKey
                    .. " does not exist locally. Refusing to bind another Book item automatically: "
                    .. tostring(fetchErr)
        end

        if entryData(bookItem).itemType ~= "book" then
            return nil,
                "Configured Zotero bookItemKey "
                    .. configuredBookItemKey
                    .. " does not refer to a Book item."
        end

        bookItemKey = configuredBookItemKey
        reused = true
    else
        local hasIsbn = normalizeIsbn(metadata.isbn) ~= ""

        if not hasIsbn and not Util.isNonEmptyString(metadata.title) then
            return nil, "Textbook metadata requires an ISBN or title before a new Zotero Book item can be provisioned."
        end

        if not hasIsbn and #metadataAuthors(metadata) == 0 then
            return nil, "Textbook metadata requires at least one author when no ISBN is available."
        end

        local existing, existingErr = findExistingBook(metadata, runtime)
        if existingErr then
            return nil, existingErr
        end

        if existing then
            bookItemKey = entryKey(existing)
            reused = true
        end
    end

    local helperResult, writeErr = provisionTextbookViaHelper({
        collectionKey = collectionKey,
        bookItemKey = bookItemKey,
        bookPath = bookPath,
        metadata = {
            title = metadata.title,
            authors = metadataAuthors(metadata),
            year = metadata.year or metadata.date,
            isbn = metadata.isbn,
        },
    }, runtime)

    if not helperResult then
        return nil, writeErr
    end

    local itemKey = Util.trim(helperResult.bookItemKey)
    if bookItemKey and itemKey ~= bookItemKey then
        return nil,
            string.format(
                "Course Workflow Zotero helper returned Book item %s, but provisioning was bound to %s.",
                itemKey,
                bookItemKey
            )
    end

    local citationKey, citationErr = waitForCitationKey(itemKey, runtime)

    -- The helper mutation above is already durable: the Book identity,
    -- collection membership, and linked attachment now exist in Zotero.
    -- Do not turn a delayed Better BibTeX citation/export into a provisioning
    -- failure that encourages callers to roll local state back underneath the
    -- linked attachment. Callers persist bookItemKey first, then verify the
    -- derived bibliography separately.

    return {
        bookItemKey = itemKey,
        citationKey = citationKey,
        citationKeyError = citationKey and nil or citationErr,
        reused = reused or helperResult.reused == true,
        collectionMembershipChanged = helperResult.collectionMembershipChanged == true,
        attachmentKey = helperResult.attachmentKey,
        attachmentReused = helperResult.attachmentReused == true,
        bookPath = bookPath,
        helperVersion = helper.version,
    }
end

return References

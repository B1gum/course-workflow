local Textbook = {}

local Config = require("course.config")
local References = require("course.references")
local Util = require("course.util")

local HOME = os.getenv("HOME") or ""

local function runtimeFunction(runtime, name, fallback)
    if type(runtime) == "table" and type(runtime[name]) == "function" then
        return runtime[name]
    end
    return fallback
end

local function courseLabel(course)
    return course.shortName or course.name or course.id or "course"
end

local function defaultPathMode(path)
    local mode = hs.fs.attributes(path, "mode")
    return mode
end

local function defaultSymlinkMode(path)
    local mode = hs.fs.symlinkAttributes(path, "mode")
    return mode
end

local function defaultChoosePdf(course, currentSource)
    local directory = HOME .. "/Documents"

    if Util.isNonEmptyString(currentSource) then
        local source = Util.normalizePath(currentSource) or Util.trim(currentSource)
        local parent = source:match("^(.*)/[^/]+$")

        if parent and hs.fs.attributes(parent, "mode") == "directory" then
            directory = parent
        end
    end

    local result = hs.dialog.chooseFileOrFolder(
        "Choose textbook PDF for " .. courseLabel(course),
        directory,
        true,
        false,
        false,
        { "pdf" },
        true
    )

    if result and result[1] then
        return result[1]
    end

    return nil
end

local function defaultPromptText(title, message, defaultValue)
    local button, value = hs.dialog.textPrompt(
        title,
        message,
        defaultValue or "",
        "Save",
        "Cancel"
    )

    if button ~= "Save" then
        return nil
    end

    return Util.trim(value or "")
end

local function defaultConfirmExistingIdentity(course)
    local choice = hs.dialog.blockAlert(
        "Change Textbook — " .. courseLabel(course),
        table.concat({
            "This course already has a Zotero Book identity.",
            "",
            "The selected PDF must be another copy/revision of that same bibliographic book.",
            "Replacing the course with an entirely different title/edition is deliberately not automated yet, because the old Zotero item has a linked attachment at literature/book.pdf.",
        }, "\n"),
        "Use Existing Book",
        "Cancel"
    )

    if choice == "Use Existing Book" then
        return true
    end

    return nil
end

local function defaultReadLink(path)
    local command = "/usr/bin/readlink " .. Util.shellQuote(path)
    local output, ok = hs.execute(command)

    if not ok then
        return nil, "Could not read existing textbook symlink."
    end

    output = Util.trim(output or "")

    if output == "" then
        return nil, "Existing textbook symlink has no readable target."
    end

    if output:sub(1, 1) ~= "/" then
        local parent = path:match("^(.*)/[^/]+$") or "."
        output = Util.joinPath(parent, output)
    end

    return output
end

local function temporaryLinkPath(path)
    return string.format(
        "%s.tmp.%d.%06d",
        path,
        os.time(),
        math.random(0, 999999)
    )
end

local function defaultReplaceSymlink(source, linkPath)
    local temporary = temporaryLinkPath(linkPath)
    pcall(os.remove, temporary)

    local command = "/bin/ln -s "
        .. Util.shellQuote(source)
        .. " "
        .. Util.shellQuote(temporary)

    local _, ok = hs.execute(command)

    if not ok then
        pcall(os.remove, temporary)
        return nil, "Could not create temporary textbook symlink."
    end

    local renamed, renameErr = os.rename(temporary, linkPath)

    if not renamed then
        pcall(os.remove, temporary)
        return nil, "Could not install textbook symlink: " .. tostring(renameErr)
    end

    return true
end

local function defaultRemovePath(path)
    local ok, err = os.remove(path)

    if not ok then
        return nil, err
    end

    return true
end

local function callRuntime(runtime, name, fallback, ...)
    local fn = runtimeFunction(runtime, name, fallback)
    local ok, result, err = pcall(fn, ...)

    if not ok then
        return nil, tostring(result)
    end

    if result == false then
        return nil, err or (name .. " failed.")
    end

    return result, err
end

local function sourcePath(course, options, runtime)
    local source = options.source

    if source == nil then
        local chosen, chooseErr = callRuntime(
            runtime,
            "chooseTextbookPdf",
            defaultChoosePdf,
            course,
            course.bookSource
        )

        if chooseErr then
            return nil, chooseErr
        end

        if chosen == nil then
            return nil, nil, true
        end

        source = chosen
    end

    if not Util.isNonEmptyString(source) then
        return nil, "Textbook source must be a PDF path."
    end

    source = Util.normalizePath(source) or Util.trim(source)

    if source:lower():match("%.pdf$") == nil then
        return nil, "Textbook source must be a PDF file."
    end

    local mode, modeErr = callRuntime(
        runtime,
        "pathMode",
        defaultPathMode,
        source
    )

    if modeErr then
        return nil, "Could not inspect textbook source: " .. tostring(modeErr)
    end

    if mode ~= "file" then
        return nil, "Textbook source is not a readable file: " .. source
    end

    return source
end

local function defaultBookTitle(source)
    local filename = tostring(source or ""):match("([^/]+)$") or ""
    filename = filename:gsub("%.[Pp][Dd][Ff]$", "")
    filename = filename:gsub("[_%-]+", " "):gsub("%s+", " ")
    return Util.trim(filename)
end

local function promptValue(runtime, title, message, defaultValue)
    local value, err = callRuntime(
        runtime,
        "promptText",
        defaultPromptText,
        title,
        message,
        defaultValue
    )

    if err then
        return nil, err
    end

    return value
end

local function promptRequired(runtime, title, message, defaultValue)
    while true do
        local value, err = promptValue(
            runtime,
            title,
            message,
            defaultValue
        )

        if err then
            return nil, err
        end

        if value == nil then
            return nil, nil, true
        end

        value = Util.trim(value)

        if value ~= "" then
            return value
        end

        hs.alert.show("This field cannot be empty.")
    end
end

local function collectMetadata(course, source, options, runtime)
    if type(options.metadata) == "table" then
        return {
            title = options.metadata.title,
            authors = options.metadata.authors,
            year = options.metadata.year or options.metadata.date,
            isbn = options.metadata.isbn,
        }
    end

    local title, titleErr, cancelled = promptRequired(
        runtime,
        "Textbook metadata — " .. courseLabel(course),
        "Book title",
        defaultBookTitle(source)
    )

    if cancelled then
        return nil, nil, true
    end

    if not title then
        return nil, titleErr
    end

    local authors, authorsErr
    authors, authorsErr, cancelled = promptRequired(
        runtime,
        "Textbook metadata — " .. courseLabel(course),
        "Author(s)\n\nSeparate multiple authors with semicolons.",
        ""
    )

    if cancelled then
        return nil, nil, true
    end

    if not authors then
        return nil, authorsErr
    end

    local year

    while true do
        local yearErr
        year, yearErr, cancelled = promptRequired(
            runtime,
            "Textbook metadata — " .. courseLabel(course),
            "Publication year",
            ""
        )

        if cancelled then
            return nil, nil, true
        end

        if not year then
            return nil, yearErr
        end

        if year:match("^%d%d%d%d$") then
            break
        end

        hs.alert.show("Publication year must be four digits, for example 2019.")
    end

    local isbn, isbnErr = promptValue(
        runtime,
        "Textbook metadata — " .. courseLabel(course),
        "ISBN (optional; used to avoid duplicate Book items)",
        ""
    )

    if isbnErr then
        return nil, isbnErr
    end

    if isbn == nil then
        return nil, nil, true
    end

    return {
        title = title,
        authors = authors,
        year = year,
        isbn = isbn,
    }
end

local function shouldReuseExistingIdentity(
    course,
    source,
    previousSource,
    existingBookItemKey,
    options,
    runtime
)
    if not Util.isNonEmptyString(existingBookItemKey) then
        return false
    end

    if Util.isNonEmptyString(previousSource) then
        local normalizedPrevious =
            Util.normalizePath(previousSource) or Util.trim(previousSource)

        if normalizedPrevious == source then
            return true
        end
    end

    if options.reuseBookItem == false then
        return nil,
            "Replacing a configured course with an entirely different textbook is not automated safely yet. "
                .. "The existing Zotero Book item has a linked attachment at literature/book.pdf; "
                .. "remove/rehome that old textbook in Zotero first, then clear zotero.bookItemKey before adding the new title."
    end

    if options.reuseBookItem == true then
        return true
    end

    local reuse, err = callRuntime(
        runtime,
        "confirmExistingBookIdentity",
        defaultConfirmExistingIdentity,
        course,
        source
    )

    if err then
        return nil, err
    end

    if reuse == nil then
        return nil, nil, true
    end

    return true
end

local function inspectDestination(course, runtime)
    local literatureMode, literatureErr = callRuntime(
        runtime,
        "pathMode",
        defaultPathMode,
        course.literature
    )

    if literatureErr then
        return nil, "Could not inspect literature folder: " .. tostring(literatureErr)
    end

    if literatureMode ~= "directory" then
        return nil, "Literature folder is missing: " .. tostring(course.literature)
    end

    local linkMode, linkErr = callRuntime(
        runtime,
        "symlinkMode",
        defaultSymlinkMode,
        course.book
    )

    if linkErr then
        return nil, "Could not inspect existing textbook link: " .. tostring(linkErr)
    end

    if linkMode == "link" then
        local target, targetErr = callRuntime(
            runtime,
            "readLink",
            defaultReadLink,
            course.book
        )

        if not target then
            return nil, targetErr
        end

        return {
            existed = true,
            target = target,
        }
    end

    local followedMode, followedErr = callRuntime(
        runtime,
        "pathMode",
        defaultPathMode,
        course.book
    )

    if followedErr then
        return nil, "Could not inspect textbook path: " .. tostring(followedErr)
    end

    if followedMode ~= nil then
        return nil, "Refusing to replace a non-symlink at " .. tostring(course.book)
    end

    return {
        existed = false,
        target = nil,
    }
end

local function installLink(source, course, runtime)
    local installed, installErr = callRuntime(
        runtime,
        "replaceSymlink",
        defaultReplaceSymlink,
        source,
        course.book
    )

    if not installed then
        return nil, installErr
    end

    return true
end

local function restoreLink(previous, course, runtime)
    if previous.existed then
        return callRuntime(
            runtime,
            "replaceSymlink",
            defaultReplaceSymlink,
            previous.target,
            course.book
        )
    end

    local symlinkMode = runtimeFunction(
        runtime,
        "symlinkMode",
        defaultSymlinkMode
    )
    local ok, linkMode = pcall(symlinkMode, course.book)

    if not ok then
        return nil, tostring(linkMode)
    end

    if linkMode ~= "link" then
        return true
    end

    return callRuntime(
        runtime,
        "removePath",
        defaultRemovePath,
        course.book
    )
end

local function appendRollback(message, rollbackOk, rollbackErr)
    if rollbackOk then
        return message
    end

    return message
        .. " Filesystem rollback also failed: "
        .. tostring(rollbackErr)
end

function Textbook.set(course, options, runtime)
    options = options or {}

    if type(course) ~= "table" then
        return nil, "Textbook management requires a course."
    end

    if not Util.isNonEmptyString(course.configPath)
        or not Util.isNonEmptyString(course.book)
        or not Util.isNonEmptyString(course.literature)
        or not Util.isNonEmptyString(course.referencesBib) then

        return nil, "Course textbook paths/configuration are incomplete."
    end

    local collectionKey = course.zotero
        and course.zotero.collectionKey
        or nil

    if not Util.isNonEmptyString(collectionKey) then
        return nil,
            "Course " .. courseLabel(course)
                .. " has no Zotero collectionKey."
    end

    collectionKey = Util.trim(collectionKey)

    local raw, rawErr = Util.readJson(course.configPath)

    if not raw then
        return nil, rawErr
    end

    local oldConfigContents, oldConfigErr = Util.readFile(course.configPath)

    if not oldConfigContents then
        return nil,
            "Could not read existing course config for rollback: "
                .. tostring(oldConfigErr)
    end

    local previousSource = raw.book
        and raw.book.source
        or course.bookSource

    local existingBookItemKey = raw.zotero
        and raw.zotero.bookItemKey
        or nil

    local source, sourceErr, cancelled =
        sourcePath(course, options, runtime)

    if cancelled then
        return {
            cancelled = true,
            course = course,
        }
    end

    if not source then
        return nil, sourceErr
    end

    local reuseExisting, reuseErr, identityCancelled =
        shouldReuseExistingIdentity(
            course,
            source,
            previousSource,
            existingBookItemKey,
            options,
            runtime
        )

    if identityCancelled then
        return {
            cancelled = true,
            course = course,
        }
    end

    if reuseExisting == nil then
        return nil, reuseErr
    end

    local metadata = {}

    if not reuseExisting then
        local metadataErr
        metadata, metadataErr, cancelled =
            collectMetadata(course, source, options, runtime)

        if cancelled then
            return {
                cancelled = true,
                course = course,
            }
        end

        if not metadata then
            return nil, metadataErr
        end
    end

    local global = options.global

    if type(global) ~= "table" then
        local globalErr
        global, globalErr = Config.loadGlobal()

        if not global then
            return nil, globalErr
        end
    end

    local ready, readyErr = References.ensureReady({
        zoteroBundleId = global.zoteroBundleId,
    }, runtime)

    if not ready then
        return nil, readyErr
    end

    local helper, helperErr = References.helperReady(runtime)

    if not helper then
        return nil, helperErr
    end

    local previous, destinationErr = inspectDestination(course, runtime)

    if not previous then
        return nil, destinationErr
    end

    local linked, linkErr = installLink(source, course, runtime)

    if not linked then
        return nil, linkErr
    end

    local provisioned, provisionErr = References.provisionTextbook({
        collectionKey = collectionKey,
        bookItemKey = reuseExisting and existingBookItemKey or nil,
        bookPath = course.book,
        exportPath = course.referencesBib,
        metadata = metadata,
    }, runtime)

    if not provisioned then
        local rollbackOk, rollbackErr = restoreLink(
            previous,
            course,
            runtime
        )

        return nil, appendRollback(
            "Zotero textbook provisioning failed; textbook link was rolled back: "
                .. tostring(provisionErr),
            rollbackOk,
            rollbackErr
        )
    end

    raw.book = type(raw.book) == "table" and raw.book or {}
    raw.book.source = source

    raw.zotero = type(raw.zotero) == "table" and raw.zotero or {}
    raw.zotero.collectionKey = collectionKey
    raw.zotero.bookItemKey = provisioned.bookItemKey

    local encoded = hs.json.encode(raw, true) .. "\n"
    local wrote, writeErr = Util.writeFileAtomic(
        course.configPath,
        encoded
    )

    if not wrote then
        local rollbackOk, rollbackErr = restoreLink(
            previous,
            course,
            runtime
        )

        return nil, appendRollback(
            "Could not update course JSON; textbook link was rolled back. "
                .. "Zotero may already contain the provisioned textbook: "
                .. tostring(writeErr),
            rollbackOk,
            rollbackErr
        )
    end

    local validated, validationErr =
        Config.loadSemester(course.semesterId)

    if not validated then
        local restoredConfig, restoreConfigErr =
            Util.writeFileAtomic(
                course.configPath,
                oldConfigContents
            )

        local rollbackOk, rollbackErr = restoreLink(
            previous,
            course,
            runtime
        )

        local message =
            "Updated course config failed validation and was rolled back: "
                .. tostring(validationErr)

        if not restoredConfig then
            message = message
                .. " Config rollback also failed: "
                .. tostring(restoreConfigErr)
        end

        return nil, appendRollback(
            message,
            rollbackOk,
            rollbackErr
        )
    end

    return {
        cancelled = false,
        course = course,
        source = source,
        bookPath = course.book,
        bookItemKey = provisioned.bookItemKey,
        citationKey = provisioned.citationKey,
        reusedBookItem = provisioned.reused == true,
        reusedPreviousIdentity = reuseExisting == true,
        helperVersion = helper.version,
    }
end

return Textbook

local Wizard = {}

local References = require("course.references")
local Timetable = require("course.timetable")
local Util = require("course.util")

local HOME = os.getenv("HOME")

local CONFIG_ROOT =
    HOME .. "/.config/course-workflow"

local GLOBAL_CONFIG_PATH =
    CONFIG_ROOT .. "/config.json"

-- The semester currently being assembled.
-- Nothing in here has been written to disk yet.
Wizard._draft = nil


local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end


local function showError(message)
    hs.dialog.blockAlert(
        "New Semester",
        message,
        "OK"
    )
end


local function prompt(title, message, defaultValue)
    local button, value = hs.dialog.textPrompt(
        title,
        message,
        defaultValue or "",
        "Next",
        "Cancel"
    )

    if button ~= "Next" then
        return nil
    end

    return trim(value)
end


local function validateSemesterId(id)
    if id == "" then
        return false, "Semester ID cannot be empty."
    end

    if not id:match("^[a-z0-9][a-z0-9_-]*$") then
        return false,
            "Semester ID may contain only lowercase letters, numbers, underscores and hyphens."
    end

    return true
end


local function loadGlobalConfig()
    local config = hs.json.read(GLOBAL_CONFIG_PATH)

    if not config then
        return nil,
            "Could not read:\n\n" .. GLOBAL_CONFIG_PATH
    end

    if type(config.universityRoot) ~= "string"
        or trim(config.universityRoot) == "" then

        return nil,
            "config.json does not contain a valid universityRoot."
    end

    config.universityRoot =
        trim(config.universityRoot):gsub("/+$", "")

    if type(config.zoteroBundleId) ~= "string"
        or trim(config.zoteroBundleId) == "" then

        return nil,
            "config.json does not contain a valid zoteroBundleId."
    end

    config.zoteroBundleId = trim(config.zoteroBundleId)

    return config
end


local function inferSemesterName(id)
    local number = id:match("^sem(%d+)$")

    if number then
        return "Semester " .. number
    end

    return ""
end


local function existingSemesterConfig(id)
    local path =
        CONFIG_ROOT
        .. "/semesters/"
        .. id
        .. "/semester.json"

    -- No existing semester is perfectly fine.
    if not hs.fs.attributes(path) then
        return nil
    end

    local config = hs.json.read(path)

    if not config then
        return false,
            "Existing semester configuration is invalid JSON:\n\n"
            .. path
    end

    return config
end


function Wizard.collectSemester()
    local globalConfig, configError =
        loadGlobalConfig()

    if not globalConfig then
        showError(configError)
        return nil
    end

    local semesterId
    local existing

    while true do
        semesterId = prompt(
            "New Semester",
            "Semester ID\n\nExample: sem5",
            ""
        )

        if semesterId == nil then
            return nil
        end

        semesterId = semesterId:lower()

        local valid, validationError =
            validateSemesterId(semesterId)

        if valid then
            local existingResult, existingError =
                existingSemesterConfig(semesterId)

            if existingResult == false then
                showError(existingError)
                return nil
            end

            existing = existingResult
            break
        end

        showError(validationError)
    end

    local defaultName

    if existing and existing.name then
        defaultName = existing.name
    else
        defaultName = inferSemesterName(semesterId)
    end


    local semesterName

    while true do
        semesterName = prompt(
            "New Semester",
            "Semester display name",
            defaultName
        )

        if semesterName == nil then
            return nil
        end

        if semesterName ~= "" then
            break
        end

        showError(
            "Semester display name cannot be empty."
        )
    end

    local semesterConfigRoot =
        CONFIG_ROOT
        .. "/semesters/"
        .. semesterId

    local universitySemesterRoot =
        globalConfig.universityRoot
        .. "/"
        .. semesterId


    return {
        semester = {
            id = semesterId,
            name = semesterName,
        },

        courses = {},

        paths = {
            configRoot =
                CONFIG_ROOT,

            semesterConfigRoot =
                semesterConfigRoot,

            coursesConfigRoot =
                semesterConfigRoot .. "/courses",

            semesterConfig =
                semesterConfigRoot .. "/semester.json",

            universitySemesterRoot =
                universitySemesterRoot,
        },

        existingSemester = existing,
        globalConfig = globalConfig,
    }
end

function Wizard.courseRoot(draft, slug)
    return draft.paths.universitySemesterRoot
        .. "/"
        .. slug
end


function Wizard.courseConfigPath(draft, slug)
    return draft.paths.coursesConfigRoot
        .. "/"
        .. slug
        .. ".json"
end

local function promptRequired(
    title,
    message,
    defaultValue
)
    while true do
        local value =
            prompt(
                title,
                message,
                defaultValue or ""
            )

        if value == nil then
            return nil
        end

        if value ~= "" then
            return value
        end

        showError(
            "This field cannot be empty."
        )
    end
end


local function suggestSlug(name)
    local slug = name

    -- Danish letters
    slug = slug:gsub("Æ", "ae")
    slug = slug:gsub("æ", "ae")
    slug = slug:gsub("Ø", "o")
    slug = slug:gsub("ø", "o")
    slug = slug:gsub("Å", "aa")
    slug = slug:gsub("å", "aa")

    slug = slug:lower()

    -- Everything except letters/numbers becomes "-"
    slug = slug:gsub("[^a-z0-9]+", "-")

    -- Remove leading/trailing "-"
    slug = slug:gsub("^%-+", "")
    slug = slug:gsub("%-+$", "")

    return slug
end


local function validateCourseSlug(slug)
    if slug == "" then
        return false,
            "Course slug cannot be empty."
    end

    if not slug:match(
        "^[a-z0-9][a-z0-9_-]*$"
    ) then
        return false,
            "Course slug may contain only lowercase letters, "
            .. "numbers, underscores and hyphens."
    end

    return true
end


local function slugAlreadyUsed(
    draft,
    slug
)
    for _, course in ipairs(draft.courses) do
        if course.slug == slug then
            return true
        end
    end

    return false
end


local function validateCourseUrl(url)
    if url:match("^https?://") then
        return true
    end

    return false,
        "Course webpage must begin with http:// or https://."
end


local function chooseOptionalBook(courseName)
    while true do
        local choice = hs.dialog.blockAlert(
            "Textbook — " .. courseName,
            "Does this course have a textbook PDF?",
            "Choose PDF",
            "No textbook"
        )

        if choice == "No textbook" then
            return nil
        end

        local result = hs.dialog.chooseFileOrFolder(
            "Choose textbook PDF for " .. courseName,
            HOME .. "/Documents",
            true,
            false,
            false,
            { "pdf" },
            true
        )

        local path = Util.selectedFilePath(result)

        if path then
            path = hs.fs.pathToAbsolute(path) or path

            if hs.fs.attributes(path, "mode") == "file" then
                return path
            end

            showError("The selected textbook is not a readable file:\n\n" .. tostring(path))
        else
            local cancelledChoice = hs.dialog.blockAlert(
                "Textbook — " .. courseName,
                "No PDF was selected.",
                "Choose Again",
                "No textbook"
            )

            if cancelledChoice == "No textbook" then
                return nil
            end
        end
    end
end

local function defaultBookTitle(bookSource)
    local filename = tostring(bookSource or ""):match("([^/]+)$") or ""
    filename = filename:gsub("%.[Pp][Dd][Ff]$", "")
    filename = filename:gsub("[_%-]+", " "):gsub("%s+", " ")
    return trim(filename)
end


local function collectMissingBookMetadata(draft)
    for _, course in ipairs(draft.courses or {}) do
        local hasBook = course.book
            and course.book.source
            and trim(course.book.source) ~= ""
        local hasStableBookIdentity = course.zotero
            and course.zotero.bookItemKey
            and trim(course.zotero.bookItemKey) ~= ""

        if hasBook and not hasStableBookIdentity then
            local title = promptRequired(
                "Textbook metadata — " .. course.name,
                "Book title",
                defaultBookTitle(course.book.source)
            )

            if title == nil then
                return nil, "Textbook metadata entry was cancelled."
            end

            local authors = promptRequired(
                "Textbook metadata — " .. course.name,
                "Author(s)\n\nSeparate multiple authors with semicolons.",
                ""
            )

            if authors == nil then
                return nil, "Textbook metadata entry was cancelled."
            end

            local year

            while true do
                year = promptRequired(
                    "Textbook metadata — " .. course.name,
                    "Publication year",
                    ""
                )

                if year == nil then
                    return nil, "Textbook metadata entry was cancelled."
                end

                if year:match("^%d%d%d%d$") then
                    break
                end

                showError("Publication year must be four digits, for example 2019.")
            end

            local isbn = prompt(
                "Textbook metadata — " .. course.name,
                "ISBN (optional; used to avoid duplicate Book items)",
                ""
            )

            if isbn == nil then
                return nil, "Textbook metadata entry was cancelled."
            end

            course.book.metadata = {
                title = title,
                authors = authors,
                year = year,
                isbn = isbn,
            }
        end
    end

    return true
end


local function collectOneCourse(
    draft,
    courseNumber
)
    local prefix =
        "Course " .. tostring(courseNumber)

    local name =
        promptRequired(
            prefix,
            "Full course name",
            ""
        )

    if name == nil then
        return nil
    end

    local shortName =
        promptRequired(
            prefix .. " — " .. name,
            "Short course name",
            name
        )

    if shortName == nil then
        return nil
    end

    local code =
        promptRequired(
            prefix .. " — " .. name,
            "Course code",
            ""
        )

    if code == nil then
        return nil
    end

    local slug

    while true do
        slug =
            prompt(
                prefix .. " — " .. name,
                "Folder slug",
                suggestSlug(name)
            )

        if slug == nil then
            return nil
        end

        slug = slug:lower()

        local valid, errorMessage =
            validateCourseSlug(slug)

        if not valid then
            showError(errorMessage)

        elseif slugAlreadyUsed(
            draft,
            slug
        ) then

            showError(
                "Another course in this semester "
                    .. "already uses the slug:\n\n"
                    .. slug
            )

        else
            break
        end
    end

    local courseUrl

    while true do
        courseUrl =
            prompt(
                prefix .. " — " .. name,
                "Course webpage URL",
                "https://"
            )

        if courseUrl == nil then
            return nil
        end

        local valid, errorMessage =
            validateCourseUrl(courseUrl)

        if valid then
            break
        end

        showError(errorMessage)
    end

    local bookSource =
        chooseOptionalBook(name)

    local timetable

    while true do
        local timetableText =
            prompt(
                prefix .. " — " .. name,

                "Weekly timetable\n\n"
                    .. "Enter all fixed weekly classes separated by semicolons.\n"
                    .. "Each class must last 2 or 4 hours and use boundaries "
                    .. "8, 10, 12, 14, or 16.\n\n"
                    .. "Example:\nMon 12-16; Thu 8-10\n\n"
                    .. "Leave blank if this course has no fixed weekly slot.",

                ""
            )

        if timetableText == nil then
            return nil
        end

        local timetableError
        timetable, timetableError = Timetable.parse(timetableText)

        if timetable then
            local conflicts = Timetable.conflicts(
                timetable,
                draft.courses,
                nil
            )

            if #conflicts == 0 then
                break
            end

            local choice = hs.dialog.blockAlert(
                "Timetable conflict — " .. name,
                "This overlap is allowed. During the overlap, timetable-only context will refuse to guess which course is active.\n\n"
                    .. tostring(Timetable.conflictSummary(conflicts, name)),
                "Keep Conflict",
                "Edit Timetable"
            )

            if choice == "Keep Conflict" then
                break
            end
        else
            showError(timetableError)
        end
    end

    local course = {
        -- We deliberately freeze id = slug.
        id = slug,

        name = name,
        shortName = shortName,
        code = code,
        slug = slug,

        courseUrl = courseUrl,

        timetable = timetable,
    }


    if bookSource then
        course.book = {
            source = bookSource,
        }
    end


    return course
end


function Wizard.collectCourses(draft)
    local courseNumber =
        #draft.courses + 1

    while true do
        local course =
            collectOneCourse(
                draft,
                courseNumber
            )

        if not course then
            print(
                "New Semester cancelled during course entry. "
                    .. "Nothing was written."
            )

            return nil
        end


        table.insert(
            draft.courses,
            course
        )


        print(
            "Added course:"
        )

        print(
            hs.inspect(course)
        )

        local nextAction =
            hs.dialog.blockAlert(
                "Course added",
                course.name
                    .. "\n\n"
                    .. Wizard.courseRoot(
                        draft,
                        course.slug
                    ),

                "Add Another",
                "Preview Semester"
            )


        if nextAction
            == "Preview Semester" then

            break
        end


        courseNumber =
            courseNumber + 1
    end


    return Wizard.previewSemester(
        draft
    )
end

local function previewBook(course)
    if course.book
        and course.book.source then

        return course.book.source
    end

    return "None"
end


local function buildSemesterPreview(draft)
    local lines = {}

    table.insert(
        lines,
        draft.semester.name
            .. " ("
            .. draft.semester.id
            .. ")"
    )

    table.insert(lines, "")

    table.insert(
        lines,
        "Semester root:"
    )

    table.insert(
        lines,
        draft.paths.universitySemesterRoot
    )

    table.insert(lines, "")


    for index, course
        in ipairs(draft.courses) do

        table.insert(
            lines,
            string.format(
                "%d. %s",
                index,
                course.name
            )
        )

        table.insert(
            lines,
            "Code: "
                .. course.code
        )

        table.insert(
            lines,
            "Short name: "
                .. course.shortName
        )

        table.insert(
            lines,
            "Slug: "
                .. course.slug
        )

        table.insert(
            lines,
            "Folder:"
        )

        table.insert(
            lines,
            Wizard.courseRoot(
                draft,
                course.slug
            )
        )

        table.insert(
            lines,
            "Webpage: "
                .. course.courseUrl
        )

        table.insert(
            lines,
            "Book: "
                .. previewBook(course)
        )

        table.insert(
            lines,
            "Timetable: "
                .. (Timetable.format(course.timetable) ~= "" and Timetable.format(course.timetable) or "None")
        )

        table.insert(lines, "")
    end


    return table.concat(
        lines,
        "\n"
    )
end


function Wizard.previewSemester(draft)
    if not draft
        or not draft.courses
        or #draft.courses == 0 then

        showError(
            "No courses have been entered."
        )

        return nil
    end


    local preview =
        buildSemesterPreview(draft)

    print(
        "\n===== New Semester Preview ====="
    )

    print(preview)

    local action =
        hs.dialog.blockAlert(
            "Create semester?",
            preview,
            "Create",
            "Cancel"
        )


    if action ~= "Create" then
        print(
            "Semester creation cancelled. "
                .. "Nothing was written."
        )

        return draft
    end

    return Wizard.commit(draft)
end

local NOTES_MASTER_TEMPLATE =
    CONFIG_ROOT .. "/templates/notes/master.tex"

local function pathExists(path)
    if hs.fs.attributes(path) then
        return true
    end

    -- Important for dangling symlinks:
    if hs.fs.symlinkAttributes(path) then
        return true
    end

    return false
end


local function parentPath(path)
    return path:match("^(.*)/[^/]+$")
end


local function mkdirp(path)
    local mode = hs.fs.attributes(path, "mode")

    if mode then
        if mode == "directory" then
            return true, "existing"
        end

        return nil,
            "Path exists but is not a directory: " .. path
    end

    -- Catch dangling symlinks or other link weirdness.
    if hs.fs.symlinkAttributes(path) then
        return nil,
            "Path is a symbolic link, not a directory: " .. path
    end

    local parent = parentPath(path)

    if parent and parent ~= "" and parent ~= path then
        local ok, err = mkdirp(parent)

        if not ok then
            return nil, err
        end
    end

    local ok, err = hs.fs.mkdir(path)

    if ok then
        return true, "created"
    end

    -- Handle the unlikely case where something created it
    -- between our check and mkdir().
    if hs.fs.attributes(path, "mode") == "directory" then
        return true, "existing"
    end

    return nil, err
end


local function readFile(path)
    local file, err = io.open(path, "rb")

    if not file then
        return nil, err
    end

    local contents = file:read("*a")
    file:close()

    return contents
end


local function atomicWrite(path, contents, replace)
    if pathExists(path) and not replace then
        return nil, "File already exists: " .. path
    end

    local parent = parentPath(path)

    if parent then
        local ok, err = mkdirp(parent)

        if not ok then
            return nil, err
        end
    end

    local temporaryPath =
        path
        .. ".tmp-"
        .. tostring(os.time())
        .. "-"
        .. tostring(math.random(100000, 999999))

    local file, err = io.open(temporaryPath, "wb")

    if not file then
        return nil, err
    end

    local ok, writeErr = file:write(contents)

    if not ok then
        file:close()
        os.remove(temporaryPath)
        return nil, writeErr
    end

    file:flush()
    file:close()

    local renamed, renameErr =
        os.rename(temporaryPath, path)

    if not renamed then
        os.remove(temporaryPath)
        return nil, renameErr
    end

    return true
end

local function decodeJsonFile(path)
    local contents, readErr = readFile(path)

    if not contents then
        return nil, readErr
    end

    local ok, value =
        pcall(hs.json.decode, contents)

    if not ok or type(value) ~= "table" then
        return nil, "Invalid JSON: " .. path
    end

    return value
end


local function deepEqual(a, b)
    if type(a) ~= type(b) then
        return false
    end

    if type(a) ~= "table" then
        return a == b
    end

    for key, value in pairs(a) do
        if not deepEqual(value, b[key]) then
            return false
        end
    end

    for key, _ in pairs(b) do
        if a[key] == nil then
            return false
        end
    end

    return true
end


local function writeJsonSafely(path, data, allowReplace)
    local exists = pathExists(path)

    if exists then
        -- Configuration files managed by this wizard should
        -- themselves not be symlinks.
        if hs.fs.symlinkAttributes(path) then
            return nil,
                "Refusing to replace configuration symlink: "
                .. path
        end

        local existing, err =
            decodeJsonFile(path)

        if not existing then
            return nil, err
        end

        if deepEqual(existing, data) then
            return "existing"
        end

        if not allowReplace then
            return "skipped",
                "Existing configuration differs and was preserved: "
                .. path
        end
    end

    local encoded =
        hs.json.encode(data, true) .. "\n"

    local ok, err =
        atomicWrite(path, encoded, exists and allowReplace)

    if not ok then
        return nil, err
    end

    -- validate immediately after writing.
    local validated, validationErr =
        decodeJsonFile(path)

    if not validated then
        return nil,
            "JSON validation failed after write: "
            .. tostring(validationErr)
    end

    if exists then
        return "updated"
    end

    return "created"
end

local function newReport()
    return {
        created = {},
        updated = {},
        existing = {},
        skipped = {},
        errors = {},
    }
end


local function addReport(report, category, message)
    table.insert(report[category], message)
end


local function recordStatus(
    report,
    status,
    label,
    extra
)
    if not status then
        addReport(
            report,
            "errors",
            label .. ": " .. tostring(extra)
        )

        return false
    end

    if status == "created" then
        addReport(report, "created", label)

    elseif status == "updated" then
        addReport(report, "updated", label)

    elseif status == "existing" then
        addReport(report, "existing", label)

    elseif status == "skipped" then
        addReport(
            report,
            "skipped",
            label
                .. (extra and (" — " .. extra) or "")
        )
    end

    return true
end


local function formatReport(report)
    local sections = {
        { "CREATED", report.created },
        { "UPDATED", report.updated },
        { "ALREADY EXISTS", report.existing },
        { "SKIPPED", report.skipped },
        { "ERROR", report.errors },
    }

    local result = {}

    for _, section in ipairs(sections) do
        local title = section[1]
        local values = section[2]

        table.insert(
            result,
            string.format(
                "%s (%d)",
                title,
                #values
            )
        )

        if #values == 0 then
            table.insert(result, "  —")
        else
            for _, value in ipairs(values) do
                table.insert(
                    result,
                    "  " .. value
                )
            end
        end

        table.insert(result, "")
    end

    return table.concat(result, "\n")
end


local function showReport(report)
    local detailed =
        formatReport(report)

    print("\n===== Semester Setup Report =====")
    print(detailed)

    local summary = string.format(
        "Created: %d\n"
            .. "Updated: %d\n"
            .. "Already exists: %d\n"
            .. "Skipped: %d\n"
            .. "Errors: %d\n\n"
            .. "Full details are in the Hammerspoon console.",
        #report.created,
        #report.updated,
        #report.existing,
        #report.skipped,
        #report.errors
    )

    hs.dialog.blockAlert(
        #report.errors == 0
            and "Semester setup complete"
            or "Semester setup completed with errors",
        summary,
        "OK"
    )
end

local function semesterJsonFromDraft(draft)
    local courseIds = {}

    for _, course in ipairs(draft.courses) do
        table.insert(
            courseIds,
            course.id or course.slug
        )
    end

    return {
        id = draft.semester.id,
        name = draft.semester.name,
        courses = courseIds,
    }
end


local function courseJsonFromDraft(course)
    local result = {
        id = course.id or course.slug,
        name = course.name,
        shortName = course.shortName,
        code = course.code,
        slug = course.slug,

        courseUrl = course.courseUrl,

        timetable = course.timetable or {},
    }

    local bookSource

    if course.book then
        bookSource = course.book.source
    elseif course.bookSource then
        bookSource = course.bookSource
    end

    if bookSource
        and trim(bookSource) ~= "" then

        result.book = {
            source = trim(bookSource),
        }
    end

    if course.zotero
        and course.zotero.collectionKey
        and trim(course.zotero.collectionKey) ~= "" then

        result.zotero = {
            collectionKey =
                trim(course.zotero.collectionKey),
        }

        if course.zotero.bookItemKey
            and trim(course.zotero.bookItemKey) ~= "" then

            result.zotero.bookItemKey =
                trim(course.zotero.bookItemKey)
        end
    end

    return result
end

local function validateDraftForCommit(draft)
    local errors = {}

    if not draft
        or not draft.semester then

        table.insert(
            errors,
            "No semester draft exists."
        )

        return false, errors
    end

    if type(draft.courses) ~= "table"
        or #draft.courses == 0 then

        table.insert(
            errors,
            "The semester contains no courses."
        )
    end

    local seenSlugs = {}

    for index, course in ipairs(draft.courses or {}) do
        local prefix =
            "Course " .. tostring(index) .. ": "

        if not course.slug
            or trim(course.slug) == "" then

            table.insert(
                errors,
                prefix .. "missing slug."
            )

        elseif seenSlugs[course.slug] then
            table.insert(
                errors,
                prefix
                    .. "duplicate slug "
                    .. course.slug
                    .. "."
            )

        else
            seenSlugs[course.slug] = true
        end

        if course.id
            and course.slug
            and course.id ~= course.slug then

            table.insert(
                errors,
                prefix
                    .. "id and slug must be identical."
            )
        end

        if not course.name
            or trim(course.name) == "" then

            table.insert(
                errors,
                prefix .. "missing name."
            )
        end

        if not course.shortName
            or trim(course.shortName) == "" then

            table.insert(
                errors,
                prefix .. "missing short name."
            )
        end

        if not course.code
            or trim(course.code) == "" then

            table.insert(
                errors,
                prefix .. "missing course code."
            )
        end

        if not course.courseUrl
            or trim(course.courseUrl) == "" then

            table.insert(
                errors,
                prefix .. "missing course URL."
            )
        end

        local bookSource =
            course.book
            and course.book.source
            or course.bookSource

        if bookSource
            and trim(bookSource) ~= ""
            and not hs.fs.attributes(bookSource) then

            table.insert(
                errors,
                prefix
                    .. "textbook does not exist:\n"
                    .. bookSource
            )
        end
    end

    if hs.fs.attributes(
        NOTES_MASTER_TEMPLATE,
        "mode"
    ) ~= "file" then

        table.insert(
            errors,
            "Notes template is missing:\n"
                .. NOTES_MASTER_TEMPLATE
        )
    end

    return #errors == 0, errors
end

local function hydrateExistingZoteroIdentity(draft)
    for _, course in ipairs(draft.courses or {}) do
        local path = Wizard.courseConfigPath(draft, course.slug)

        if pathExists(path) then
            local existing, existingErr = decodeJsonFile(path)

            if not existing then
                return nil, existingErr
            end

            local existingZotero = existing.zotero
            existing.zotero = nil

            local desired = courseJsonFromDraft(course)
            desired.zotero = nil

            if not deepEqual(existing, desired) then
                return nil,
                    "Existing course configuration differs from the wizard input and was preserved: "
                        .. path
                        .. "\nResolve the course metadata difference before Zotero provisioning."
            end

            existing.zotero = existingZotero

            if existing.zotero ~= nil then
                if type(existing.zotero) ~= "table" then
                    return nil, "Existing course has invalid zotero configuration: " .. path
                end

                if existing.zotero.collection ~= nil then
                    return nil,
                        "Existing course still uses legacy name-based zotero.collection: "
                            .. path
                            .. "\nReplace it with a verified zotero.collectionKey before rerunning the wizard."
                end

                if not existing.zotero.collectionKey
                    or trim(existing.zotero.collectionKey) == "" then

                    return nil, "Existing course has an empty zotero.collectionKey: " .. path
                end

                course.zotero = {
                    collectionKey = trim(existing.zotero.collectionKey),
                }

                if existing.zotero.bookItemKey ~= nil then
                    if type(existing.zotero.bookItemKey) ~= "string"
                        or trim(existing.zotero.bookItemKey) == "" then

                        return nil, "Existing course has an invalid zotero.bookItemKey: " .. path
                    end

                    course.zotero.bookItemKey =
                        trim(existing.zotero.bookItemKey)
                end
            end
        end
    end

    return true
end

local function writeProvisionedCourseConfig(draft, course, report)
    local path = Wizard.courseConfigPath(draft, course.slug)
    local status, extra = writeJsonSafely(
        path,
        courseJsonFromDraft(course),
        true
    )

    return recordStatus(report, status, path, extra)
end

local function provisionCourseReferences(draft, course, report)
    local root = Wizard.courseRoot(draft, course.slug)
    local exportPath = root .. "/references/references.bib"
    local configuredKey = course.zotero and course.zotero.collectionKey or nil

    local result, err = References.provisionCourse({
        semesterName = draft.semester.name,
        courseName = course.name,
        collectionKey = configuredKey,
        exportPath = exportPath,
        zoteroBundleId = draft.globalConfig.zoteroBundleId,
    })

    if not result then
        addReport(
            report,
            "errors",
            "Zotero provisioning for " .. course.name .. ": " .. tostring(err)
        )
        return false
    end

    course.zotero = {
        collectionKey = result.collectionKey,
        bookItemKey = course.zotero and course.zotero.bookItemKey or nil,
    }

    addReport(
        report,
        result.reused and "existing" or "created",
        string.format(
            "Zotero collection %s/%s [%s]",
            draft.semester.name,
            course.name,
            result.collectionKey
        )
    )

    addReport(
        report,
        result.reused and "updated" or "created",
        "Better BibLaTeX auto-export -> " .. exportPath
    )

    -- Persist stable identity before waiting on the derived export so a
    -- failed/slow BBT verification can be resumed safely on the next run.
    if not writeProvisionedCourseConfig(draft, course, report) then
        return false
    end

    local exportReady, exportErr = References.waitForExportFile(exportPath)

    if not exportReady then
        addReport(
            report,
            "errors",
            "Bibliography export for " .. course.name .. ": " .. tostring(exportErr)
        )
        return false
    end

    addReport(report, "existing", "Verified bibliography export -> " .. exportPath)
    return true
end

local function preflightZotero(draft)
    local universityRoot = draft.globalConfig
        and draft.globalConfig.universityRoot
        or nil

    if not universityRoot
        or hs.fs.attributes(universityRoot, "mode") ~= "directory" then

        return nil,
            "University root does not exist or is not a directory:\n"
                .. tostring(universityRoot)
    end

    local needsTextbookHelper = false

    for _, course in ipairs(draft.courses or {}) do
        if course.book
            and course.book.source
            and trim(course.book.source) ~= "" then

            needsTextbookHelper = true
            break
        end
    end

    return References.preflight({
        zoteroBundleId = draft.globalConfig.zoteroBundleId,
        requireTextbookHelper = needsTextbookHelper,
    })
end


local function provisionCourseTextbook(draft, course, report)
    if not course.book
        or not course.book.source
        or trim(course.book.source) == "" then

        return true
    end

    if not course.zotero
        or not course.zotero.collectionKey then

        addReport(
            report,
            "errors",
            "Cannot provision textbook for "
                .. course.name
                .. " without a stable Zotero collectionKey."
        )
        return false
    end

    local root = Wizard.courseRoot(draft, course.slug)
    local bookPath = root .. "/literature/book.pdf"
    local exportPath = root .. "/references/references.bib"
    local metadata = course.book.metadata or {}

    local result, err = References.provisionTextbook({
        collectionKey = course.zotero.collectionKey,
        bookItemKey = course.zotero.bookItemKey,
        bookPath = bookPath,
        metadata = metadata,
    })

    if not result then
        addReport(
            report,
            "errors",
            "Textbook Zotero provisioning for "
                .. course.name
                .. ": "
                .. tostring(err)
        )
        return false
    end

    course.zotero.bookItemKey = result.bookItemKey

    -- Persist durable textbook identity before waiting on Better BibTeX's
    -- derived auto-export. A slow export must not lose the Book binding on the
    -- next idempotent run.
    if not writeProvisionedCourseConfig(draft, course, report) then
        return false
    end

    addReport(
        report,
        result.reused and "existing" or "created",
        string.format(
            "Zotero Book %s [%s] -> %s",
            course.name,
            result.bookItemKey,
            result.citationKey or "(citation key pending)"
        )
    )

    addReport(
        report,
        result.attachmentReused and "existing" or "created",
        "Linked textbook attachment -> " .. bookPath
    )

    if not Util.isNonEmptyString(result.citationKey) then
        addReport(
            report,
            "errors",
            "Textbook citation key for "
                .. course.name
                .. " is still pending: "
                .. tostring(result.citationKeyError)
        )
        return false
    end

    local exported, exportErr = References.waitForBibKey(
        exportPath,
        result.citationKey
    )

    if not exported then
        addReport(
            report,
            "errors",
            "Textbook bibliography export for "
                .. course.name
                .. ": "
                .. tostring(exportErr)
        )
        return false
    end

    addReport(
        report,
        "existing",
        "Verified textbook citation in bibliography -> " .. exportPath
    )

    return true
end


local function validateCourseReferenceSetup(draft, course, report)
    local root = Wizard.courseRoot(draft, course.slug)
    local exportPath = root .. "/references/references.bib"
    local collectionKey = course.zotero and course.zotero.collectionKey or nil

    if not collectionKey then
        addReport(report, "errors", "Reference validation for " .. course.name .. ": missing collectionKey")
        return false
    end

    local collection, collectionErr = References.collection(course)

    if not collection then
        addReport(
            report,
            "errors",
            "Reference validation for " .. course.name .. ": " .. tostring(collectionErr)
        )
        return false
    end

    if hs.fs.attributes(exportPath, "mode") ~= "file" then
        addReport(
            report,
            "errors",
            "Reference validation for " .. course.name .. ": bibliography export is missing: " .. exportPath
        )
        return false
    end

    local hasBook = course.book
        and course.book.source
        and trim(course.book.source) ~= ""

    if hasBook then
        local bookItemKey = course.zotero.bookItemKey

        if not bookItemKey then
            addReport(report, "errors", "Reference validation for " .. course.name .. ": missing bookItemKey")
            return false
        end

        local item, itemErr = References.item(bookItemKey)

        if not item then
            addReport(
                report,
                "errors",
                "Reference validation for " .. course.name .. ": " .. tostring(itemErr)
            )
            return false
        end

        local data = type(item.data) == "table" and item.data or item

        if data.itemType ~= "book" then
            addReport(
                report,
                "errors",
                "Reference validation for " .. course.name .. ": configured bookItemKey is not a Zotero Book"
            )
            return false
        end

        local member = false

        for _, key in ipairs(type(data.collections) == "table" and data.collections or {}) do
            if key == collectionKey then
                member = true
                break
            end
        end

        if not member then
            addReport(
                report,
                "errors",
                "Reference validation for " .. course.name .. ": textbook is not in the stable course collection"
            )
            return false
        end

        local pdf, pdfErr = References.resolvePdfAttachment(bookItemKey)

        if not pdf then
            addReport(
                report,
                "errors",
                "Reference validation for " .. course.name .. ": textbook linked PDF is unavailable: " .. tostring(pdfErr)
            )
            return false
        end
    end

    addReport(
        report,
        "existing",
        "Validated Zotero/reference setup for " .. course.name .. " [" .. tostring(collectionKey) .. "]"
    )
    return true
end


local function writeConfiguration(draft, report)
    local configDirectories = {
        draft.paths.semesterConfigRoot,
        draft.paths.coursesConfigRoot,
    }

    for _, path in ipairs(configDirectories) do
        local ok, statusOrError =
            mkdirp(path)

        if ok then
            recordStatus(
                report,
                statusOrError,
                path
            )
        else
            addReport(
                report,
                "errors",
                path
                    .. ": "
                    .. tostring(statusOrError)
            )

            return false
        end
    end

    local semesterData =
        semesterJsonFromDraft(draft)

    local status, extra =
        writeJsonSafely(
            draft.paths.semesterConfig,
            semesterData,

            -- This is deliberately true.
            true
        )

    if not recordStatus(
        report,
        status,
        draft.paths.semesterConfig,
        extra
    ) then
        return false
    end

    for _, course in ipairs(draft.courses) do
        local data =
            courseJsonFromDraft(course)

        local path =
            Wizard.courseConfigPath(
                draft,
                course.slug
            )

        local courseStatus,
            courseExtra =
            writeJsonSafely(
                path,
                data,

                -- Existing course config with different
                -- contents is preserved rather than
                -- silently overwritten.
                false
            )

        if not recordStatus(
            report,
            courseStatus,
            path,
            courseExtra
        ) then
            return false
        end
    end

    return true
end


local function renderNotesTemplate(
    template,
    draft,
    course
)
    local replacements = {
        ["{{COURSE_NAME}}"] =
            course.name,

        ["{{COURSE_SHORT_NAME}}"] =
            course.shortName,

        ["{{COURSE_CODE}}"] =
            course.code,

        ["{{SEMESTER_ID}}"] =
            draft.semester.id,

        ["{{SEMESTER_NAME}}"] =
            draft.semester.name,
    }

    local result = template

    for token, replacement
        in pairs(replacements) do

        result = result:gsub(
            token,
            function()
                return replacement
            end
        )
    end

    return result
end


local function scaffoldCourse(
    draft,
    course,
    report
)
    local root =
        Wizard.courseRoot(
            draft,
            course.slug
        )

    local directories = {
        root,

        root .. "/notes",
        root .. "/notes/lectures",
        root .. "/notes/figures",
        root .. "/notes/.build",

        root .. "/assignments",
        root .. "/assignments/figures",

        root .. "/matlab",

        root .. "/literature",

        root .. "/references",
    }

    for _, path in ipairs(directories) do
        local ok, statusOrError =
            mkdirp(path)

        if ok then
            recordStatus(
                report,
                statusOrError,
                path
            )
        else
            addReport(
                report,
                "errors",
                path
                    .. ": "
                    .. tostring(statusOrError)
            )

            return false
        end
    end

    local referencesIgnorePath = root .. "/references/.gitignore"

    if pathExists(referencesIgnorePath) then
        addReport(report, "existing", referencesIgnorePath .. " (preserved)")
    else
        local ignoreContents = table.concat({
            "# External research PDFs are owned by Zotero, not the course repository.",
            "*.pdf",
            "*.PDF",
            "",
        }, "\n")
        local ignored, ignoreErr = atomicWrite(referencesIgnorePath, ignoreContents, false)

        if not ignored then
            addReport(report, "errors", referencesIgnorePath .. ": " .. tostring(ignoreErr))
            return false
        end

        addReport(report, "created", referencesIgnorePath)
    end

    local masterPath =
        root .. "/notes/master.tex"

    if pathExists(masterPath) then
        addReport(
            report,
            "existing",
            masterPath
                .. " (preserved)"
        )

        return true
    end

    local template, templateError =
        readFile(NOTES_MASTER_TEMPLATE)

    if not template then
        addReport(
            report,
            "errors",
            "Could not read notes template: "
                .. tostring(templateError)
        )

        return false
    end

    local rendered =
        renderNotesTemplate(
            template,
            draft,
            course
        )

    local written, writeError =
        atomicWrite(
            masterPath,
            rendered,
            false
        )

    if not written then
        addReport(
            report,
            "errors",
            masterPath
                .. ": "
                .. tostring(writeError)
        )

        return false
    end

    addReport(
        report,
        "created",
        masterPath
    )

    return true
end


local function createBookSymlink(
    draft,
    course,
    report
)
    local bookSource =
        course.book
        and course.book.source
        or course.bookSource

    local root =
        Wizard.courseRoot(
            draft,
            course.slug
        )

    local linkPath =
        root .. "/literature/book.pdf"

    if not bookSource
        or trim(bookSource) == "" then

        addReport(
            report,
            "skipped",
            linkPath
                .. " — no textbook configured"
        )

        return true
    end

    bookSource = trim(bookSource)

    local linkAttributes =
        hs.fs.symlinkAttributes(linkPath)

    if linkAttributes then
        local wanted =
            hs.fs.pathToAbsolute(bookSource)
            or bookSource

        local actual =
            hs.fs.pathToAbsolute(
                linkAttributes.target
            )
            or linkAttributes.target

        if wanted == actual then
            addReport(
                report,
                "existing",
                linkPath
            )
        else
            addReport(
                report,
                "errors",
                linkPath
                    .. " — existing symlink points elsewhere"
            )
            return false
        end

        return true
    end

    if hs.fs.attributes(linkPath) then
        addReport(
            report,
            "errors",
            linkPath
                .. " — expected textbook symlink but found an existing file"
        )

        return false
    end

    local ok, err =
        hs.fs.link(
            bookSource,
            linkPath,
            true
        )

    if not ok then
        addReport(
            report,
            "errors",
            linkPath
                .. ": "
                .. tostring(err)
        )

        return false
    end

    local verify =
        hs.fs.symlinkAttributes(linkPath)

    if not verify then
        addReport(
            report,
            "errors",
            linkPath
                .. ": symlink could not be verified"
        )

        return false
    end

    addReport(
        report,
        "created",
        linkPath
            .. " -> "
            .. bookSource
    )

    return true
end


function Wizard.commit(draft)
    local valid, validationErrors =
        validateDraftForCommit(draft)

    if not valid then
        showError(
            "Cannot create semester:\n\n"
                .. table.concat(
                    validationErrors,
                    "\n\n"
                )
        )

        return nil
    end

    local identityOK, identityErr =
        hydrateExistingZoteroIdentity(draft)

    if not identityOK then
        showError(
            "Cannot safely provision Zotero:\n\n"
                .. tostring(identityErr)
        )
        return nil
    end

    local zoteroReady, zoteroErr =
        preflightZotero(draft)

    if not zoteroReady then
        showError(
            "Cannot safely provision Zotero:\n\n"
                .. tostring(zoteroErr)
        )
        return nil
    end

    local metadataOK, metadataErr =
        collectMissingBookMetadata(draft)

    if not metadataOK then
        showError(
            "Cannot provision course textbook:\n\n"
                .. tostring(metadataErr)
        )
        return nil
    end

    local report =
        newReport()


    local configurationOK =
        writeConfiguration(
            draft,
            report
        )

    -- If configuration cannot be written safely,
    -- stop before touching academic directories.
    if not configurationOK then
        showReport(report)
        return report
    end



    for _, course in ipairs(draft.courses) do
        local scaffoldOK =
            scaffoldCourse(
                draft,
                course,
                report
            )

        if scaffoldOK then
            local bookOK = createBookSymlink(
                draft,
                course,
                report
            )

            if bookOK then
                local referencesOK = provisionCourseReferences(
                    draft,
                    course,
                    report
                )

                if referencesOK then
                    local textbookOK = provisionCourseTextbook(
                        draft,
                        course,
                        report
                    )

                    if textbookOK then
                        validateCourseReferenceSetup(
                            draft,
                            course,
                            report
                        )
                    end
                end
            end
        end
    end

    showReport(report)

    return report
end

function Wizard.start()
    Wizard._draft = nil

    local draft = Wizard.collectSemester()

    if not draft then
        return
    end

    Wizard._draft = draft

    print("New Semester draft:")
    print(hs.inspect(draft))

    -- Once Wizard.collectCourses() exists, starting the wizard
    -- automatically proceeds to course entry.
    if type(Wizard.collectCourses) == "function" then
        return Wizard.collectCourses(draft)
    end

    hs.dialog.blockAlert(
        "New Semester — Setup-initialization complete",
        draft.semester.name
            .. "\n\nID: "
            .. draft.semester.id
            .. "\n\nUniversity folder:\n"
            .. draft.paths.universitySemesterRoot
            .. "\n\nNothing has been written yet.",
        "OK"
    )

    return draft
end


function Wizard.currentDraft()
    return Wizard._draft
end


return Wizard

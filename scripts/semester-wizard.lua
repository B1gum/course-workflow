local Wizard = {}

local HOME = os.getenv("HOME")

local CONFIG_ROOT =
    HOME .. "/.config/course-workflow"

local GLOBAL_CONFIG_PATH =
    CONFIG_ROOT .. "/config.json"

-- The semester currently being assembled.
-- Nothing in here has been written to disk yet.
Wizard._draft = nil


-- ============================================================
-- Helpers
-- ============================================================

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


-- ============================================================
-- Phase 7
-- ============================================================

function Wizard.collectSemester()
    local globalConfig, configError =
        loadGlobalConfig()

    if not globalConfig then
        showError(configError)
        return nil
    end


    ------------------------------------------------------------
    -- Semester ID
    ------------------------------------------------------------

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


    ------------------------------------------------------------
    -- Semester display name
    ------------------------------------------------------------

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


    ------------------------------------------------------------
    -- Build the in-memory draft
    ------------------------------------------------------------

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
    }
end


-- ============================================================
-- Derived paths
-- These become useful immediately in phases 8 and 9.
-- ============================================================

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


-- ============================================================
-- Start wizard
-- ============================================================

function Wizard.start()
    Wizard._draft = nil

    local draft = Wizard.collectSemester()

    if not draft then
        return
    end

    Wizard._draft = draft

    print("New Semester draft:")
    print(hs.inspect(draft))

    -- Phase 8 extension point:
    --
    -- Once Wizard.collectCourses() exists, starting the wizard
    -- automatically proceeds to course entry.
    if type(Wizard.collectCourses) == "function" then
        return Wizard.collectCourses(draft)
    end

    -- Temporary Phase 7 ending.
    hs.dialog.blockAlert(
        "New Semester — Phase 7 complete",
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

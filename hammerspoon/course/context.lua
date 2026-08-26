local Context = {}

local Util = require("course.util")
local Registry = require("course.registry")
local State = require("course.state")

local HOME = os.getenv("HOME") or ""
local NVIM_STATE_ROOT = HOME .. "/.local/state/course-workflow/nvim"

Context.LEVEL = {
    EXPLICIT = "A",
    PATH = "B",
    MANUAL = "C",
    TIMETABLE = "D",
    -- Backwards-compatible alias for older callers.
    CALENDAR = "D",
}

Context.WORK_CONTEXT = {
    NOTES = "notes",
    ASSIGNMENT = "assignment",
    EXERCISES = "exercises",
}

Context.SOURCE = {
    EXPLICIT = "explicit",
    EXPLICIT_PATH = "explicit-path",
    NEOVIM_PATH = "neovim-path",
    SKIM_PATH = "skim-path",
    FINDER_PATH = "finder-path",
    MANUAL_COURSE = "manual-course",
    TIMETABLE = "timetable",
    -- Backwards-compatible alias; Level D no longer queries Calendar.app.
    CALENDAR = "timetable",
}

Context.ERROR = {
    NO_COURSE = "No course context available.",
}

local VALID_LEVELS = {
    A = true,
    B = true,
    C = true,
    D = true,
}

local VALID_WORK_CONTEXTS = {
    notes = true,
    assignment = true,
    exercises = true,
}

local function isPositiveInteger(value)
    return type(value) == "number"
        and value >= 1
        and value % 1 == 0
end

local function resolveCourseReference(value)
    local courseId

    if type(value) == "string" then
        if not Util.isNonEmptyString(value) then
            return nil, "Explicit course must be a non-empty course ID."
        end

        courseId = Util.trim(value)

    elseif type(value) == "table" then
        if not Util.isNonEmptyString(value.id) then
            return nil, "Course object must contain a valid id."
        end

        courseId = Util.trim(value.id)

    else
        return nil, "Course must be a course ID or course object."
    end

    local course, err = Registry.getCourse(courseId)

    if not course then
        if err then
            return nil, err
        end

        return nil,
            string.format(
                'Unknown course "%s" in the active semester.',
                courseId
            )
    end

    return course
end

function Context.makeResult(options)
    if type(options) ~= "table" then
        return nil, "Context result options must be a table."
    end

    -- Assignment identity is deliberately NOT tracked.
    if options.assignment ~= nil then
        return nil,
            "Assignment identity is not tracked; use workContext = \"assignment\"."
    end

    local course = options.course

    if type(course) ~= "table"
        or not Util.isNonEmptyString(course.id) then

        return nil, "Context result requires a valid course object."
    end

    local level = options.level

    if not VALID_LEVELS[level] then
        return nil, 'Context result level must be "A", "B", "C", or "D".'
    end

    local workContext = options.workContext

    if workContext ~= nil
        and not VALID_WORK_CONTEXTS[workContext] then

        return nil,
            'Context workContext must be "notes", "assignment", "exercises", or nil.'
    end

    local lecture = options.lecture

    if lecture ~= nil and not isPositiveInteger(lecture) then
        return nil, "Context lecture must be a positive integer or nil."
    end

    if lecture ~= nil
        and workContext ~= Context.WORK_CONTEXT.NOTES then

        return nil, "A lecture can only exist in notes context."
    end

    if not Util.isNonEmptyString(options.source) then
        return nil, "Context result requires a source."
    end

    local confidence = options.confidence or "exact"

    if confidence ~= "exact" then
        return nil,
            'Context confidence currently only supports "exact".'
    end

    local path = nil

    if options.path ~= nil then
        if not Util.isNonEmptyString(options.path) then
            return nil, "Context path must be a non-empty string or nil."
        end

        path = Util.normalizePath(options.path)

        if not path then
            return nil, "Context path could not be normalized."
        end
    end

    return {
        course = course,
        workContext = workContext,
        lecture = lecture,
        level = level,
        source = Util.trim(options.source),
        confidence = confidence,
        path = path,
    }
end

function Context.resolveExplicit(options)
    if options == nil then
        return nil
    end

    if type(options) ~= "table" then
        return nil, "Context options must be a table or nil."
    end

    if options.assignment ~= nil then
        return nil,
            "Assignment identity is not tracked; use workContext = \"assignment\"."
    end

    if options.course == nil then
        if options.workContext ~= nil
            or options.lecture ~= nil then

            return nil,
                "Explicit work context or lecture requires an explicit course."
        end

        return nil
    end

    local course, courseErr = resolveCourseReference(options.course)

    if not course then
        return nil, courseErr
    end

    local workContext = options.workContext

    if workContext == nil and options.lecture ~= nil then
        workContext = Context.WORK_CONTEXT.NOTES
    end

    return Context.makeResult({
        course = course,
        workContext = workContext,
        lecture = options.lecture,
        level = Context.LEVEL.EXPLICIT,
        source = Context.SOURCE.EXPLICIT,
        confidence = "exact",
    })
end

local function lectureNumberFromPath(path, course)
    local normalized = Util.normalizePath(path)
    local lecturesRoot = Util.normalizePath(course.notes.lectures)

    if not normalized or not lecturesRoot then
        return nil
    end

    if not Util.isPathWithin(normalized, lecturesRoot) then
        return nil
    end

    if normalized == lecturesRoot then
        return nil
    end

    -- Only direct children of notes/lectures/ count as lecture files.
    local relative = normalized:sub(#lecturesRoot + 2)

    if relative:find("/", 1, true) then
        return nil
    end

    -- At least two digits:
    -- lec_01.tex   -> valid
    -- lec_07.tex   -> valid
    -- lec_123.tex  -> valid
    -- lec_7.tex    -> invalid
    -- lec_07_old.tex -> invalid
    local digits = relative:match("^lec_(%d%d+)%.tex$")

    if not digits then
        return nil
    end

    local number = tonumber(digits)

    if not number or number < 1 then
        return nil
    end

    return number
end

function Context.lectureFromPath(path, courseReference)
    local course, err = resolveCourseReference(courseReference)

    if not course then
        return nil, err
    end

    return lectureNumberFromPath(path, course)
end

function Context.resolvePath(path, source)
    if not Util.isNonEmptyString(path) then
        return nil, "Path context requires a non-empty path."
    end

    local normalized = Util.normalizePath(path)

    if not normalized then
        return nil, "Could not normalize path."
    end

    local course, courseErr = Registry.courseFromPath(normalized)

    if not course then
        if courseErr then
            return nil, courseErr
        end

        -- Exact path exists, but it is not inside a configured course.
        return nil
    end

    local workContext = nil
    local lecture = nil

    if Util.isPathWithin(normalized, course.notes.root) then
        workContext = Context.WORK_CONTEXT.NOTES
        lecture = lectureNumberFromPath(normalized, course)

    elseif Util.isPathWithin(normalized, course.assignments.root) then
        workContext = Context.WORK_CONTEXT.ASSIGNMENT

        -- Deliberately do NOT derive assignment identity from filename.
    elseif Util.isPathWithin(normalized, course.exercises.root) then
        workContext = Context.WORK_CONTEXT.EXERCISES
    end

    return Context.makeResult({
        course = course,
        workContext = workContext,
        lecture = lecture,
        level = Context.LEVEL.PATH,
        source = source or Context.SOURCE.EXPLICIT_PATH,
        confidence = "exact",
        path = normalized,
    })
end

function Context.latestAssignmentFile(courseReference)
    local course, courseErr = resolveCourseReference(courseReference)

    if not course then
        return nil, courseErr
    end

    local root = course.assignments.root

    if hs.fs.attributes(root, "mode") ~= "directory" then
        return nil,
            string.format(
                'Assignment directory does not exist for "%s": %s',
                course.id,
                root
            )
    end

    local bestPath = nil
    local bestCreation = nil
    local bestModification = nil

    for name in hs.fs.dir(root) do
        if name ~= "."
            and name ~= ".."
            and name:match("%.tex$") then

            local path = Util.joinPath(root, name)
            local attributes = hs.fs.attributes(path)

            if attributes and attributes.mode == "file" then
                local creation = attributes.creation
                    or attributes.modification
                    or 0

                local modification = attributes.modification or 0

                local isBetter = false

                if bestPath == nil then
                    isBetter = true

                elseif creation > bestCreation then
                    isBetter = true

                elseif creation == bestCreation
                    and modification > bestModification then

                    isBetter = true

                elseif creation == bestCreation
                    and modification == bestModification
                    and path > bestPath then

                    -- Deterministic final tie-break.
                    isBetter = true
                end

                if isBetter then
                    bestPath = path
                    bestCreation = creation
                    bestModification = modification
                end
            end
        end
    end

    if not bestPath then
        return nil,
            string.format(
                'No assignment .tex files exist for "%s".',
                course.id
            )
    end

    return bestPath
end

local function currentITermTTY()
    local ok, result = hs.osascript.applescript([[
        tell application "iTerm2"
            if not (exists current window) then
                return ""
            end if

            return tty of current session of current window
        end tell
    ]])

    if not ok or not Util.isNonEmptyString(result) then
        return nil
    end

    local tty = Util.trim(result)
    tty = tty:gsub("^/dev/", "")

    if tty == "" then
        return nil
    end

    return tty
end

local function currentNeovimPath()
    local tty = currentITermTTY()

    if not tty then
        return nil
    end

    local statePath = Util.joinPath(
        NVIM_STATE_ROOT,
        tty .. ".json"
    )

    if hs.fs.attributes(statePath, "mode") ~= "file" then
        return nil
    end

    local contents = Util.readFile(statePath)

    if not contents then
        return nil
    end

    local ok, state = pcall(hs.json.decode, contents)

    if not ok or type(state) ~= "table" then
        return nil
    end

    if not Util.isNonEmptyString(state.path)
        or not Util.isNonEmptyString(state.tty)
        or type(state.pid) ~= "number"
        or state.pid < 1
        or state.pid % 1 ~= 0 then

        return nil
    end

    local stateTTY = Util.trim(state.tty):gsub("^/dev/", "")

    if stateTTY ~= tty then
        return nil
    end

    -- Verify that the recorded Neovim process still exists
    -- and still belongs to this terminal.
    local ttyOutput, ttyOk = hs.execute(
        string.format(
            "/bin/ps -p %d -o tty= 2>/dev/null",
            state.pid
        )
    )

    if not ttyOk or not Util.isNonEmptyString(ttyOutput) then
        return nil
    end

    local processTTY = Util.trim(ttyOutput):gsub("^/dev/", "")

    if processTTY ~= tty then
        return nil
    end

    local commandOutput, commandOk = hs.execute(
        string.format(
            "/bin/ps -p %d -o comm= 2>/dev/null",
            state.pid
        )
    )

    if not commandOk or not Util.isNonEmptyString(commandOutput) then
        return nil
    end

    local command = Util.trim(commandOutput)
    local executable = command:match("([^/]+)$")

    if executable ~= "nvim" then
        return nil
    end

    return Util.normalizePath(state.path)
end

local function currentSkimPath()
    local ok, result = hs.osascript.applescript([[
        tell application "Skim"
            if (count of documents) = 0 then
                return ""
            end if

            set documentFile to file of front document

            if documentFile is missing value then
                return ""
            end if

            return POSIX path of documentFile
        end tell
    ]])

    if not ok or not Util.isNonEmptyString(result) then
        return nil
    end

    return Util.normalizePath(result)
end

local function currentFinderPath()
    local ok, result = hs.osascript.applescript([[
        tell application "Finder"
            set selectedItems to selection

            if (count of selectedItems) = 1 then
                return POSIX path of (item 1 of selectedItems as alias)
            end if

            if (count of Finder windows) > 0 then
                return POSIX path of (target of front Finder window as alias)
            end if

            return ""
        end tell
    ]])

    if not ok or not Util.isNonEmptyString(result) then
        return nil
    end

    return Util.normalizePath(result)
end

function Context.currentPathEvidence()
    local snapshot, snapshotErr = Registry.snapshot()

    if not snapshot then
        return nil, nil, snapshotErr
    end

    local application = hs.application.frontmostApplication()

    if not application then
        return nil
    end

    local bundleId = application:bundleID()
    local global = snapshot.global

    if bundleId == global.itermBundleId then
        local path = currentNeovimPath()

        if path then
            return path, Context.SOURCE.NEOVIM_PATH
        end

        return nil

    elseif bundleId == global.skimBundleId then
        local path = currentSkimPath()

        if path then
            return path, Context.SOURCE.SKIM_PATH
        end

        return nil

    elseif bundleId == "com.apple.finder" then
        local path = currentFinderPath()

        if path then
            return path, Context.SOURCE.FINDER_PATH
        end

        return nil
    end

    return nil
end

function Context.resolvePathContext(options)
    options = options or {}

    -- Useful for future callers that already possess
    -- an authoritative filesystem path.
    if options.path ~= nil then
        return Context.resolvePath(
            options.path,
            options.pathSource or Context.SOURCE.EXPLICIT_PATH
        )
    end

    local path, source, evidenceErr = Context.currentPathEvidence()

    if evidenceErr then
        return nil, evidenceErr
    end

    if not path then
        return nil
    end

    return Context.resolvePath(path, source)
end

local function copyArray(values)
    local result = {}

    for index, value in ipairs(values or {}) do
        result[index] = value
    end

    return result
end

local WEEKDAY_BY_WDAY = {
    [1] = "sunday",
    [2] = "monday",
    [3] = "tuesday",
    [4] = "wednesday",
    [5] = "thursday",
    [6] = "friday",
    [7] = "saturday",
}

local function timetableNow(runtime)
    if type(runtime) == "table" and type(runtime.now) == "table" then
        return runtime.now
    end

    return os.date("*t")
end

local function timetableSlotKey(course, slot)
    return string.format(
        "%s::%s::%02d-%02d",
        course.id,
        slot.day,
        slot.start,
        slot["end"]
    )
end

function Context.currentTimetableContext(runtime)
    local now = timetableNow(runtime)

    if type(now.wday) ~= "number"
        or type(now.hour) ~= "number" then

        return nil, "Could not determine current local timetable time."
    end

    local day = WEEKDAY_BY_WDAY[now.wday]

    if not day then
        return nil, "Could not determine current timetable weekday."
    end

    local minute = now.min or 0
    local second = now.sec or 0
    local currentMinutes = now.hour * 60 + minute + second / 60

    local courses, coursesErr = Registry.allCourses()

    if not courses then
        return nil, coursesErr
    end

    local matches = {}
    local coursesById = {}

    for _, course in ipairs(courses) do
        for _, slot in ipairs(course.timetable or {}) do
            local startMinutes = slot.start * 60
            local endMinutes = slot["end"] * 60

            -- Start-inclusive, end-exclusive. Adjacent slots therefore never
            -- overlap at the exact boundary (e.g. 10:00 belongs to 10-12).
            if slot.day == day
                and currentMinutes >= startMinutes
                and currentMinutes < endMinutes then

                table.insert(matches, {
                    course = course,
                    key = timetableSlotKey(course, slot),
                    slot = slot,
                })

                coursesById[course.id] = course
            end
        end
    end

    if #matches == 0 then
        return nil
    end

    local courseCount = 0
    local onlyCourse = nil

    for _, course in pairs(coursesById) do
        courseCount = courseCount + 1
        onlyCourse = course
    end

    if courseCount ~= 1 then
        local ids = {}

        for courseId in pairs(coursesById) do
            table.insert(ids, courseId)
        end

        table.sort(ids)

        return nil,
            "Timetable context is ambiguous: "
                .. table.concat(ids, ", ")
                .. " are active at the same time. Choose a course explicitly or use path/manual context."
    end

    local slotKeys = {}

    for _, match in ipairs(matches) do
        table.insert(slotKeys, match.key)
    end

    table.sort(slotKeys)

    return {
        course = onlyCourse,
        eventKeys = slotKeys, -- compatibility with existing override shape users
        slotKeys = slotKeys,
    }
end

-- Compatibility only: this function no longer touches Calendar.app.
Context.currentCalendarContext = Context.currentTimetableContext

local function timetableEvidence(runtime)
    if type(runtime) == "table" then
        if runtime.timetableError ~= nil then
            return nil, runtime.timetableError
        end

        if runtime.timetableContext ~= nil then
            if runtime.timetableContext == false then
                return nil
            end

            return runtime.timetableContext
        end

        -- Backwards-compatible test/runtime injection names.
        if runtime.calendarError ~= nil then
            return nil, runtime.calendarError
        end

        if runtime.calendarContext ~= nil then
            if runtime.calendarContext == false then
                return nil
            end

            return runtime.calendarContext
        end
    end

    return Context.currentTimetableContext(runtime)
end

local function timetableKeys(timetableContext)
    if not timetableContext then
        return {}
    end

    return copyArray(
        timetableContext.slotKeys
            or timetableContext.eventKeys
            or {}
    )
end

local function manualOverrideBaseline(timetableContext)
    return {
        version = 2,
        semesterId = State.getActiveSemester(),
        baselineKnown = true,
        timetableSlotKeys = timetableKeys(timetableContext),
    }
end

local function overrideHasNewSlot(override, timetableContext)
    if not timetableContext then
        return false
    end

    local baseline = {}

    for _, key in ipairs(override.timetableSlotKeys or {}) do
        baseline[key] = true
    end

    for _, key in ipairs(timetableKeys(timetableContext)) do
        if not baseline[key] then
            return true
        end
    end

    return false
end

function Context.activateManualCourse(courseReference, runtime)
    local course, courseErr = resolveCourseReference(courseReference)

    if not course then
        return nil, courseErr
    end

    local timetableContext = nil
    local timetableErr = nil

    if State.getTimetableAutoSwitchEnabled() then
        timetableContext, timetableErr = timetableEvidence(runtime)
    end

    local override

    if timetableErr then
        -- Manual selection must not fail due to a timetable/config error.
        -- Preserve the manual course and establish a fresh baseline after the
        -- next successful timetable resolution.
        override = {
            version = 2,
            semesterId = State.getActiveSemester(),
            baselineKnown = false,
            timetableSlotKeys = {},
        }
    else
        override = manualOverrideBaseline(timetableContext)
    end

    local ok, stateErr = State.setManualCourse(course.id)

    if not ok then
        return nil, stateErr
    end

    ok, stateErr = State.setManualOverrideState(override)

    if not ok then
        State.clearManualCourse()
        return nil, stateErr
    end

    return course
end

function Context.resolveManual(timetableContext, timetableErr)
    local courseId = State.getManualCourse()

    if not courseId then
        return nil
    end

    local course, courseErr = Registry.getCourse(courseId)

    if not course then
        if courseErr then
            return nil, courseErr
        end

        State.clearManualCourse()
        State.clearManualOverrideState()
        return nil
    end

    if State.getTimetableAutoSwitchEnabled() then
        if not timetableErr then
            local override = State.getManualOverrideState()
            local activeSemester = State.getActiveSemester()

            local validOverride = type(override) == "table"
                and override.version == 2
                and override.semesterId == activeSemester
                and type(override.baselineKnown) == "boolean"
                and type(override.timetableSlotKeys) == "table"

            if not validOverride or override.baselineKnown ~= true then
                override = manualOverrideBaseline(timetableContext)
                State.setManualOverrideState(override)

            elseif overrideHasNewSlot(override, timetableContext) then
                -- A configured class slot that was not active when the manual
                -- course was selected has begun. Level C expires; Level D wins.
                State.clearManualCourse()
                State.clearManualOverrideState()
                return nil
            end
        end
    end

    return Context.makeResult({
        course = course,
        workContext = nil,
        lecture = nil,
        level = Context.LEVEL.MANUAL,
        source = Context.SOURCE.MANUAL_COURSE,
        confidence = "exact",
    })
end

function Context.resolveTimetable(timetableContext, timetableErr)
    if not State.getTimetableAutoSwitchEnabled() then
        return nil
    end

    if timetableErr then
        return nil, timetableErr
    end

    if not timetableContext then
        return nil
    end

    local course = timetableContext.course

    if type(course) ~= "table" or not Util.isNonEmptyString(course.id) then
        return nil, "Timetable context did not contain a valid course."
    end

    local registered, courseErr = Registry.getCourse(course.id)

    if not registered then
        return nil, courseErr or 'Timetable resolved an unknown course "' .. course.id .. '".'
    end

    return Context.makeResult({
        course = registered,
        workContext = nil,
        lecture = nil,
        level = Context.LEVEL.TIMETABLE,
        source = Context.SOURCE.TIMETABLE,
        confidence = "exact",
    })
end

-- Compatibility alias for older callers.
Context.resolveCalendar = Context.resolveTimetable

function Context.resolve(options, runtime)
    local result, err = Context.resolveExplicit(options)

    if result or err then
        return result, err
    end

    result, err = Context.resolvePathContext(options)

    if result or err then
        return result, err
    end

    local timetableContext = nil
    local timetableErr = nil

    if State.getTimetableAutoSwitchEnabled() then
        timetableContext, timetableErr = timetableEvidence(runtime)
    end

    result, err = Context.resolveManual(timetableContext, timetableErr)

    if result or err then
        return result, err
    end

    result, err = Context.resolveTimetable(timetableContext, timetableErr)

    if result or err then
        return result, err
    end

    return nil, Context.ERROR.NO_COURSE
end

function Context.resolveOrNotify(options, runtime)
    local result, err = Context.resolve(options, runtime)

    if result then
        return result
    end

    hs.alert.show(err or Context.ERROR.NO_COURSE)
    return nil, err or Context.ERROR.NO_COURSE
end

return Context

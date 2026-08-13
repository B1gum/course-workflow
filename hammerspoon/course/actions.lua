local Actions = {}

local Config = require("course.config")
local Context = require("course.context")
local Registry = require("course.registry")
local State = require("course.state")
local Util = require("course.util")
local Lectures = require("course.lectures")
local LaTeX = require("course.latex")
local Figures = require("course.figures")

Actions.ERROR = {
    NO_WORK_CONTEXT = "No work context available.",
    NO_LECTURE = "No current lecture context available.",
}

Actions.SPEC = {
    setActiveSemester = {
        part = "VI",
        implemented = true,
        context = false,
    },
    setActiveCourse = {
        part = "VI",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    newSemester = {
        part = "VII",
        implemented = true,
        context = false,
    },
    reloadConfiguration = {
        part = "VII",
        implemented = true,
        context = false,
    },
    setTimetableAutoSwitchEnabled = {
        part = "XV",
        implemented = true,
        context = false,
    },
    -- Compatibility alias retained for old custom bindings.
    setCalendarAutoSwitchEnabled = {
        part = "XV",
        implemented = true,
        context = false,
    },

    launchCourse = {
        part = "VIII",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    openCourseRoot = {
        part = "XVI",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    openNotesFolder = {
        part = "XVI",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    openLecturesFolder = {
        part = "XVI",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    openNotesFigures = {
        part = "XVI",
        implemented = true,
        context = true,
        requirements = { course = true },
    },

    openNotes = {
        part = "X",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    newLecture = {
        part = "X",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    chooseLecture = {
        part = "X",
        implemented = true,
        context = true,
        requirements = { course = true },
    },

    openAssignments = {
        part = "XVI",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    openAssignmentFigures = {
        part = "XVI",
        implemented = true,
        context = true,
        requirements = { course = true },
    },

    newFigure = {
        part = "XII",
        implemented = true,
        context = true,
        requirements = { course = true, workContext = true },
    },
    findFigure = {
        part = "XII",
        implemented = true,
        context = true,
        requirements = { course = true, workContext = true },
    },

    openMatlab = {
        part = "XIII",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    openMatlabFolder = {
        part = "XIII",
        implemented = true,
        context = true,
        requirements = { course = true },
    },

    openLiterature = {
        part = "XIV",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    openLiteratureFolder = {
        part = "XIV",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    openReferences = {
        part = "XIV",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    openReferencesFolder = {
        part = "XVI",
        implemented = true,
        context = true,
        requirements = { course = true },
    },

    openCoursePage = {
        part = "VIII",
        implemented = true,
        context = true,
        requirements = { course = true },
    },

    compileCurrent = {
        part = "XI",
        implemented = true,
        context = true,
        requirements = { course = true, workContext = "notes", lecture = true },
    },
    compileRecent = {
        part = "XI",
        implemented = true,
        context = true,
        requirements = { course = true, workContext = "notes", lecture = true },
    },
    compileRange = {
        part = "XI",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    compileSelected = {
        part = "XI",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
    compileAll = {
        part = "XI",
        implemented = true,
        context = true,
        requirements = { course = true },
    },
}

local function shallowCopy(value)
    local copy = {}

    for key, item in pairs(value or {}) do
        copy[key] = item
    end

    return copy
end

local function normalizeOptions(options)
    if options == nil then
        return {}
    end

    if type(options) ~= "table" then
        return nil, "Action options must be a table or nil."
    end

    return options
end

local function restoreState(snapshot)
    if snapshot.activeSemester then
        local ok, err = State.setActiveSemester(snapshot.activeSemester)

        if not ok then
            return nil, err
        end
    else
        State.clearActiveSemester()
    end

    local timetableEnabled = snapshot.timetableAutoSwitchEnabled

    if timetableEnabled == nil then
        timetableEnabled = snapshot.calendarAutoSwitchEnabled
    end

    local ok, err = State.setTimetableAutoSwitchEnabled(
        timetableEnabled ~= false
    )

    if not ok then
        return nil, err
    end

    if snapshot.manualCourse then
        ok, err = State.setManualCourse(snapshot.manualCourse)

        if not ok then
            return nil, err
        end
    else
        State.clearManualCourse()
    end

    if snapshot.manualOverrideState then
        ok, err = State.setManualOverrideState(snapshot.manualOverrideState)

        if not ok then
            return nil, err
        end
    else
        State.clearManualOverrideState()
    end

    return true
end

local function validateRequirements(context, requirements)
    requirements = requirements or {}

    if requirements.course and not context.course then
        return nil, Context.ERROR.NO_COURSE
    end

    if requirements.workContext == true and context.workContext == nil then
        return nil, Actions.ERROR.NO_WORK_CONTEXT
    end

    if type(requirements.workContext) == "string"
        and context.workContext ~= requirements.workContext then

        if context.workContext == nil then
            return nil, Actions.ERROR.NO_WORK_CONTEXT
        end

        return nil,
            string.format(
                'This action requires %s context, but resolved %s context.',
                requirements.workContext,
                context.workContext
            )
    end

    if requirements.lecture and context.lecture == nil then
        return nil, Actions.ERROR.NO_LECTURE
    end

    return true
end

-- Resolve exactly once through the central A -> B -> C -> D resolver, then
-- enforce only the semantic requirements of the requested action.
--
-- Passing { course = "...", workContext = "...", lecture = N } therefore
-- remains Level A and outranks any currently focused document/manual/timetable
-- context, which is the contract required by Phase 28.
function Actions.resolveFor(actionName, options, runtime)
    local spec = Actions.SPEC[actionName]

    if not spec then
        return nil, 'Unknown action "' .. tostring(actionName) .. '".'
    end

    if spec.context == false then
        return nil,
            string.format(
                'Action "%s" does not use course context.',
                actionName
            )
    end

    local normalized, optionsErr = normalizeOptions(options)

    if not normalized then
        return nil, optionsErr
    end

    local context, contextErr = Context.resolve(normalized, runtime)

    if not context then
        return nil, contextErr or Context.ERROR.NO_COURSE
    end

    local ok, requirementsErr = validateRequirements(
        context,
        spec.requirements
    )

    if not ok then
        return nil, requirementsErr
    end

    return context
end

function Actions.describe(actionName)
    local spec = Actions.SPEC[actionName]

    if not spec then
        return nil
    end

    local result = shallowCopy(spec)

    if spec.requirements then
        result.requirements = shallowCopy(spec.requirements)
    end

    return result
end

function Actions.actionNames()
    local names = {}

    for name in pairs(Actions.SPEC) do
        table.insert(names, name)
    end

    table.sort(names)
    return names
end

function Actions.setActiveSemester(value)
    local semesterId = value

    if type(value) == "table" then
        semesterId = value.semesterId or value.semester
    end

    if not Util.isNonEmptyString(semesterId) then
        return nil, "Semester ID must be a non-empty string."
    end

    semesterId = Util.trim(semesterId)

    -- Validate the target before changing persistent state. This prevents a
    -- typo/broken semester config from evicting the currently working one.
    local prospective, validationErr = Config.loadSemester(semesterId)

    if not prospective then
        return nil, validationErr
    end

    local previous = State.snapshot()
    local ok, stateErr = State.setActiveSemester(semesterId)

    if not ok then
        return nil, stateErr
    end

    Registry.clear()

    ok, stateErr = Registry.reload()

    if not ok then
        -- Extremely defensive: Config.loadSemester() already succeeded, so a
        -- reload failure would normally mean the files changed between the two
        -- operations. Restore the previous persistent state and registry.
        local restoreOk, restoreErr = restoreState(previous)
        Registry.clear()

        if previous.activeSemester then
            local registryOk, registryErr = Registry.reload()

            if not registryOk then
                restoreErr = restoreErr or registryErr
            end
        end

        return nil,
            string.format(
                "Could not activate semester %s: %s%s",
                semesterId,
                tostring(stateErr),
                restoreOk and "" or ("; rollback failed: " .. tostring(restoreErr))
            )
    end

    local semester = Registry.getActiveSemester()

    if not semester then
        return nil, "Active semester could not be read after activation."
    end

    return semester
end

function Actions.setActiveCourse(value, runtime)
    local courseReference = value

    if type(value) == "table" then
        if value.course ~= nil then
            courseReference = value.course
        elseif value.id ~= nil then
            -- Permit passing a resolved course object directly.
            courseReference = value
        else
            courseReference = nil
        end
    end

    if courseReference == nil then
        -- If no explicit course is supplied, setting the active course means
        -- pinning whatever the resolver can currently establish exactly.
        local context, contextErr = Context.resolve(nil, runtime)

        if not context then
            return nil, contextErr or Context.ERROR.NO_COURSE
        end

        courseReference = context.course
    end

    return Context.activateManualCourse(courseReference, runtime)
end

local function loadSemesterWizard(runtime)
    if type(runtime) == "table"
        and type(runtime.semesterWizard) == "table"
        and type(runtime.semesterWizard.start) == "function" then

        return runtime.semesterWizard
    end

    if type(_G.SemesterWizard) == "table"
        and type(_G.SemesterWizard.start) == "function" then

        return _G.SemesterWizard
    end

    -- In the normal installation the repository/configuration root is
    -- ~/.config/course-workflow, so the existing Part III wizard lives here.
    -- loadfile keeps the wizard independent from Hammerspoon package.path.
    local wizardPath = Util.joinPath(
        Config.ROOT,
        "scripts",
        "semester-wizard.lua"
    )

    local chunk, loadErr = loadfile(wizardPath)

    if not chunk then
        return nil,
            "Could not load New Semester wizard at "
                .. wizardPath
                .. ": "
                .. tostring(loadErr)
    end

    local ok, wizardOrErr = pcall(chunk)

    if not ok then
        return nil,
            "Could not initialize New Semester wizard: "
                .. tostring(wizardOrErr)
    end

    if type(wizardOrErr) ~= "table"
        or type(wizardOrErr.start) ~= "function" then

        return nil,
            "New Semester wizard did not return a valid Wizard.start()."
    end

    return wizardOrErr
end

function Actions.newSemester(_, runtime)
    local wizard, wizardErr = loadSemesterWizard(runtime)

    if not wizard then
        return nil, wizardErr
    end

    local ok, result = pcall(wizard.start)

    if not ok then
        return nil, "New Semester failed: " .. tostring(result)
    end

    -- Cancellation legitimately returns nil. Distinguish that from failure by
    -- returning true when the wizard itself completed without a value.
    if result == nil then
        return true
    end

    return result
end

function Actions.reloadConfiguration()
    local ok, err = Registry.reload()

    if not ok then
        return nil, err
    end

    -- A reload may remove/rename a course or change timetable slots. Never
    -- leave stale course state pointing at the old registry snapshot.
    local manualCourse = State.getManualCourse()

    if manualCourse then
        local course = Registry.getCourse(manualCourse)

        if not course then
            State.clearManualContext()
        else
            -- Preserve the explicit manual course, but force the timetable
            -- baseline to be rebuilt against the newly loaded schedule.
            State.clearManualOverrideState()
        end
    end

    return true
end

function Actions.setTimetableAutoSwitchEnabled(value)
    local enabled = value

    if type(value) == "table" then
        enabled = value.enabled

        if enabled == nil then
            enabled = value.timetableAutoSwitchEnabled
        end

        -- Backwards compatibility for callers created before Part XV.
        if enabled == nil then
            enabled = value.calendarAutoSwitchEnabled
        end
    end

    if type(enabled) ~= "boolean" then
        return nil, "Timetable auto-switch state must be a boolean."
    end

    local ok, err = State.setTimetableAutoSwitchEnabled(enabled)

    if not ok then
        return nil, err
    end

    return { enabled = enabled }
end

Actions.setCalendarAutoSwitchEnabled = Actions.setTimetableAutoSwitchEnabled

local function runtimeFunction(runtime, key, fallback)
    if type(runtime) == "table" and type(runtime[key]) == "function" then
        return runtime[key]
    end

    return fallback
end

local function workflowGlobalConfig()
    local snapshot, err = Registry.snapshot()

    if not snapshot then
        return nil, err
    end

    if type(snapshot.global) ~= "table" then
        return nil, "Loaded workflow configuration has no global settings."
    end

    return snapshot.global
end

local function appleScriptString(value)
    value = tostring(value)
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    value = value:gsub("\r", "\\r")
    value = value:gsub("\n", "\\n")
    return '"' .. value .. '"'
end

local function defaultPathMode(path)
    return hs.fs.attributes(path, "mode")
end

local function defaultNotify(message)
    hs.alert.show(message)
    return true
end

local function defaultOpenFileWithBundle(path, bundleId)
    local task = hs.task.new(
        "/usr/bin/open",
        nil,
        nil,
        { "-b", bundleId, path }
    )

    if not task then
        return nil, "Could not create /usr/bin/open task."
    end

    if task:start() == false then
        return nil, "Could not start /usr/bin/open task."
    end

    return true
end

local function defaultOpenURLWithBundle(url, bundleId)
    if hs.urlevent.openURLWithBundle(url, bundleId) then
        return true
    end

    return nil,
        string.format(
            "Could not open URL with application bundle %s.",
            bundleId
        )
end

local function defaultOpenPath(path)
    local task = hs.task.new(
        "/usr/bin/open",
        nil,
        nil,
        { path }
    )

    if not task then
        return nil, "Could not create /usr/bin/open task."
    end

    if task:start() == false then
        return nil, "Could not start /usr/bin/open task."
    end

    return true
end

local function defaultLaunchBundle(bundleId)
    if hs.application.launchOrFocusByBundleID(bundleId) then
        return true
    end

    return nil,
        string.format(
            "Could not launch application bundle %s.",
            bundleId
        )
end

local function defaultOpenItermAt(path, bundleId)
    local script = table.concat({
        "tell application id " .. appleScriptString(bundleId),
        "activate",
        "set newWindow to (create window with default profile)",
        "tell current session of newWindow",
        "write text \"cd \" & quoted form of "
            .. appleScriptString(path)
            .. " & \"; clear\"",
        "end tell",
        "end tell",
    }, "\n")

    local ok, _, descriptor = hs.osascript.applescript(script)

    if not ok then
        local detail = nil

        if type(descriptor) == "table" then
            detail = descriptor.NSAppleScriptErrorMessage
                or descriptor.NSLocalizedDescription
        end

        return nil,
            "Could not open iTerm2 at course root"
                .. (detail and (": " .. tostring(detail)) or ".")
    end

    return true
end


local function defaultOpenItermCommand(command, workingDirectory, bundleId)
    local shellCommand = "cd "
        .. Util.shellQuote(workingDirectory)
        .. " && "
        .. command

    local script = table.concat({
        "tell application id " .. appleScriptString(bundleId),
        "activate",
        "set newWindow to (create window with default profile)",
        "tell current session of newWindow",
        "write text " .. appleScriptString(shellCommand),
        "end tell",
        "end tell",
    }, "\n")

    local ok, _, descriptor = hs.osascript.applescript(script)

    if not ok then
        local detail = nil

        if type(descriptor) == "table" then
            detail = descriptor.NSAppleScriptErrorMessage
                or descriptor.NSLocalizedDescription
        end

        return nil,
            "Could not launch figure workflow in iTerm2"
                .. (detail and (": " .. tostring(detail)) or ".")
    end

    return true
end

local function defaultOpenItermNvim(path, workingDirectory, bundleId)
    local script = table.concat({
        "tell application id " .. appleScriptString(bundleId),
        "activate",
        "set newWindow to (create window with default profile)",
        "tell current session of newWindow",
        "write text \"cd \" & quoted form of "
            .. appleScriptString(workingDirectory)
            .. " & \" && nvim \" & quoted form of "
            .. appleScriptString(path),
        "end tell",
        "end tell",
    }, "\n")

    local ok, _, descriptor = hs.osascript.applescript(script)

    if not ok then
        local detail = nil

        if type(descriptor) == "table" then
            detail = descriptor.NSAppleScriptErrorMessage
                or descriptor.NSLocalizedDescription
        end

        return nil,
            "Could not open Neovim in iTerm2"
                .. (detail and (": " .. tostring(detail)) or ".")
    end

    return true
end

local function defaultOpenPathInNvim(path, workingDirectory, bundleId)
    return defaultOpenItermNvim(path, workingDirectory, bundleId)
end

local function callRuntime(runtime, key, fallback, ...)
    local fn = runtimeFunction(runtime, key, fallback)
    local ok, result, err = pcall(fn, ...)

    if not ok then
        return nil, tostring(result)
    end

    if result == false or result == nil then
        return nil, err or (key .. " failed.")
    end

    return result
end

local function openCoursePageFor(course, global, runtime)
    if not Util.isNonEmptyString(course.courseUrl) then
        return nil,
            string.format('Course "%s" has no course URL configured.', course.id)
    end

    local result, err = callRuntime(
        runtime,
        "openURLWithBundle",
        defaultOpenURLWithBundle,
        course.courseUrl,
        global.safariBundleId
    )

    if not result then
        return nil,
            string.format(
                'Could not open course webpage for "%s": %s',
                course.id,
                tostring(err)
            )
    end

    return true
end

function Actions.openCoursePage(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "openCoursePage",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local global, globalErr = workflowGlobalConfig()

    if not global then
        return nil, globalErr
    end

    local ok, pageErr = openCoursePageFor(context.course, global, runtime)

    if not ok then
        return nil, pageErr
    end

    return context.course
end

local function openCourseDirectory(actionName, pathKey, label, options, runtime)
    local context, contextErr = Actions.resolveFor(
        actionName,
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local path

    if type(pathKey) == "function" then
        path = pathKey(context.course)
    else
        path = context.course[pathKey]
    end

    if not Util.isNonEmptyString(path) then
        return nil,
            string.format(
                "%s path is not configured for %s.",
                label,
                context.course.shortName or context.course.name
            )
    end

    path = Util.normalizePath(path)

    if not path or not Util.isPathWithin(path, context.course.root) then
        return nil,
            string.format(
                "%s resolved outside the course root for %s.",
                label,
                context.course.shortName or context.course.name
            )
    end

    local pathMode = runtimeFunction(runtime, "pathMode", defaultPathMode)
    local modeOk, mode = pcall(pathMode, path)

    if not modeOk then
        return nil,
            string.format(
                "Could not inspect %s for %s: %s",
                label,
                context.course.shortName or context.course.name,
                tostring(mode)
            )
    end

    if mode ~= "directory" then
        return nil,
            string.format(
                "%s is missing for %s: %s",
                label,
                context.course.shortName or context.course.name,
                path
            )
    end

    local opened, openErr = callRuntime(
        runtime,
        "openPath",
        defaultOpenPath,
        path
    )

    if not opened then
        return nil,
            string.format(
                "Could not open %s for %s: %s",
                label,
                context.course.shortName or context.course.name,
                tostring(openErr)
            )
    end

    return {
        course = context.course,
        path = path,
    }
end

function Actions.openCourseRoot(options, runtime)
    return openCourseDirectory(
        "openCourseRoot",
        "root",
        "Course root",
        options,
        runtime
    )
end

function Actions.openNotesFolder(options, runtime)
    return openCourseDirectory(
        "openNotesFolder",
        function(course) return course.notes.root end,
        "Notes folder",
        options,
        runtime
    )
end

function Actions.openLecturesFolder(options, runtime)
    return openCourseDirectory(
        "openLecturesFolder",
        function(course) return course.notes.lectures end,
        "Lectures folder",
        options,
        runtime
    )
end

function Actions.openNotesFigures(options, runtime)
    return openCourseDirectory(
        "openNotesFigures",
        function(course) return course.notes.figures end,
        "Notes figures folder",
        options,
        runtime
    )
end

function Actions.openAssignments(options, runtime)
    return openCourseDirectory(
        "openAssignments",
        function(course) return course.assignments.root end,
        "Assignments folder",
        options,
        runtime
    )
end

function Actions.openAssignmentFigures(options, runtime)
    return openCourseDirectory(
        "openAssignmentFigures",
        function(course) return course.assignments.figures end,
        "Assignment figures folder",
        options,
        runtime
    )
end

function Actions.openMatlab(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "openMatlab",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local global, globalErr = workflowGlobalConfig()

    if not global then
        return nil, globalErr
    end

    local opened, openErr = callRuntime(
        runtime,
        "launchBundle",
        defaultLaunchBundle,
        global.matlabBundleId
    )

    if not opened then
        return nil, "Could not open MATLAB: " .. tostring(openErr)
    end

    return context.course
end

function Actions.openMatlabFolder(options, runtime)
    return openCourseDirectory(
        "openMatlabFolder",
        "matlab",
        "MATLAB folder",
        options,
        runtime
    )
end

function Actions.openLiterature(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "openLiterature",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local global, globalErr = workflowGlobalConfig()

    if not global then
        return nil, globalErr
    end

    local course = context.course
    local pathMode = runtimeFunction(runtime, "pathMode", defaultPathMode)
    local modeOk, mode = pcall(pathMode, course.book)

    if not modeOk then
        return nil, "Could not inspect textbook path: " .. tostring(mode)
    end

    if mode == nil then
        return nil,
            string.format(
                "No textbook available for %s.",
                course.shortName or course.name
            )
    end

    if mode ~= "file" then
        return nil,
            string.format(
                "Textbook path for %s is not a regular file: %s",
                course.shortName or course.name,
                course.book
            )
    end

    local opened, openErr = callRuntime(
        runtime,
        "openFileWithBundle",
        defaultOpenFileWithBundle,
        course.book,
        global.skimBundleId
    )

    if not opened then
        return nil,
            string.format(
                "Could not open textbook for %s: %s",
                course.shortName or course.name,
                tostring(openErr)
            )
    end

    return {
        course = course,
        path = course.book,
    }
end

function Actions.openLiteratureFolder(options, runtime)
    return openCourseDirectory(
        "openLiteratureFolder",
        "literature",
        "Literature folder",
        options,
        runtime
    )
end

function Actions.openReferences(options, runtime)
    return openCourseDirectory(
        "openReferences",
        "references",
        "References folder",
        options,
        runtime
    )
end

function Actions.openReferencesFolder(options, runtime)
    return openCourseDirectory(
        "openReferencesFolder",
        "references",
        "References folder",
        options,
        runtime
    )
end

function Actions.launchCourse(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "launchCourse",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local course = context.course

    local activated, activateErr = Actions.setActiveCourse(
        { course = course.id },
        runtime
    )

    if not activated then
        return nil, activateErr
    end

    local global, globalErr = workflowGlobalConfig()

    if not global then
        return nil, globalErr
    end

    local pathMode = runtimeFunction(runtime, "pathMode", defaultPathMode)
    local notify = runtimeFunction(runtime, "notify", defaultNotify)
    local errors = {}

    local rootModeOk, rootMode = pcall(pathMode, course.root)

    if not rootModeOk then
        table.insert(errors, "Could not inspect course root: " .. tostring(rootMode))
    elseif rootMode ~= "directory" then
        table.insert(
            errors,
            string.format(
                'Course root does not exist for "%s": %s',
                course.id,
                course.root
            )
        )
    else
        local opened, openErr = callRuntime(
            runtime,
            "openItermAt",
            defaultOpenItermAt,
            course.root,
            global.itermBundleId
        )

        if not opened then
            table.insert(errors, tostring(openErr))
        end
    end

    local bookModeOk, bookMode = pcall(pathMode, course.book)

    if not bookModeOk then
        table.insert(errors, "Could not inspect textbook path: " .. tostring(bookMode))
    elseif bookMode == "file" then
        local opened, openErr = callRuntime(
            runtime,
            "openFileWithBundle",
            defaultOpenFileWithBundle,
            course.book,
            global.skimBundleId
        )

        if not opened then
            table.insert(
                errors,
                string.format(
                    'Could not open textbook for "%s": %s',
                    course.id,
                    tostring(openErr)
                )
            )
        end
    elseif bookMode == nil then
        pcall(
            notify,
            string.format(
                "No textbook available for %s; continuing launch.",
                course.shortName or course.name
            )
        )
    else
        table.insert(
            errors,
            string.format(
                'Textbook path for "%s" is not a regular file: %s',
                course.id,
                course.book
            )
        )
    end

    local pageOk, pageErr = openCoursePageFor(course, global, runtime)

    if not pageOk then
        table.insert(errors, pageErr)
    end

    if #errors > 0 then
        return nil, table.concat(errors, "\n")
    end

    return course
end

local function openNotesPath(path, course, runtime)
    local global, globalErr = workflowGlobalConfig()

    if not global then
        return nil, globalErr
    end

    local pathMode = runtimeFunction(runtime, "pathMode", defaultPathMode)
    local modeOk, mode = pcall(pathMode, path)

    if not modeOk then
        return nil, "Could not inspect notes path: " .. tostring(mode)
    end

    if mode ~= "file" then
        return nil, "Notes file is missing: " .. path
    end

    local opened, openErr = callRuntime(
        runtime,
        "openPathInNvim",
        defaultOpenPathInNvim,
        path,
        course.root,
        global.itermBundleId
    )

    if not opened then
        return nil, "Could not open notes in Neovim: " .. tostring(openErr)
    end

    return true
end

function Actions.openNotes(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "openNotes",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local ok, openErr = openNotesPath(
        context.course.notes.master,
        context.course,
        runtime
    )

    if not ok then
        return nil, openErr
    end

    return {
        course = context.course,
        path = context.course.notes.master,
    }
end


local function defaultPromptLectureTitle(course, number)
    local numberText = assert(Lectures.numberText(number))
    local button, title = hs.dialog.textPrompt(
        "New Lecture",
        string.format(
            "%s · lec_%s.tex",
            course.shortName or course.name or course.id,
            numberText
        ),
        "",
        "Create",
        "Cancel"
    )

    if button ~= "Create" then
        return false
    end

    return title
end

function Actions.newLecture(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "newLecture",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local course = context.course
    local nextNumber, numberErr = Lectures.nextNumber(course)

    if not nextNumber then
        return nil, numberErr
    end

    local prompt = runtimeFunction(
        runtime,
        "promptLectureTitle",
        defaultPromptLectureTitle
    )

    local promptOk, titleOrCancelled = pcall(prompt, course, nextNumber)

    if not promptOk then
        return nil, "Could not ask for lecture title: " .. tostring(titleOrCancelled)
    end

    if titleOrCancelled == false or titleOrCancelled == nil then
        return { cancelled = true }
    end

    if not Util.isNonEmptyString(titleOrCancelled) then
        return nil, "Lecture title cannot be empty."
    end

    local date = nil

    if type(runtime) == "table" and Util.isNonEmptyString(runtime.today) then
        date = Util.trim(runtime.today)
    else
        date = os.date("%Y-%m-%d")
    end

    local lecture, createErr = Lectures.create(course, {
        number = nextNumber,
        date = date,
        title = titleOrCancelled,
    })

    if not lecture then
        return nil, createErr
    end

    local opened, openErr = openNotesPath(lecture.path, course, runtime)

    if not opened then
        -- Creation succeeded; never delete academic work merely because the
        -- editor handoff failed. Return the path in the error for recovery.
        return nil,
            string.format(
                "Lecture created at %s, but could not open it: %s",
                lecture.path,
                tostring(openErr)
            )
    end

    return lecture
end

local function lectureChoice(lecture)
    local title = Util.isNonEmptyString(lecture.title)
        and lecture.title
        or "Untitled lecture"
    local details = {}

    if Util.isNonEmptyString(lecture.date) then
        table.insert(details, lecture.date)
    end

    table.insert(details, lecture.path)

    return {
        text = string.format("lec_%s · %s", lecture.numberText, title),
        subText = table.concat(details, " · "),
        lecture = lecture.number,
    }
end

function Actions.chooseLecture(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "chooseLecture",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local lectures, listErr = Lectures.list(context.course)

    if not lectures then
        return nil, listErr
    end

    if #lectures == 0 then
        return nil,
            string.format(
                'No lecture files exist for "%s".',
                context.course.id
            )
    end

    local choose = runtimeFunction(runtime, "chooseLectureEntry", nil)

    if choose then
        local selected = choose(lectures, context.course)

        if selected == false or selected == nil then
            return { cancelled = true }
        end

        local selectedLecture = nil

        if type(selected) == "table" and selected.path then
            selectedLecture = selected
        else
            local number = type(selected) == "table" and selected.number or selected

            for _, lecture in ipairs(lectures) do
                if lecture.number == number then
                    selectedLecture = lecture
                    break
                end
            end
        end

        if not selectedLecture then
            return nil, "Selected lecture no longer exists."
        end

        local opened, openErr = openNotesPath(
            selectedLecture.path,
            context.course,
            runtime
        )

        if not opened then
            return nil, openErr
        end

        return selectedLecture
    end

    local choices = {}

    for _, lecture in ipairs(lectures) do
        table.insert(choices, lectureChoice(lecture))
    end

    if Actions._lectureChooser then
        Actions._lectureChooser:delete()
        Actions._lectureChooser = nil
    end

    local course = context.course
    local chooser
    chooser = hs.chooser.new(function(choice)
        Actions._lectureChooser = nil

        if not choice then
            return
        end

        local selectedLecture = nil

        for _, lecture in ipairs(lectures) do
            if lecture.number == choice.lecture then
                selectedLecture = lecture
                break
            end
        end

        if not selectedLecture then
            hs.alert.show("Selected lecture no longer exists.")
            return
        end

        local opened, openErr = openNotesPath(
            selectedLecture.path,
            course
        )

        if not opened and openErr then
            hs.alert.show(openErr)
        end
    end)

    chooser:searchSubText(true)
    chooser:placeholderText(
        "Choose lecture · " .. (course.shortName or course.name or course.id)
    )
    chooser:choices(choices)
    chooser:rows(math.min(math.max(#choices, 5), 12))
    chooser:show()

    Actions._lectureChooser = chooser

    return {
        chooser = chooser,
        course = course,
        lectureCount = #lectures,
    }
end

local function launchFigureWorkflow(context, mode, runtime)
    local invocation, invocationErr = Figures.invocation(
        context.course,
        context.workContext,
        mode
    )

    if not invocation then
        return nil, invocationErr
    end

    local writeBridge = runtimeFunction(
        runtime,
        "writeFigureBridge",
        Util.writeFileAtomic
    )

    local writeOk, writeResult, writeErr = pcall(
        writeBridge,
        invocation.bridgePath,
        invocation.bridgeContents
    )

    if not writeOk or not writeResult then
        return nil,
            "Could not prepare figure workflow bridge: "
                .. tostring(writeOk and writeErr or writeResult)
    end

    local global, globalErr = workflowGlobalConfig()

    if not global then
        return nil, globalErr
    end

    local launched, launchErr = callRuntime(
        runtime,
        "openFigureWorkflow",
        defaultOpenItermCommand,
        invocation.command,
        invocation.projectRoot,
        global.itermBundleId
    )

    if not launched then
        return nil, launchErr
    end

    return {
        course = context.course,
        workContext = context.workContext,
        figuresDir = invocation.figuresDir,
        mode = mode,
    }
end

function Actions.newFigure(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "newFigure",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    return launchFigureWorkflow(context, Figures.MODE.NEW, runtime)
end

function Actions.findFigure(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "findFigure",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    return launchFigureWorkflow(context, Figures.MODE.FIND, runtime)
end

local function courseBuildLabel(course)
    return course.shortName or course.name or course.id
end

local function buildLectureLabel(course, lectureNumbers)
    local courseLabel = courseBuildLabel(course)

    if #lectureNumbers == 1 then
        return string.format("%s · lec_%02d", courseLabel, lectureNumbers[1])
    end

    local contiguous = true

    for index = 2, #lectureNumbers do
        if lectureNumbers[index] ~= lectureNumbers[index - 1] + 1 then
            contiguous = false
            break
        end
    end

    if contiguous then
        return string.format(
            "%s · lec_%02d–lec_%02d",
            courseLabel,
            lectureNumbers[1],
            lectureNumbers[#lectureNumbers]
        )
    end

    if #lectureNumbers <= 4 then
        local labels = {}

        for _, number in ipairs(lectureNumbers) do
            table.insert(labels, string.format("lec_%02d", number))
        end

        return courseLabel .. " · " .. table.concat(labels, ", ")
    end

    return string.format(
        "%s · %d selected lectures",
        courseLabel,
        #lectureNumbers
    )
end

local function defaultPromptRecentCount(course, currentLecture)
    local button, value = hs.dialog.textPrompt(
        "Compile Recent",
        string.format(
            "%s · ending at lec_%02d\nHow many lectures?",
            courseBuildLabel(course),
            currentLecture
        ),
        "5",
        "Compile",
        "Cancel"
    )

    if button ~= "Compile" then
        return false
    end

    return value
end

local function defaultPromptRange(course, lectures)
    local first = lectures[1] and lectures[1].number or 1
    local last = lectures[#lectures] and lectures[#lectures].number or first
    local button, value = hs.dialog.textPrompt(
        "Compile Range",
        string.format(
            "%s · enter a lecture range (for example 3-8)",
            courseBuildLabel(course)
        ),
        string.format("%d-%d", first, last),
        "Compile",
        "Cancel"
    )

    if button ~= "Compile" then
        return false
    end

    return value
end

local function defaultPromptSelection(course)
    local button, value = hs.dialog.textPrompt(
        "Compile Selected",
        string.format(
            "%s · enter lectures such as 1,3,5-7",
            courseBuildLabel(course)
        ),
        "",
        "Compile",
        "Cancel"
    )

    if button ~= "Compile" then
        return false
    end

    return value
end

local function parsePositiveCount(value)
    if type(value) == "string" then
        value = tonumber(Util.trim(value))
    end

    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
        return nil, "Recent lecture count must be a positive integer."
    end

    return value
end

local function defaultStartLatexBuild(course, request)
    return LaTeX.startBuild(course, request)
end

local function startLatexBuild(course, lectureNumbers, label, runtime)
    local notify = runtimeFunction(runtime, "notify", defaultNotify)
    local start = runtimeFunction(
        runtime,
        "startLatexBuild",
        defaultStartLatexBuild
    )

    local request = {
        lectureNumbers = lectureNumbers,
        label = label,
        onStart = function()
            pcall(notify, "Compiling " .. label)
        end,
        onComplete = function(result)
            if result.success then
                pcall(notify, "Compilation complete · " .. label)
                return
            end

            local message = "Compilation failed · " .. label

            if Util.isNonEmptyString(result.logPath) then
                message = message .. "\nLog: " .. result.logPath
            end

            pcall(notify, message)

            if hs and hs.printf then
                hs.printf(
                    "Course workflow LaTeX compilation failed for %s. Log: %s",
                    label,
                    tostring(result.logPath or "unavailable")
                )
            end
        end,
    }

    local ok, buildOrErr, startErr = pcall(start, course, request)

    if not ok then
        return nil, "Could not start LaTeX build: " .. tostring(buildOrErr)
    end

    if not buildOrErr then
        return nil, tostring(startErr or "Could not start LaTeX build.")
    end

    return buildOrErr
end

function Actions.compileCurrent(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "compileCurrent",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local lectureNumbers = { context.lecture }
    local label = buildLectureLabel(context.course, lectureNumbers)

    return startLatexBuild(
        context.course,
        lectureNumbers,
        label,
        runtime
    )
end

function Actions.compileRecent(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "compileRecent",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local actionOptions = type(options) == "table" and options or {}
    local countValue = actionOptions.count

    if countValue == nil then
        local prompt = runtimeFunction(
            runtime,
            "promptRecentCount",
            defaultPromptRecentCount
        )
        local ok, prompted = pcall(
            prompt,
            context.course,
            context.lecture
        )

        if not ok then
            return nil, "Could not ask for recent lecture count: " .. tostring(prompted)
        end

        if prompted == false or prompted == nil then
            return { cancelled = true }
        end

        countValue = prompted
    end

    local count, countErr = parsePositiveCount(countValue)

    if not count then
        return nil, countErr
    end

    local lectureNumbers, recentErr = LaTeX.recentLectureNumbers(
        context.course,
        context.lecture,
        count
    )

    if not lectureNumbers then
        return nil, recentErr
    end

    local label = buildLectureLabel(context.course, lectureNumbers)

    return startLatexBuild(
        context.course,
        lectureNumbers,
        label,
        runtime
    )
end

function Actions.compileRange(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "compileRange",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local actionOptions = type(options) == "table" and options or {}
    local firstLecture = actionOptions.firstLecture
    local lastLecture = actionOptions.lastLecture

    if firstLecture == nil or lastLecture == nil then
        local rangeValue = actionOptions.range

        if rangeValue == nil then
            local lectures, listErr = Lectures.list(context.course)

            if not lectures then
                return nil, listErr
            end

            if #lectures == 0 then
                return nil,
                    string.format(
                        'No lecture files exist for "%s".',
                        context.course.id
                    )
            end

            local prompt = runtimeFunction(
                runtime,
                "promptLectureRange",
                defaultPromptRange
            )
            local ok, prompted = pcall(prompt, context.course, lectures)

            if not ok then
                return nil, "Could not ask for lecture range: " .. tostring(prompted)
            end

            if prompted == false or prompted == nil then
                return { cancelled = true }
            end

            rangeValue = prompted
        end

        local parsedFirst, parsedLastOrErr = LaTeX.parseRange(rangeValue)

        if not parsedFirst then
            return nil, parsedLastOrErr
        end

        firstLecture = parsedFirst
        lastLecture = parsedLastOrErr
    else
        firstLecture = tonumber(firstLecture)
        lastLecture = tonumber(lastLecture)
    end

    local lectureNumbers, rangeErr = LaTeX.rangeLectureNumbers(
        context.course,
        firstLecture,
        lastLecture
    )

    if not lectureNumbers then
        return nil, rangeErr
    end

    local label = buildLectureLabel(context.course, lectureNumbers)

    return startLatexBuild(
        context.course,
        lectureNumbers,
        label,
        runtime
    )
end

function Actions.compileSelected(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "compileSelected",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local actionOptions = type(options) == "table" and options or {}
    local lectureNumbers = actionOptions.lectures

    if lectureNumbers == nil then
        local selectionValue = actionOptions.selection

        if selectionValue == nil then
            local prompt = runtimeFunction(
                runtime,
                "promptLectureSelection",
                defaultPromptSelection
            )
            local ok, prompted = pcall(prompt, context.course)

            if not ok then
                return nil, "Could not ask for lecture selection: " .. tostring(prompted)
            end

            if prompted == false or prompted == nil then
                return { cancelled = true }
            end

            selectionValue = prompted
        end

        local selectionErr
        lectureNumbers, selectionErr = LaTeX.parseSelection(selectionValue)

        if not lectureNumbers then
            return nil, selectionErr
        end
    end

    local resolved, selectionErr = LaTeX.resolveLectures(
        context.course,
        lectureNumbers
    )

    if not resolved then
        return nil, selectionErr
    end

    lectureNumbers = {}

    for _, lecture in ipairs(resolved) do
        table.insert(lectureNumbers, lecture.number)
    end

    local label = buildLectureLabel(context.course, lectureNumbers)

    return startLatexBuild(
        context.course,
        lectureNumbers,
        label,
        runtime
    )
end

function Actions.compileAll(options, runtime)
    local context, contextErr = Actions.resolveFor(
        "compileAll",
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local label = courseBuildLabel(context.course) .. " · all lectures"

    return startLatexBuild(
        context.course,
        nil,
        label,
        runtime
    )
end

local function deferred(actionName, options, runtime)
    local context, contextErr = Actions.resolveFor(
        actionName,
        options,
        runtime
    )

    if not context then
        return nil, contextErr
    end

    local spec = Actions.SPEC[actionName]

    return nil,
        string.format(
            'Action "%s" is defined by the central API but is not implemented yet.',
            actionName
        )
end

for actionName, spec in pairs(Actions.SPEC) do
    if spec.implemented ~= true and Actions[actionName] == nil then
        local name = actionName

        Actions[name] = function(options, runtime)
            return deferred(name, options, runtime)
        end
    end
end

return Actions

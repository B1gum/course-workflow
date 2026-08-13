local Menubar = {}

local Actions = require("course.actions")
local Context = require("course.context")
local Launcher = require("course.launcher")
local Registry = require("course.registry")
local State = require("course.state")

Menubar._item = nil
Menubar._runtime = nil
Menubar._started = false

local AUTOSAVE_NAME = "noah-course-workflow-menubar"

local SOURCE_LABELS = {
    [Context.SOURCE.EXPLICIT] = "explicit",
    [Context.SOURCE.EXPLICIT_PATH] = "explicit path",
    [Context.SOURCE.NEOVIM_PATH] = "Neovim path",
    [Context.SOURCE.SKIM_PATH] = "Skim path",
    [Context.SOURCE.FINDER_PATH] = "Finder path",
    [Context.SOURCE.MANUAL_COURSE] = "manual course",
    [Context.SOURCE.CALENDAR] = "timetable",
}

local function defaultNotify(message)
    hs.alert.show(message)
end

local function runtimeFunction(runtime, key, fallback)
    if type(runtime) == "table" and type(runtime[key]) == "function" then
        return runtime[key]
    end

    return fallback
end

local function notify(message)
    local fn = runtimeFunction(Menubar._runtime, "notify", defaultNotify)
    pcall(fn, tostring(message))
end

local function resolveContext()
    local fn = runtimeFunction(
        Menubar._runtime,
        "resolveContext",
        function()
            return Context.resolve()
        end
    )

    local ok, context, err = pcall(fn)

    if not ok then
        return nil, tostring(context)
    end

    return context, err
end

local function courseLabel(course)
    if not course then
        return nil
    end

    return course.shortName or course.name or course.id
end

function Menubar.titleForContext(context)
    if context and context.course then
        return "AU · " .. courseLabel(context.course)
    end

    return "AU"
end

local function contextDescription(context)
    if not context then
        return nil
    end

    local parts = {
        "Level " .. tostring(context.level or "?"),
        SOURCE_LABELS[context.source] or tostring(context.source or "unknown"),
    }

    if context.workContext then
        table.insert(parts, context.workContext)
    end

    if context.lecture then
        table.insert(parts, string.format("lecture %02d", context.lecture))
    end

    return table.concat(parts, " · ")
end

local function explicitCourseOptions(course, workContext)
    local options = { course = course.id }

    if workContext ~= nil then
        options.workContext = workContext
    end

    return options
end

local function optionsFromContext(context)
    if not context or not context.course then
        return nil
    end

    local options = { course = context.course.id }

    if context.workContext then
        options.workContext = context.workContext
    end

    if context.lecture then
        options.lecture = context.lecture
    end

    return options
end

local function requirementsSatisfied(spec, options)
    local requirements = spec and spec.requirements or {}
    options = options or {}

    if requirements.course and options.course == nil then
        return false
    end

    if requirements.workContext == true and options.workContext == nil then
        return false
    end

    if type(requirements.workContext) == "string"
        and options.workContext ~= requirements.workContext then

        return false
    end

    if requirements.lecture and options.lecture == nil then
        return false
    end

    return true
end

function Menubar.invoke(actionName, options)
    local fn = Actions[actionName]

    if type(fn) ~= "function" then
        local err = 'Unknown action "' .. tostring(actionName) .. '".'
        notify(err)
        return nil, err
    end

    local result, err = fn(options)

    if not result then
        if err then
            notify(err)
        end
        return nil, err
    end

    if actionName == "setActiveCourse" then
        notify("Active course · " .. courseLabel(result))
    elseif actionName == "setActiveSemester" then
        notify("Active semester · " .. tostring(result.name or result.id))
    elseif actionName == "reloadConfiguration" then
        notify("Course configuration reloaded.")
    elseif actionName == "setCalendarAutoSwitchEnabled" then
        notify(
            result.enabled == true
                and "Automatic timetable switching enabled."
                or "Automatic timetable switching disabled."
        )
    end

    Menubar.refresh()
    return result
end

local function actionItem(label, actionName, options, extra)
    extra = extra or {}

    local spec = Actions.describe(actionName)
    local disabled = false
    local tooltip = extra.tooltip

    if not spec then
        disabled = true
        tooltip = 'Unknown action "' .. tostring(actionName) .. '".'
    elseif spec.implemented ~= true then
        disabled = true
        tooltip = "Not implemented yet · Part " .. tostring(spec.part or "?")
    elseif spec.context ~= false and not requirementsSatisfied(spec, options) then
        disabled = true
        tooltip = extra.unavailableReason or "Required course context is not available."
    end

    return {
        title = label,
        disabled = disabled,
        tooltip = tooltip,
        checked = extra.checked,
        fn = disabled and nil or function()
            Menubar.invoke(actionName, options)
        end,
    }
end

local function courseSwitchMenu(context)
    local courses, err = Registry.allCourses()

    if not courses then
        return {
            {
                title = err or "No courses available.",
                disabled = true,
            },
        }
    end

    local menu = {}
    local currentId = context and context.course and context.course.id or nil

    for _, course in ipairs(courses) do
        table.insert(menu, {
            title = courseLabel(course),
            checked = currentId == course.id,
            fn = function()
                Menubar.invoke(
                    "setActiveCourse",
                    explicitCourseOptions(course)
                )
            end,
        })
    end

    if #menu == 0 then
        table.insert(menu, {
            title = "No courses configured.",
            disabled = true,
        })
    end

    return menu
end

local function notesMenu(context)
    local course = context and context.course or nil
    local courseOptions = course and explicitCourseOptions(course) or nil
    local currentOptions = optionsFromContext(context)
    local notesOptions = course
        and explicitCourseOptions(course, Context.WORK_CONTEXT.NOTES)
        or nil

    return {
        actionItem("Open Notes", "openNotes", courseOptions),
        actionItem("New Lecture", "newLecture", courseOptions),
        actionItem("Choose Lecture…", "chooseLecture", courseOptions),
        { title = "-" },
        actionItem("New Notes Figure", "newFigure", notesOptions),
        actionItem("Find Notes Figure", "findFigure", notesOptions),
        { title = "-" },
        actionItem(
            "Compile Current",
            "compileCurrent",
            currentOptions,
            { unavailableReason = "No current lecture context available." }
        ),
        actionItem(
            "Compile Recent…",
            "compileRecent",
            currentOptions,
            { unavailableReason = "No current lecture context available." }
        ),
        actionItem("Compile Range…", "compileRange", courseOptions),
        actionItem("Compile Selected…", "compileSelected", courseOptions),
        actionItem("Compile All", "compileAll", courseOptions),
    }
end

local function assignmentsMenu(context)
    local course = context and context.course or nil
    local courseOptions = course and explicitCourseOptions(course) or nil
    local assignmentOptions = course
        and explicitCourseOptions(course, Context.WORK_CONTEXT.ASSIGNMENT)
        or nil

    return {
        actionItem("Open Assignments", "openAssignments", courseOptions),
        { title = "-" },
        actionItem("New Assignment Figure", "newFigure", assignmentOptions),
        actionItem("Find Assignment Figure", "findFigure", assignmentOptions),
    }
end

local function figuresMenu(context)
    local course = context and context.course or nil
    local currentOptions = optionsFromContext(context)
    local notesOptions = course
        and explicitCourseOptions(course, Context.WORK_CONTEXT.NOTES)
        or nil
    local assignmentOptions = course
        and explicitCourseOptions(course, Context.WORK_CONTEXT.ASSIGNMENT)
        or nil

    return {
        actionItem(
            "New Figure",
            "newFigure",
            currentOptions,
            { unavailableReason = "No notes/assignment context available." }
        ),
        actionItem(
            "Find Figure",
            "findFigure",
            currentOptions,
            { unavailableReason = "No notes/assignment context available." }
        ),
        { title = "-" },
        actionItem("New Notes Figure", "newFigure", notesOptions),
        actionItem("New Assignment Figure", "newFigure", assignmentOptions),
        actionItem("Find Notes Figure", "findFigure", notesOptions),
        actionItem("Find Assignment Figure", "findFigure", assignmentOptions),
    }
end

local function literatureMenu(context)
    local course = context and context.course or nil
    local options = course and explicitCourseOptions(course) or nil

    return {
        actionItem("Open Textbook", "openLiterature", options),
        actionItem("Open Literature Folder", "openLiteratureFolder", options),
    }
end

function Menubar.buildMenu(context, contextErr)
    local menu = {}
    local course = context and context.course or nil
    local courseOptions = course and explicitCourseOptions(course) or nil

    if course then
        table.insert(menu, {
            title = courseLabel(course),
            disabled = true,
            tooltip = contextDescription(context),
        })
        table.insert(menu, { title = "-" })

        table.insert(menu, actionItem("Launch Course", "launchCourse", courseOptions))
        table.insert(menu, { title = "Notes", menu = notesMenu(context) })
        table.insert(menu, { title = "Assignments", menu = assignmentsMenu(context) })
        table.insert(menu, { title = "Figures", menu = figuresMenu(context) })
        table.insert(menu, actionItem("MATLAB", "openMatlab", courseOptions))
        table.insert(menu, { title = "Literature", menu = literatureMenu(context) })
        table.insert(menu, actionItem("References", "openReferences", courseOptions))
        table.insert(menu, actionItem("Course Webpage", "openCoursePage", courseOptions))
        table.insert(menu, actionItem("Open Course Root", "openCourseRoot", courseOptions))
        table.insert(menu, { title = "-" })
    else
        table.insert(menu, {
            title = "No course context available",
            disabled = true,
            tooltip = contextErr or Context.ERROR.NO_COURSE,
        })
        table.insert(menu, { title = "-" })
    end

    table.insert(menu, {
        title = "Switch Course…",
        menu = courseSwitchMenu(context),
    })

    table.insert(menu, {
        title = "Switch Semester…",
        fn = function()
            Launcher.showSemesters()
        end,
    })

    table.insert(menu, {
        title = "New Semester…",
        fn = function()
            Menubar.invoke("newSemester", nil)
        end,
    })

    table.insert(
        menu,
        actionItem(
            "Automatic Timetable Switching",
            "setCalendarAutoSwitchEnabled",
            { enabled = not State.getCalendarAutoSwitchEnabled() },
            { checked = State.getCalendarAutoSwitchEnabled() }
        )
    )

    table.insert(menu, {
        title = "Reload Configuration",
        fn = function()
            Menubar.invoke("reloadConfiguration", nil)
        end,
    })

    table.insert(menu, { title = "-" })
    table.insert(menu, {
        title = "Open Launcher…",
        fn = function()
            Launcher.show()
        end,
    })

    return menu
end

function Menubar.refresh(context)
    if not Menubar._item then
        return true
    end

    if context == nil then
        context = select(1, resolveContext())
    end

    Menubar._item:setTitle(Menubar.titleForContext(context))
    return true
end

function Menubar.start(runtime)
    Menubar.stop()
    Menubar._runtime = runtime

    local newMenubar = runtimeFunction(
        runtime,
        "newMenubar",
        function()
            return hs.menubar.new(true, AUTOSAVE_NAME)
        end
    )

    local ok, itemOrErr = pcall(newMenubar)

    if not ok then
        Menubar._runtime = nil
        return nil, "Could not create course menubar: " .. tostring(itemOrErr)
    end

    if not itemOrErr then
        Menubar._runtime = nil
        return nil, "Could not create course menubar."
    end

    Menubar._item = itemOrErr

    local context = select(1, resolveContext())
    Menubar._item:setTitle(Menubar.titleForContext(context))
    Menubar._item:setTooltip("AU course workflow")
    Menubar._item:setMenu(function()
        local current, err = resolveContext()
        Menubar._item:setTitle(Menubar.titleForContext(current))
        return Menubar.buildMenu(current, err)
    end)

    Menubar._started = true
    return true
end

function Menubar.stop()
    if Menubar._item then
        Menubar._item:delete()
        Menubar._item = nil
    end

    Menubar._runtime = nil
    Menubar._started = false
    return true
end

return Menubar

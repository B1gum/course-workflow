local Launcher = {}

local Actions = require("course.actions")
local Config = require("course.config")
local Context = require("course.context")
local Registry = require("course.registry")
local State = require("course.state")
local Util = require("course.util")

Launcher._chooser = nil
Launcher._activeContext = nil
Launcher._started = false

local ROOT_ROWS = 16
local CHILD_ROWS = 15
local WIDTH = 42

local SOURCE_LABELS = {
    [Context.SOURCE.EXPLICIT] = "explicit",
    [Context.SOURCE.EXPLICIT_PATH] = "explicit path",
    [Context.SOURCE.NEOVIM_PATH] = "Neovim path",
    [Context.SOURCE.SKIM_PATH] = "Skim path",
    [Context.SOURCE.FINDER_PATH] = "Finder path",
    [Context.SOURCE.MANUAL_COURSE] = "manual course",
    [Context.SOURCE.TIMETABLE] = "timetable",
}

local function copyOptions(options)
    local result = {}

    for key, value in pairs(options or {}) do
        result[key] = value
    end

    return result
end

local function notify(message)
    if Util.isNonEmptyString(message) then
        hs.alert.show(message)
    end
end

local function header(text, subText)
    return {
        text = text,
        subText = subText,
        valid = false,
        kind = "header",
    }
end

local function navigation(text, target, subText, extra)
    local choice = {
        text = text,
        subText = subText,
        kind = "navigate",
        target = target,
    }

    for key, value in pairs(extra or {}) do
        choice[key] = value
    end

    return choice
end

local function formatContext(context)
    if not context then
        return "No course context resolved"
    end

    local parts = {
        "Level " .. tostring(context.level),
        SOURCE_LABELS[context.source] or tostring(context.source),
    }

    if context.workContext then
        table.insert(parts, context.workContext)
    end

    if context.lecture then
        table.insert(parts, string.format("lecture %02d", context.lecture))
    end

    return table.concat(parts, " · ")
end

local function contextOptions(context)
    if not context or not context.course then
        return nil
    end

    return {
        course = context.course.id,
        workContext = context.workContext,
        lecture = context.lecture,
    }
end

local function explicitCourseOptions(course, workContext)
    local options = { course = course.id }

    if workContext then
        options.workContext = workContext
    end

    return options
end

local function missingRequirementReason(actionName, options)
    local spec = Actions.describe(actionName)

    if not spec then
        return "Unknown central action"
    end

    if spec.implemented ~= true then
        return "Not implemented yet · Part " .. tostring(spec.part or "?")
    end

    local requirements = spec.requirements or {}
    options = options or {}

    if requirements.course and not options.course then
        return Context.ERROR.NO_COURSE
    end

    if requirements.workContext == true and not options.workContext then
        return Actions.ERROR.NO_WORK_CONTEXT
    end

    if type(requirements.workContext) == "string"
        and options.workContext ~= requirements.workContext then

        if options.workContext == nil then
            return "Needs " .. requirements.workContext .. " context"
        end

        return "Needs "
            .. requirements.workContext
            .. " context · currently "
            .. tostring(options.workContext)
    end

    if requirements.lecture and not options.lecture then
        return Actions.ERROR.NO_LECTURE
    end

    return nil
end

local function actionChoice(text, actionName, options, subText)
    options = copyOptions(options)

    local disabledReason = missingRequirementReason(actionName, options)
    local detail = subText

    if disabledReason then
        detail = disabledReason
    end

    return {
        text = text,
        subText = detail,
        valid = disabledReason == nil,
        kind = "action",
        actionName = actionName,
        courseId = options.course,
        workContext = options.workContext,
        lecture = options.lecture,
        enabled = options.enabled,
        disabledReason = disabledReason,
    }
end

local function actionOptionsFromChoice(choice)
    local options = {}

    if choice.courseId then
        options.course = choice.courseId
    end

    if choice.workContext then
        options.workContext = choice.workContext
    end

    if choice.lecture then
        options.lecture = choice.lecture
    end

    if choice.enabled ~= nil then
        options.enabled = choice.enabled
    end

    if next(options) == nil then
        return nil
    end

    return options
end

local function activeCourseMatches(course)
    return Launcher._activeContext
        and Launcher._activeContext.course
        and Launcher._activeContext.course.id == course.id
end

local function optionsForCourseCurrentContext(course)
    if activeCourseMatches(course) then
        return contextOptions(Launcher._activeContext)
    end

    return explicitCourseOptions(course)
end

local function courseSort(a, b)
    local aName = (a.shortName or a.name or a.id):lower()
    local bName = (b.shortName or b.name or b.id):lower()
    return aName < bName
end

local function safeCourses()
    local courses, err = Registry.allCourses()

    if not courses then
        return nil, err
    end

    table.sort(courses, courseSort)
    return courses
end

function Launcher.buildRootChoices(context)
    local choices = {}

    if context and context.course then
        local course = context.course
        local activeOptions = contextOptions(context)
        local courseOptions = explicitCourseOptions(course)
        local assignmentOptions = explicitCourseOptions(
            course,
            Context.WORK_CONTEXT.ASSIGNMENT
        )

        table.insert(
            choices,
            header(
                "ACTIVE · " .. (course.shortName or course.name),
                formatContext(context)
            )
        )

        table.insert(choices, actionChoice("Launch Course", "launchCourse", courseOptions))
        table.insert(choices, actionChoice("Open Notes", "openNotes", courseOptions))
        table.insert(choices, actionChoice("New Lecture", "newLecture", courseOptions))
        table.insert(choices, actionChoice("New Figure", "newFigure", activeOptions))
        table.insert(choices, actionChoice("Find Figure", "findFigure", activeOptions))
        table.insert(choices, actionChoice("Open Assignments", "openAssignments", courseOptions))
        table.insert(choices, actionChoice("New Assignment Figure", "newFigure", assignmentOptions))
        table.insert(choices, actionChoice("Find Assignment Figure", "findFigure", assignmentOptions))
        table.insert(choices, actionChoice("MATLAB", "openMatlab", courseOptions))
        table.insert(choices, actionChoice("Open MATLAB Folder", "openMatlabFolder", courseOptions))
        table.insert(choices, actionChoice("Open Literature", "openLiterature", courseOptions))
        table.insert(choices, actionChoice("Open Literature Folder", "openLiteratureFolder", courseOptions))
        table.insert(choices, actionChoice("References", "openReferences", courseOptions))
        table.insert(choices, actionChoice("Compile Current", "compileCurrent", activeOptions))
        table.insert(choices, actionChoice("Compile Recent", "compileRecent", activeOptions))
        table.insert(choices, actionChoice("Compile Range", "compileRange", courseOptions))
        table.insert(choices, actionChoice("Compile All", "compileAll", courseOptions))
        table.insert(choices, actionChoice("Course Webpage", "openCoursePage", courseOptions))
        table.insert(choices, actionChoice("Open Course Root", "openCourseRoot", courseOptions))
    else
        table.insert(
            choices,
            header(
                "NO ACTIVE COURSE",
                "Choose Courses… to select one explicitly"
            )
        )
    end

    table.insert(choices, header("NAVIGATION", "Explicit course/action routes"))
    table.insert(
        choices,
        navigation(
            "Courses…",
            "courses",
            "Choose a course, then an action"
        )
    )
    table.insert(
        choices,
        navigation(
            "Actions…",
            "actions",
            "Choose an action, then a course"
        )
    )

    local semester = Registry.getActiveSemester()
    local semesterLabel = semester and semester.name or State.getActiveSemester() or "none"

    table.insert(choices, header("MANAGEMENT", "Semester and configuration"))
    table.insert(
        choices,
        navigation(
            "Switch Semester…",
            "semesters",
            "Current · " .. tostring(semesterLabel)
        )
    )
    table.insert(choices, actionChoice("New Semester", "newSemester", nil))
    table.insert(choices, actionChoice("Reload Configuration", "reloadConfiguration", nil))

    local timetableEnabled = State.getTimetableAutoSwitchEnabled()
    table.insert(
        choices,
        actionChoice(
            "Automatic Timetable Switching · " .. (timetableEnabled and "On" or "Off"),
            "setTimetableAutoSwitchEnabled",
            { enabled = not timetableEnabled },
            "Level D uses only pre-programmed weekly course slots"
        )
    )

    return choices
end

function Launcher.buildCourseListChoices()
    local choices = {
        navigation("← Launcher", "root", "Back to active-course actions"),
        header("COURSES", "Explicit Level-A course selection"),
    }

    local courses, err = safeCourses()

    if not courses then
        table.insert(choices, header("Could not load courses", err))
        return choices
    end

    for _, course in ipairs(courses) do
        local subText = course.code

        if activeCourseMatches(course) then
            subText = tostring(subText) .. " · currently resolved"
        elseif State.getManualCourse() == course.id then
            subText = tostring(subText) .. " · manual fallback"
        end

        table.insert(
            choices,
            navigation(
                course.shortName or course.name,
                "course",
                subText,
                { courseId = course.id }
            )
        )
    end

    return choices
end

function Launcher.buildCourseChoices(course)
    local choices = {
        navigation("← Courses", "courses", "Choose another course"),
        header(
            (course.shortName or course.name):upper(),
            course.code .. " · explicit Level A"
        ),
    }

    local courseOptions = explicitCourseOptions(course)
    local currentOptions = optionsForCourseCurrentContext(course)
    local notesOptions = explicitCourseOptions(course, Context.WORK_CONTEXT.NOTES)
    local assignmentOptions = explicitCourseOptions(
        course,
        Context.WORK_CONTEXT.ASSIGNMENT
    )

    table.insert(choices, actionChoice("Set Active Course", "setActiveCourse", courseOptions))
    table.insert(choices, actionChoice("Launch Course", "launchCourse", courseOptions))

    table.insert(choices, header("NOTES", nil))
    table.insert(choices, actionChoice("Open Notes", "openNotes", courseOptions))
    table.insert(choices, actionChoice("New Lecture", "newLecture", courseOptions))
    table.insert(choices, actionChoice("Choose Lecture", "chooseLecture", courseOptions))
    table.insert(choices, actionChoice("New Notes Figure", "newFigure", notesOptions))
    table.insert(choices, actionChoice("Find Notes Figure", "findFigure", notesOptions))
    table.insert(choices, actionChoice("Compile Current", "compileCurrent", currentOptions))
    table.insert(choices, actionChoice("Compile Recent", "compileRecent", currentOptions))
    table.insert(choices, actionChoice("Compile Range", "compileRange", courseOptions))
    table.insert(choices, actionChoice("Compile Selected", "compileSelected", courseOptions))
    table.insert(choices, actionChoice("Compile All", "compileAll", courseOptions))

    table.insert(choices, header("ASSIGNMENTS", nil))
    table.insert(choices, actionChoice("Open Assignments", "openAssignments", courseOptions))
    table.insert(choices, actionChoice("New Assignment Figure", "newFigure", assignmentOptions))
    table.insert(choices, actionChoice("Find Assignment Figure", "findFigure", assignmentOptions))

    table.insert(choices, header("TOOLS & RESOURCES", nil))
    table.insert(choices, actionChoice("MATLAB", "openMatlab", courseOptions))
    table.insert(choices, actionChoice("Open MATLAB Folder", "openMatlabFolder", courseOptions))
    table.insert(choices, actionChoice("Open Literature", "openLiterature", courseOptions))
    table.insert(choices, actionChoice("Open Literature Folder", "openLiteratureFolder", courseOptions))
    table.insert(choices, actionChoice("References", "openReferences", courseOptions))
    table.insert(choices, actionChoice("Course Webpage", "openCoursePage", courseOptions))

    table.insert(choices, header("FOLDERS", nil))
    table.insert(choices, actionChoice("Open Course Root", "openCourseRoot", courseOptions))
    table.insert(choices, actionChoice("Open Notes Folder", "openNotesFolder", courseOptions))
    table.insert(choices, actionChoice("Open Lectures Folder", "openLecturesFolder", courseOptions))
    table.insert(choices, actionChoice("Open Notes Figures", "openNotesFigures", courseOptions))
    table.insert(choices, actionChoice("Open Assignments Folder", "openAssignments", courseOptions))
    table.insert(choices, actionChoice("Open Assignment Figures", "openAssignmentFigures", courseOptions))
    table.insert(choices, actionChoice("Open References Folder", "openReferencesFolder", courseOptions))

    return choices
end

local ACTION_FIRST = {
    { text = "Set Active Course", action = "setActiveCourse" },
    { text = "Launch Course", action = "launchCourse" },
    { text = "Open Notes", action = "openNotes" },
    { text = "New Lecture", action = "newLecture" },
    { text = "Choose Lecture", action = "chooseLecture" },
    {
        text = "New Notes Figure",
        action = "newFigure",
        workContext = Context.WORK_CONTEXT.NOTES,
    },
    {
        text = "Find Notes Figure",
        action = "findFigure",
        workContext = Context.WORK_CONTEXT.NOTES,
    },
    { text = "Open Assignments", action = "openAssignments" },
    {
        text = "New Assignment Figure",
        action = "newFigure",
        workContext = Context.WORK_CONTEXT.ASSIGNMENT,
    },
    {
        text = "Find Assignment Figure",
        action = "findFigure",
        workContext = Context.WORK_CONTEXT.ASSIGNMENT,
    },
    { text = "MATLAB", action = "openMatlab" },
    { text = "Open MATLAB Folder", action = "openMatlabFolder" },
    { text = "Open Literature", action = "openLiterature" },
    { text = "Open Literature Folder", action = "openLiteratureFolder" },
    { text = "References", action = "openReferences" },
    { text = "Compile Range", action = "compileRange" },
    { text = "Compile Selected", action = "compileSelected" },
    { text = "Compile All", action = "compileAll" },
    { text = "Course Webpage", action = "openCoursePage" },
    { text = "Open Course Root", action = "openCourseRoot" },
    { text = "Open Notes Folder", action = "openNotesFolder" },
    { text = "Open Lectures Folder", action = "openLecturesFolder" },
    { text = "Open Notes Figures", action = "openNotesFigures" },
    { text = "Open Assignment Figures", action = "openAssignmentFigures" },
    { text = "Open References Folder", action = "openReferencesFolder" },
}

function Launcher.buildActionListChoices()
    local choices = {
        navigation("← Launcher", "root", "Back to active-course actions"),
        header("ACTIONS", "Choose an action, then a course"),
    }

    for _, definition in ipairs(ACTION_FIRST) do
        local spec = Actions.describe(definition.action)
        local subText = nil

        if spec and spec.implemented ~= true then
            subText = "Not implemented yet · Part " .. tostring(spec.part or "?")
        end

        table.insert(choices, {
            text = definition.text,
            subText = subText,
            kind = "navigate",
            target = "actionCourses",
            actionName = definition.action,
            workContext = definition.workContext,
        })
    end

    return choices
end

function Launcher.buildActionCourseChoices(actionName, workContext, actionLabel)
    local choices = {
        navigation("← Actions", "actions", "Choose another action"),
        header(actionLabel or actionName, "Choose explicit course"),
    }

    local courses, err = safeCourses()

    if not courses then
        table.insert(choices, header("Could not load courses", err))
        return choices
    end

    for _, course in ipairs(courses) do
        local options = explicitCourseOptions(course, workContext)
        local choice = actionChoice(
            course.shortName or course.name,
            actionName,
            options,
            course.code
        )
        table.insert(choices, choice)
    end

    return choices
end

local function listSemesterChoices()
    local choices = {
        navigation("← Launcher", "root", "Back to active-course actions"),
        header("SEMESTERS", "Semester switching is always manual"),
    }

    local ok, iteratorOrErr, directoryObject = pcall(
        hs.fs.dir,
        Config.SEMESTERS_ROOT
    )

    if not ok then
        table.insert(
            choices,
            header(
                "Could not list semesters",
                tostring(iteratorOrErr)
            )
        )
        return choices
    end

    local semesterIds = {}

    for name in iteratorOrErr, directoryObject do
        if name ~= "." and name ~= ".." then
            local root = Util.joinPath(Config.SEMESTERS_ROOT, name)

            if hs.fs.attributes(root, "mode") == "directory" then
                table.insert(semesterIds, name)
            end
        end
    end

    table.sort(semesterIds)

    for _, semesterId in ipairs(semesterIds) do
        local snapshot, err = Config.loadSemester(semesterId)

        if snapshot then
            local semester = snapshot.semester
            local subText = semester.id

            if State.getActiveSemester() == semester.id then
                subText = subText .. " · active"
            end

            table.insert(choices, {
                text = semester.name,
                subText = subText,
                kind = "semester",
                semesterId = semester.id,
            })
        else
            table.insert(choices, {
                text = semesterId,
                subText = "Invalid configuration · " .. tostring(err),
                valid = false,
                kind = "disabled",
                disabledReason = tostring(err),
            })
        end
    end

    if #semesterIds == 0 then
        table.insert(choices, header("No semesters found", Config.SEMESTERS_ROOT))
    end

    return choices
end

local function ensureChooser()
    if Launcher._chooser then
        return Launcher._chooser
    end

    local chooser = hs.chooser.new(function(choice)
        if not choice then
            return
        end

        Launcher._dispatch(choice)
    end)

    chooser:searchSubText(true)
    chooser:width(WIDTH)
    chooser:rows(ROOT_ROWS)
    chooser:invalidCallback(function(choice)
        if not choice or choice.kind == "header" then
            return
        end

        notify(choice.disabledReason or "This launcher entry is unavailable.")
    end)

    Launcher._chooser = chooser
    return chooser
end

local function present(choices, placeholder, rows, selectedRow)
    local chooser = ensureChooser()
    chooser:choices(choices)
    chooser:placeholderText(placeholder)
    chooser:rows(rows or CHILD_ROWS)
    chooser:query("")
    chooser:show()

    if selectedRow then
        chooser:selectedRow(selectedRow)
    end
end

local function invoke(actionName, options)
    local fn = Actions[actionName]

    if type(fn) ~= "function" then
        notify('Unknown action "' .. tostring(actionName) .. '".')
        return
    end

    local result, err = fn(options)

    if not result then
        if err then
            notify(err)
        end
        return
    end

    if actionName == "setActiveCourse" then
        local course = result
        notify("Active course · " .. (course.shortName or course.name or course.id))
    elseif actionName == "reloadConfiguration" then
        notify("Course configuration reloaded.")
    elseif actionName == "setTimetableAutoSwitchEnabled"
        or actionName == "setCalendarAutoSwitchEnabled" then
        notify(
            result.enabled == true
                and "Automatic timetable switching enabled."
                or "Automatic timetable switching disabled."
        )
    end
end

function Launcher._dispatch(choice)
    if choice.kind == "action" then
        invoke(choice.actionName, actionOptionsFromChoice(choice))
        return
    end

    if choice.kind == "semester" then
        local semester, err = Actions.setActiveSemester(choice.semesterId)

        if not semester then
            notify(err)
            return
        end

        notify("Active semester · " .. semester.name)
        Launcher.show()
        return
    end

    if choice.kind ~= "navigate" then
        return
    end

    if choice.target == "root" then
        Launcher.show()
    elseif choice.target == "courses" then
        Launcher.showCourses()
    elseif choice.target == "actions" then
        Launcher.showActions()
    elseif choice.target == "semesters" then
        Launcher.showSemesters()
    elseif choice.target == "course" then
        Launcher.showCourse(choice.courseId)
    elseif choice.target == "actionCourses" then
        Launcher.showActionCourses(
            choice.actionName,
            choice.workContext,
            choice.text
        )
    end
end

function Launcher.show()
    -- Resolve BEFORE hs.chooser takes focus. This preserves exact Level-B
    -- evidence from Neovim/Skim/Finder and makes the prominent active-course
    -- actions stable for the lifetime of this launcher invocation.
    local context = Context.resolve()
    Launcher._activeContext = context

    present(
        Launcher.buildRootChoices(context),
        context and context.course
            and ("Course actions · " .. (context.course.shortName or context.course.name))
            or "Course launcher · choose a course",
        ROOT_ROWS,
        context and context.course and 2 or 3
    )
end

function Launcher.showCourses()
    present(
        Launcher.buildCourseListChoices(),
        "Courses · choose explicit course",
        CHILD_ROWS,
        3
    )
end

function Launcher.showCourse(courseId)
    local course, err = Registry.getCourse(courseId)

    if not course then
        notify(err or ('Unknown course "' .. tostring(courseId) .. '".'))
        return
    end

    present(
        Launcher.buildCourseChoices(course),
        course.shortName or course.name,
        CHILD_ROWS,
        3
    )
end

function Launcher.showActions()
    present(
        Launcher.buildActionListChoices(),
        "Actions · choose action",
        CHILD_ROWS,
        3
    )
end

function Launcher.showActionCourses(actionName, workContext, actionLabel)
    present(
        Launcher.buildActionCourseChoices(
            actionName,
            workContext,
            actionLabel
        ),
        (actionLabel or actionName) .. " · choose course",
        CHILD_ROWS,
        3
    )
end

function Launcher.showSemesters()
    present(
        listSemesterChoices(),
        "Switch semester",
        CHILD_ROWS,
        3
    )
end

function Launcher.start()
    ensureChooser()
    Launcher._started = true
    return true
end

function Launcher.stop()
    if Launcher._chooser then
        Launcher._chooser:hide()
        Launcher._chooser:delete()
        Launcher._chooser = nil
    end

    Launcher._activeContext = nil
    Launcher._started = false
    return true
end

function Launcher.toggle()
    local chooser = ensureChooser()

    if chooser:isVisible() then
        chooser:hide()
        return
    end

    Launcher.show()
end

return Launcher

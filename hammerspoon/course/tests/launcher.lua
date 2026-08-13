local Tests = {}

local Context = require("course.context")
local Launcher = require("course.launcher")
local Registry = require("course.registry")
local State = require("course.state")
local Actions = require("course.actions")

local TEST_SEMESTER = "semtest"
local COURSE_A = "test-dynamics"

local function fail(message)
    error(message, 2)
end

local function assertEqual(actual, expected, label)
    if actual ~= expected then
        fail(string.format(
            "%s: expected %s, got %s",
            label,
            tostring(expected),
            tostring(actual)
        ))
    end
end

local function assertTruthy(value, label)
    if not value then
        fail(label .. ": expected a truthy value")
    end
end

local function assertNil(value, label)
    if value ~= nil then
        fail(string.format(
            "%s: expected nil, got %s",
            label,
            tostring(value)
        ))
    end
end

local function choiceByText(choices, text)
    for _, choice in ipairs(choices) do
        if choice.text == text then
            return choice
        end
    end

    return nil
end

local function choiceIndex(choices, text)
    for index, choice in ipairs(choices) do
        if choice.text == text then
            return index
        end
    end

    return nil
end

local function restoreState(snapshot)
    if snapshot.activeSemester then
        State.setActiveSemester(snapshot.activeSemester)
    else
        State.clearActiveSemester()
    end

    State.setCalendarAutoSwitchEnabled(snapshot.calendarAutoSwitchEnabled)

    if snapshot.manualCourse then
        State.setManualCourse(snapshot.manualCourse)
    else
        State.clearManualCourse()
    end

    if snapshot.manualOverrideState then
        State.setManualOverrideState(snapshot.manualOverrideState)
    else
        State.clearManualOverrideState()
    end

    Registry.clear()

    if snapshot.activeSemester then
        Registry.reload()
    end
end

local function prepare()
    local semester, err = Actions.setActiveSemester(TEST_SEMESTER)

    if not semester then
        fail(err or "Could not activate test semester.")
    end

    local course, courseErr = Registry.getCourse(COURSE_A)

    if not course then
        fail(courseErr or "Test course missing.")
    end

    return course
end

local function runCases(course)
    local cases = {}

    local function case(name, fn)
        table.insert(cases, { name = name, fn = fn })
    end

    local context = Context.makeResult({
        course = course,
        workContext = Context.WORK_CONTEXT.NOTES,
        lecture = 7,
        level = Context.LEVEL.PATH,
        source = Context.SOURCE.NEOVIM_PATH,
        confidence = "exact",
    })

    case("root is active-course first", function()
        local choices = Launcher.buildRootChoices(context)

        assertEqual(
            choices[1].text,
            "ACTIVE · " .. (course.shortName or course.name),
            "active header"
        )
        assertEqual(choices[2].text, "Launch Course", "first active action")

        local coursesIndex = choiceIndex(choices, "Courses…")
        local rootIndex = choiceIndex(choices, "Open Course Root")

        assertTruthy(coursesIndex, "courses navigation exists")
        assertTruthy(rootIndex, "course-root action exists")
        assertTruthy(
            coursesIndex > rootIndex,
            "course navigation follows prominent active actions"
        )
    end)

    case("active context is frozen into current-context actions", function()
        local choices = Launcher.buildRootChoices(context)
        local current = choiceByText(choices, "Compile Current")

        assertTruthy(current, "compile-current choice")
        assertEqual(current.courseId, course.id, "compile-current course")
        assertEqual(current.workContext, "notes", "compile-current context")
        assertEqual(current.lecture, 7, "compile-current lecture")
    end)

    case("assignment figure is explicit Level A", function()
        local choices = Launcher.buildRootChoices(context)
        local figure = choiceByText(choices, "New Assignment Figure")

        assertTruthy(figure, "assignment-figure choice")
        assertEqual(figure.actionName, "newFigure", "assignment-figure action")
        assertEqual(figure.courseId, course.id, "assignment-figure course")
        assertEqual(
            figure.workContext,
            Context.WORK_CONTEXT.ASSIGNMENT,
            "assignment-figure work context"
        )
    end)

    case("implemented course, lecture, and compile actions are enabled", function()
        local choices = Launcher.buildRootChoices(context)
        local launch = choiceByText(choices, "Launch Course")
        local page = choiceByText(choices, "Course Webpage")
        local notes = choiceByText(choices, "Open Notes")
        local current = choiceByText(choices, "Compile Current")

        assertTruthy(launch, "launch choice")
        assertTruthy(page, "course-page choice")
        assertTruthy(notes, "notes choice")
        assertTruthy(current, "compile-current choice")
        assertEqual(launch.valid, true, "launch validity")
        assertEqual(page.valid, true, "course-page validity")
        assertEqual(notes.valid, true, "notes validity")
        assertEqual(current.valid, true, "compile-current validity")
    end)

    case("management actions are implemented and selectable", function()
        local choices = Launcher.buildRootChoices(context)
        local newSemester = choiceByText(choices, "New Semester")
        local reload = choiceByText(choices, "Reload Configuration")

        assertTruthy(newSemester, "new-semester choice")
        assertTruthy(reload, "reload choice")
        assertEqual(newSemester.valid, true, "new-semester validity")
        assertEqual(reload.valid, true, "reload validity")
    end)

    case("course submenu exposes explicit notes and assignment figure routes", function()
        Launcher._activeContext = context
        local choices = Launcher.buildCourseChoices(course)
        local notesFigure = choiceByText(choices, "New Notes Figure")
        local assignmentFigure = choiceByText(choices, "New Assignment Figure")
        local setActive = choiceByText(choices, "Set Active Course")

        assertEqual(notesFigure.courseId, course.id, "notes-figure course")
        assertEqual(notesFigure.workContext, "notes", "notes-figure context")
        assertEqual(assignmentFigure.workContext, "assignment", "assignment context")
        assertEqual(setActive.valid, true, "set-active validity")
    end)

    case("action-first navigation carries fixed work context", function()
        local actions = Launcher.buildActionListChoices()
        local definition = choiceByText(actions, "New Notes Figure")

        assertTruthy(definition, "action-first notes figure")
        assertEqual(definition.target, "actionCourses", "action-first target")
        assertEqual(definition.actionName, "newFigure", "action-first action")
        assertEqual(definition.workContext, "notes", "action-first work context")

        local courses = Launcher.buildActionCourseChoices(
            definition.actionName,
            definition.workContext,
            definition.text
        )
        local courseChoice = choiceByText(courses, course.shortName or course.name)

        assertTruthy(courseChoice, "action-first course choice")
        assertEqual(courseChoice.courseId, course.id, "action-first explicit course")
        assertEqual(courseChoice.workContext, "notes", "action-first explicit context")
    end)

    local passed = 0

    for _, testCase in ipairs(cases) do
        testCase.fn()
        passed = passed + 1
        print("✓ " .. testCase.name)
    end

    return passed, #cases
end

function Tests.run()
    local previous = State.snapshot()
    local previousContext = Launcher._activeContext

    local ok, resultOrError, total = xpcall(function()
        local course = prepare()
        local passed, count = runCases(course)
        return passed, count
    end, debug.traceback)

    Launcher._activeContext = previousContext
    restoreState(previous)

    if not ok then
        print("✗ Launcher tests failed")
        print(resultOrError)
        return nil, resultOrError
    end

    print(string.format("Launcher tests passed: %d/%d", resultOrError, total))
    return true
end

return Tests

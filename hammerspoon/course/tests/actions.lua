local Tests = {}

local Actions = require("course.actions")
local Context = require("course.context")
local Registry = require("course.registry")
local State = require("course.state")

local TEST_SEMESTER = "semtest"
local COURSE_A = "test-dynamics"
local COURSE_B = "test-materials"
local NON_COURSE_PATH = "/tmp/course-workflow-actions-test-outside"

local EXPECTED_ACTIONS = {
    "setActiveSemester",
    "setActiveCourse",
    "newSemester",
    "reloadConfiguration",
    "setCalendarAutoSwitchEnabled",
    "launchCourse",
    "openCourseRoot",
    "openNotes",
    "newLecture",
    "chooseLecture",
    "openAssignments",
    "newFigure",
    "findFigure",
    "openMatlab",
    "openLiterature",
    "openLiteratureFolder",
    "openReferences",
    "openCoursePage",
    "compileCurrent",
    "compileRecent",
    "compileRange",
    "compileSelected",
    "compileAll",
}

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

local function assertNil(value, label)
    if value ~= nil then
        fail(string.format(
            "%s: expected nil, got %s",
            label,
            tostring(value)
        ))
    end
end

local function assertTruthy(value, label)
    if not value then
        fail(label .. ": expected a truthy value")
    end
end

local function assertContains(value, needle, label)
    if type(value) ~= "string" or not value:find(needle, 1, true) then
        fail(string.format(
            "%s: expected %q to contain %q",
            label,
            tostring(value),
            needle
        ))
    end
end

local function noCalendarRuntime()
    return { calendarContext = false }
end

local function resetManual()
    State.clearManualContext()
    State.setCalendarAutoSwitchEnabled(true)
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
    local semester, semesterErr = Actions.setActiveSemester(TEST_SEMESTER)

    if not semester then
        fail(
            "Could not activate test semester. Make sure semtest is installed "
                .. "under ~/.config/course-workflow/semesters/semtest: "
                .. tostring(semesterErr)
        )
    end

    resetManual()

    local courseA, errA = Registry.getCourse(COURSE_A)
    local courseB, errB = Registry.getCourse(COURSE_B)

    if not courseA then
        fail(errA or "First test course is missing.")
    end

    if not courseB then
        fail(errB or "Second test course is missing.")
    end

    return courseA, courseB
end

local function runCases(courseA, courseB)
    local cases = {}

    local function case(name, fn)
        table.insert(cases, { name = name, fn = fn })
    end

    case("canonical API surface exists", function()
        for _, name in ipairs(EXPECTED_ACTIONS) do
            assertEqual(type(Actions[name]), "function", name .. " function")
            assertTruthy(Actions.describe(name), name .. " spec")
        end
    end)

    case("explicit course outranks manual course", function()
        local activated, activateErr = Actions.setActiveCourse(
            { course = courseA.id },
            noCalendarRuntime()
        )

        assertTruthy(activated, "manual activation")
        assertNil(activateErr, "manual activation error")

        local context, err = Actions.resolveFor(
            "openNotes",
            {
                course = courseB.id,
                path = NON_COURSE_PATH,
            },
            noCalendarRuntime()
        )

        assertNil(err, "explicit resolution error")
        assertEqual(context.level, Context.LEVEL.EXPLICIT, "explicit level")
        assertEqual(context.course.id, courseB.id, "explicit course")
        assertEqual(State.getManualCourse(), courseA.id, "manual course unchanged")
    end)

    case("explicit assignment context satisfies figure action", function()
        local context, err = Actions.resolveFor(
            "newFigure",
            {
                course = courseB.id,
                workContext = Context.WORK_CONTEXT.ASSIGNMENT,
            },
            noCalendarRuntime()
        )

        assertNil(err, "figure context error")
        assertEqual(context.course.id, courseB.id, "figure course")
        assertEqual(context.workContext, "assignment", "figure work context")
    end)

    case("figure action refuses unknown work context", function()
        resetManual()

        local context, err = Actions.resolveFor(
            "newFigure",
            { course = courseA.id },
            noCalendarRuntime()
        )

        assertNil(context, "figure context")
        assertEqual(err, Actions.ERROR.NO_WORK_CONTEXT, "figure error")
    end)

    case("new figure bridges explicit notes scope", function()
        local captured = nil
        local runtime = {
            calendarContext = false,
            writeFigureBridge = function(path, contents)
                return true
            end,
            openFigureWorkflow = function(command, workingDirectory, bundleId)
                captured = {
                    command = command,
                    workingDirectory = workingDirectory,
                    bundleId = bundleId,
                }
                return true
            end,
        }

        local result, err = Actions.newFigure({
            course = courseA.id,
            workContext = Context.WORK_CONTEXT.NOTES,
        }, runtime)

        assertNil(err, "new-figure bridge error")
        assertTruthy(result, "new-figure bridge result")
        assertEqual(result.workContext, "notes", "new-figure work context")
        assertEqual(result.figuresDir, courseA.notes.figures, "new-figure directory")
        assertTruthy(captured, "new-figure invocation captured")
        assertEqual(captured.workingDirectory, courseA.notes.root, "new-figure cwd")
        assertContains(captured.command, "NOAH_COURSE_FIGURE_BRIDGE", "new-figure command")
    end)

    case("find figure bridges explicit assignment scope", function()
        local captured = nil
        local runtime = {
            calendarContext = false,
            writeFigureBridge = function(path, contents)
                return true
            end,
            openFigureWorkflow = function(command, workingDirectory, bundleId)
                captured = {
                    command = command,
                    workingDirectory = workingDirectory,
                    bundleId = bundleId,
                }
                return true
            end,
        }

        local result, err = Actions.findFigure({
            course = courseB.id,
            workContext = Context.WORK_CONTEXT.ASSIGNMENT,
        }, runtime)

        assertNil(err, "find-figure bridge error")
        assertTruthy(result, "find-figure bridge result")
        assertEqual(result.workContext, "assignment", "find-figure work context")
        assertEqual(
            result.figuresDir,
            courseB.assignments.figures,
            "find-figure directory"
        )
        assertTruthy(captured, "find-figure invocation captured")
        assertEqual(
            captured.workingDirectory,
            courseB.assignments.root,
            "find-figure cwd"
        )
        assertContains(captured.command, "NOAH_COURSE_FIGURE_BRIDGE", "find-figure command")
    end)

    case("compile current requires exact notes lecture", function()
        local context, err = Actions.resolveFor(
            "compileCurrent",
            {
                course = courseA.id,
                workContext = Context.WORK_CONTEXT.NOTES,
                lecture = 7,
            },
            noCalendarRuntime()
        )

        assertNil(err, "compile-current error")
        assertEqual(context.lecture, 7, "compile-current lecture")
        assertEqual(context.workContext, "notes", "compile-current work context")
    end)

    case("compile current rejects assignment context", function()
        local context, err = Actions.resolveFor(
            "compileCurrent",
            {
                course = courseA.id,
                workContext = Context.WORK_CONTEXT.ASSIGNMENT,
            },
            noCalendarRuntime()
        )

        assertNil(context, "assignment compile context")
        assertContains(err, "requires notes context", "assignment compile error")
    end)

    case("compile current refuses missing lecture", function()
        local context, err = Actions.resolveFor(
            "compileCurrent",
            {
                course = courseA.id,
                workContext = Context.WORK_CONTEXT.NOTES,
            },
            noCalendarRuntime()
        )

        assertNil(context, "missing-lecture context")
        assertEqual(err, Actions.ERROR.NO_LECTURE, "missing-lecture error")
    end)

    case("no context fails safely", function()
        resetManual()

        local context, err = Actions.resolveFor(
            "openNotes",
            { path = NON_COURSE_PATH },
            noCalendarRuntime()
        )

        assertNil(context, "no-context result")
        assertEqual(err, Context.ERROR.NO_COURSE, "no-context error")
    end)

    case("set active course accepts explicit action options", function()
        resetManual()

        local course, err = Actions.setActiveCourse(
            { course = courseB.id },
            noCalendarRuntime()
        )

        assertNil(err, "set-active-course error")
        assertEqual(course.id, courseB.id, "set-active-course result")
        assertEqual(State.getManualCourse(), courseB.id, "persisted manual course")
    end)

    case("set active course accepts course object", function()
        resetManual()

        local course, err = Actions.setActiveCourse(
            courseA,
            noCalendarRuntime()
        )

        assertNil(err, "course-object error")
        assertEqual(course.id, courseA.id, "course-object result")
        assertEqual(State.getManualCourse(), courseA.id, "course-object persisted")
    end)

    case("new semester delegates to existing wizard through central API", function()
        local called = false
        local marker = { created = true }
        local result, err = Actions.newSemester(nil, {
            semesterWizard = {
                start = function()
                    called = true
                    return marker
                end,
            },
        })

        assertNil(err, "new-semester error")
        assertTruthy(called, "new-semester wizard called")
        assertEqual(result, marker, "new-semester result")
    end)

    case("reload configuration is a central implemented action", function()
        local result, err = Actions.reloadConfiguration()

        assertNil(err, "reload-configuration error")
        assertTruthy(result, "reload-configuration result")
    end)

    case("calendar auto switching is controlled through the central API", function()
        local previous = State.getCalendarAutoSwitchEnabled()

        local disabled, disableErr = Actions.setCalendarAutoSwitchEnabled(false)
        assertNil(disableErr, "calendar disable error")
        assertEqual(disabled.enabled, false, "calendar disable result")
        assertEqual(
            State.getCalendarAutoSwitchEnabled(),
            false,
            "calendar disabled state"
        )

        local enabled, enableErr = Actions.setCalendarAutoSwitchEnabled({
            enabled = true,
        })
        assertNil(enableErr, "calendar enable error")
        assertEqual(enabled.enabled, true, "calendar enable result")
        assertEqual(
            State.getCalendarAutoSwitchEnabled(),
            true,
            "calendar enabled state"
        )

        State.setCalendarAutoSwitchEnabled(previous)
    end)

    case("launch course performs the Part VIII app sequence", function()
        resetManual()

        local calls = {}
        local runtime = {
            calendarContext = false,
            pathMode = function(path)
                if path == courseB.root then
                    return "directory"
                end

                if path == courseB.book then
                    return "file"
                end

                return nil
            end,
            openItermAt = function(path, bundleId)
                table.insert(calls, { "iterm", path, bundleId })
                return true
            end,
            openFileWithBundle = function(path, bundleId)
                table.insert(calls, { "book", path, bundleId })
                return true
            end,
            openURLWithBundle = function(url, bundleId)
                table.insert(calls, { "url", url, bundleId })
                return true
            end,
            notify = function(message)
                table.insert(calls, { "notify", message })
                return true
            end,
        }

        local course, err = Actions.launchCourse(
            { course = courseB.id },
            runtime
        )

        assertNil(err, "launch-course error")
        assertEqual(course.id, courseB.id, "launch-course result")
        assertEqual(State.getManualCourse(), courseB.id, "launch manual course")
        assertEqual(#calls, 3, "launch call count")
        assertEqual(calls[1][1], "iterm", "launch first app")
        assertEqual(calls[1][2], courseB.root, "launch iTerm path")
        assertEqual(calls[1][3], "com.googlecode.iterm2", "launch iTerm bundle")
        assertEqual(calls[2][1], "book", "launch second app")
        assertEqual(calls[2][2], courseB.book, "launch textbook path")
        assertEqual(calls[2][3], "net.sourceforge.skim-app.skim", "launch Skim bundle")
        assertEqual(calls[3][1], "url", "launch third app")
        assertEqual(calls[3][2], courseB.courseUrl, "launch course URL")
        assertEqual(calls[3][3], "com.apple.Safari", "launch Safari bundle")
    end)

    case("launch course skips a missing textbook and continues", function()
        resetManual()

        local calls = {}
        local runtime = {
            calendarContext = false,
            pathMode = function(path)
                if path == courseA.root then
                    return "directory"
                end

                if path == courseA.book then
                    return nil
                end

                return nil
            end,
            openItermAt = function(path, bundleId)
                table.insert(calls, { "iterm", path, bundleId })
                return true
            end,
            openFileWithBundle = function(path, bundleId)
                table.insert(calls, { "book", path, bundleId })
                return true
            end,
            openURLWithBundle = function(url, bundleId)
                table.insert(calls, { "url", url, bundleId })
                return true
            end,
            notify = function(message)
                table.insert(calls, { "notify", message })
                return true
            end,
        }

        local course, err = Actions.launchCourse(
            { course = courseA.id },
            runtime
        )

        assertNil(err, "missing-book launch error")
        assertEqual(course.id, courseA.id, "missing-book launch result")
        assertEqual(State.getManualCourse(), courseA.id, "missing-book manual course")
        assertEqual(#calls, 3, "missing-book call count")
        assertEqual(calls[1][1], "iterm", "missing-book iTerm call")
        assertEqual(calls[2][1], "notify", "missing-book notification")
        assertContains(calls[2][2], "No textbook available", "missing-book message")
        assertEqual(calls[3][1], "url", "missing-book Safari call")
    end)

    case("open course page uses Safari without changing manual course", function()
        resetManual()

        local openedUrl = nil
        local openedBundle = nil
        local course, err = Actions.openCoursePage(
            { course = courseB.id },
            {
                calendarContext = false,
                openURLWithBundle = function(url, bundleId)
                    openedUrl = url
                    openedBundle = bundleId
                    return true
                end,
            }
        )

        assertNil(err, "open-course-page error")
        assertEqual(course.id, courseB.id, "open-course-page result")
        assertEqual(openedUrl, courseB.courseUrl, "open-course-page URL")
        assertEqual(openedBundle, "com.apple.Safari", "open-course-page bundle")
        assertNil(State.getManualCourse(), "open-course-page manual course")
    end)

    case("launch course reports terminal failure but still opens webpage", function()
        resetManual()

        local webpageOpened = false
        local course, err = Actions.launchCourse(
            { course = courseA.id },
            {
                calendarContext = false,
                pathMode = function(path)
                    if path == courseA.root then
                        return "directory"
                    end

                    return nil
                end,
                openItermAt = function()
                    return nil, "simulated iTerm failure"
                end,
                openURLWithBundle = function()
                    webpageOpened = true
                    return true
                end,
                notify = function()
                    return true
                end,
            }
        )

        assertNil(course, "terminal-failure launch result")
        assertContains(err, "simulated iTerm failure", "terminal-failure error")
        assertTruthy(webpageOpened, "terminal-failure webpage continuation")
        assertEqual(State.getManualCourse(), courseA.id, "terminal-failure manual course")
    end)

    case("deferred action still validates explicit context", function()
        local result, err = Actions.openCourseRoot(
            { course = courseB.id },
            noCalendarRuntime()
        )

        assertNil(result, "deferred result")
        assertContains(err, 'Action "openCourseRoot" is defined', "deferred error")
    end)

    case("compile current starts a selective build with exact lecture", function()
        local captured = nil
        local result, err = Actions.compileCurrent(
            {
                course = courseA.id,
                workContext = Context.WORK_CONTEXT.NOTES,
                lecture = 7,
            },
            {
                calendarContext = false,
                startLatexBuild = function(course, request)
                    captured = { course = course, request = request }
                    return { started = true }
                end,
                notify = function()
                    return true
                end,
            }
        )

        assertNil(err, "compile-current start error")
        assertTruthy(result, "compile-current build result")
        assertEqual(captured.course.id, courseA.id, "compile-current course")
        assertEqual(captured.request.lectureNumbers[1], 7, "compile-current lecture")
        assertContains(captured.request.label, "lec_07", "compile-current label")
    end)

    case("compile all starts canonical master build", function()
        local captured = nil
        local result, err = Actions.compileAll(
            { course = courseB.id },
            {
                calendarContext = false,
                startLatexBuild = function(course, request)
                    captured = { course = course, request = request }
                    return { started = true }
                end,
                notify = function()
                    return true
                end,
            }
        )

        assertNil(err, "compile-all start error")
        assertTruthy(result, "compile-all build result")
        assertEqual(captured.course.id, courseB.id, "compile-all course")
        assertNil(captured.request.lectureNumbers, "compile-all selection")
        assertContains(captured.request.label, "all lectures", "compile-all label")
    end)

    case("invalid semester does not evict active semester", function()
        local before = State.getActiveSemester()
        local semester, err = Actions.setActiveSemester(
            "definitely-not-a-real-semester"
        )

        assertNil(semester, "invalid semester result")
        assertTruthy(err, "invalid semester error")
        assertEqual(State.getActiveSemester(), before, "active semester preserved")
    end)

    case("set active semester returns loaded semester", function()
        local semester, err = Actions.setActiveSemester(TEST_SEMESTER)

        assertNil(err, "semester activation error")
        assertEqual(semester.id, TEST_SEMESTER, "semester activation id")
    end)

    case("unknown action fails explicitly", function()
        local context, err = Actions.resolveFor(
            "notARealAction",
            { course = courseA.id },
            noCalendarRuntime()
        )

        assertNil(context, "unknown action result")
        assertContains(err, "Unknown action", "unknown action error")
    end)

    local passed = 0

    for _, testCase in ipairs(cases) do
        resetManual()
        testCase.fn()
        passed = passed + 1
        print("✓ " .. testCase.name)
    end

    return passed, #cases
end

function Tests.run()
    local previous = State.snapshot()

    local ok, resultOrError, total = xpcall(function()
        local courseA, courseB = prepare()
        local passed, count = runCases(courseA, courseB)
        return passed, count
    end, debug.traceback)

    restoreState(previous)

    if not ok then
        print("✗ Action tests failed")
        print(resultOrError)
        return nil, resultOrError
    end

    print(string.format("Action tests passed: %d/%d", resultOrError, total))
    return true
end

return Tests

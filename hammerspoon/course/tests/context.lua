local Tests = {}

local Context = require("course.context")
local Registry = require("course.registry")
local State = require("course.state")
local Util = require("course.util")

local TEST_SEMESTER = "semtest"
local TEST_COURSE = "test-dynamics"
local NON_COURSE_PATH = "/tmp/course-workflow-context-test-outside"

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
        fail(string.format("%s: expected nil, got %s", label, tostring(value)))
    end
end

local function assertTruthy(value, label)
    if not value then
        fail(label .. ": expected a truthy value")
    end
end

local function calendarContext(course, ...)
    return {
        course = course,
        eventKeys = { ... },
    }
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
    local ok, err = State.setActiveSemester(TEST_SEMESTER)

    if not ok then
        fail(err)
    end

    Registry.clear()

    ok, err = Registry.reload()

    if not ok then
        fail(
            "Could not load test semester. Make sure semtest is installed under "
                .. "~/.config/course-workflow/semesters/semtest: "
                .. tostring(err)
        )
    end

    resetManual()

    local course, courseErr = Registry.getCourse(TEST_COURSE)

    if not course then
        fail(courseErr or "Test course is missing.")
    end

    return course
end

local function runCases(course)
    local cases = {}

    local function case(name, fn)
        table.insert(cases, { name = name, fn = fn })
    end

    case("explicit course", function()
        local result, err = Context.resolve({
            course = course.id,
            path = NON_COURSE_PATH,
        }, noCalendarRuntime())

        assertNil(err, "explicit course error")
        assertEqual(result.level, Context.LEVEL.EXPLICIT, "explicit course level")
        assertEqual(result.course.id, course.id, "explicit course id")
    end)

    case("explicit assignment context", function()
        local result, err = Context.resolve({
            course = course.id,
            workContext = Context.WORK_CONTEXT.ASSIGNMENT,
            path = NON_COURSE_PATH,
        }, noCalendarRuntime())

        assertNil(err, "explicit assignment error")
        assertEqual(result.level, Context.LEVEL.EXPLICIT, "explicit assignment level")
        assertEqual(result.workContext, Context.WORK_CONTEXT.ASSIGNMENT, "explicit assignment context")
    end)

    case("Neovim lecture path", function()
        local path = Util.joinPath(course.notes.lectures, "lec_07.tex")
        local result, err = Context.resolve({
            path = path,
            pathSource = Context.SOURCE.NEOVIM_PATH,
        }, noCalendarRuntime())

        assertNil(err, "lecture path error")
        assertEqual(result.level, Context.LEVEL.PATH, "lecture path level")
        assertEqual(result.source, Context.SOURCE.NEOVIM_PATH, "lecture path source")
        assertEqual(result.workContext, Context.WORK_CONTEXT.NOTES, "lecture path work context")
        assertEqual(result.lecture, 7, "lecture path lecture")
    end)

    case("Neovim assignment path", function()
        local path = Util.joinPath(course.assignments.root, "problem-set-alpha.tex")
        local result, err = Context.resolve({
            path = path,
            pathSource = Context.SOURCE.NEOVIM_PATH,
        }, noCalendarRuntime())

        assertNil(err, "assignment path error")
        assertEqual(result.level, Context.LEVEL.PATH, "assignment path level")
        assertEqual(result.workContext, Context.WORK_CONTEXT.ASSIGNMENT, "assignment path work context")
        assertNil(result.lecture, "assignment path lecture")
    end)

    case("course root path", function()
        local result, err = Context.resolve({ path = course.root }, noCalendarRuntime())

        assertNil(err, "course root error")
        assertEqual(result.level, Context.LEVEL.PATH, "course root level")
        assertEqual(result.course.id, course.id, "course root course")
        assertNil(result.workContext, "course root work context")
    end)

    case("non-course path", function()
        resetManual()
        local result, err = Context.resolve({ path = NON_COURSE_PATH }, noCalendarRuntime())

        assertNil(result, "non-course result")
        assertEqual(err, Context.ERROR.NO_COURSE, "non-course safe failure")
    end)

    case("manual course only", function()
        resetManual()
        local activated, activateErr = Context.activateManualCourse(
            course.id,
            noCalendarRuntime()
        )

        assertTruthy(activated, "manual activation")
        assertNil(activateErr, "manual activation error")

        local result, err = Context.resolve(
            { path = NON_COURSE_PATH },
            noCalendarRuntime()
        )

        assertNil(err, "manual-only error")
        assertEqual(result.level, Context.LEVEL.MANUAL, "manual-only level")
        assertEqual(result.course.id, course.id, "manual-only course")
    end)

    case("calendar course only", function()
        resetManual()
        local event = calendarContext(course, "event-1")
        local result, err = Context.resolve(
            { path = NON_COURSE_PATH },
            { calendarContext = event }
        )

        assertNil(err, "calendar-only error")
        assertEqual(result.level, Context.LEVEL.CALENDAR, "calendar-only level")
        assertEqual(result.course.id, course.id, "calendar-only course")
    end)

    case("manual override during calendar event", function()
        resetManual()
        local event = calendarContext(course, "event-1")

        local activated, activateErr = Context.activateManualCourse(
            course.id,
            { calendarContext = event }
        )

        assertTruthy(activated, "manual override activation")
        assertNil(activateErr, "manual override activation error")

        local result, err = Context.resolve(
            { path = NON_COURSE_PATH },
            { calendarContext = event }
        )

        assertNil(err, "manual override error")
        assertEqual(result.level, Context.LEVEL.MANUAL, "manual override level")
    end)

    case("next calendar event expires manual override", function()
        resetManual()
        local event1 = calendarContext(course, "event-1")
        local event2 = calendarContext(course, "event-2")

        local activated, activateErr = Context.activateManualCourse(
            course.id,
            { calendarContext = event1 }
        )

        assertTruthy(activated, "next-event activation")
        assertNil(activateErr, "next-event activation error")

        local result, err = Context.resolve(
            { path = NON_COURSE_PATH },
            { calendarContext = event2 }
        )

        assertNil(err, "next-event error")
        assertEqual(result.level, Context.LEVEL.CALENDAR, "next-event level")
        assertNil(State.getManualCourse(), "expired manual course")
        assertNil(State.getManualOverrideState(), "expired manual override state")
    end)

    case("manual survives event ending but expires when next begins", function()
        resetManual()
        local event1 = calendarContext(course, "event-1")
        local event2 = calendarContext(course, "event-2")

        Context.activateManualCourse(course.id, { calendarContext = event1 })

        local gapResult, gapErr = Context.resolve(
            { path = NON_COURSE_PATH },
            noCalendarRuntime()
        )

        assertNil(gapErr, "gap error")
        assertEqual(gapResult.level, Context.LEVEL.MANUAL, "gap manual level")

        local nextResult, nextErr = Context.resolve(
            { path = NON_COURSE_PATH },
            { calendarContext = event2 }
        )

        assertNil(nextErr, "post-gap next-event error")
        assertEqual(nextResult.level, Context.LEVEL.CALENDAR, "post-gap next-event level")
    end)

    case("manual selected outside event expires when event begins", function()
        resetManual()
        Context.activateManualCourse(course.id, noCalendarRuntime())

        local event = calendarContext(course, "event-1")
        local result, err = Context.resolve(
            { path = NON_COURSE_PATH },
            { calendarContext = event }
        )

        assertNil(err, "outside-to-event error")
        assertEqual(result.level, Context.LEVEL.CALENDAR, "outside-to-event level")
    end)

    case("calendar switching disabled", function()
        resetManual()
        Context.activateManualCourse(course.id, noCalendarRuntime())
        State.setCalendarAutoSwitchEnabled(false)

        local event = calendarContext(course, "event-1")
        local result, err = Context.resolve(
            { path = NON_COURSE_PATH },
            { calendarContext = event }
        )

        assertNil(err, "calendar-disabled error")
        assertEqual(result.level, Context.LEVEL.MANUAL, "calendar-disabled level")
    end)

    case("weekly timetable resolves a 4-hour Dynamics class", function()
        resetManual()
        local timetable, timetableErr = Context.currentTimetableContext({
            now = { wday = 2, hour = 13, min = 15, sec = 0 },
        })

        assertNil(timetableErr, "timetable lookup error")
        assertTruthy(timetable, "timetable context")
        assertEqual(timetable.course.id, course.id, "timetable course")

        local result, err = Context.resolve(
            { path = NON_COURSE_PATH },
            { timetableContext = timetable }
        )

        assertNil(err, "timetable resolve error")
        assertEqual(result.level, Context.LEVEL.TIMETABLE, "timetable level")
        assertEqual(result.source, Context.SOURCE.TIMETABLE, "timetable source")
    end)

    case("timetable end boundary is exclusive", function()
        resetManual()
        local timetable, timetableErr = Context.currentTimetableContext({
            now = { wday = 2, hour = 16, min = 0, sec = 0 },
        })

        assertNil(timetableErr, "boundary timetable error")
        assertNil(timetable, "16:00 must be outside 12-16")
    end)

    case("course can have multiple weekly timetable slots", function()
        resetManual()
        local timetable, timetableErr = Context.currentTimetableContext({
            now = { wday = 5, hour = 8, min = 30, sec = 0 },
        })

        assertNil(timetableErr, "second-slot timetable error")
        assertTruthy(timetable, "second timetable slot")
        assertEqual(timetable.course.id, course.id, "second-slot course")
    end)

    case("no available context", function()
        resetManual()
        local result, err = Context.resolve(
            { path = NON_COURSE_PATH },
            noCalendarRuntime()
        )

        assertNil(result, "no-context result")
        assertEqual(err, "No course context available.", "no-context error")
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
        local course = prepare()
        local passed, count = runCases(course)
        return passed, count
    end, debug.traceback)

    restoreState(previous)

    if not ok then
        print("✗ Context tests failed")
        print(resultOrError)
        return nil, resultOrError
    end

    print(string.format("Context tests passed: %d/%d", resultOrError, total))
    return true
end

return Tests

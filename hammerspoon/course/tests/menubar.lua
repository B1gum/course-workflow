local Tests = {}

local Actions = require("course.actions")
local Context = require("course.context")
local Menubar = require("course.menubar")
local Registry = require("course.registry")
local State = require("course.state")

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

local function itemByTitle(menu, title)
    for _, item in ipairs(menu or {}) do
        if item.title == title then
            return item
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

    State.setTimetableAutoSwitchEnabled(snapshot.timetableAutoSwitchEnabled)

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

    State.setTimetableAutoSwitchEnabled(false)

    local course, courseErr = Registry.getCourse(COURSE_A)

    if not course then
        fail(courseErr or "Test course missing.")
    end

    return course
end

local function fakeMenubar()
    local item = {
        deleted = false,
        titleValue = nil,
        tooltipValue = nil,
        menuProvider = nil,
    }

    function item:setTitle(value)
        self.titleValue = value
        return self
    end

    function item:setTooltip(value)
        self.tooltipValue = value
        return self
    end

    function item:setMenu(value)
        self.menuProvider = value
        return self
    end

    function item:delete()
        self.deleted = true
    end

    return item
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

    case("menubar title follows resolved course", function()
        assertEqual(
            Menubar.titleForContext(context),
            "AU · " .. (course.shortName or course.name),
            "menubar title"
        )
        assertEqual(Menubar.titleForContext(nil), "AU", "empty menubar title")
    end)

    case("menu is active-course first", function()
        local menu = Menubar.buildMenu(context)

        assertEqual(menu[1].title, course.shortName or course.name, "course header")
        assertEqual(menu[3].title, "Launch Course", "first course action")
        assertEqual(menu[3].disabled, false, "launch enabled")

        local notes = itemByTitle(menu, "Notes")
        local coursePage = itemByTitle(menu, "Course Webpage")
        local switchCourse = itemByTitle(menu, "Switch Course…")

        assertTruthy(notes and notes.menu, "notes submenu")
        assertTruthy(coursePage, "course-page item")
        assertEqual(coursePage.disabled, false, "course-page enabled")
        assertTruthy(switchCourse and switchCourse.menu, "switch-course submenu")
    end)

    case("implemented notes and compile actions are enabled", function()
        local menu = Menubar.buildMenu(context)
        local notes = itemByTitle(menu, "Notes")
        local openNotes = itemByTitle(notes.menu, "Open Notes")
        local current = itemByTitle(notes.menu, "Compile Current")
        local notesFigure = itemByTitle(notes.menu, "New Notes Figure")

        assertTruthy(openNotes, "open-notes item")
        assertTruthy(current, "compile-current item")
        assertTruthy(notesFigure, "notes-figure item")
        assertEqual(openNotes.disabled, false, "open-notes enabled")
        assertEqual(current.disabled, false, "compile-current enabled")
        assertEqual(notesFigure.disabled, false, "notes figure enabled")
    end)

    case("MATLAB and literature expose separate app/file actions", function()
        local menu = Menubar.buildMenu(context)
        local matlab = itemByTitle(menu, "MATLAB")
        local literature = itemByTitle(menu, "Literature")
        local saveReference = itemByTitle(menu, "Save Reference")
        local saveUnfiled = itemByTitle(menu, "Save Reference Unfiled")
        local searchReferences = itemByTitle(menu, "Search References")
        local openReferences = itemByTitle(menu, "Open References")
        local searchAll = itemByTitle(menu, "Search All References")

        assertTruthy(matlab and matlab.menu, "MATLAB submenu")
        assertTruthy(literature and literature.menu, "literature submenu")
        assertTruthy(saveReference, "save-reference item")
        assertTruthy(saveUnfiled, "save-unfiled item")
        assertTruthy(searchReferences, "search-references item")
        assertTruthy(openReferences, "open-references item")
        assertTruthy(searchAll, "search-all-references item")
        assertEqual(
            itemByTitle(matlab.menu, "Open MATLAB").disabled,
            false,
            "open-MATLAB enabled"
        )
        assertEqual(
            itemByTitle(matlab.menu, "Open MATLAB Folder").disabled,
            false,
            "open-MATLAB-folder enabled"
        )
        assertEqual(
            itemByTitle(literature.menu, "Open Textbook").disabled,
            false,
            "open-textbook enabled"
        )
        assertEqual(
            itemByTitle(literature.menu, "Open Literature Folder").disabled,
            false,
            "open-literature-folder enabled"
        )
        assertEqual(saveReference.disabled, false, "save-reference enabled")
        assertEqual(saveUnfiled.disabled, false, "save-unfiled enabled")
        assertEqual(searchReferences.disabled, false, "search-references enabled")
        assertEqual(openReferences.disabled, false, "open-references enabled")
        assertEqual(searchAll.disabled, false, "search-all-references enabled")
    end)

    case("Folders submenu exposes every Part XVI derived directory", function()
        local menu = Menubar.buildMenu(context)
        local folders = itemByTitle(menu, "Folders")

        assertTruthy(folders and folders.menu, "folders submenu")

        local names = {
            "Course Root",
            "Notes",
            "Lectures",
            "Notes Figures",
            "Assignments",
            "Assignment Figures",
            "MATLAB",
            "Literature",
            "References Folder",
        }

        for _, name in ipairs(names) do
            local item = itemByTitle(folders.menu, name)
            assertTruthy(item, name .. " folder item")
            assertEqual(item.disabled, false, name .. " folder enabled")
            assertEqual(type(item.fn), "function", name .. " folder callback")
        end
    end)

    case("switch course submenu is explicit and marks current course", function()
        local menu = Menubar.buildMenu(context)
        local switchCourse = itemByTitle(menu, "Switch Course…")
        local current = itemByTitle(
            switchCourse.menu,
            course.shortName or course.name
        )

        assertTruthy(current, "current course switch item")
        assertEqual(current.checked, true, "current course checkmark")
        assertEqual(type(current.fn), "function", "current course callback")
    end)

    case("timetable control is live central-action frontend", function()
        State.setTimetableAutoSwitchEnabled(true)
        local menu = Menubar.buildMenu(context)
        local timetable = itemByTitle(menu, "Automatic Timetable Switching")

        assertTruthy(timetable, "timetable item")
        assertEqual(timetable.checked, true, "timetable checkmark")
        assertEqual(timetable.disabled, false, "timetable enabled")
        assertEqual(type(timetable.fn), "function", "timetable callback")
    end)

    case("menubar lifecycle deletes previous item on restart", function()
        local created = {}
        local runtime = {
            resolveContext = function()
                return context
            end,
            newMenubar = function()
                local item = fakeMenubar()
                table.insert(created, item)
                return item
            end,
            notify = function()
                return true
            end,
        }

        local ok, err = Menubar.start(runtime)
        assertTruthy(ok, err or "first menubar start")
        assertEqual(#created, 1, "first menubar count")
        assertEqual(created[1].deleted, false, "first menubar alive")
        assertEqual(type(created[1].menuProvider), "function", "dynamic menu provider")

        ok, err = Menubar.start(runtime)
        assertTruthy(ok, err or "second menubar start")
        assertEqual(#created, 2, "second menubar count")
        assertEqual(created[1].deleted, true, "old menubar deleted")
        assertEqual(created[2].deleted, false, "new menubar alive")

        Menubar.stop()
        assertEqual(created[2].deleted, true, "new menubar deleted on stop")
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

    local ok, resultOrError, total = xpcall(function()
        local course = prepare()
        local passed, count = runCases(course)
        return passed, count
    end, debug.traceback)

    Menubar.stop()
    restoreState(previous)

    if not ok then
        print("✗ Menubar tests failed")
        print(resultOrError)
        return nil, resultOrError
    end

    print(string.format("Menubar tests passed: %d/%d", resultOrError, total))
    return true
end

return Tests

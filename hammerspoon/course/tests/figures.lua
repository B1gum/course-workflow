local Tests = {}

local Context = require("course.context")
local Figures = require("course.figures")

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

local function fixtureCourse()
    return {
        id = "dynamics",
        notes = {
            root = "/tmp/University Notes/Dynamics/notes",
            figures = "/tmp/University Notes/Dynamics/notes/figures",
        },
        assignments = {
            root = "/tmp/University Notes/Dynamics/assignments",
            figures = "/tmp/University Notes/Dynamics/assignments/figures",
        },
    }
end

function Tests.run()
    local course = fixtureCourse()

    local notes, notesErr = Figures.scope(
        course,
        Context.WORK_CONTEXT.NOTES
    )

    assertTruthy(notes, "notes scope")
    assertEqual(notesErr, nil, "notes scope error")
    assertEqual(notes.projectRoot, course.notes.root, "notes project root")
    assertEqual(notes.figuresDir, course.notes.figures, "notes figures")

    local assignment, assignmentErr = Figures.scope(
        course,
        Context.WORK_CONTEXT.ASSIGNMENT
    )

    assertTruthy(assignment, "assignment scope")
    assertEqual(assignmentErr, nil, "assignment scope error")
    assertEqual(
        assignment.projectRoot,
        course.assignments.root,
        "assignment project root"
    )
    assertEqual(
        assignment.figuresDir,
        course.assignments.figures,
        "assignment figures"
    )

    local missing, missingErr = Figures.scope(course, nil)
    assertEqual(missing, nil, "missing work context scope")
    assertContains(missingErr, "notes or assignment", "missing context error")

    local newInvocation, newErr = Figures.invocation(
        course,
        Context.WORK_CONTEXT.NOTES,
        Figures.MODE.NEW
    )

    assertTruthy(newInvocation, "new invocation")
    assertEqual(newErr, nil, "new invocation error")
    assertEqual(newInvocation.figuresDir, course.notes.figures, "new figures dir")
    assertContains(newInvocation.command, "NOAH_COURSE_FIGURES_DIR=", "new env")
    assertContains(newInvocation.command, "NOAH_COURSE_FIGURE_BRIDGE=", "new bridge env")
    assertContains(newInvocation.command, "dofile", "new bridge loader")
    assertContains(newInvocation.bridgeContents, "Figure name:", "new name prompt")
    assertContains(newInvocation.bridgeContents, "pick_template", "new template picker")
    assertContains(newInvocation.bridgeContents, "new_figure", "new workflow script")

    local findInvocation, findErr = Figures.invocation(
        course,
        Context.WORK_CONTEXT.ASSIGNMENT,
        Figures.MODE.FIND
    )

    assertTruthy(findInvocation, "find invocation")
    assertEqual(findErr, nil, "find invocation error")
    assertEqual(
        findInvocation.figuresDir,
        course.assignments.figures,
        "find figures dir"
    )
    assertContains(findInvocation.command, "telescope.pick", "find telescope")
    assertContains(findInvocation.command, "Open in Inkscape", "find open action")
    assertContains(findInvocation.command, "Open exported PDF", "find PDF action")
    assertContains(findInvocation.command, "Reveal source SVG", "find source action")
    assertContains(findInvocation.command, "Reveal pdf_tex", "find pdf_tex action")
    assertContains(findInvocation.command, "Copy LaTeX", "find copy action")
    assertContains(findInvocation.command, "\\\\incfig{", "find incfig generation")

    print("Figure bridge tests passed.")
    return true
end

return Tests

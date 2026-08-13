local Tests = {}

function Tests.run()
    local contextOk, contextErr = require("course.tests.context").run()

    if not contextOk then
        return nil, contextErr
    end

    local actionsOk, actionsErr = require("course.tests.actions").run()

    if not actionsOk then
        return nil, actionsErr
    end

    local latexOk, latexErr = require("course.tests.latex").run()

    if not latexOk then
        return nil, latexErr
    end

    local figuresOk, figuresErr = require("course.tests.figures").run()

    if not figuresOk then
        return nil, figuresErr
    end

    local launcherOk, launcherErr = require("course.tests.launcher").run()

    if not launcherOk then
        return nil, launcherErr
    end

    local menubarOk, menubarErr = require("course.tests.menubar").run()

    if not menubarOk then
        return nil, menubarErr
    end

    local hotkeysOk, hotkeysErr = require("course.tests.hotkeys").run()

    if not hotkeysOk then
        return nil, hotkeysErr
    end

    print("All course-workflow tests passed.")
    return true
end

return Tests

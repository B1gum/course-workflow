local CourseWorkflow = {}

CourseWorkflow.Util = require("course.util")
CourseWorkflow.State = require("course.state")
CourseWorkflow.Config = require("course.config")
CourseWorkflow.Registry = require("course.registry")
CourseWorkflow.Context = require("course.context")
CourseWorkflow.Lectures = require("course.lectures")
CourseWorkflow.Actions = require("course.actions")
CourseWorkflow.Launcher = require("course.launcher")
CourseWorkflow.Menubar = require("course.menubar")
CourseWorkflow.Hotkeys = require("course.hotkeys")
CourseWorkflow.LaTeX = require("course.latex")
CourseWorkflow.Figures = require("course.figures")

function CourseWorkflow.start()
    -- Frontends stay available even before a semester has been selected so the
    -- management routes can bootstrap the workflow. Each frontend owns its
    -- lifecycle and start() first removes any previous long-lived objects.
    CourseWorkflow.Launcher.start()

    local activeSemester = CourseWorkflow.State.getActiveSemester()
    local registryOk = true
    local registryErr = nil

    if activeSemester then
        registryOk, registryErr = CourseWorkflow.Registry.reload()
    end

    local menubarOk, menubarErr = CourseWorkflow.Menubar.start()
    local hotkeysOk, hotkeysErr = CourseWorkflow.Hotkeys.start()

    if not registryOk then
        return nil, registryErr
    end

    if not menubarOk then
        return nil, menubarErr
    end

    if not hotkeysOk then
        return nil, hotkeysErr
    end

    return true
end

function CourseWorkflow.reloadConfiguration()
    local ok, err = CourseWorkflow.Actions.reloadConfiguration()

    if not ok then
        return nil, err
    end

    CourseWorkflow.Menubar.refresh()
    return true
end

function CourseWorkflow.stop()
    CourseWorkflow.LaTeX.stopAll()
    CourseWorkflow.Hotkeys.stop()
    CourseWorkflow.Menubar.stop()
    CourseWorkflow.Launcher.stop()
    return true
end

return CourseWorkflow

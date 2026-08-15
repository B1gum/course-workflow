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
CourseWorkflow.References = require("course.references")
CourseWorkflow.ReferenceServer = require("course.reference_server")
CourseWorkflow.ReferenceChooser = require("course.reference_chooser")

function CourseWorkflow.start()
    -- Neovim talks to the central Hammerspoon reference service over a
    -- loopback-only HTTP endpoint. Starting it here keeps Zotero/context logic
    -- in one place and avoids a second reference database in the editor.
    CourseWorkflow.ReferenceServer.start()

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
    CourseWorkflow.ReferenceChooser.stop()
    CourseWorkflow.ReferenceServer.stop()
    CourseWorkflow.Hotkeys.stop()
    CourseWorkflow.Menubar.stop()
    CourseWorkflow.Launcher.stop()
    return true
end

local function reportStartupFailure(err)
    local detail = tostring(err or "Unknown startup error.")
    local message = "Course workflow failed to start: " .. detail

    print(message)

    if hs and hs.notify and type(hs.notify.new) == "function" then
        pcall(function()
            hs.notify.new({
                title = "AU Course Workflow",
                informativeText = detail,
            }):send()
        end)
    end
end

-- Loading the module is the bootstrap. Keep exactly one require in the main
-- ~/.hammerspoon/init.lua, for example:
--
--     Course = require("course")
--
-- Hammerspoon reloads init.lua on startup/reload, so the workflow now starts
-- automatically without a separate Course.start() console command. All
-- long-lived frontends already own restart-safe start/stop lifecycles.
local started, startupErr = CourseWorkflow.start()

if not started then
    reportStartupFailure(startupErr)
end

return CourseWorkflow

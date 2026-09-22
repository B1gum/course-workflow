local Capture = {}

local Context = require("course.context")
local Figures = require("course.figures")
local Util = require("course.util")

local HOME = os.getenv("HOME") or ""
local STATE_DIR = HOME .. "/.local/state/course-workflow/nvim"
local SHORTCUT = "Course Problem Analysis"
local CROP_SCRIPT = HOME .. "/.config/course-workflow/scripts/crop_problem.swift"

Capture._current = nil

local function finish(job, message)
    if Capture._current ~= job then return end
    Capture._current = nil
    job.task = nil
    job.chooser = nil
    for _, name in ipairs({ "selection.png", "analysis.json", "figure.png", "insert.json" }) do
        os.remove(Util.joinPath(job.dir, name))
    end
    hs.fs.rmdir(job.dir)
    if message then hs.alert.show(message) end
end

local function run(job, executable, arguments, callback)
    local task = hs.task.new(executable, function(code, stdout, stderr)
        if Capture._current ~= job then return end
        job.task = nil
        callback(code, stdout or "", stderr or "")
    end, nil, arguments)
    if not task or not task:start() then
        return nil, "Could not start " .. executable
    end
    job.task = task
    return true
end

local function validProcess(state)
    if type(state) ~= "table" or type(state.path) ~= "string"
        or type(state.tty) ~= "string" or not state.tty:match("^ttys?[%w]+$")
        or type(state.pid) ~= "number" or state.pid < 1
        or state.pid % 1 ~= 0 or type(state.ui_pid) ~= "number"
        or state.ui_pid < 1 or state.ui_pid % 1 ~= 0
        or type(state.server) ~= "string"
        or state.server == "" or type(state.executable) ~= "string"
        or not state.executable:match("/nvim$")
        or type(state.cursor) ~= "table"
        or type(state.cursor[1]) ~= "number" or type(state.cursor[2]) ~= "number"
        or type(state.changedtick) ~= "number" then
        return false
    end
    if hs.fs.attributes(state.server, "mode") ~= "socket" then return false end
    local comm, commOk = hs.execute(
        string.format("/bin/ps -p %d -o comm= 2>/dev/null", state.pid)
    )
    if not commOk or Util.trim(comm or ""):match("([^/]+)$") ~= "nvim" then
        return false
    end
    if state.ui_pid ~= state.pid then
        local parent, parentOk = hs.execute(
            string.format("/bin/ps -p %d -o ppid= 2>/dev/null", state.pid)
        )
        local uiComm, uiOk = hs.execute(
            string.format("/bin/ps -p %d -o comm= 2>/dev/null", state.ui_pid)
        )
        if not parentOk or tonumber(Util.trim(parent or "")) ~= state.ui_pid
            or not uiOk or Util.trim(uiComm or ""):match("([^/]+)$") ~= "nvim" then
            return false
        end
    end
    local tty, ttyOk = hs.execute(
        string.format("/bin/ps -p %d -o tty= 2>/dev/null", state.ui_pid)
    )
    return ttyOk and Util.trim(tty or ""):gsub("^/dev/", "") == state.tty
end

local function targetForCourse(courseId)
    if hs.fs.attributes(STATE_DIR, "mode") ~= "directory" then
        return nil, "No Neovim course session found."
    end
    local best
    for name in hs.fs.dir(STATE_DIR) do
        if name:match("^ttys?[%w]+%.json$") then
            local data = Util.readFile(Util.joinPath(STATE_DIR, name))
            local ok, state = pcall(hs.json.decode, data or "")
            if ok and validProcess(state) and state.path:match("%.tex$") then
                local resolved = Context.resolvePath(state.path)
                if resolved and resolved.course.id == courseId
                    and (resolved.workContext == Context.WORK_CONTEXT.ASSIGNMENT
                        or resolved.workContext == Context.WORK_CONTEXT.EXERCISES)
                    and (not best or (state.last_active_ms or 0)
                        > (best.last_active_ms or 0)) then
                    best = state
                    best.context = resolved
                end
            end
        end
    end
    if not best then
        return nil, "Open an assignment or exercise .tex file in Neovim for this course."
    end
    return best
end

local function readAnalysis(path)
    local raw = Util.readFile(path)
    if not raw then return nil, "The shortcut returned no JSON text." end
    local ok, data = pcall(hs.json.decode, raw)
    if not ok or type(data) ~= "table" then
        return nil, "The shortcut must return only a JSON object."
    end
    if type(data.number) ~= "string" or type(data.body) ~= "string"
        or type(data.figure_regions) ~= "table"
        or type(data.needs_figure) ~= "boolean"
        or type(data.number_confident) ~= "boolean"
        or type(data.crop_confident) ~= "boolean"
        or type(data.transcription_confident) ~= "boolean" then
        return nil, "The model output is missing required fields; check the Shortcuts prompt."
    end
    data.number = Util.trim(data.number)
    data.body = Util.trim(data.body)
    if data.number:match("^%d+%.%d+$") then
        data.number = data.number:gsub("%.", "--")
    end
    if data.number ~= "" and not data.number:match("^[%w%.%-]+$") then
        return nil, "The model returned an invalid problem number."
    end
    local forbidden = {
        "\\input", "\\include", "\\write", "\\openout", "\\read",
        "\\directlua", "\\luaexec", "\\immediate", "\\catcode",
        "\\usepackage", "\\documentclass", "\\end{document}",
    }
    for _, command in ipairs(forbidden) do
        if data.body:find(command, 1, true) then
            return nil, "The model returned an external-file or executable LaTeX command."
        end
    end
    if data.body == "" or #data.body > 30000
        or data.body:find("\\begin{problem", 1, true)
        or data.body:find("\\end{problem", 1, true) then
        return nil, "The model must return only the problem body in LaTeX."
    end
    if #data.figure_regions > 8
        or data.needs_figure ~= (#data.figure_regions > 0) then
        return nil, "The model returned inconsistent figure regions."
    end
    if data.needs_figure and data.layout ~= "horizontal"
        and data.layout ~= "vertical" and data.layout ~= "grid" then
        return nil, "The model must select horizontal, vertical, or grid layout."
    end
    for _, region in ipairs(data.figure_regions) do
        if type(region) ~= "table" then return nil, "Invalid figure region." end
        for _, key in ipairs({ "x", "y", "width", "height" }) do
            if type(region[key]) ~= "number" or region[key] < 0
                or region[key] > 1 then
                return nil, "Figure coordinates must be fractions from 0 to 1."
            end
        end
        if region.width == 0 or region.height == 0
            or region.x + region.width > 1.001
            or region.y + region.height > 1.001 then
            return nil, "The figure region extends outside the selected screenshot."
        end
    end
    return data
end

local function problemText(analysis, imageName)
    local kind = imageName and "problemwithimage" or "problem"
    local opening = imageName
        and string.format("\\begin{%s}{%s}{%s}", kind, imageName, analysis.number)
        or string.format("\\begin{%s}{%s}", kind, analysis.number)
    local indented = analysis.body:gsub("\n", "\n  ")
    return opening .. "\n  " .. indented .. "\n\\end{" .. kind .. "}"
end

local function imageName(analysis)
    return "p" .. analysis.number:gsub("%-%-", "_"):gsub("[^%w_]", "_")
end

local function destination(figuresDir, base)
    local path = Util.joinPath(figuresDir, base .. ".png")
    if not hs.fs.attributes(path) then return path, base end
    local stamp = os.date("%Y%m%d-%H%M%S")
    for index = 0, 99 do
        local suffix = stamp .. (index > 0 and ("-" .. index) or "")
        local stem = base .. "_" .. suffix
        path = Util.joinPath(figuresDir, stem .. ".png")
        if not hs.fs.attributes(path) then return path, stem end
    end
    return nil, "Too many figure filename collisions."
end

local function focusSession(tty)
    -- TTY comes from the verified Neovim state, never from model output.
    local script = [[
        tell application "iTerm2"
            repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                    repeat with theSession in sessions of theTab
                        if tty of theSession is "]] .. "/dev/" .. tty .. [[" then
                            select theSession
                            select theTab
                            select theWindow
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
    ]]
    local ok, selected = hs.osascript.applescript(script)
    return ok and selected == true
end

local function insert(job, analysis)
    local figurePath, stem
    if analysis.needs_figure then
        if hs.fs.attributes(job.scope.figuresDir, "mode") ~= "directory" then
            return finish(job, "Figure directory does not exist: " .. job.scope.figuresDir)
        end
        figurePath, stem = destination(job.scope.figuresDir, imageName(analysis))
        if not figurePath then return finish(job, stem) end
        local candidate = Util.joinPath(job.dir, "figure.png")
        local file = Util.readFile(candidate)
        if not file then return finish(job, "Could not read cropped figure.") end
        local wrote, err = Util.writeFileAtomic(figurePath, file)
        if not wrote then return finish(job, "Could not save figure: " .. tostring(err)) end
    end

    local manifest = Util.joinPath(job.dir, "insert.json")
    local wrote, err = Util.writeFileAtomic(manifest, hs.json.encode({
        path = job.target.path,
        changedtick = job.target.changedtick,
        cursor = job.target.cursor,
        text = problemText(analysis, stem),
    }))
    if not wrote then
        if figurePath then os.remove(figurePath) end
        return finish(job, "Could not prepare insertion: " .. tostring(err))
    end

    local nvim = job.target.executable
    if hs.fs.attributes(nvim, "mode") ~= "file" then
        if figurePath then os.remove(figurePath) end
        return finish(job, "Could not locate the Neovim executable.")
    end
    local expr = 'v:lua.require("course_context").insert_from_file("'
        .. manifest .. '")'
    local started, runErr = run(job, nvim,
        { "--server", job.target.server, "--remote-expr", expr },
        function(code, output, stderr)
            if code ~= 0 or Util.trim(output) ~= "OK" then
                if figurePath and output:find("^ERROR: Neovim buffer or cursor changed") then
                    os.remove(figurePath)
                end
                -- Remote errors may occur after the editor has changed; keep
                -- the image so an inserted but unsaved block still resolves.
                return finish(job, "Neovim insertion failed: " ..
                    Util.trim(output ~= "" and output or stderr))
            end
            if not focusSession(job.target.tty) then
                return finish(job, "Inserted and saved; could not focus its iTerm2 session.")
            end
            finish(job, "Problem inserted and saved.")
        end)
    if not started then
        if figurePath then os.remove(figurePath) end
        finish(job, runErr)
    end
end

local function review(job, analysis)
    local lowConfidence = not analysis.number_confident
        or not analysis.crop_confident or not analysis.transcription_confident
    if not lowConfidence then return insert(job, analysis) end
    if analysis.needs_figure then
        hs.execute("/usr/bin/open -a Preview " ..
            Util.shellQuote(Util.joinPath(job.dir, "figure.png")))
    end
    job.chooser = hs.chooser.new(function(choice)
        job.chooser = nil
        if not choice then return finish(job) end
        if choice.action == "accept" then
            insert(job, analysis)
        elseif choice.action == "retry" then
            job.source:activate()
            hs.timer.doAfter(0.25, function()
                if Capture._current == job then job.capture() end
            end)
        else
            finish(job)
        end
    end)
    job.chooser:choices({
        { text = "Accept problem " .. analysis.number, action = "accept",
            subText = analysis.body:sub(1, 180) },
        { text = "Mark again", action = "retry",
            subText = "Select a new region in the source app" },
        { text = "Cancel", action = "cancel" },
    }):show()
end

local function analyze(job)
    local output = Util.joinPath(job.dir, "analysis.json")
    os.remove(output)
    local started, err = run(job, "/usr/bin/shortcuts",
        { "run", SHORTCUT, "-i", Util.joinPath(job.dir, "selection.png"),
          "-o", output }, function(code, _, stderr)
            if code ~= 0 then
                return finish(job, "Shortcuts failed: " .. Util.trim(stderr))
            end
            local analysis, parseErr = readAnalysis(output)
            if not analysis then return finish(job, parseErr) end
            if analysis.number == "" or not analysis.number_confident then
                local button, number = hs.dialog.textPrompt(
                    "Problem number", "Confirm the number printed in the image:",
                    analysis.number, "Use number", "Cancel")
                if button ~= "Use number" then return finish(job) end
                number = Util.trim(number or "")
                if not number:match("^[%w%.%-]+$") then
                    return finish(job, "Invalid problem number.")
                end
                analysis.number = number:match("^%d+%.%d+$")
                    and number:gsub("%.", "--") or number
            end
            if not analysis.needs_figure then return review(job, analysis) end
            os.remove(Util.joinPath(job.dir, "figure.png"))
            local crop, cropErr = run(job, "/usr/bin/swift", {
                CROP_SCRIPT, Util.joinPath(job.dir, "selection.png"),
                output, Util.joinPath(job.dir, "figure.png"),
            }, function(cropCode, _, cropStderr)
                if cropCode ~= 0 then
                    return finish(job, "Figure crop failed: " .. Util.trim(cropStderr))
                end
                review(job, analysis)
            end)
            if not crop then finish(job, cropErr) end
        end)
    if not started then finish(job, err) end
end

function Capture.start(context)
    if Capture._current then return nil, "A problem capture is already running." end
    local target, targetErr = targetForCourse(context.course.id)
    if not target then return nil, targetErr end
    local scope, scopeErr = Figures.scope(target.context.course,
        target.context.workContext)
    if not scope then return nil, scopeErr end
    local source = hs.application.frontmostApplication()
    local dir = Util.joinPath(hs.fs.temporaryDirectory(),
        "course-problem-" .. hs.host.uuid())
    local made, makeErr = hs.fs.mkdir(dir)
    if not made then return nil, tostring(makeErr) end
    local job = { target = target, scope = scope, source = source, dir = dir }
    Capture._current = job
    job.capture = function()
        local path = Util.joinPath(dir, "selection.png")
        os.remove(path)
        local started, err = run(job, "/usr/sbin/screencapture",
            { "-i", "-s", "-x", path }, function(code)
                if code ~= 0 or hs.fs.attributes(path, "mode") ~= "file" then
                    return finish(job)
                end
                analyze(job)
            end)
        if not started then finish(job, err) end
    end
    job.capture()
    return true
end

return Capture

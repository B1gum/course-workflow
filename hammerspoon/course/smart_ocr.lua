local M = {}

local SHORTCUT_NAME = "Course Smart OCR"

-- Keep asynchronous tasks alive until callbacks have fired.
local activeTasks = {}

local function alert(message)
    hs.alert.show(message, 1.5)
end

local function tempImagePath()
    local stamp = math.floor(hs.timer.secondsSinceEpoch() * 1000)
    return string.format("/tmp/course-smart-ocr-%d.png", stamp)
end

local function fileExists(path)
    local f = io.open(path, "rb")

    if not f then
        return false
    end

    f:close()
    return true
end

local function cleanup(path)
    if path then
        os.remove(path)
    end
end

local function startTask(path, arguments, callback)
    local task

    task = hs.task.new(
        path,
        function(exitCode, stdout, stderr)
            activeTasks[task] = nil
            callback(exitCode, stdout, stderr)
        end,
        arguments
    )

    if not task then
        return false
    end

    activeTasks[task] = true

    if not task:start() then
        activeTasks[task] = nil
        return false
    end

    return true
end

local function parseResponse(raw)
    local confidence = raw:match("^LOW_CONFIDENCE:%s*(true)")
        or raw:match("^LOW_CONFIDENCE:%s*(false)")

    local latex = raw:match("\n%-%-%-LATEX%-%-%-\n(.*)$")

    if not confidence or not latex or latex == "" then
        return nil, nil
    end

    -- Remove trailing whitespace only.
    latex = latex:gsub("%s+$", "")

    if latex:find("\t", 1, true) or latex:find("\f", 1, true) then
        print("[Smart OCR] Unsafe control character in response:")
        print(string.format("%q", latex))
        alert("Smart OCR failed — unsafe output")
        return
    end
    -- Restore LaTeX backslashes after safe transport through Shortcuts.
    latex = latex:gsub("§", "\\")

    return confidence == "true", latex
end

local function runShortcut(imagePath)
    local started = startTask(
        "/usr/bin/shortcuts",
        {
            "run",
            SHORTCUT_NAME,
            "-i",
            imagePath,
        },
        function(exitCode, stdout, stderr)
            cleanup(imagePath)

            if exitCode ~= 0 then
                print(
                    string.format(
                        "[Smart OCR] shortcuts failed (%d): %s",
                        exitCode,
                        stderr or ""
                    )
                )

                alert("Smart OCR failed")
                return
            end

            local raw = stdout or ""

            -- Keep this while debugging. Remove later if desired.
            print("[Smart OCR] RAW stdout:")
            print(string.format("%q", raw))

            local lowConfidence, latex = parseResponse(raw)

            if lowConfidence == nil or not latex then
                print("[Smart OCR] Invalid response:")
                print(raw)

                alert("Smart OCR failed — invalid response")
                return
            end

            hs.pasteboard.setContents(latex)

            if lowConfidence then
                alert("Smart OCR copied ⚠︎ Low confidence")
            else
                alert("Smart OCR copied ✓")
            end
        end
    )

    if not started then
        cleanup(imagePath)
        alert("Smart OCR failed to start")
    end
end

function M.run()
    local imagePath = tempImagePath()

    local started = startTask(
        "/usr/sbin/screencapture",
        {
            "-i",
            "-s",
            "-x",
            imagePath,
        },
        function(exitCode)
            -- Esc during capture should silently cancel.
            if exitCode ~= 0 or not fileExists(imagePath) then
                cleanup(imagePath)
                return
            end

            runShortcut(imagePath)
        end
    )

    if not started then
        cleanup(imagePath)
        return nil, "Smart OCR failed to start capture."
    end

    return true
end

return M

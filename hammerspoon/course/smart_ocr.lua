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
    if type(raw) ~= "string" or raw == "" then
        return nil, nil
    end

    -- Normalize line endings.
    raw = raw:gsub("\r\n", "\n")
    raw = raw:gsub("\r", "\n")

    local marker = "---LATEX---"
    local markerStart, markerEnd = raw:find(marker, 1, true)

    if not markerStart then
        print("[Smart OCR] Missing LATEX marker:")
        print(string.format("%q", raw))
        return nil, nil
    end

    -- Confidence is useful metadata, but must not be required for a
    -- successful transcription.
    local header = raw:sub(1, markerStart - 1)

    local confidenceText = header:match("LOW_CONFIDENCE:%s*(true)")
        or header:match("LOW_CONFIDENCE:%s*(false)")

    -- Everything after ---LATEX--- is the actual transcription.
    local latex = raw:sub(markerEnd + 1)

    latex = latex:gsub("^%s+", "")
    latex = latex:gsub("%s+$", "")

    if latex == "" then
        return nil, nil
    end

    -- Catch actual escape corruption such as \t -> TAB or \f -> form feed.
    if latex:find("\t", 1, true) or latex:find("\f", 1, true) then
        print("[Smart OCR] Unsafe control character in response:")
        print(string.format("%q", latex))
        return nil, nil
    end

    -- The model is instructed to use § for transport safety, but accept
    -- literal backslashes too when they survive Shortcuts correctly.
    latex = latex:gsub("§", "\\")

    local lowConfidence = confidenceText == "true"

    if confidenceText == nil then
        print("[Smart OCR] Warning: model omitted LOW_CONFIDENCE header")
    end

    return lowConfidence, latex
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

local LaTeX = {}

local Lectures = require("course.lectures")
local Util = require("course.util")

LaTeX.SELECTED_FILENAME = "selected.tex"
LaTeX.LAST_BUILD_LOG_FILENAME = "last-build.log"

LaTeX._tasks = {}

local LATEXMK_CANDIDATES = {
    "/Library/TeX/texbin/latexmk",
    "/opt/homebrew/bin/latexmk",
    "/usr/local/bin/latexmk",
    "/usr/bin/latexmk",
}

local function courseIsValid(course)
    return type(course) == "table"
        and Util.isNonEmptyString(course.id)
        and type(course.notes) == "table"
        and Util.isNonEmptyString(course.notes.root)
        and Util.isNonEmptyString(course.notes.master)
        and Util.isNonEmptyString(course.notes.lectures)
        and Util.isNonEmptyString(course.notes.build)
end

local function pathMode(path)
    return hs.fs.attributes(path, "mode")
end

local function positiveInteger(value)
    return type(value) == "number"
        and value >= 1
        and value % 1 == 0
end

local function copyArray(values)
    local copy = {}

    for index, value in ipairs(values or {}) do
        copy[index] = value
    end

    return copy
end

local function ensureBuildDirectory(course)
    local mode = pathMode(course.notes.build)

    if mode == "directory" then
        return true
    end

    if mode ~= nil then
        return nil, "notes/.build exists but is not a directory: " .. course.notes.build
    end

    local ok, result = pcall(hs.fs.mkdir, course.notes.build)

    if not ok or result ~= true then
        return nil, "Could not create notes/.build: " .. course.notes.build
    end

    return true
end

local function allPlainOccurrences(contents, needle)
    local occurrences = {}
    local offset = 1

    while true do
        local startIndex, endIndex = contents:find(needle, offset, true)

        if not startIndex then
            break
        end

        table.insert(occurrences, {
            startIndex = startIndex,
            endIndex = endIndex,
        })

        offset = endIndex + 1
    end

    return occurrences
end

local function managedRegion(contents)
    local begins = allPlainOccurrences(contents, Lectures.MANAGED_BEGIN)
    local ends = allPlainOccurrences(contents, Lectures.MANAGED_END)

    if #begins ~= 1 then
        return nil,
            string.format(
                "notes/master.tex must contain exactly one %s marker; found %d.",
                Lectures.MANAGED_BEGIN,
                #begins
            )
    end

    if #ends ~= 1 then
        return nil,
            string.format(
                "notes/master.tex must contain exactly one %s marker; found %d.",
                Lectures.MANAGED_END,
                #ends
            )
    end

    if begins[1].endIndex >= ends[1].startIndex then
        return nil, "The managed lecture markers in notes/master.tex are out of order."
    end

    return {
        beginStart = begins[1].startIndex,
        beginEnd = begins[1].endIndex,
        endStart = ends[1].startIndex,
        endEnd = ends[1].endIndex,
    }
end

local function lectureIndex(course)
    local lectures, listErr = Lectures.list(course)

    if not lectures then
        return nil, nil, listErr
    end

    local byNumber = {}

    for _, lecture in ipairs(lectures) do
        if byNumber[lecture.number] ~= nil then
            return nil,
                nil,
                string.format(
                    "Lecture number %d is ambiguous because more than one strict lec_NN.tex file uses it.",
                    lecture.number
                )
        end

        byNumber[lecture.number] = lecture
    end

    return lectures, byNumber
end

function LaTeX.selectionPath(course)
    if not courseIsValid(course) then
        return nil, "Course does not contain valid notes/build paths."
    end

    return Util.joinPath(course.notes.build, LaTeX.SELECTED_FILENAME)
end

function LaTeX.lastBuildLogPath(course)
    if not courseIsValid(course) then
        return nil, "Course does not contain valid notes/build paths."
    end

    return Util.joinPath(course.notes.build, LaTeX.LAST_BUILD_LOG_FILENAME)
end

function LaTeX.resolveLectures(course, lectureNumbers)
    if not courseIsValid(course) then
        return nil, "Course does not contain valid notes/build paths."
    end

    if type(lectureNumbers) ~= "table" or #lectureNumbers == 0 then
        return nil, "At least one lecture must be selected for a partial build."
    end

    local _, byNumber, listErr = lectureIndex(course)

    if not byNumber then
        return nil, listErr
    end

    local selected = {}
    local seen = {}

    for index, number in ipairs(lectureNumbers) do
        if not positiveInteger(number) then
            return nil,
                string.format(
                    "Selected lecture at index %d is not a positive integer.",
                    index
                )
        end

        if not seen[number] then
            local lecture = byNumber[number]

            if not lecture then
                return nil,
                    string.format(
                        "Lecture lec_%02d.tex does not exist.",
                        number
                    )
            end

            seen[number] = true
            table.insert(selected, lecture)
        end
    end

    table.sort(selected, function(a, b)
        return a.number < b.number
    end)

    return selected
end

function LaTeX.generateSelection(course, lectureNumbers)
    if not courseIsValid(course) then
        return nil, "Course does not contain valid notes/build paths."
    end

    if pathMode(course.notes.master) ~= "file" then
        return nil, "notes/master.tex is missing: " .. course.notes.master
    end

    local buildOk, buildErr = ensureBuildDirectory(course)

    if not buildOk then
        return nil, buildErr
    end

    local lectures, selectionErr = LaTeX.resolveLectures(
        course,
        lectureNumbers
    )

    if not lectures then
        return nil, selectionErr
    end

    local contents, readErr = Util.readFile(course.notes.master)

    if not contents then
        return nil, "Could not read notes/master.tex: " .. tostring(readErr)
    end

    local region, regionErr = managedRegion(contents)

    if not region then
        return nil, regionErr
    end

    local inputLines = {}

    for _, lecture in ipairs(lectures) do
        local stem = lecture.filename:gsub("%.tex$", "")
        table.insert(inputLines, "\\input{lectures/" .. stem .. "}")
    end

    -- master.tex itself is never changed. Only the bytes strictly between the
    -- two managed markers are replaced in the disposable copy.
    local before = contents:sub(1, region.beginEnd)
    local after = contents:sub(region.endStart)
    local replacement = "\n\n" .. table.concat(inputLines, "\n") .. "\n\n"
    local selectedContents = before .. replacement .. after

    local selectionPath = assert(LaTeX.selectionPath(course))
    local wrote, writeErr = Util.writeFileAtomic(
        selectionPath,
        selectedContents
    )

    if not wrote then
        return nil,
            "Could not write disposable selection document: " .. tostring(writeErr)
    end

    return {
        path = selectionPath,
        contents = selectedContents,
        lectures = lectures,
        lectureNumbers = (function()
            local numbers = {}

            for _, lecture in ipairs(lectures) do
                table.insert(numbers, lecture.number)
            end

            return numbers
        end)(),
    }
end

function LaTeX.recentLectureNumbers(course, currentLecture, count)
    if not positiveInteger(currentLecture) then
        return nil, "Current lecture must be a positive integer."
    end

    if not positiveInteger(count) then
        return nil, "Recent lecture count must be a positive integer."
    end

    local lectures, _, listErr = lectureIndex(course)

    if not lectures then
        return nil, listErr
    end

    local currentIndex = nil

    for index, lecture in ipairs(lectures) do
        if lecture.number == currentLecture then
            currentIndex = index
            break
        end
    end

    if not currentIndex then
        return nil,
            string.format(
                "Current lecture lec_%02d.tex does not exist.",
                currentLecture
            )
    end

    local firstIndex = math.max(1, currentIndex - count + 1)
    local numbers = {}

    for index = firstIndex, currentIndex do
        table.insert(numbers, lectures[index].number)
    end

    return numbers
end

function LaTeX.rangeLectureNumbers(course, firstLecture, lastLecture)
    if not positiveInteger(firstLecture) or not positiveInteger(lastLecture) then
        return nil, "Lecture range endpoints must be positive integers."
    end

    if firstLecture > lastLecture then
        return nil, "Lecture range start cannot be after its end."
    end

    local lectures, _, listErr = lectureIndex(course)

    if not lectures then
        return nil, listErr
    end

    local numbers = {}

    for _, lecture in ipairs(lectures) do
        if lecture.number >= firstLecture and lecture.number <= lastLecture then
            table.insert(numbers, lecture.number)
        end
    end

    if #numbers == 0 then
        return nil,
            string.format(
                "No lecture files exist in the range lec_%02d to lec_%02d.",
                firstLecture,
                lastLecture
            )
    end

    return numbers
end

function LaTeX.parseRange(value)
    if not Util.isNonEmptyString(value) then
        return nil, "Lecture range cannot be empty."
    end

    local normalized = Util.trim(value)
    normalized = normalized:gsub("–", "-"):gsub("—", "-")

    local firstText, lastText = normalized:match(
        "^(%d+)%s*%-%s*(%d+)$"
    )

    if not firstText then
        return nil, 'Use a range such as "3-8".'
    end

    local firstLecture = tonumber(firstText)
    local lastLecture = tonumber(lastText)

    if not positiveInteger(firstLecture) or not positiveInteger(lastLecture) then
        return nil, "Lecture range endpoints must be positive integers."
    end

    if firstLecture > lastLecture then
        return nil, "Lecture range start cannot be after its end."
    end

    return firstLecture, lastLecture
end

function LaTeX.parseSelection(value)
    if not Util.isNonEmptyString(value) then
        return nil, "Lecture selection cannot be empty."
    end

    local normalized = Util.trim(value)
    normalized = normalized:gsub("–", "-"):gsub("—", "-")

    local numbers = {}
    local seen = {}
    local tokenCount = 0

    for rawToken in normalized:gmatch("[^,]+") do
        tokenCount = tokenCount + 1
        local token = Util.trim(rawToken)
        local single = token:match("^(%d+)$")
        local firstText, lastText = token:match("^(%d+)%s*%-%s*(%d+)$")

        if single then
            local number = tonumber(single)

            if not positiveInteger(number) then
                return nil, "Lecture numbers must be positive integers."
            end

            if not seen[number] then
                seen[number] = true
                table.insert(numbers, number)
            end

        elseif firstText then
            local firstLecture = tonumber(firstText)
            local lastLecture = tonumber(lastText)

            if not positiveInteger(firstLecture)
                or not positiveInteger(lastLecture)
                or firstLecture > lastLecture then

                return nil, 'Invalid lecture range "' .. token .. '".'
            end

            for number = firstLecture, lastLecture do
                if not seen[number] then
                    seen[number] = true
                    table.insert(numbers, number)
                end
            end

        else
            return nil,
                'Invalid lecture selection "'
                    .. token
                    .. '". Use values such as "1,3,5-7".'
        end
    end

    if tokenCount == 0 or #numbers == 0 then
        return nil, "Lecture selection cannot be empty."
    end

    table.sort(numbers)
    return numbers
end

local function executableMode(path)
    return Util.isNonEmptyString(path)
        and pathMode(path) == "file"
end

function LaTeX.resolveLatexmk(explicitPath)
    if explicitPath ~= nil then
        local normalized = Util.normalizePath(explicitPath)

        if not normalized or not executableMode(normalized) then
            return nil, "Configured latexmk executable does not exist: " .. tostring(explicitPath)
        end

        return normalized
    end

    for _, candidate in ipairs(LATEXMK_CANDIDATES) do
        if executableMode(candidate) then
            return candidate
        end
    end

    return nil,
        "Could not find latexmk. Expected MacTeX at /Library/TeX/texbin/latexmk or latexmk in a standard Homebrew/system location."
end

local function defaultTaskFactory(executable, arguments, workingDirectory, callback)
    local task = hs.task.new(
        executable,
        callback,
        nil,
        arguments
    )

    if not task then
        return nil, "Could not create latexmk task."
    end

    if task:setWorkingDirectory(workingDirectory) == false then
        return nil, "Could not set latexmk working directory."
    end

    if task:start() == false then
        return nil, "Could not start latexmk task."
    end

    return task
end

local function writeBuildLog(build, exitCode, stdOut, stdErr)
    local logPath = assert(LaTeX.lastBuildLogPath(build.course))
    local chunks = {
        "Course workflow LaTeX build",
        "===========================",
        "Course: " .. tostring(build.course.id),
        "Mode: " .. tostring(build.mode),
        "Source: " .. tostring(build.sourcePath),
        "Working directory: " .. tostring(build.workingDirectory),
        "Exit code: " .. tostring(exitCode),
        "",
        "STDOUT",
        "------",
        stdOut or "",
        "",
        "STDERR",
        "------",
        stdErr or "",
        "",
    }

    local ok, err = Util.writeFileAtomic(logPath, table.concat(chunks, "\n"))

    if not ok then
        return nil, err
    end

    return logPath
end

local function relativeBuildSource(course, sourcePath)
    local notesRoot = Util.normalizePath(course.notes.root)
    local normalizedSource = Util.normalizePath(sourcePath)

    if not notesRoot or not normalizedSource
        or not Util.isPathWithin(normalizedSource, notesRoot)
        or normalizedSource == notesRoot then

        return nil, "LaTeX source must be inside the course notes directory."
    end

    return normalizedSource:sub(#notesRoot + 2)
end

function LaTeX.startBuild(course, options)
    options = options or {}

    if not courseIsValid(course) then
        return nil, "Course does not contain valid notes/build paths."
    end

    if LaTeX._tasks[course.id] ~= nil then
        return nil,
            string.format(
                'A notes compilation is already running for "%s".',
                course.id
            )
    end

    local buildOk, buildErr = ensureBuildDirectory(course)

    if not buildOk then
        return nil, buildErr
    end

    local build = {
        course = course,
        mode = options.lectureNumbers and "partial" or "all",
        label = options.label,
        lectureNumbers = options.lectureNumbers
            and copyArray(options.lectureNumbers)
            or nil,
        workingDirectory = course.notes.root,
    }

    if build.mode == "partial" then
        local selection, selectionErr = LaTeX.generateSelection(
            course,
            build.lectureNumbers
        )

        if not selection then
            return nil, selectionErr
        end

        build.selection = selection
        build.sourcePath = selection.path
        build.outputPdf = Util.joinPath(course.notes.build, "selected.pdf")
    else
        if pathMode(course.notes.master) ~= "file" then
            return nil, "notes/master.tex is missing: " .. course.notes.master
        end

        build.sourcePath = course.notes.master
        build.outputPdf = Util.joinPath(course.notes.root, "master.pdf")
    end

    local relativeSource, relativeErr = relativeBuildSource(
        course,
        build.sourcePath
    )

    if not relativeSource then
        return nil, relativeErr
    end

    local latexmkPath, latexmkErr = LaTeX.resolveLatexmk(options.latexmkPath)

    if not latexmkPath then
        return nil, latexmkErr
    end

    local arguments = {
        "-lualatex",
        "-interaction=nonstopmode",
        "-file-line-error",
        "-synctex=1",
    }

    if build.mode == "partial" then
        table.insert(arguments, "-outdir=.build")
    end

    table.insert(arguments, relativeSource)

    build.executable = latexmkPath
    build.arguments = copyArray(arguments)
    build.logPath = assert(LaTeX.lastBuildLogPath(course))

    local token = { build = build }
    LaTeX._tasks[course.id] = token

    local taskFactory = options.taskFactory or defaultTaskFactory
    local task

    local function completed(exitCode, stdOut, stdErr)
        if LaTeX._tasks[course.id] == token then
            LaTeX._tasks[course.id] = nil
        end

        local logPath, logErr = writeBuildLog(
            build,
            exitCode,
            stdOut,
            stdErr
        )

        local pdfExists = pathMode(build.outputPdf) == "file"
        local success = exitCode == 0 and pdfExists
        local result = {
            success = success,
            exitCode = exitCode,
            course = course,
            mode = build.mode,
            label = build.label,
            lectureNumbers = build.lectureNumbers
                and copyArray(build.lectureNumbers)
                or nil,
            sourcePath = build.sourcePath,
            outputPdf = build.outputPdf,
            logPath = logPath or build.logPath,
            logError = logErr,
            stdout = stdOut or "",
            stderr = stdErr or "",
        }

        if exitCode == 0 and not pdfExists then
            result.error = "latexmk exited successfully but no PDF was produced."
        elseif exitCode ~= 0 then
            result.error = "latexmk exited with code " .. tostring(exitCode) .. "."
        end

        if type(options.onComplete) == "function" then
            pcall(options.onComplete, result)
        end
    end

    local ok, taskOrErr, creationErr = pcall(
        taskFactory,
        latexmkPath,
        arguments,
        course.notes.root,
        completed,
        build
    )

    if not ok or not taskOrErr then
        LaTeX._tasks[course.id] = nil
        return nil,
            ok
                and tostring(creationErr or "Could not start latexmk task.")
                or tostring(taskOrErr)
    end

    task = taskOrErr
    token.task = task
    build.task = task

    if type(options.onStart) == "function" then
        pcall(options.onStart, build)
    end

    return build
end

function LaTeX.stopAll()
    for courseId, token in pairs(LaTeX._tasks) do
        local task = token and token.task or nil

        if task then
            pcall(function()
                if type(task.isRunning) ~= "function" or task:isRunning() then
                    task:terminate()
                end
            end)
        end

        LaTeX._tasks[courseId] = nil
    end

    return true
end

return LaTeX

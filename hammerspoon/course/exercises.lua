local Exercises = {}

local Util = require("course.util")

Exercises.MANAGED_BEGIN = "% WORKFLOW:EXERCISES-BEGIN"
Exercises.MANAGED_END = "% WORKFLOW:EXERCISES-END"

local function courseIsValid(course)
    return type(course) == "table"
        and type(course.exercises) == "table"
        and Util.isNonEmptyString(course.exercises.root)
        and Util.isNonEmptyString(course.exercises.master)
        and Util.isNonEmptyString(course.exercises.entries)
        and Util.isNonEmptyString(course.exercises.figures)
        and Util.isNonEmptyString(course.name)
        and Util.isNonEmptyString(course.shortName)
        and Util.isNonEmptyString(course.code)
        and Util.isNonEmptyString(course.semesterName)
end

local function pathMode(path)
    return hs.fs.attributes(path, "mode")
end

local function classSettings(course)
    local language = "english"
    local output = "screen"

    if type(course.notes) == "table"
        and Util.isNonEmptyString(course.notes.master)
        and pathMode(course.notes.master) == "file" then

        local contents = Util.readFile(course.notes.master)

        if type(contents) == "string" then
            local options = contents:match(
                "\\documentclass%s*%[([^%]]+)%]%s*{noahnotes}"
            )

            if options then
                for token in options:gmatch("[^,]+") do
                    token = Util.trim(token)

                    if token == "english" or token == "danish" then
                        language = token
                    elseif token == "screen" or token == "print" then
                        output = token
                    end
                end
            end
        end
    end

    return language, output
end

local function documentTitle(course)
    local language = classSettings(course)
    return language == "danish" and "Øvelser" or "Exercises"
end

local function notApplicableText(course)
    local language = classSettings(course)
    return language == "danish" and "Ikke relevant" or "Not applicable"
end

local function classOptions(course)
    local language, output = classSettings(course)
    return table.concat({ language, output, "final" }, ",")
end

local function ensureDirectory(path, label)
    local mode = pathMode(path)

    if mode == "directory" then
        return true, false
    end

    if mode ~= nil then
        return nil, label .. " exists but is not a directory: " .. path
    end

    local ok, result = pcall(hs.fs.mkdir, path)

    if not ok or result ~= true then
        return nil, "Could not create " .. label .. ": " .. path
    end

    return true, true
end

function Exercises.isProvisioned(course)
    if not courseIsValid(course) then
        return false
    end

    return pathMode(course.exercises.root) == "directory"
        and pathMode(course.exercises.master) == "file"
        and pathMode(course.exercises.entries) == "directory"
        and pathMode(course.exercises.figures) == "directory"
end

function Exercises.numberText(number)
    if type(number) ~= "number" or number < 1 or number % 1 ~= 0 then
        return nil, "Exercise number must be a positive integer."
    end

    return string.format("%02d", number)
end

function Exercises.filename(number)
    local numberText, err = Exercises.numberText(number)

    if not numberText then
        return nil, err
    end

    return "ex_" .. numberText .. ".tex"
end

function Exercises.renderMaster(course)
    if not courseIsValid(course) then
        return nil, "Course does not contain valid exercise paths/metadata."
    end

    local title = documentTitle(course)

    return table.concat({
        string.format("\\documentclass[%s]{noahassignment}", classOptions(course)),
        "",
        "\\addbibresource{../references/references.bib}",
        "",
        string.format("\\title{%s}", title),
        "",
        "\\documentsetup{",
        string.format("  course={%s},", course.name),
        string.format("  course-code={%s},", course.code),
        string.format("  course-short={%s},", course.shortName),
        string.format("  running-title={%s},", title),
        "  instructor={},",
        string.format("  semester={%s},", course.semesterName),
        string.format("  submission-date={%s},", notApplicableText(course)),
        "  submission-date-iso={},",
        "  problem-numbering=manual,",
        "  subproblem-numbering=letters,",
        "  toc-subproblems=true",
        "}",
        "",
        "\\begin{document}",
        "",
        "\\tableofcontents",
        "",
        Exercises.MANAGED_BEGIN,
        "",
        Exercises.MANAGED_END,
        "",
        "\\printbibliography",
        "",
        "\\end{document}",
        "",
    }, "\n")
end

function Exercises.render(number)
    local numberText, numberErr = Exercises.numberText(number)

    if not numberText then
        return nil, numberErr
    end

    return table.concat({
        "% !TeX root = ../master.tex",
        "",
        string.format("\\begin{problem}{%d}", number),
        "",
        "\\end{problem}",
        "",
    }, "\n")
end

function Exercises.list(course)
    if not courseIsValid(course) then
        return nil, "Course does not contain valid exercise paths/metadata."
    end

    if pathMode(course.exercises.entries) ~= "directory" then
        return nil, "Exercise directory is missing: " .. course.exercises.entries
    end

    local exercises = {}
    local ok, scanErr = pcall(function()
        for entry in hs.fs.dir(course.exercises.entries) do
            local numberText = entry:match("^ex_(%d%d+)%.tex$")

            if numberText then
                local path = Util.joinPath(course.exercises.entries, entry)

                if pathMode(path) == "file" then
                    table.insert(exercises, {
                        number = tonumber(numberText),
                        numberText = numberText,
                        filename = entry,
                        path = path,
                    })
                end
            end
        end
    end)

    if not ok then
        return nil,
            "Could not scan exercise directory "
                .. course.exercises.entries
                .. ": "
                .. tostring(scanErr)
    end

    table.sort(exercises, function(a, b)
        if a.number == b.number then
            return a.filename < b.filename
        end

        return a.number < b.number
    end)

    return exercises
end

function Exercises.nextNumber(course)
    local exercises, err = Exercises.list(course)

    if not exercises then
        return nil, err
    end

    local highest = 0

    for _, exercise in ipairs(exercises) do
        if exercise.number > highest then
            highest = exercise.number
        end
    end

    return highest + 1
end

local function addInputToMaster(course, exercise)
    if pathMode(course.exercises.master) ~= "file" then
        return nil, "exercises/master.tex is missing: " .. course.exercises.master
    end

    local contents, readErr = Util.readFile(course.exercises.master)

    if not contents then
        return nil,
            "Could not read exercises/master.tex: " .. tostring(readErr)
    end

    local beginStart, beginEnd = contents:find(
        Exercises.MANAGED_BEGIN,
        1,
        true
    )

    if not beginStart then
        return nil,
            "exercises/master.tex is missing " .. Exercises.MANAGED_BEGIN .. "."
    end

    local endStart = contents:find(
        Exercises.MANAGED_END,
        beginEnd + 1,
        true
    )

    if not endStart then
        return nil,
            "exercises/master.tex is missing " .. Exercises.MANAGED_END .. "."
    end

    local stem = exercise.filename:gsub("%.tex$", "")
    local inputLine = "\\input{exercises/" .. stem .. "}"
    local managedRegion = contents:sub(beginEnd + 1, endStart - 1)

    if managedRegion:find(inputLine, 1, true) then
        return contents, false
    end

    local beforeEnd = contents:sub(1, endStart - 1)

    if beforeEnd:sub(-1) ~= "\n" then
        beforeEnd = beforeEnd .. "\n"
    end

    beforeEnd = beforeEnd:gsub("[ \t]*\n[ \t]*\n+$", "\n")

    local updated = beforeEnd
        .. inputLine
        .. "\n\n"
        .. contents:sub(endStart)

    return updated, true
end

function Exercises.provision(course)
    if not courseIsValid(course) then
        return nil, "Course does not contain valid exercise paths/metadata."
    end

    if pathMode(course.root) ~= "directory" then
        return nil, "Course root is missing: " .. tostring(course.root)
    end

    local created = {}

    for _, directory in ipairs({
        { path = course.exercises.root, label = "exercises folder" },
        { path = course.exercises.entries, label = "exercise files folder" },
        { path = course.exercises.figures, label = "exercise figures folder" },
    }) do
        local ok, wasCreatedOrErr = ensureDirectory(directory.path, directory.label)

        if not ok then
            return nil, wasCreatedOrErr
        end

        if wasCreatedOrErr then
            table.insert(created, directory.path)
        end
    end

    local masterMode = pathMode(course.exercises.master)
    local masterCreated = false

    if masterMode == nil then
        local contents, renderErr = Exercises.renderMaster(course)

        if not contents then
            return nil, renderErr
        end

        local wrote, writeErr = Util.writeFileAtomic(
            course.exercises.master,
            contents
        )

        if not wrote then
            return nil,
                "Could not create exercises/master.tex: " .. tostring(writeErr)
        end

        masterCreated = true
    elseif masterMode ~= "file" then
        return nil,
            "exercises/master.tex exists but is not a regular file: "
                .. course.exercises.master
    end

    return {
        course = course,
        master = course.exercises.master,
        createdDirectories = created,
        masterCreated = masterCreated,
        provisioned = Exercises.isProvisioned(course),
    }
end

function Exercises.create(course, options)
    options = options or {}

    if not courseIsValid(course) then
        return nil, "Course does not contain valid exercise paths/metadata."
    end

    if not Exercises.isProvisioned(course) then
        return nil,
            "Exercises are not provisioned for "
                .. (course.shortName or course.name or course.id)
                .. ". Use Add Exercises first."
    end

    local number = options.number

    if number == nil then
        local nextNumber, nextErr = Exercises.nextNumber(course)

        if not nextNumber then
            return nil, nextErr
        end

        number = nextNumber
    end

    local filename, filenameErr = Exercises.filename(number)

    if not filename then
        return nil, filenameErr
    end

    local target = Util.joinPath(course.exercises.entries, filename)

    if pathMode(target) ~= nil then
        return nil, "Refusing to overwrite existing exercise: " .. target
    end

    local rendered, renderErr = Exercises.render(number)

    if not rendered then
        return nil, renderErr
    end

    local exercise = {
        number = number,
        numberText = assert(Exercises.numberText(number)),
        filename = filename,
        path = target,
    }

    local updatedMaster, masterChangedOrErr = addInputToMaster(course, exercise)

    if not updatedMaster then
        return nil, masterChangedOrErr
    end

    local wroteExercise, exerciseErr = Util.writeFileAtomic(target, rendered)

    if not wroteExercise then
        return nil, "Could not create " .. target .. ": " .. tostring(exerciseErr)
    end

    if masterChangedOrErr then
        local wroteMaster, masterErr = Util.writeFileAtomic(
            course.exercises.master,
            updatedMaster
        )

        if not wroteMaster then
            pcall(os.remove, target)
            return nil,
                "Could not update exercises/master.tex: " .. tostring(masterErr)
        end
    end

    return exercise
end

return Exercises

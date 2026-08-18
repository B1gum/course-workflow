local Assignments = {}

local Util = require("course.util")

local function courseIsValid(course)
    return type(course) == "table"
        and type(course.assignments) == "table"
        and Util.isNonEmptyString(course.assignments.root)
        and Util.isNonEmptyString(course.name)
        and Util.isNonEmptyString(course.shortName)
        and Util.isNonEmptyString(course.code)
        and Util.isNonEmptyString(course.semesterName)
end

local function pathMode(path)
    return hs.fs.attributes(path, "mode")
end

local function classOptions(course)
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

    return table.concat({ language, output, "final" }, ",")
end

function Assignments.numberText(number)
    if type(number) ~= "number" or number < 1 or number % 1 ~= 0 then
        return nil, "Assignment number must be a positive integer."
    end

    return string.format("%02d", number)
end

function Assignments.filename(number)
    local numberText, err = Assignments.numberText(number)

    if not numberText then
        return nil, err
    end

    return "assignment_" .. numberText .. ".tex"
end

function Assignments.list(course)
    if not courseIsValid(course) then
        return nil, "Course does not contain valid assignment paths/metadata."
    end

    if pathMode(course.assignments.root) ~= "directory" then
        return nil, "Assignment directory is missing: " .. course.assignments.root
    end

    local assignments = {}
    local ok, scanErr = pcall(function()
        for entry in hs.fs.dir(course.assignments.root) do
            local numberText = entry:match("^assignment_(%d%d+)%.tex$")

            if numberText then
                local path = Util.joinPath(course.assignments.root, entry)

                if pathMode(path) == "file" then
                    table.insert(assignments, {
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
            "Could not scan assignment directory "
                .. course.assignments.root
                .. ": "
                .. tostring(scanErr)
    end

    table.sort(assignments, function(a, b)
        if a.number == b.number then
            return a.filename < b.filename
        end

        return a.number < b.number
    end)

    return assignments
end

function Assignments.nextNumber(course)
    local assignments, err = Assignments.list(course)

    if not assignments then
        return nil, err
    end

    local highest = 0

    for _, assignment in ipairs(assignments) do
        if assignment.number > highest then
            highest = assignment.number
        end
    end

    return highest + 1
end

function Assignments.render(course, number, title)
    if not courseIsValid(course) then
        return nil, "Course does not contain valid assignment paths/metadata."
    end

    local numberText, numberErr = Assignments.numberText(number)

    if not numberText then
        return nil, numberErr
    end

    if not Util.isNonEmptyString(title) then
        return nil, "Assignment title must be a non-empty string."
    end

    title = Util.trim(title)

    if title:find("[\r\n]") then
        return nil, "Assignment title must be a single line."
    end

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
        "  % Fill these when the submission date is known.",
        "  submission-date={},",
        "  submission-date-iso={},",
        "  problem-numbering=automatic,",
        "  subproblem-numbering=letters,",
        "  toc-subproblems=true",
        "}",
        "",
        "\\begin{document}",
        "",
        "\\frontmatter",
        "\\maketitle",
        "\\tableofcontents",
        "",
        "\\mainmatter",
        "",
        "\\begin{problem}",
        "",
        "\\end{problem}",
        "",
        "\\printbibliography",
        "",
        "\\end{document}",
        "",
    }, "\n")
end

function Assignments.create(course, options)
    options = options or {}

    if not courseIsValid(course) then
        return nil, "Course does not contain valid assignment paths/metadata."
    end

    if pathMode(course.assignments.root) ~= "directory" then
        return nil, "Assignment directory is missing: " .. course.assignments.root
    end

    local number = options.number

    if number == nil then
        local nextNumber, nextErr = Assignments.nextNumber(course)

        if not nextNumber then
            return nil, nextErr
        end

        number = nextNumber
    end

    local filename, filenameErr = Assignments.filename(number)

    if not filename then
        return nil, filenameErr
    end

    local target = Util.joinPath(course.assignments.root, filename)

    if pathMode(target) ~= nil then
        return nil, "Refusing to overwrite existing assignment: " .. target
    end

    local title = options.title
    local rendered, renderErr = Assignments.render(course, number, title)

    if not rendered then
        return nil, renderErr
    end

    local wrote, writeErr = Util.writeFileAtomic(target, rendered)

    if not wrote then
        return nil, "Could not create " .. target .. ": " .. tostring(writeErr)
    end

    return {
        number = number,
        numberText = assert(Assignments.numberText(number)),
        filename = filename,
        path = target,
        title = Util.trim(title),
    }
end

return Assignments

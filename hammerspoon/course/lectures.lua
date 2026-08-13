local Lectures = {}

local Util = require("course.util")

Lectures.MANAGED_BEGIN = "% WORKFLOW:LECTURES-BEGIN"
Lectures.MANAGED_END = "% WORKFLOW:LECTURES-END"

local function courseIsValid(course)
    return type(course) == "table"
        and type(course.notes) == "table"
        and Util.isNonEmptyString(course.notes.lectures)
        and Util.isNonEmptyString(course.notes.master)
end

local function pathMode(path)
    return hs.fs.attributes(path, "mode")
end

local function stripBraces(value)
    if type(value) ~= "string" or #value < 2 then
        return value
    end

    return value:sub(2, -2)
end

local function parseLectureCommand(contents)
    if type(contents) ~= "string" then
        return nil
    end

    -- Current noahnotes syntax:
    --   \lecture[optional short title]{number}{YYYY-MM-DD}{title}
    -- The %b{}/%b[] patterns preserve balanced nested braces in titles.
    local numberArg, dateArg, titleArg = contents:match(
        "\\lecture%s*%b[]%s*(%b{})%s*(%b{})%s*(%b{})"
    )

    if not numberArg then
        numberArg, dateArg, titleArg = contents:match(
            "\\lecture%s*(%b{})%s*(%b{})%s*(%b{})"
        )
    end

    -- Compatibility with the older implementation-plan spelling. We never
    -- generate \lec, but recognizing it makes the chooser useful for any old
    -- lecture files the user may already have.
    if not numberArg then
        numberArg, dateArg, titleArg = contents:match(
            "\\lec%s*(%b{})%s*(%b{})%s*(%b{})"
        )
    end

    if not numberArg then
        return nil
    end

    local number = tonumber(Util.trim(stripBraces(numberArg) or ""))

    return {
        number = number,
        date = Util.trim(stripBraces(dateArg) or ""),
        title = Util.trim(stripBraces(titleArg) or ""),
    }
end

function Lectures.numberText(number)
    if type(number) ~= "number" or number < 1 or number % 1 ~= 0 then
        return nil, "Lecture number must be a positive integer."
    end

    return string.format("%02d", number)
end

function Lectures.filename(number)
    local numberText, err = Lectures.numberText(number)

    if not numberText then
        return nil, err
    end

    return "lec_" .. numberText .. ".tex"
end

function Lectures.metadataFromFile(path)
    local contents, err = Util.readFile(path)

    if not contents then
        return nil, "Could not read lecture file " .. path .. ": " .. tostring(err)
    end

    return parseLectureCommand(contents)
end

function Lectures.list(course)
    if not courseIsValid(course) then
        return nil, "Course does not contain valid notes paths."
    end

    if pathMode(course.notes.lectures) ~= "directory" then
        return nil, "Lecture directory is missing: " .. course.notes.lectures
    end

    local lectures = {}
    local ok, scanErr = pcall(function()
        for entry in hs.fs.dir(course.notes.lectures) do
            local numberText = entry:match("^lec_(%d%d+)%.tex$")

            if numberText then
                local number = tonumber(numberText)
                local path = Util.joinPath(course.notes.lectures, entry)

                if pathMode(path) == "file" then
                    local metadata = Lectures.metadataFromFile(path) or {}

                    table.insert(lectures, {
                        number = number,
                        numberText = numberText,
                        filename = entry,
                        path = path,
                        date = metadata.date,
                        title = metadata.title,
                    })
                end
            end
        end
    end)

    if not ok then
        return nil,
            "Could not scan lecture directory "
                .. course.notes.lectures
                .. ": "
                .. tostring(scanErr)
    end

    table.sort(lectures, function(a, b)
        if a.number == b.number then
            return a.filename < b.filename
        end

        return a.number < b.number
    end)

    return lectures
end

function Lectures.nextNumber(course)
    local lectures, err = Lectures.list(course)

    if not lectures then
        return nil, err
    end

    local highest = 0

    for _, lecture in ipairs(lectures) do
        if lecture.number > highest then
            highest = lecture.number
        end
    end

    return highest + 1
end

function Lectures.render(number, date, title)
    local numberText, numberErr = Lectures.numberText(number)

    if not numberText then
        return nil, numberErr
    end

    if not Util.isNonEmptyString(date) then
        return nil, "Lecture date must be a non-empty string."
    end

    if not Util.isNonEmptyString(title) then
        return nil, "Lecture title must be a non-empty string."
    end

    title = Util.trim(title)

    if title:find("[\r\n]") then
        return nil, "Lecture title must be a single line."
    end

    -- Keep each lecture rooted at the canonical notes master for VimTeX while
    -- still leaving the lecture file itself tiny and readable.
    return table.concat({
        "% !TeX root = ../master.tex",
        "",
        string.format(
            "\\lecture{%d}{%s}{%s}",
            number,
            Util.trim(date),
            title
        ),
        "",
    }, "\n")
end

local function addInputToMaster(course, lecture)
    if pathMode(course.notes.master) ~= "file" then
        return nil, "notes/master.tex is missing: " .. course.notes.master
    end

    local contents, readErr = Util.readFile(course.notes.master)

    if not contents then
        return nil,
            "Could not read notes/master.tex: " .. tostring(readErr)
    end

    local beginStart, beginEnd = contents:find(
        Lectures.MANAGED_BEGIN,
        1,
        true
    )

    if not beginStart then
        return nil,
            "notes/master.tex is missing " .. Lectures.MANAGED_BEGIN .. "."
    end

    local endStart = contents:find(
        Lectures.MANAGED_END,
        beginEnd + 1,
        true
    )

    if not endStart then
        return nil,
            "notes/master.tex is missing " .. Lectures.MANAGED_END .. "."
    end

    local stem = lecture.filename:gsub("%.tex$", "")
    local inputLine = "\\input{lectures/" .. stem .. "}"
    local managedRegion = contents:sub(beginEnd + 1, endStart - 1)

    if managedRegion:find(inputLine, 1, true) then
        return contents, false
    end

    local beforeEnd = contents:sub(1, endStart - 1)

    if beforeEnd:sub(-1) ~= "\n" then
        beforeEnd = beforeEnd .. "\n"
    end

    -- Collapse only the blank space immediately before the end marker so the
    -- managed input list stays compact. Academic content outside the managed
    -- region is left byte-for-byte unchanged.
    beforeEnd = beforeEnd:gsub("[ \t]*\n[ \t]*\n+$", "\n")

    local updated = beforeEnd
        .. inputLine
        .. "\n\n"
        .. contents:sub(endStart)

    return updated, true
end

function Lectures.create(course, options)
    options = options or {}

    if not courseIsValid(course) then
        return nil, "Course does not contain valid notes paths."
    end

    if pathMode(course.notes.lectures) ~= "directory" then
        return nil, "Lecture directory is missing: " .. course.notes.lectures
    end

    local number = options.number

    if number == nil then
        local nextNumber, nextErr = Lectures.nextNumber(course)

        if not nextNumber then
            return nil, nextErr
        end

        number = nextNumber
    end

    local filename, filenameErr = Lectures.filename(number)

    if not filename then
        return nil, filenameErr
    end

    local target = Util.joinPath(course.notes.lectures, filename)

    if pathMode(target) ~= nil then
        return nil, "Refusing to overwrite existing lecture: " .. target
    end

    local date = options.date or os.date("%Y-%m-%d")
    local title = options.title
    local rendered, renderErr = Lectures.render(number, date, title)

    if not rendered then
        return nil, renderErr
    end

    local lecture = {
        number = number,
        numberText = assert(Lectures.numberText(number)),
        filename = filename,
        path = target,
        date = date,
        title = Util.trim(title),
    }

    -- Validate and prepare the canonical master update before creating either
    -- file. This avoids producing an orphan lecture when the markers are
    -- missing or master.tex is otherwise unreadable.
    local updatedMaster, masterChangedOrErr = addInputToMaster(course, lecture)

    if not updatedMaster then
        return nil, masterChangedOrErr
    end

    local wroteLecture, lectureErr = Util.writeFileAtomic(target, rendered)

    if not wroteLecture then
        return nil, "Could not create " .. target .. ": " .. tostring(lectureErr)
    end

    if masterChangedOrErr then
        local wroteMaster, masterErr = Util.writeFileAtomic(
            course.notes.master,
            updatedMaster
        )

        if not wroteMaster then
            -- Best-effort rollback: the master was not changed, so remove the
            -- just-created unreferenced lecture rather than leave half a
            -- completed New Lecture operation behind.
            pcall(os.remove, target)
            return nil,
                "Could not update notes/master.tex: " .. tostring(masterErr)
        end
    end

    return lecture
end

return Lectures

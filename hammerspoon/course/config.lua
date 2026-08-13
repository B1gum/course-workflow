local Config = {}

local Util = require("course.util")
local State = require("course.state")

local HOME = os.getenv("HOME")

Config.ROOT = HOME .. "/.config/course-workflow"
Config.GLOBAL_CONFIG_PATH = Config.ROOT .. "/config.json"
Config.SEMESTERS_ROOT = Config.ROOT .. "/semesters"

local REQUIRED_GLOBAL_STRINGS = {
    "universityRoot",
    "skimBundleId",
    "itermBundleId",
    "safariBundleId",
    "matlabBundleId",
}

local REQUIRED_COURSE_STRINGS = {
    "id",
    "name",
    "shortName",
    "code",
    "slug",
    "courseUrl",
}

local function requireString(object, key, label)
    if not Util.isNonEmptyString(object[key]) then
        return nil, label .. " has no valid " .. key .. "."
    end

    object[key] = Util.trim(object[key])
    return true
end

local function validateGlobal(global)
    for _, key in ipairs(REQUIRED_GLOBAL_STRINGS) do
        local ok, err = requireString(global, key, "Global config")

        if not ok then
            return nil, err
        end
    end

    global.universityRoot = Util.normalizePath(global.universityRoot)

    if not global.universityRoot then
        return nil, "Global config has no valid universityRoot."
    end

    return true
end

local function validateSemester(semester, expectedId)
    local ok, err = requireString(semester, "id", "Semester config")

    if not ok then
        return nil, err
    end

    ok, err = requireString(semester, "name", "Semester " .. semester.id)

    if not ok then
        return nil, err
    end

    if semester.id ~= expectedId then
        return nil,
            string.format(
                'Semester config ID "%s" does not match selected semester "%s".',
                semester.id,
                expectedId
            )
    end

    if type(semester.courses) ~= "table" then
        return nil, 'Semester "' .. semester.id .. '" has no valid courses array.'
    end

    local seen = {}

    for index, courseId in ipairs(semester.courses) do
        if not Util.isNonEmptyString(courseId) then
            return nil,
                string.format(
                    'Semester "%s" has an invalid course ID at index %d.',
                    semester.id,
                    index
                )
        end

        courseId = Util.trim(courseId)
        semester.courses[index] = courseId

        if seen[courseId] then
            return nil,
                string.format(
                    'Semester "%s" lists course "%s" more than once.',
                    semester.id,
                    courseId
                )
        end

        seen[courseId] = true
    end

    return true
end

local VALID_TIMETABLE_DAYS = {
    monday = true,
    tuesday = true,
    wednesday = true,
    thursday = true,
    friday = true,
    saturday = true,
    sunday = true,
}

local VALID_TIMETABLE_BOUNDARIES = {
    [8] = true,
    [10] = true,
    [12] = true,
    [14] = true,
    [16] = true,
}

local function validateTimetable(raw)
    if raw.timetable == nil then
        -- Backwards compatibility with course JSON created before the
        -- timetable-based Level D resolver. Such courses simply have no
        -- automatic timetable context until a timetable is added.
        raw.timetable = {}
    end

    if type(raw.timetable) ~= "table" then
        return nil, 'Course "' .. raw.id .. '" has no valid timetable array.'
    end

    local normalized = {}
    local byDay = {}

    for index, slot in ipairs(raw.timetable) do
        if type(slot) ~= "table" then
            return nil, string.format(
                'Course "%s" has an invalid timetable slot at index %d.',
                raw.id,
                index
            )
        end

        local day = slot.day

        if not Util.isNonEmptyString(day) then
            return nil, string.format(
                'Course "%s" timetable slot %d has no valid day.',
                raw.id,
                index
            )
        end

        day = Util.trim(day):lower()

        if not VALID_TIMETABLE_DAYS[day] then
            return nil, string.format(
                'Course "%s" timetable slot %d has invalid day "%s".',
                raw.id,
                index,
                day
            )
        end

        local startHour = slot.start
        local endHour = slot["end"]

        if type(startHour) ~= "number" or startHour % 1 ~= 0
            or not VALID_TIMETABLE_BOUNDARIES[startHour] then

            return nil, string.format(
                'Course "%s" timetable slot %d has invalid start time.',
                raw.id,
                index
            )
        end

        if type(endHour) ~= "number" or endHour % 1 ~= 0
            or not VALID_TIMETABLE_BOUNDARIES[endHour] then

            return nil, string.format(
                'Course "%s" timetable slot %d has invalid end time.',
                raw.id,
                index
            )
        end

        local duration = endHour - startHour

        if duration ~= 2 and duration ~= 4 then
            return nil, string.format(
                'Course "%s" timetable slot %d must last exactly 2 or 4 hours.',
                raw.id,
                index
            )
        end

        byDay[day] = byDay[day] or {}

        for _, existing in ipairs(byDay[day]) do
            if startHour < existing["end"] and endHour > existing.start then
                return nil, string.format(
                    'Course "%s" has overlapping timetable slots on %s.',
                    raw.id,
                    day
                )
            end
        end

        local normalizedSlot = {
            day = day,
            start = startHour,
            ["end"] = endHour,
        }

        table.insert(byDay[day], normalizedSlot)
        table.insert(normalized, normalizedSlot)
    end

    raw.timetable = normalized
    return true
end

local function validateCourse(raw, expectedId)
    for _, key in ipairs(REQUIRED_COURSE_STRINGS) do
        local ok, err = requireString(raw, key, 'Course "' .. expectedId .. '"')

        if not ok then
            return nil, err
        end
    end

    if raw.id ~= expectedId then
        return nil,
            string.format(
                'Course file "%s.json" contains id "%s".',
                expectedId,
                raw.id
            )
    end

    if raw.slug ~= raw.id then
        return nil,
            string.format(
                'Course "%s" must have identical id and slug.',
                raw.id
            )
    end

    if not raw.courseUrl:match("^https?://") then
        return nil, 'Course "' .. raw.id .. '" has an invalid courseUrl.'
    end

    local timetableOk, timetableErr = validateTimetable(raw)

    if not timetableOk then
        return nil, timetableErr
    end

    if raw.book ~= nil then
        if type(raw.book) ~= "table"
            or not Util.isNonEmptyString(raw.book.source) then

            return nil, 'Course "' .. raw.id .. '" has an invalid book configuration.'
        end

        raw.book.source = Util.normalizePath(raw.book.source) or Util.trim(raw.book.source)
    end

    if raw.zotero ~= nil then
        if type(raw.zotero) ~= "table"
            or not Util.isNonEmptyString(raw.zotero.collection) then

            return nil, 'Course "' .. raw.id .. '" has an invalid zotero configuration.'
        end

        raw.zotero.collection = Util.trim(raw.zotero.collection)
    end

    return true
end

local function resolveCourse(raw, global, semester)
    local root = Util.joinPath(
        global.universityRoot,
        semester.id,
        raw.slug
    )

    root = Util.normalizePath(root) or root

    local course = {
        id = raw.id,
        name = raw.name,
        shortName = raw.shortName,
        code = raw.code,
        slug = raw.slug,
        courseUrl = raw.courseUrl,
        timetable = {},
        zotero = raw.zotero,

        semesterId = semester.id,
        semesterName = semester.name,

        root = root,
    }

    for _, slot in ipairs(raw.timetable or {}) do
        table.insert(course.timetable, {
            day = slot.day,
            start = slot.start,
            ["end"] = slot["end"],
        })
    end

    course.notes = {
        root = Util.joinPath(root, "notes"),
        master = Util.joinPath(root, "notes", "master.tex"),
        lectures = Util.joinPath(root, "notes", "lectures"),
        figures = Util.joinPath(root, "notes", "figures"),
        build = Util.joinPath(root, "notes", ".build"),
    }

    course.assignments = {
        root = Util.joinPath(root, "assignments"),
        figures = Util.joinPath(root, "assignments", "figures"),
    }

    course.matlab = Util.joinPath(root, "matlab")
    course.literature = Util.joinPath(root, "literature")
    course.book = Util.joinPath(root, "literature", "book.pdf")
    course.references = Util.joinPath(root, "references")

    course.bookSource = raw.book and raw.book.source or nil

    return course
end

function Config.loadGlobal()
    local global, err = Util.readJson(Config.GLOBAL_CONFIG_PATH)

    if not global then
        return nil, err
    end

    local ok, validationErr = validateGlobal(global)

    if not ok then
        return nil, validationErr
    end

    return global
end

local function validateCourseTimetableConflicts(courses)
    local occupied = {}

    for _, course in ipairs(courses or {}) do
        for _, slot in ipairs(course.timetable or {}) do
            occupied[slot.day] = occupied[slot.day] or {}

            for _, existing in ipairs(occupied[slot.day]) do
                if slot.start < existing.slot["end"]
                    and slot["end"] > existing.slot.start then

                    return nil, string.format(
                        'Timetable conflict on %s: "%s" %02d-%02d overlaps "%s" %02d-%02d.',
                        slot.day,
                        existing.course.name,
                        existing.slot.start,
                        existing.slot["end"],
                        course.name,
                        slot.start,
                        slot["end"]
                    )
                end
            end

            table.insert(occupied[slot.day], {
                course = course,
                slot = slot,
            })
        end
    end

    return true
end

function Config.loadSemester(semesterId)
    if not Util.isNonEmptyString(semesterId) then
        return nil, "No active semester selected."
    end

    semesterId = Util.trim(semesterId)

    local global, globalErr = Config.loadGlobal()

    if not global then
        return nil, globalErr
    end

    local semesterRoot = Util.joinPath(Config.SEMESTERS_ROOT, semesterId)
    local semesterPath = Util.joinPath(semesterRoot, "semester.json")

    local semester, semesterErr = Util.readJson(semesterPath)

    if not semester then
        return nil, semesterErr
    end

    local ok, validationErr = validateSemester(semester, semesterId)

    if not ok then
        return nil, validationErr
    end

    local courses = {}
    local coursesById = {}

    for _, courseId in ipairs(semester.courses) do
        local coursePath = Util.joinPath(
            semesterRoot,
            "courses",
            courseId .. ".json"
        )

        local raw, courseErr = Util.readJson(coursePath)

        if not raw then
            return nil,
                string.format(
                    'Semester "%s" references course "%s", but its config could not be loaded: %s',
                    semester.id,
                    courseId,
                    courseErr
                )
        end

        ok, validationErr = validateCourse(raw, courseId)

        if not ok then
            return nil, validationErr
        end

        local course = resolveCourse(raw, global, semester)
        course.configPath = coursePath

        table.insert(courses, course)
        coursesById[course.id] = course
    end

    local timetableOk, timetableErr = validateCourseTimetableConflicts(courses)

    if not timetableOk then
        return nil, timetableErr
    end

    return {
        root = Config.ROOT,
        global = global,
        semester = semester,
        semesterRoot = semesterRoot,
        semesterConfigPath = semesterPath,
        courses = courses,
        coursesById = coursesById,
    }
end

function Config.load()
    return Config.loadSemester(State.getActiveSemester())
end

return Config

local Registry = {}

local Config = require("course.config")
local Util = require("course.util")

Registry._snapshot = nil

local function ensureLoaded()
    if Registry._snapshot then
        return Registry._snapshot
    end

    local ok, err = Registry.reload()

    if not ok then
        return nil, err
    end

    return Registry._snapshot
end

function Registry.reload()
    local loaded, err = Config.load()

    if not loaded then
        return nil, err
    end

    -- Replace the registry only after a complete successful load.
    Registry._snapshot = loaded
    return true
end

function Registry.clear()
    Registry._snapshot = nil
end

function Registry.allCourses()
    local snapshot, err = ensureLoaded()

    if not snapshot then
        return nil, err
    end

    return Util.copyArray(snapshot.courses)
end

function Registry.getCourse(id)
    if not Util.isNonEmptyString(id) then
        return nil
    end

    local snapshot, err = ensureLoaded()

    if not snapshot then
        return nil, err
    end

    return snapshot.coursesById[Util.trim(id)]
end

function Registry.getActiveSemester()
    local snapshot, err = ensureLoaded()

    if not snapshot then
        return nil, err
    end

    return snapshot.semester
end

function Registry.courseFromPath(path)
    local normalized = Util.normalizePath(path)

    if not normalized then
        return nil
    end

    local snapshot, err = ensureLoaded()

    if not snapshot then
        return nil, err
    end

    for _, course in ipairs(snapshot.courses) do
        if Util.isPathWithin(normalized, course.root) then
            return course
        end
    end

    return nil
end

function Registry.snapshot()
    return ensureLoaded()
end

return Registry

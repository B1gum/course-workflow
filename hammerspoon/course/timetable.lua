local Timetable = {}

local Util = require("course.util")

Timetable.DAY_ALIASES = {
    mon = "monday",
    monday = "monday",
    man = "monday",
    mandag = "monday",

    tue = "tuesday",
    tues = "tuesday",
    tuesday = "tuesday",
    tir = "tuesday",
    tirsdag = "tuesday",

    wed = "wednesday",
    wednesday = "wednesday",
    ons = "wednesday",
    onsdag = "wednesday",

    thu = "thursday",
    thur = "thursday",
    thurs = "thursday",
    thursday = "thursday",
    tor = "thursday",
    torsdag = "thursday",

    fri = "friday",
    friday = "friday",
    fre = "friday",
    fredag = "friday",

    sat = "saturday",
    saturday = "saturday",
    lor = "saturday",
    lordag = "saturday",

    sun = "sunday",
    sunday = "sunday",
    son = "sunday",
    sondag = "sunday",
}

Timetable.BOUNDARIES = {
    [8] = true,
    [10] = true,
    [12] = true,
    [14] = true,
    [16] = true,
}

Timetable.DAY_LABELS = {
    monday = "Mon",
    tuesday = "Tue",
    wednesday = "Wed",
    thursday = "Thu",
    friday = "Fri",
    saturday = "Sat",
    sunday = "Sun",
}

local function overlaps(a, b)
    return a.day == b.day
        and a.start < b["end"]
        and a["end"] > b.start
end

function Timetable.parse(value)
    local slots = {}
    value = Util.trim(value or "")

    if value == "" then
        return slots
    end

    local byDay = {}

    for rawSlot in value:gmatch("[^;]+") do
        rawSlot = Util.trim(rawSlot)

        local rawDay, rawStart, rawEnd = rawSlot:match(
            "^(%a+)%s+(%d%d?)%s*%-%s*(%d%d?)$"
        )

        if not rawDay then
            return nil,
                'Invalid timetable slot "'
                    .. rawSlot
                    .. '". Use e.g. "Mon 12-16; Thu 8-10".'
        end

        local day = Timetable.DAY_ALIASES[rawDay:lower()]

        if not day then
            return nil, 'Unknown timetable day "' .. rawDay .. '".'
        end

        local startHour = tonumber(rawStart)
        local endHour = tonumber(rawEnd)

        if not Timetable.BOUNDARIES[startHour]
            or not Timetable.BOUNDARIES[endHour] then

            return nil,
                "Timetable boundaries must be one of 8, 10, 12, 14, or 16."
        end

        local duration = endHour - startHour

        if duration ~= 2 and duration ~= 4 then
            return nil, "Each class must last exactly 2 or 4 hours."
        end

        local slot = {
            day = day,
            start = startHour,
            ["end"] = endHour,
        }

        byDay[day] = byDay[day] or {}

        for _, existing in ipairs(byDay[day]) do
            if overlaps(slot, existing) then
                return nil,
                    "Timetable slots inside the same course overlap on "
                        .. day
                        .. "."
            end
        end

        table.insert(byDay[day], slot)
        table.insert(slots, slot)
    end

    return slots
end

function Timetable.format(timetable)
    if type(timetable) ~= "table" or #timetable == 0 then
        return ""
    end

    local parts = {}

    for _, slot in ipairs(timetable) do
        table.insert(
            parts,
            string.format(
                "%s %02d-%02d",
                Timetable.DAY_LABELS[slot.day] or slot.day,
                slot.start,
                slot["end"]
            )
        )
    end

    return table.concat(parts, "; ")
end

function Timetable.conflicts(timetable, courses, ignoredCourseId)
    local conflicts = {}

    for _, slot in ipairs(timetable or {}) do
        for _, course in ipairs(courses or {}) do
            if course.id ~= ignoredCourseId then
                for _, existing in ipairs(course.timetable or {}) do
                    if overlaps(slot, existing) then
                        table.insert(conflicts, {
                            course = course,
                            slot = slot,
                            existing = existing,
                        })
                    end
                end
            end
        end
    end

    return conflicts
end

function Timetable.conflictSummary(conflicts, editedCourseName)
    local lines = {}

    for _, conflict in ipairs(conflicts or {}) do
        local slot = conflict.slot
        local existing = conflict.existing
        local other = conflict.course

        table.insert(
            lines,
            string.format(
                "%s %02d-%02d overlaps %s %02d-%02d (%s)",
                Timetable.DAY_LABELS[slot.day] or slot.day,
                slot.start,
                slot["end"],
                Timetable.DAY_LABELS[existing.day] or existing.day,
                existing.start,
                existing["end"],
                other.shortName or other.name or other.id
            )
        )
    end

    if #lines == 0 then
        return nil
    end

    local prefix = editedCourseName and (editedCourseName .. ":\n") or ""
    return prefix .. table.concat(lines, "\n")
end

return Timetable

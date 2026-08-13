local State = {}

local Util = require("course.util")

local PREFIX = "noah.courseWorkflow."

local KEYS = {
    activeSemester = PREFIX .. "activeSemester",
    manualCourse = PREFIX .. "manualCourse",
    timetableAutoSwitchEnabled = PREFIX .. "timetableAutoSwitchEnabled",
    -- Legacy key from the Calendar.app implementation. Read-only migration
    -- support keeps existing installations from unexpectedly flipping state.
    legacyCalendarAutoSwitchEnabled = PREFIX .. "calendarAutoSwitchEnabled",
    manualOverrideState = PREFIX .. "manualOverrideState",
}

local function get(key)
    return hs.settings.get(key)
end

local function set(key, value)
    hs.settings.set(key, value)
end

local function clear(key)
    hs.settings.clear(key)
end

function State.getActiveSemester()
    local value = get(KEYS.activeSemester)

    if Util.isNonEmptyString(value) then
        return value
    end

    return nil
end

function State.setActiveSemester(semesterId)
    if not Util.isNonEmptyString(semesterId) then
        return nil, "activeSemester must be a non-empty string."
    end

    semesterId = Util.trim(semesterId)

    local previous = State.getActiveSemester()
    set(KEYS.activeSemester, semesterId)

    -- Course-level state must never leak across semesters.
    if previous ~= semesterId then
        State.clearManualCourse()
        State.clearManualOverrideState()
    end

    return true
end

function State.clearActiveSemester()
    clear(KEYS.activeSemester)
    State.clearManualCourse()
    State.clearManualOverrideState()
end

function State.getManualCourse()
    local value = get(KEYS.manualCourse)

    if Util.isNonEmptyString(value) then
        return value
    end

    return nil
end

function State.setManualCourse(courseId)
    if not Util.isNonEmptyString(courseId) then
        return nil, "manualCourse must be a non-empty string."
    end

    set(KEYS.manualCourse, Util.trim(courseId))
    return true
end

function State.clearManualCourse()
    clear(KEYS.manualCourse)
end

function State.getTimetableAutoSwitchEnabled()
    local value = get(KEYS.timetableAutoSwitchEnabled)

    if value == nil then
        value = get(KEYS.legacyCalendarAutoSwitchEnabled)
    end

    if value == nil then
        return true
    end

    return value == true
end

function State.setTimetableAutoSwitchEnabled(enabled)
    if type(enabled) ~= "boolean" then
        return nil, "timetableAutoSwitchEnabled must be a boolean."
    end

    set(KEYS.timetableAutoSwitchEnabled, enabled)
    clear(KEYS.legacyCalendarAutoSwitchEnabled)
    return true
end

-- Compatibility aliases for old init.lua/tests/custom bindings. New code must
-- use the timetable names; no Calendar.app access remains anywhere in Level D.
State.getCalendarAutoSwitchEnabled = State.getTimetableAutoSwitchEnabled
State.setCalendarAutoSwitchEnabled = State.setTimetableAutoSwitchEnabled

function State.getManualOverrideState()
    local value = get(KEYS.manualOverrideState)

    if type(value) == "table" then
        return value
    end

    return nil
end

function State.setManualOverrideState(value)
    if value == nil then
        State.clearManualOverrideState()
        return true
    end

    if type(value) ~= "table" then
        return nil, "manualOverrideState must be a table or nil."
    end

    set(KEYS.manualOverrideState, value)
    return true
end

function State.clearManualOverrideState()
    clear(KEYS.manualOverrideState)
end

function State.clearManualContext()
    State.clearManualCourse()
    State.clearManualOverrideState()
end

function State.snapshot()
    local timetableEnabled = State.getTimetableAutoSwitchEnabled()

    return {
        activeSemester = State.getActiveSemester(),
        manualCourse = State.getManualCourse(),
        timetableAutoSwitchEnabled = timetableEnabled,
        -- Keep this mirrored field so an older rollback helper can still
        -- restore a snapshot created by this version.
        calendarAutoSwitchEnabled = timetableEnabled,
        manualOverrideState = State.getManualOverrideState(),
    }
end

return State

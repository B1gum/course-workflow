local Hotkeys = {}

local Actions = require("course.actions")
local Launcher = require("course.launcher")

Hotkeys.MODIFIERS = { "cmd", "shift" }

Hotkeys.DEFINITIONS = {
    {
        id = "launcher",
        label = "Open Launcher",
        key = "space",
        launcher = true,
    },
    {
        id = "openNotes",
        label = "Open Notes",
        key = "n",
        action = "openNotes",
    },
    {
        id = "findFigure",
        label = "Figures",
        key = "f",
        action = "findFigure",
    },
    {
        id = "openAssignments",
        label = "Open Assignments",
        key = "a",
        action = "openAssignments",
    },
    {
        id = "openMatlab",
        label = "MATLAB",
        key = "m",
        action = "openMatlab",
    },
    {
        id = "openLiterature",
        label = "Open Literature",
        key = "l",
        action = "openLiterature",
    },
    {
        id = "searchReferences",
        label = "Search References",
        key = "r",
        action = "searchReferences",
    },
    {
        id = "compileCurrent",
        label = "Compile Current",
        key = "c",
        action = "compileCurrent",
    },
}

Hotkeys._hotkeys = {}
Hotkeys._conflicts = {}
Hotkeys._runtime = nil
Hotkeys._started = false

local function defaultNotify(message)
    hs.alert.show(message)
end

local function runtimeFunction(runtime, key, fallback)
    if type(runtime) == "table" and type(runtime[key]) == "function" then
        return runtime[key]
    end

    return fallback
end

local function notify(message)
    local fn = runtimeFunction(Hotkeys._runtime, "notify", defaultNotify)
    pcall(fn, tostring(message))
end

local function defaultAssignable(modifiers, key)
    return hs.hotkey.assignable(modifiers, key)
end

local function defaultNewHotkey(modifiers, key, callback)
    local hotkey = hs.hotkey.new(modifiers, key, callback)

    if not hotkey then
        return nil, "hs.hotkey.new() returned nil."
    end

    local enabled = hotkey:enable()

    if not enabled then
        hotkey:delete()
        return nil, "Hotkey could not be enabled."
    end

    return hotkey
end

local function copyArray(values)
    local copy = {}

    for index, value in ipairs(values or {}) do
        copy[index] = value
    end

    return copy
end

function Hotkeys.invoke(definition)
    if definition.launcher then
        Launcher.toggle()
        return true
    end

    local actionName = definition.action
    local fn = Actions[actionName]

    if type(fn) ~= "function" then
        local err = 'Unknown action "' .. tostring(actionName) .. '".'
        notify(err)
        return nil, err
    end

    local result, err = fn()

    if not result then
        if err then
            notify(err)
        end
        return nil, err
    end

    return result
end

function Hotkeys.conflicts()
    return copyArray(Hotkeys._conflicts)
end

function Hotkeys.start(runtime)
    Hotkeys.stop()
    Hotkeys._runtime = runtime
    Hotkeys._conflicts = {}

    local assignable = runtimeFunction(runtime, "assignable", defaultAssignable)
    local newHotkey = runtimeFunction(runtime, "newHotkey", defaultNewHotkey)

    for _, definition in ipairs(Hotkeys.DEFINITIONS) do
        local assignableOk, canAssign = pcall(
            assignable,
            Hotkeys.MODIFIERS,
            definition.key
        )

        if not assignableOk or canAssign ~= true then
            table.insert(Hotkeys._conflicts, {
                id = definition.id,
                label = definition.label,
                key = definition.key,
                reason = assignableOk
                    and "not assignable on this Mac"
                    or tostring(canAssign),
            })
        else
            local callback = function()
                Hotkeys.invoke(definition)
            end

            local ok, hotkeyOrErr, creationErr = pcall(
                newHotkey,
                Hotkeys.MODIFIERS,
                definition.key,
                callback,
                definition
            )

            if not ok or not hotkeyOrErr then
                table.insert(Hotkeys._conflicts, {
                    id = definition.id,
                    label = definition.label,
                    key = definition.key,
                    reason = ok
                        and tostring(creationErr or "could not create hotkey")
                        or tostring(hotkeyOrErr),
                })
            else
                table.insert(Hotkeys._hotkeys, hotkeyOrErr)
            end
        end
    end

    Hotkeys._started = true

    if #Hotkeys._conflicts > 0 then
        local messages = {}

        for _, conflict in ipairs(Hotkeys._conflicts) do
            table.insert(
                messages,
                string.format(
                    "%s (%s): %s",
                    conflict.label,
                    conflict.key,
                    conflict.reason
                )
            )
        end

        if hs and hs.printf then
            hs.printf(
                "Course workflow skipped %d hotkey(s): %s",
                #Hotkeys._conflicts,
                table.concat(messages, "; ")
            )
        end
    end

    return true, Hotkeys.conflicts()
end

function Hotkeys.stop()
    for _, hotkey in ipairs(Hotkeys._hotkeys) do
        pcall(function()
            hotkey:delete()
        end)
    end

    Hotkeys._hotkeys = {}
    Hotkeys._conflicts = {}
    Hotkeys._runtime = nil
    Hotkeys._started = false
    return true
end

return Hotkeys

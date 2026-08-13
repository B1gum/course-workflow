local Tests = {}

local Actions = require("course.actions")
local Hotkeys = require("course.hotkeys")

local function fail(message)
    error(message, 2)
end

local function assertEqual(actual, expected, label)
    if actual ~= expected then
        fail(string.format(
            "%s: expected %s, got %s",
            label,
            tostring(expected),
            tostring(actual)
        ))
    end
end

local function assertTruthy(value, label)
    if not value then
        fail(label .. ": expected a truthy value")
    end
end

local function definitionById(id)
    for _, definition in ipairs(Hotkeys.DEFINITIONS) do
        if definition.id == id then
            return definition
        end
    end

    return nil
end

local function fakeHotkey(deletedCounter)
    local hotkey = { deleted = false }

    function hotkey:delete()
        if not self.deleted then
            self.deleted = true
            deletedCounter.count = deletedCounter.count + 1
        end
    end

    return hotkey
end

local function runCases()
    local cases = {}

    local function case(name, fn)
        table.insert(cases, { name = name, fn = fn })
    end

    case("default bindings use one Hyper-style layer", function()
        assertEqual(#Hotkeys.MODIFIERS, 4, "modifier count")
        assertEqual(definitionById("launcher").key, "space", "launcher key")
        assertEqual(definitionById("openNotes").key, "n", "notes key")
        assertEqual(definitionById("newFigure").key, "f", "new-figure key")
        assertEqual(definitionById("findFigure").key, "s", "find-figure key")
        assertEqual(definitionById("openAssignments").key, "a", "assignments key")
        assertEqual(definitionById("openMatlab").key, "m", "matlab key")
        assertEqual(definitionById("openLiterature").key, "l", "literature key")
        assertEqual(definitionById("compileCurrent").key, "c", "compile key")
    end)

    case("semantic hotkeys point only at central action API", function()
        for _, definition in ipairs(Hotkeys.DEFINITIONS) do
            if not definition.launcher then
                assertTruthy(definition.action, definition.id .. " action name")
                assertEqual(
                    type(Actions[definition.action]),
                    "function",
                    definition.id .. " central action"
                )
            end
        end
    end)

    case("unassignable shortcuts are skipped rather than shadowed", function()
        local created = {}
        local deleted = { count = 0 }
        local runtime = {
            assignable = function(_, key)
                return key ~= "m"
            end,
            newHotkey = function(_, key, callback)
                local hotkey = fakeHotkey(deleted)
                hotkey.key = key
                hotkey.callback = callback
                table.insert(created, hotkey)
                return hotkey
            end,
            notify = function()
                return true
            end,
        }

        local ok, conflicts = Hotkeys.start(runtime)
        assertTruthy(ok, "hotkey start")
        assertEqual(#created, #Hotkeys.DEFINITIONS - 1, "created hotkeys")
        assertEqual(#conflicts, 1, "conflict count")
        assertEqual(conflicts[1].id, "openMatlab", "conflicting binding")

        Hotkeys.stop()
        assertEqual(deleted.count, #created, "deleted hotkeys")
    end)

    case("restart deletes old hotkeys before rebinding", function()
        local created = {}
        local deleted = { count = 0 }
        local runtime = {
            assignable = function()
                return true
            end,
            newHotkey = function(_, key, callback)
                local hotkey = fakeHotkey(deleted)
                hotkey.key = key
                hotkey.callback = callback
                table.insert(created, hotkey)
                return hotkey
            end,
            notify = function()
                return true
            end,
        }

        Hotkeys.start(runtime)
        local perStart = #Hotkeys.DEFINITIONS
        assertEqual(#created, perStart, "first binding count")

        Hotkeys.start(runtime)
        assertEqual(#created, perStart * 2, "second binding count")
        assertEqual(deleted.count, perStart, "old bindings deleted")

        Hotkeys.stop()
        assertEqual(deleted.count, perStart * 2, "all bindings deleted")
    end)

    local passed = 0

    for _, testCase in ipairs(cases) do
        testCase.fn()
        passed = passed + 1
        print("✓ " .. testCase.name)
    end

    return passed, #cases
end

function Tests.run()
    local ok, resultOrError, total = xpcall(function()
        local passed, count = runCases()
        return passed, count
    end, debug.traceback)

    Hotkeys.stop()

    if not ok then
        print("✗ Hotkey tests failed")
        print(resultOrError)
        return nil, resultOrError
    end

    print(string.format("Hotkey tests passed: %d/%d", resultOrError, total))
    return true
end

return Tests
